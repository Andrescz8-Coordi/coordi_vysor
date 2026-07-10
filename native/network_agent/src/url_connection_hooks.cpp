#include "url_connection_hooks.h"

#include "socket_emitter.h"

#include <algorithm>
#include <android/log.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <jni.h>
#include <jvmti.h>
#include <mutex>
#include <string>
#include <unistd.h>
#include <unordered_map>

namespace {

constexpr const char* kTag = "CoordiNetAgent";

JavaVM* g_vm = nullptr;
jvmtiEnv* g_jvmti = nullptr;

enum TipoHook {
    kNinguno = 0,
    kOkHttpExecute = 2,
    kVolleyPerformRequest = 3,
    kVolleyExecuteRequest = 4,
    kUrlOpenConnection = 6,
    kAppJsonBody = 7,
    kRequestQueueAdd = 8,
    kVolleyOnResponse = 9,
    kOkHttpEnqueue = 10,
    kCallbackOnResponse = 11,
    kCallbackOnFailure = 12,
    kVolleyGetUrl = 13,
    kVolleyGetHeaders = 14,
};

// Datos acumulados por hilo (GetLocalObject falla en Volley AAR; captura por capas).
struct CapturaHilo {
    std::string url;
    std::string metodo;  // vacío por defecto; se llena desde hooks onMethodEntry
    std::string reqHeaders = "{}";
    std::string reqBody;
    std::string respHeaders = "{}";
    std::string respBody;
    bool activa = false;
    std::chrono::steady_clock::time_point inicio{};
};

struct ContextoPendiente {
    jobject objetivo = nullptr;
    int tipo = kNinguno;
    std::chrono::steady_clock::time_point inicio;
};

thread_local ContextoPendiente tls_pendiente;
thread_local CapturaHilo tls_cap;
// Fallback HttpURLConnection: openConnection() guarda la conexión; getResponseCode la consume.
thread_local jobject tls_conexionAbierta = nullptr;
thread_local std::chrono::steady_clock::time_point tls_conexionInicio;
thread_local int tls_statusHttpPendiente = 0;

// Config: si false, no se consume el InputStream en getInputStream (no rompe la app).
static std::atomic<bool> g_httpUrlConnectionBodyCapture{true};

// Mapa global para correlacionar OkHttp async: identityHash(RealCall) → enqueue start time.
static std::mutex g_okhttp_mutex;
static std::unordered_map<jint, std::chrono::steady_clock::time_point> g_okhttp_enqueue_start;

// Mapa global request: url → {metodo, reqBody} (transfiere entre hilo caller y hilo de red).
static std::mutex g_request_mutex;
static std::unordered_map<std::string, std::pair<std::string, std::string>> g_request_map;

// Cache de JNI para System.identityHashCode.
static jclass g_clsSystem = nullptr;
static jmethodID g_midIdentityHashCode = nullptr;

jint identidadHash(JNIEnv* env, jobject obj) {
    if (g_midIdentityHashCode == nullptr) {
        const jclass tmp = env->FindClass("java/lang/System");
        if (tmp == nullptr) { env->ExceptionClear(); return 0; }
        g_clsSystem = static_cast<jclass>(env->NewGlobalRef(tmp));
        g_midIdentityHashCode = env->GetStaticMethodID(tmp, "identityHashCode", "(Ljava/lang/Object;)I");
        if (g_midIdentityHashCode == nullptr) { env->ExceptionClear(); return 0; }
    }
    return env->CallStaticIntMethod(g_clsSystem, g_midIdentityHashCode, obj);
}

std::string escaparJson(const std::string& texto) {
    std::string salida;
    salida.reserve(texto.size() + 8);
    for (const char c : texto) {
        switch (c) {
            case '\\': salida += "\\\\"; break;
            case '"': salida += "\\\""; break;
            case '\n': salida += "\\n"; break;
            case '\r': salida += "\\r"; break;
            case '\t': salida += "\\t"; break;
            default: salida.push_back(c); break;
        }
    }
    return salida;
}

std::string jstringAStd(JNIEnv* env, jstring valor) {
    if (valor == nullptr) return {};
    const char* utf = env->GetStringUTFChars(valor, nullptr);
    if (utf == nullptr) return {};
    const std::string salida(utf);
    env->ReleaseStringUTFChars(valor, utf);
    return salida;
}

const char* metodoVolley(int codigo) {
    switch (codigo) {
        case 0: return "GET";
        case 1: return "POST";
        case 2: return "PUT";
        case 3: return "DELETE";
        case 4: return "HEAD";
        case 5: return "OPTIONS";
        case 6: return "TRACE";
        case 7: return "PATCH";
        default: return "GET";
    }
}

int64_t millisDesde(const std::chrono::steady_clock::time_point& inicio) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now() - inicio)
        .count();
}

// Límite por cuerpo para no emitir payloads gigantes por el socket.
constexpr size_t kMaxBody = 4 * 1024;
// Límite para OkHttp peekBody: si Content-Length es mayor, se trunca.
constexpr jlong kMaxPeekBody = 1024 * 1024; // 1 MB

void logErrorExtraccion(JNIEnv* env, const char* funcion, const char* campo);

// Object.toString() → std::string (limpia excepciones).
std::string objetoAString(JNIEnv* env, jobject obj) {
    if (obj == nullptr) return {};
    const jclass clase = env->GetObjectClass(obj);
    if (clase == nullptr) return {};
    const jmethodID midToString =
        env->GetMethodID(clase, "toString", "()Ljava/lang/String;");
    if (midToString == nullptr) {
        logErrorExtraccion(env, "objetoAString", "GetMethodID toString");
        env->ExceptionClear();
        return {};
    }
    const jstring s = static_cast<jstring>(env->CallObjectMethod(obj, midToString));
    if (env->ExceptionCheck()) {
        logErrorExtraccion(env, "objetoAString", "Object.toString()");
        env->ExceptionClear();
        return {};
    }
    return jstringAStd(env, s);
}

// Helper: loggea error de extracción con nombre de función y campo.
void logErrorExtraccion(JNIEnv* env, const char* funcion, const char* campo) {
    const char* tipo = "?";
    jthrowable exc = env->ExceptionOccurred();
    env->ExceptionClear();  // Limpiar antes de GetObjectClass (CheckJNI aborta si hay pendiente)
    if (exc != nullptr) {
        jclass excCls = env->GetObjectClass(exc);
        if (excCls != nullptr) {
            jmethodID midName = env->GetMethodID(excCls, "toString", "()Ljava/lang/String;");
            if (midName != nullptr) {
                jstring jTipo = static_cast<jstring>(env->CallObjectMethod(exc, midName));
                if (jTipo != nullptr) {
                    const char* utf = env->GetStringUTFChars(jTipo, nullptr);
                    if (utf != nullptr) {
                        tipo = utf;
                        __android_log_print(ANDROID_LOG_ERROR, kTag,
                            "FALLO extraccion en %s: %s - %s", funcion, campo, tipo);
                        env->ReleaseStringUTFChars(jTipo, utf);
                        env->DeleteLocalRef(jTipo);
                        env->DeleteLocalRef(excCls);
                        return;
                    }
                    env->DeleteLocalRef(jTipo);
                }
                env->ExceptionClear();
            }
            env->DeleteLocalRef(excCls);
        }
        env->ExceptionClear();
    }
    __android_log_print(ANDROID_LOG_ERROR, kTag,
        "FALLO extraccion en %s: %s - (sin excepcion pendiente)", funcion, campo);
}

// byte[] → std::string (recortado a kMaxBody).
std::string bytesAString(JNIEnv* env, jbyteArray arr) {
    if (arr == nullptr) return {};
    const jsize len = env->GetArrayLength(arr);
    if (len <= 0) return {};
    size_t n = static_cast<size_t>(len);
    bool truncado = false;
    if (n > kMaxBody) {
        n = kMaxBody;
        truncado = true;
    }
    jbyte* datos = env->GetByteArrayElements(arr, nullptr);
    if (datos == nullptr) return {};
    std::string salida(reinterpret_cast<const char*>(datos), n);
    env->ReleaseByteArrayElements(arr, datos, JNI_ABORT);
    if (truncado) salida += "…(truncado)";
    return salida;
}

// Map<?,?> → objeto JSON {"k":"v",...} con claves/valores via toString().
std::string mapAJsonObjeto(JNIEnv* env, jobject map) {
    if (map == nullptr) return "{}";
    const jclass mapCls = env->FindClass("java/util/Map");
    const jmethodID midEntrySet = env->GetMethodID(mapCls, "entrySet", "()Ljava/util/Set;");
    const jobject set = env->CallObjectMethod(map, midEntrySet);
    if (env->ExceptionCheck() || set == nullptr) {
        logErrorExtraccion(env, "mapAJsonObjeto", "Map.entrySet()");
        env->ExceptionClear();
        return "{}";
    }
    const jclass setCls = env->FindClass("java/util/Set");
    const jmethodID midIterator = env->GetMethodID(setCls, "iterator", "()Ljava/util/Iterator;");
    const jobject it = env->CallObjectMethod(set, midIterator);
    const jclass itCls = env->FindClass("java/util/Iterator");
    const jmethodID midHasNext = env->GetMethodID(itCls, "hasNext", "()Z");
    const jmethodID midNext = env->GetMethodID(itCls, "next", "()Ljava/lang/Object;");
    const jclass entryCls = env->FindClass("java/util/Map$Entry");
    const jmethodID midGetKey = env->GetMethodID(entryCls, "getKey", "()Ljava/lang/Object;");
    const jmethodID midGetValue = env->GetMethodID(entryCls, "getValue", "()Ljava/lang/Object;");
    std::string out = "{";
    bool primero = true;
    while (env->CallBooleanMethod(it, midHasNext)) {
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "mapAJsonObjeto", "Iterator.hasNext()");
            env->ExceptionClear();
            out += out.size() > 1 ? ",\"__error\":true}" : "\"__error\":true}";
            return out;
        }
        const jobject entry = env->CallObjectMethod(it, midNext);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "mapAJsonObjeto", "Iterator.next()");
            env->ExceptionClear();
            out += out.size() > 1 ? ",\"__error\":true}" : "\"__error\":true}";
            return out;
        }
        const jobject k = env->CallObjectMethod(entry, midGetKey);
        const jobject v = env->CallObjectMethod(entry, midGetValue);
        const std::string ks = objetoAString(env, k);
        const std::string vs = objetoAString(env, v);
        if (!primero) out += ",";
        primero = false;
        out += "\"" + escaparJson(ks) + "\":\"" + escaparJson(vs) + "\"";
        env->DeleteLocalRef(entry);
        env->DeleteLocalRef(k);
        env->DeleteLocalRef(v);
    }
    out += "}";
    return out;
}

// List<Header> de Volley (getName/getValue) → objeto JSON.
std::string listaHeadersAJson(JNIEnv* env, jobject list) {
    if (list == nullptr) return "{}";
    const jclass listCls = env->FindClass("java/util/List");
    const jmethodID midSize = env->GetMethodID(listCls, "size", "()I");
    const jmethodID midGet = env->GetMethodID(listCls, "get", "(I)Ljava/lang/Object;");
    const jint size = env->CallIntMethod(list, midSize);
    if (env->ExceptionCheck()) {
        logErrorExtraccion(env, "listaHeadersAJson", "List.size()");
        env->ExceptionClear();
        return "{}";
    }
    std::string out = "{";
    bool primero = true;
    for (jint i = 0; i < size; ++i) {
        const jobject h = env->CallObjectMethod(list, midGet, i);
        if (h == nullptr) continue;
        const jclass hCls = env->GetObjectClass(h);
        const jmethodID gn = env->GetMethodID(hCls, "getName", "()Ljava/lang/String;");
        const jmethodID gv = env->GetMethodID(hCls, "getValue", "()Ljava/lang/String;");
        if (gn != nullptr && gv != nullptr) {
            const jstring jn = static_cast<jstring>(env->CallObjectMethod(h, gn));
            const jstring jv = static_cast<jstring>(env->CallObjectMethod(h, gv));
            if (!primero) out += ",";
            primero = false;
            out += "\"" + escaparJson(jstringAStd(env, jn)) + "\":\"" +
                   escaparJson(jstringAStd(env, jv)) + "\"";
        } else {
            env->ExceptionClear();
        }
        env->DeleteLocalRef(h);
    }
    out += "}";
    return out;
}

void emitirFlowCompleto(
    const std::string& id,
    const std::string& metodo,
    const std::string& url,
    int status,
    const std::string& reqHeadersJson,
    const std::string& reqBody,
    const std::string& respHeadersJson,
    const std::string& respBody,
    int64_t duracionMs,
    jlong bodySize = -1,
    bool bodyTruncated = false,
    const std::string& bodyEncoding = "") {
    static std::atomic<uint64_t> contador{0};
    const uint64_t n = ++contador;
    const double ts =
        static_cast<double>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch())
                .count()) /
        1000.0;
    char tsBuf[32];
    std::snprintf(tsBuf, sizeof(tsBuf), "%.3f", ts);

    std::string json = "{";
    json += "\"id\":\"" + escaparJson(id) + "-" + std::to_string(n) + "\",";
    json += "\"method\":\"" + escaparJson(metodo) + "\",";
    json += "\"url\":\"" + escaparJson(url) + "\",";
    json += "\"status\":" + std::to_string(status) + ",";
    json += "\"reqHeaders\":" + (reqHeadersJson.empty() ? "{}" : reqHeadersJson) + ",";
    json += "\"reqBody\":\"" + escaparJson(reqBody) + "\",";
    json += "\"respHeaders\":" + (respHeadersJson.empty() ? "{}" : respHeadersJson) + ",";
    json += "\"respBody\":\"" + escaparJson(respBody) + "\",";
    json += "\"durationMs\":" + std::to_string(static_cast<long long>(duracionMs)) + ",";
    json += "\"ts\":" + std::string(tsBuf);
    if (bodySize >= 0) {
        json += ",\"bodySize\":" + std::to_string(static_cast<long long>(bodySize));
    }
    if (bodyTruncated) {
        json += ",\"bodyTruncated\":true";
    }
    if (!bodyEncoding.empty()) {
        json += ",\"bodyEncoding\":\"" + escaparJson(bodyEncoding) + "\"";
    }
    json += "}";
    emitirJson(json);

    // Log resumido a logcat (una sola línea)
    __android_log_print(ANDROID_LOG_INFO, kTag,
        "CAP %s-%llu %s %s status=%d dur=%lldms body=%zuB%s",
        id.c_str(), static_cast<unsigned long long>(n),
        metodo.c_str(), url.c_str(), status,
        static_cast<long long>(duracionMs),
        respBody.size(),
        bodyTruncated ? " truncado" : "");
}

void emitirFlow(
    const std::string& id,
    const std::string& metodo,
    const std::string& url,
    int status,
    int64_t duracionMs) {
    emitirFlowCompleto(id, metodo, url, status, "{}", "", "{}", "", duracionMs);
}

void limpiarPendiente(JNIEnv* env) {
    if (tls_pendiente.objetivo != nullptr) {
        env->DeleteGlobalRef(tls_pendiente.objetivo);
        tls_pendiente.objetivo = nullptr;
    }
    tls_pendiente.tipo = kNinguno;
}

bool firmaContiene(const char* firma, const char* fragmento) {
    return firma != nullptr && strstr(firma, fragmento) != nullptr;
}

// Cache thread_local: almacena la firma de clase del último método consultado.
// Evita repetir GetMethodDeclaringClass + GetClassSignature en detectarTipoEntrada
// cuando se llama varias veces con el mismo method (entry + exit y múltiples
// claseContiene dentro de una misma invocación).
thread_local struct {
    jmethodID method = nullptr;
    std::string firma;
} tls_cacheClase;

bool claseContiene(jvmtiEnv* jvmti, jmethodID method, const char* fragmento) {
    // Cache hit: misma method ID, usar firma guardada
    if (method == tls_cacheClase.method && !tls_cacheClase.firma.empty()) {
        return strstr(tls_cacheClase.firma.c_str(), fragmento) != nullptr;
    }
    // Cache miss: obtener firma via JVMTI
    jclass decl = nullptr;
    if (jvmti->GetMethodDeclaringClass(method, &decl) != JVMTI_ERROR_NONE) {
        return false;
    }
    char* firmaClase = nullptr;
    if (jvmti->GetClassSignature(decl, &firmaClase, nullptr) != JVMTI_ERROR_NONE) {
        return false;
    }
    const bool ok = firmaClase != nullptr && strstr(firmaClase, fragmento) != nullptr;
    // Guardar en cache para próximas claseContiene con este mismo method
    if (firmaClase != nullptr) {
        tls_cacheClase.method = method;
        tls_cacheClase.firma = firmaClase;
    }
    jvmti->Deallocate(reinterpret_cast<unsigned char*>(firmaClase));
    return ok;
}

// Extrae método, URL, headers y body de un com.android.volley.Request.
void extraerRequestVolley(
    JNIEnv* env,
    jobject request,
    std::string* metodo,
    std::string* url,
    std::string* reqHeaders,
    std::string* reqBody) {
    *metodo = "GET";
    *url = "(desconocido)";
    *reqHeaders = "{}";
    *reqBody = "";
    if (request == nullptr) return;
    const jclass clase = env->GetObjectClass(request);
    if (clase == nullptr) return;

    const jmethodID midUrl = env->GetMethodID(clase, "getUrl", "()Ljava/lang/String;");
    if (midUrl != nullptr) {
        const jstring jUrl = static_cast<jstring>(env->CallObjectMethod(request, midUrl));
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "extraerRequestVolley", "Request.getUrl()");
            env->ExceptionClear();
        } else if (jUrl != nullptr) {
            *url = jstringAStd(env, jUrl);
        }
    } else {
        logErrorExtraccion(env, "extraerRequestVolley", "GetMethodID Request.getUrl");
        env->ExceptionClear();
    }

    const jmethodID midMetodo = env->GetMethodID(clase, "getMethod", "()I");
    if (midMetodo != nullptr) {
        const int codigo = env->CallIntMethod(request, midMetodo);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "extraerRequestVolley", "Request.getMethod()");
            env->ExceptionClear();
        } else {
            *metodo = metodoVolley(codigo);
        }
    } else {
        logErrorExtraccion(env, "extraerRequestVolley", "GetMethodID Request.getMethod");
        env->ExceptionClear();
    }

    // getHeaders() puede lanzar AuthFailureError; se limpia y se sigue.
    const jmethodID midHeaders =
        env->GetMethodID(clase, "getHeaders", "()Ljava/util/Map;");
    if (midHeaders != nullptr) {
        const jobject mapa = env->CallObjectMethod(request, midHeaders);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "extraerRequestVolley", "Request.getHeaders() (AuthFailureError)");
            env->ExceptionClear();
        } else if (mapa != nullptr) {
            *reqHeaders = mapAJsonObjeto(env, mapa);
        }
    } else {
        logErrorExtraccion(env, "extraerRequestVolley", "GetMethodID Request.getHeaders");
        env->ExceptionClear();
    }
    // Fallback: campo mHeaders (Volley lo usa internamente).
    if (*reqHeaders == "{}") {
        const jfieldID fHdrs =
            env->GetFieldID(clase, "mHeaders", "Ljava/util/Map;");
        if (fHdrs != nullptr) {
            const jobject mapa = env->GetObjectField(request, fHdrs);
            if (mapa != nullptr) {
                *reqHeaders = mapAJsonObjeto(env, mapa);
                if (env->ExceptionCheck()) {
                    logErrorExtraccion(env, "extraerRequestVolley",
                        "mapAJsonObjeto mHeaders");
                    env->ExceptionClear();
                }
            }
        } else {
            logErrorExtraccion(env, "extraerRequestVolley", "GetFieldID Request.mHeaders");
            env->ExceptionClear();
        }
    }

    const jmethodID midBody = env->GetMethodID(clase, "getBody", "()[B");
    if (midBody != nullptr) {
        const jobject body = env->CallObjectMethod(request, midBody);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "extraerRequestVolley", "Request.getBody()");
            env->ExceptionClear();
        } else if (body != nullptr) {
            *reqBody = bytesAString(env, static_cast<jbyteArray>(body));
        }
    } else {
        logErrorExtraccion(env, "extraerRequestVolley", "GetMethodID Request.getBody");
        env->ExceptionClear();
    }
}

// Fusiona headers extra (p.ej. additionalHeaders de executeRequest) en JSON existente.
std::string fusionarHeadersJson(
    const std::string& baseJson, JNIEnv* env, jobject mapaExtra) {
    if (mapaExtra == nullptr) return baseJson;
    const std::string extra = mapAJsonObjeto(env, mapaExtra);
    if (extra == "{}" || extra.empty()) return baseJson;
    if (baseJson == "{}" || baseJson.empty()) return extra;
    // base={...} extra={...} → un solo objeto (sin re-parsear; concat simple).
    std::string out = baseJson;
    if (out.size() >= 2 && extra.size() >= 2) {
        out.pop_back();  // quita '}'
        out += ",";
        out += extra.substr(1);  // quita '{' del extra
    }
    return out;
}

void extraerRequestVolleyConExtras(
    JNIEnv* env,
    jobject request,
    jobject headersExtra,
    std::string* metodo,
    std::string* url,
    std::string* reqHeaders,
    std::string* reqBody) {
    extraerRequestVolley(env, request, metodo, url, reqHeaders, reqBody);
    *reqHeaders = fusionarHeadersJson(*reqHeaders, env, headersExtra);
}

// Captura completa de BasicNetwork.performRequest: Request (arg) + NetworkResponse (return).
void emitirVolleyPerformRequest(
    JNIEnv* env, jobject request, jobject networkResponse, int64_t ms) {
    __android_log_print(ANDROID_LOG_INFO, kTag,
        "VOLLEY: emitirVolleyPerformRequest llamado request=%p networkResponse=%p ms=%lld",
        static_cast<void*>(request), static_cast<void*>(networkResponse),
        static_cast<long long>(ms));
    std::string metodo, url, reqHeaders, reqBody;
    extraerRequestVolley(env, request, &metodo, &url, &reqHeaders, &reqBody);

    // Fallback: si extraerRequestVolley no pudo leer el Request (GetLocalObject
    // falló en ART), usar datos capturados desde openConnection exit.
    if ((url.empty() || url == "(desconocido)") && !tls_cap.url.empty()) {
        url = tls_cap.url;
        if (!tls_cap.metodo.empty()) metodo = tls_cap.metodo;
    }
    if (reqHeaders == "{}" && tls_cap.reqHeaders != "{}") {
        reqHeaders = tls_cap.reqHeaders;
    }

    int status = 0;
    std::string respHeaders = "{}";
    std::string respBody = "";
    if (networkResponse != nullptr) {
        env->ExceptionClear();  // safety: limpia excepción pendiente de extraerRequestVolley
        const jclass nr = env->GetObjectClass(networkResponse);
        const jfieldID fStatus = env->GetFieldID(nr, "statusCode", "I");
        if (fStatus != nullptr) {
            status = env->GetIntField(networkResponse, fStatus);
        } else {
            logErrorExtraccion(env, "emitirVolleyPerformRequest", "GetFieldID NetworkResponse.statusCode");
            env->ExceptionClear();
        }
        const jfieldID fData = env->GetFieldID(nr, "data", "[B");
        if (fData != nullptr) {
            const jobject data = env->GetObjectField(networkResponse, fData);
            respBody = bytesAString(env, static_cast<jbyteArray>(data));
        } else {
            logErrorExtraccion(env, "emitirVolleyPerformRequest", "GetFieldID NetworkResponse.data");
            env->ExceptionClear();
        }
        // Volley clásico: campo Map headers; Volley 1.2+: List<Header> allHeaders.
        const jfieldID fHeaders = env->GetFieldID(nr, "headers", "Ljava/util/Map;");
        if (fHeaders != nullptr) {
            const jobject mapa = env->GetObjectField(networkResponse, fHeaders);
            if (mapa != nullptr) respHeaders = mapAJsonObjeto(env, mapa);
        } else {
            logErrorExtraccion(env, "emitirVolleyPerformRequest", "GetFieldID NetworkResponse.headers");
            env->ExceptionClear();
            const jfieldID fAll = env->GetFieldID(nr, "allHeaders", "Ljava/util/List;");
            if (fAll != nullptr) {
                const jobject lista = env->GetObjectField(networkResponse, fAll);
                if (lista != nullptr) respHeaders = listaHeadersAJson(env, lista);
            } else {
                logErrorExtraccion(env, "emitirVolleyPerformRequest", "GetFieldID NetworkResponse.allHeaders");
                env->ExceptionClear();
            }
        }
    }

    // Recuperar desde mapa global (hilo caller vs hilo de red): método + body
    {
        const std::lock_guard<std::mutex> lock(g_request_mutex);
        const auto it = g_request_map.find(url);
        if (it != g_request_map.end()) {
            if (reqBody.empty()) reqBody = it->second.second;
            if (!it->second.first.empty()) metodo = it->second.first;
            g_request_map.erase(it);
        }
    }

    emitirFlowCompleto(
        "volley", metodo, url, status, reqHeaders, reqBody, respHeaders, respBody, ms);
}

void emitirDesdeVolleyRequest(JNIEnv* env, jobject request, int status, int64_t ms) {
    std::string metodo, url, reqHeaders, reqBody;
    extraerRequestVolley(env, request, &metodo, &url, &reqHeaders, &reqBody);
    emitirFlowCompleto(
        "volley", metodo, url, status, reqHeaders, reqBody, "{}", "", ms);
}

std::string leerInputStream(JNIEnv* env, jobject inputStream);

// HurlStack.executeRequest → com.android.volley.toolbox.HttpResponse (Volley 1.2+)
// o org.apache.http.HttpResponse (Volley legacy).
void emitirVolleyExecuteRequest(
    JNIEnv* env, jobject request, jobject httpResp, jobject headersExtra, int64_t ms) {
    std::string metodo, url, reqHeaders, reqBody;
    extraerRequestVolleyConExtras(
        env, request, headersExtra, &metodo, &url, &reqHeaders, &reqBody);

    // Fallback desde openConnection exit
    if ((url.empty() || url == "(desconocido)") && !tls_cap.url.empty()) {
        url = tls_cap.url;
        if (!tls_cap.metodo.empty()) metodo = tls_cap.metodo;
    }
    if (reqHeaders == "{}" && tls_cap.reqHeaders != "{}") {
        reqHeaders = tls_cap.reqHeaders;
    }
    // Recuperar desde mapa global (hilo caller vs hilo de red): método + body
    {
        const std::lock_guard<std::mutex> lock(g_request_mutex);
        const auto it = g_request_map.find(url);
        if (it != g_request_map.end()) {
            if (reqBody.empty()) reqBody = it->second.second;
            if (!it->second.first.empty()) metodo = it->second.first;
            g_request_map.erase(it);
        }
    }

    int status = 0;
    std::string respHeaders = "{}";
    std::string respBody;
    if (httpResp == nullptr) {
        emitirFlowCompleto(
            "volley", metodo, url, status, reqHeaders, reqBody, respHeaders, respBody, ms);
        return;
    }

    env->ExceptionClear();  // safety: limpia excepción pendiente de extraerRequestVolley
    const jclass cls = env->GetObjectClass(httpResp);

    // Volley toolbox.HttpResponse (campos públicos o getters).
    const jmethodID midGetCode = env->GetMethodID(cls, "getStatusCode", "()I");
    if (midGetCode != nullptr) {
        status = env->CallIntMethod(httpResp, midGetCode);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "HttpResponse.getStatusCode()");
            env->ExceptionClear();
            status = 0;
        }
    } else {
        logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetMethodID HttpResponse.getStatusCode");
        env->ExceptionClear();
        const jfieldID fCode = env->GetFieldID(cls, "statusCode", "I");
        if (fCode != nullptr) {
            status = env->GetIntField(httpResp, fCode);
        } else {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetFieldID HttpResponse.statusCode");
            env->ExceptionClear();
        }
    }

    const jmethodID midGetData = env->GetMethodID(cls, "getData", "()[B");
    if (midGetData != nullptr) {
        const jobject data = env->CallObjectMethod(httpResp, midGetData);
        if (!env->ExceptionCheck() && data != nullptr) {
            respBody = bytesAString(env, static_cast<jbyteArray>(data));
        } else {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "HttpResponse.getData()");
            env->ExceptionClear();
        }
    } else {
        logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetMethodID HttpResponse.getData");
        env->ExceptionClear();
        const jfieldID fData = env->GetFieldID(cls, "data", "[B");
        if (fData != nullptr) {
            const jobject data = env->GetObjectField(httpResp, fData);
            if (data != nullptr) {
                respBody = bytesAString(env, static_cast<jbyteArray>(data));
            }
        } else {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetFieldID HttpResponse.data");
            env->ExceptionClear();
        }
    }

    const jmethodID midGetHdrs =
        env->GetMethodID(cls, "getHeaders", "()Ljava/util/List;");
    if (midGetHdrs != nullptr) {
        const jobject lista = env->CallObjectMethod(httpResp, midGetHdrs);
        if (!env->ExceptionCheck() && lista != nullptr) {
            respHeaders = listaHeadersAJson(env, lista);
        } else {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "HttpResponse.getHeaders()");
            env->ExceptionClear();
        }
    } else {
        logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetMethodID HttpResponse.getHeaders");
        env->ExceptionClear();
        const jfieldID fHdrs = env->GetFieldID(cls, "headers", "Ljava/util/List;");
        if (fHdrs != nullptr) {
            const jobject lista = env->GetObjectField(httpResp, fHdrs);
            if (lista != nullptr) respHeaders = listaHeadersAJson(env, lista);
        } else {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetFieldID HttpResponse.headers");
            env->ExceptionClear();
            const jfieldID fAll = env->GetFieldID(cls, "allHeaders", "Ljava/util/List;");
            if (fAll != nullptr) {
                const jobject lista = env->GetObjectField(httpResp, fAll);
                if (lista != nullptr) respHeaders = listaHeadersAJson(env, lista);
            } else {
                logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetFieldID HttpResponse.allHeaders");
                env->ExceptionClear();
            }
        }
    }

    // Fallback Apache HttpResponse (Volley antiguo).
    if (status == 0 && respBody.empty()) {
        const jmethodID midStatusLine =
            env->GetMethodID(cls, "getStatusLine", "()Lorg/apache/http/StatusLine;");
        if (midStatusLine != nullptr) {
            const jobject sl = env->CallObjectMethod(httpResp, midStatusLine);
            if (!env->ExceptionCheck() && sl != nullptr) {
                const jclass slCls = env->GetObjectClass(sl);
                const jmethodID midCode =
                    env->GetMethodID(slCls, "getStatusCode", "()I");
                if (midCode != nullptr) {
                    status = env->CallIntMethod(sl, midCode);
                    if (env->ExceptionCheck()) env->ExceptionClear();
                }
            } else {
                logErrorExtraccion(env, "emitirVolleyExecuteRequest", "Apache getStatusLine");
                env->ExceptionClear();
            }
        } else {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetMethodID Apache getStatusLine");
            env->ExceptionClear();
        }
        const jmethodID midEntity =
            env->GetMethodID(cls, "getEntity", "()Lorg/apache/http/HttpEntity;");
        if (midEntity != nullptr) {
            const jobject entity = env->CallObjectMethod(httpResp, midEntity);
            if (!env->ExceptionCheck() && entity != nullptr) {
                const jclass entCls = env->GetObjectClass(entity);
                const jmethodID midContent =
                    env->GetMethodID(entCls, "getContent", "()Ljava/io/InputStream;");
                if (midContent != nullptr) {
                    const jobject is =
                        env->CallObjectMethod(entity, midContent);
                    if (!env->ExceptionCheck() && is != nullptr) {
                        respBody = leerInputStream(env, is);
                    } else {
                        logErrorExtraccion(env, "emitirVolleyExecuteRequest", "Apache HttpEntity.getContent()");
                        env->ExceptionClear();
                    }
                }
            } else {
                logErrorExtraccion(env, "emitirVolleyExecuteRequest", "Apache HttpResponse.getEntity()");
                env->ExceptionClear();
            }
        } else {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetMethodID Apache getEntity");
            env->ExceptionClear();
        }
        const jmethodID midAllHdrs =
            env->GetMethodID(cls, "getAllHeaders", "()[Lorg/apache/http/Header;");
        if (midAllHdrs != nullptr) {
            const jobjectArray hdrs =
                static_cast<jobjectArray>(env->CallObjectMethod(httpResp, midAllHdrs));
            if (!env->ExceptionCheck() && hdrs != nullptr) {
                std::string out = "{";
                bool primero = true;
                const jsize n = env->GetArrayLength(hdrs);
                for (jsize i = 0; i < n; ++i) {
                    const jobject h = env->GetObjectArrayElement(hdrs, i);
                    if (h == nullptr) continue;
                    const jclass hCls = env->GetObjectClass(h);
                    const jmethodID gn =
                        env->GetMethodID(hCls, "getName", "()Ljava/lang/String;");
                    const jmethodID gv =
                        env->GetMethodID(hCls, "getValue", "()Ljava/lang/String;");
                    if (gn != nullptr && gv != nullptr) {
                        const jstring jn =
                            static_cast<jstring>(env->CallObjectMethod(h, gn));
                        const jstring jv =
                            static_cast<jstring>(env->CallObjectMethod(h, gv));
                        if (!primero) out += ",";
                        primero = false;
                        out += "\"" + escaparJson(jstringAStd(env, jn)) + "\":\"" +
                               escaparJson(jstringAStd(env, jv)) + "\"";
                    }
                    env->DeleteLocalRef(h);
                }
                out += "}";
                respHeaders = out;
            } else {
                logErrorExtraccion(env, "emitirVolleyExecuteRequest", "Apache getAllHeaders()");
                env->ExceptionClear();
            }
        } else {
            logErrorExtraccion(env, "emitirVolleyExecuteRequest", "GetMethodID Apache getAllHeaders");
            env->ExceptionClear();
        }
    }

    emitirFlowCompleto(
        "volley", metodo, url, status, reqHeaders, reqBody, respHeaders, respBody, ms);
}

// Lee un InputStream Java hasta kMaxBody bytes.
std::string leerInputStream(JNIEnv* env, jobject inputStream) {
    if (inputStream == nullptr) return {};
    const jclass isCls = env->FindClass("java/io/InputStream");
    const jmethodID midRead = env->GetMethodID(isCls, "read", "([B)I");
    if (midRead == nullptr) return {};
    jbyteArray buf = env->NewByteArray(static_cast<jsize>(8192));
    std::string out;
    out.reserve(4096);
    while (out.size() < kMaxBody) {
        const jint n = env->CallIntMethod(inputStream, midRead, buf);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "leerInputStream", "InputStream.read()");
            env->ExceptionClear();
            break;
        }
        if (n <= 0) break;
        jbyte* datos = env->GetByteArrayElements(buf, nullptr);
        if (datos == nullptr) break;
        out.append(reinterpret_cast<const char*>(datos),
                   static_cast<size_t>(std::min(n, static_cast<jint>(kMaxBody - out.size()))));
        env->ReleaseByteArrayElements(buf, datos, JNI_ABORT);
    }
    env->DeleteLocalRef(buf);
    if (out.size() >= kMaxBody) out += "…(truncado)";
    return out;
}

void emitirDesdeHttpURLConnection(
    JNIEnv* env, jobject conexion, int status, int64_t ms) {
    if (conexion == nullptr) return;
    const jclass clase = env->GetObjectClass(conexion);
    if (clase == nullptr) return;

    std::string metodo = "GET";
    const jmethodID midMetodo =
        env->GetMethodID(clase, "getRequestMethod", "()Ljava/lang/String;");
    if (midMetodo != nullptr) {
        const jstring jMetodo =
            static_cast<jstring>(env->CallObjectMethod(conexion, midMetodo));
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "emitirDesdeHttpURLConnection", "URLConnection.getRequestMethod()");
            env->ExceptionClear();
        } else if (jMetodo != nullptr) {
            metodo = jstringAStd(env, jMetodo);
        }
    }

    std::string url = "(desconocido)";
    const jmethodID midUrl = env->GetMethodID(clase, "getURL", "()Ljava/net/URL;");
    if (midUrl != nullptr) {
        const jobject urlObj = env->CallObjectMethod(conexion, midUrl);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "emitirDesdeHttpURLConnection", "URLConnection.getURL()");
            env->ExceptionClear();
        } else if (urlObj != nullptr) {
            url = objetoAString(env, urlObj);
        }
    }

    std::string reqHeaders = "{}";
    const jmethodID midReqProps =
        env->GetMethodID(clase, "getRequestProperties", "()Ljava/util/Map;");
    if (midReqProps != nullptr) {
        const jobject mapa = env->CallObjectMethod(conexion, midReqProps);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "emitirDesdeHttpURLConnection", "URLConnection.getRequestProperties()");
            env->ExceptionClear();
        } else if (mapa != nullptr) {
            reqHeaders = mapAJsonObjeto(env, mapa);
        }
    } else {
        logErrorExtraccion(env, "emitirDesdeHttpURLConnection", "GetMethodID getRequestProperties");
        env->ExceptionClear();
    }

    std::string respHeaders = "{}";
    const jmethodID midRespHdrs =
        env->GetMethodID(clase, "getHeaderFields", "()Ljava/util/Map;");
    if (midRespHdrs != nullptr) {
        const jobject mapa = env->CallObjectMethod(conexion, midRespHdrs);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "emitirDesdeHttpURLConnection", "URLConnection.getHeaderFields()");
            env->ExceptionClear();
        } else if (mapa != nullptr) {
            respHeaders = mapAJsonObjeto(env, mapa);
        }
    } else {
        logErrorExtraccion(env, "emitirDesdeHttpURLConnection", "GetMethodID getHeaderFields");
        env->ExceptionClear();
    }

    std::string respBody;
    const jmethodID midGetStream =
        env->GetMethodID(clase, "getInputStream", "()Ljava/io/InputStream;");
    const jmethodID midGetError =
        env->GetMethodID(clase, "getErrorStream", "()Ljava/io/InputStream;");
    jobject stream = nullptr;
    if (status >= 400 && midGetError != nullptr) {
        stream = env->CallObjectMethod(conexion, midGetError);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "emitirDesdeHttpURLConnection", "URLConnection.getErrorStream()");
            env->ExceptionClear();
            stream = nullptr;
        }
    }
    if (stream == nullptr && midGetStream != nullptr) {
        stream = env->CallObjectMethod(conexion, midGetStream);
        if (env->ExceptionCheck()) {
            logErrorExtraccion(env, "emitirDesdeHttpURLConnection", "URLConnection.getInputStream()");
            env->ExceptionClear();
            stream = nullptr;
        }
    }
    if (stream != nullptr) {
        respBody = leerInputStream(env, stream);
        env->DeleteLocalRef(stream);
    }

    emitirFlowCompleto(
        "urlconnection", metodo, url, status,
        reqHeaders, "", respHeaders, respBody, ms);
}

int statusDesdeConexion(JNIEnv* env, jobject conexion) {
    if (conexion == nullptr) return 0;
    const jclass clase = env->GetObjectClass(conexion);
    const jmethodID midCode = env->GetMethodID(clase, "getResponseCode", "()I");
    if (midCode == nullptr) return 0;
    const int code = env->CallIntMethod(conexion, midCode);
    if (env->ExceptionCheck()) {
        logErrorExtraccion(env, "statusDesdeConexion", "URLConnection.getResponseCode()");
        env->ExceptionClear();
        return 0;
    }
    return code;
}

void emitirDesdeOkHttpResponse(JNIEnv* env, jobject response, int64_t ms) {
    if (response == nullptr) return;
    const jclass claseResp = env->GetObjectClass(response);
    if (claseResp == nullptr) return;

    const jmethodID midCode = env->GetMethodID(claseResp, "code", "()I");
    const jmethodID midRequest =
        env->GetMethodID(claseResp, "request", "()Lokhttp3/Request;");
    const jmethodID midHeaders =
        env->GetMethodID(claseResp, "headers", "()Lokhttp3/Headers;");
    const jmethodID midBody =
        env->GetMethodID(claseResp, "body", "()Lokhttp3/ResponseBody;");
    if (midCode == nullptr || midRequest == nullptr) return;

    const int status = env->CallIntMethod(response, midCode);
    if (env->ExceptionCheck()) { logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "Response.code()"); env->ExceptionClear(); return; }

    const jobject request = env->CallObjectMethod(response, midRequest);
    if (env->ExceptionCheck() || request == nullptr) {
        logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "Response.request()");
        env->ExceptionClear();
        return;
    }

    const jclass claseReq = env->GetObjectClass(request);
    const jmethodID midMetodo = env->GetMethodID(claseReq, "method", "()Ljava/lang/String;");
    const jmethodID midUrl = env->GetMethodID(claseReq, "url", "()Lokhttp3/HttpUrl;");
    if (midMetodo == nullptr || midUrl == nullptr) return;

    const jstring jMetodo = static_cast<jstring>(env->CallObjectMethod(request, midMetodo));
    const jobject httpUrl = env->CallObjectMethod(request, midUrl);
    if (httpUrl == nullptr) return;

    const jclass claseHttpUrl = env->GetObjectClass(httpUrl);
    const jmethodID midToString =
        env->GetMethodID(claseHttpUrl, "toString", "()Ljava/lang/String;");
    const jstring jUrl = static_cast<jstring>(env->CallObjectMethod(httpUrl, midToString));

    const std::string metodo = jMetodo != nullptr ? jstringAStd(env, jMetodo) : "GET";
    const std::string url = jUrl != nullptr ? jstringAStd(env, jUrl) : "(desconocido)";

    // Headers
    std::string respHeadersJson = "{}";
    if (midHeaders != nullptr) {
        const jobject headers = env->CallObjectMethod(response, midHeaders);
        if (!env->ExceptionCheck() && headers != nullptr) {
            const jclass hCls = env->GetObjectClass(headers);
            const jmethodID midSize = env->GetMethodID(hCls, "size", "()I");
            const jmethodID midName = env->GetMethodID(hCls, "name", "(I)Ljava/lang/String;");
            const jmethodID midValue = env->GetMethodID(hCls, "value", "(I)Ljava/lang/String;");
            if (midSize != nullptr && midName != nullptr && midValue != nullptr) {
                const jint n = env->CallIntMethod(headers, midSize);
                std::string out = "{";
                bool primero = true;
                for (jint i = 0; i < n; ++i) {
                    const jstring jn = static_cast<jstring>(env->CallObjectMethod(headers, midName, i));
                    const jstring jv = static_cast<jstring>(env->CallObjectMethod(headers, midValue, i));
                    if (!primero) out += ",";
                    primero = false;
                    out += "\"" + escaparJson(jstringAStd(env, jn)) + "\":\"" +
                           escaparJson(jstringAStd(env, jv)) + "\"";
                }
                out += "}";
                respHeadersJson = out;
            } else {
                logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "Headers.size/name/value GetMethodID");
                env->ExceptionClear();
            }
        } else {
            logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "Response.headers() call");
            env->ExceptionClear();
        }
    }

    // Body (via ResponseBody.peekBody() para no consumir el stream)
    std::string respBody;
    jlong actualBodySize = -1;
    bool bodyTruncated = false;
    std::string bodyEncoding;
    if (midBody != nullptr) {
        const jobject body = env->CallObjectMethod(response, midBody);
        if (!env->ExceptionCheck() && body != nullptr) {
            const jclass bodyCls = env->GetObjectClass(body);

            // Content-Length (via ResponseBody.contentLength())
            jlong contentLength = -1;
            const jmethodID midContentLength = env->GetMethodID(bodyCls, "contentLength", "()J");
            if (midContentLength != nullptr) {
                contentLength = env->CallLongMethod(body, midContentLength);
                if (env->ExceptionCheck()) env->ExceptionClear();
            }

            // Content-Encoding (via Response.header(name))
            const jmethodID midRespHeader = env->GetMethodID(claseResp, "header", "(Ljava/lang/String;)Ljava/lang/String;");
            if (midRespHeader != nullptr) {
                const jstring jEncName = env->NewStringUTF("Content-Encoding");
                const jstring jEnc = static_cast<jstring>(env->CallObjectMethod(response, midRespHeader, jEncName));
                if (!env->ExceptionCheck() && jEnc != nullptr) {
                    bodyEncoding = jstringAStd(env, jEnc);
                }
                env->ExceptionClear();
            }

            // peekBody(limit) — respeta kMaxPeekBody (1 MB)
            const jlong peekLimit = (contentLength > 0 && contentLength <= kMaxPeekBody) ? contentLength : kMaxPeekBody;
            const jmethodID midPeekBody = env->GetMethodID(bodyCls, "peekBody", "(J)Lokhttp3/ResponseBody;");
            if (midPeekBody != nullptr) {
                const jobject peeked = env->CallObjectMethod(body, midPeekBody, peekLimit);
                if (!env->ExceptionCheck() && peeked != nullptr) {
                    const jclass peekedCls = env->GetObjectClass(peeked);
                    const jmethodID midStr = env->GetMethodID(peekedCls, "string", "()Ljava/lang/String;");
                    if (midStr != nullptr) {
                        const jstring jBody = static_cast<jstring>(env->CallObjectMethod(peeked, midStr));
                        if (!env->ExceptionCheck() && jBody != nullptr) {
                            respBody = jstringAStd(env, jBody);
                            actualBodySize = contentLength >= 0 ? contentLength : static_cast<jlong>(respBody.size());
                            if (contentLength > kMaxPeekBody) {
                                bodyTruncated = true;
                            }
                        } else {
                            logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "peeked.string()");
                            env->ExceptionClear();
                        }
                    } else {
                        logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "peekedCls.string GetMethodID");
                        env->ExceptionClear();
                    }
                } else {
                    logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "body.peekBody(limit)");
                    env->ExceptionClear();
                }
            } else {
                logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "bodyCls.peekBody GetMethodID");
                env->ExceptionClear();
            }
        } else {
            logErrorExtraccion(env, "emitirDesdeOkHttpResponse", "Response.body()");
            env->ExceptionClear();
        }
    }

    emitirFlowCompleto(
        "okhttp", metodo, url, status,
        "{}", "", respHeadersJson, respBody, ms,
        actualBodySize, bodyTruncated, bodyEncoding);
}

void reiniciarCaptura() {
    tls_cap = CapturaHilo{};
}

jobject buscarInstanciaEnLocals(
    jvmtiEnv* jvmti, JNIEnv* env, jthread thread, const char* claseInterna) {
    const jclass cls = env->FindClass(claseInterna);
    if (cls == nullptr) {
        logErrorExtraccion(env, "buscarInstanciaEnLocals", claseInterna);
        env->ExceptionClear();
        return nullptr;
    }
    for (int slot = 0; slot < 16; ++slot) {
        jobject local = nullptr;
        if (jvmti->GetLocalObject(thread, 0, slot, &local) != JVMTI_ERROR_NONE) {
            continue;
        }
        if (local != nullptr && env->IsInstanceOf(local, cls) == JNI_TRUE) {
            return local;
        }
    }
    return nullptr;
}

std::string objetoRespuestaAString(JNIEnv* env, jobject obj) {
    if (obj == nullptr) return {};
    const jclass cls = env->GetObjectClass(obj);
    const jmethodID midGetData = env->GetMethodID(cls, "getData", "()[B");
    if (midGetData != nullptr) {
        const jobject data = env->CallObjectMethod(obj, midGetData);
        if (!env->ExceptionCheck() && data != nullptr) {
            return bytesAString(env, static_cast<jbyteArray>(data));
        }
        logErrorExtraccion(env, "objetoRespuestaAString", "getData()");
        env->ExceptionClear();
    } else {
        env->ExceptionClear();
    }
    const jmethodID midToString = env->GetMethodID(cls, "toString", "()Ljava/lang/String;");
    if (midToString != nullptr) {
        const jstring s = static_cast<jstring>(env->CallObjectMethod(obj, midToString));
        if (!env->ExceptionCheck() && s != nullptr) {
            return jstringAStd(env, s);
        }
        logErrorExtraccion(env, "objetoRespuestaAString", "toString()");
        env->ExceptionClear();
    }
    return {};
}

void enriquecerHeadersDesdeConexion(JNIEnv* env) {
    if (tls_conexionAbierta == nullptr) return;
    const jclass cls = env->GetObjectClass(tls_conexionAbierta);
    if (tls_cap.reqHeaders == "{}") {
        const jmethodID mid =
            env->GetMethodID(cls, "getRequestProperties", "()Ljava/util/Map;");
        if (mid != nullptr) {
            const jobject mapa = env->CallObjectMethod(tls_conexionAbierta, mid);
            if (!env->ExceptionCheck() && mapa != nullptr) {
                tls_cap.reqHeaders = mapAJsonObjeto(env, mapa);
            } else {
                logErrorExtraccion(env, "enriquecerHeadersDesdeConexion", "getRequestProperties()");
                env->ExceptionClear();
            }
        } else {
            logErrorExtraccion(env, "enriquecerHeadersDesdeConexion", "GetMethodID getRequestProperties");
            env->ExceptionClear();
        }
    }
    if (tls_cap.respHeaders == "{}") {
        const jmethodID mid = env->GetMethodID(cls, "getHeaderFields", "()Ljava/util/Map;");
        if (mid != nullptr) {
            const jobject mapa = env->CallObjectMethod(tls_conexionAbierta, mid);
            if (!env->ExceptionCheck() && mapa != nullptr) {
                tls_cap.respHeaders = mapAJsonObjeto(env, mapa);
            } else {
                logErrorExtraccion(env, "enriquecerHeadersDesdeConexion", "getHeaderFields()");
                env->ExceptionClear();
            }
        } else {
            logErrorExtraccion(env, "enriquecerHeadersDesdeConexion", "GetMethodID getHeaderFields");
            env->ExceptionClear();
        }
    }
}

void emitirCapturaCompleta(JNIEnv* env, int status, int64_t ms) {
    if (!tls_cap.activa && tls_cap.reqBody.empty() && tls_cap.url.empty()) {
        return;
    }
    enriquecerHeadersDesdeConexion(env);
    if (tls_cap.respBody.empty() && tls_conexionAbierta != nullptr && status >= 400) {
        const jclass cls = env->GetObjectClass(tls_conexionAbierta);
        const jmethodID midErr =
            env->GetMethodID(cls, "getErrorStream", "()Ljava/io/InputStream;");
        if (midErr != nullptr) {
            const jobject es = env->CallObjectMethod(tls_conexionAbierta, midErr);
            if (!env->ExceptionCheck() && es != nullptr) {
                tls_cap.respBody = leerInputStream(env, es);
            } else {
                logErrorExtraccion(env, "emitirCapturaCompleta", "URLConnection.getErrorStream()");
                env->ExceptionClear();
            }
        }
    }
    // Fallback: extract URL from the stored connection if not captured at openConnection entry
    std::string url = tls_cap.url.empty() ? "(desconocido)" : tls_cap.url;
    if (url == "(desconocido)" && tls_conexionAbierta != nullptr) {
        const jclass cls = env->GetObjectClass(tls_conexionAbierta);
        const jmethodID midGetURL = env->GetMethodID(cls, "getURL", "()Ljava/net/URL;");
        if (midGetURL != nullptr) {
            const jobject urlObj = env->CallObjectMethod(tls_conexionAbierta, midGetURL);
            if (!env->ExceptionCheck() && urlObj != nullptr) {
                url = objetoAString(env, urlObj);
            } else {
                env->ExceptionClear();
            }
        } else {
            env->ExceptionClear();
        }
    }
    emitirFlowCompleto(
        "cap",
        tls_cap.metodo,
        url,
        status,
        tls_cap.reqHeaders,
        tls_cap.reqBody,
        tls_cap.respHeaders,
        tls_cap.respBody,
        ms);
    char buf[160];
    snprintf(
        buf,
        sizeof(buf),
        "emitido status=%d reqBody=%zuB respBody=%zuB url=%s",
        status,
        tls_cap.reqBody.size(),
        tls_cap.respBody.size(),
        url.c_str());
    emitirDiag(buf);
    reiniciarCaptura();
}

void capturarUrlOpenConnection(jvmtiEnv* jvmti, JNIEnv* env, jthread thread) {
    const jobject urlObj =
        buscarInstanciaEnLocals(jvmti, env, thread, "java/net/URL");
    if (urlObj == nullptr) return;
    tls_cap.url = objetoAString(env, urlObj);
    tls_cap.activa = true;
    if (tls_cap.inicio.time_since_epoch().count() == 0) {
        tls_cap.inicio = std::chrono::steady_clock::now();
    }
}

void capturarJsonRequest(jvmtiEnv* jvmti, JNIEnv* env, jthread thread) {
    const jobject json =
        buscarInstanciaEnLocals(jvmti, env, thread, "org/json/JSONObject");
    if (json == nullptr) return;
    tls_cap.reqBody = objetoAString(env, json);
    tls_cap.metodo = "POST";
    tls_cap.activa = true;
    if (tls_cap.inicio.time_since_epoch().count() == 0) {
        tls_cap.inicio = std::chrono::steady_clock::now();
    }
    emitirDiag("JSON request body capturado (app lambda)");
}

void capturarRequestQueueAdd(jvmtiEnv* jvmti, JNIEnv* env, jthread thread) {
    const jobject req =
        buscarInstanciaEnLocals(jvmti, env, thread, "com/android/volley/Request");
    if (req == nullptr) return;
    std::string metodo, url, reqHeaders, reqBody;
    extraerRequestVolley(env, req, &metodo, &url, &reqHeaders, &reqBody);
    if (!url.empty() && url != "(desconocido)") tls_cap.url = url;
    if (!metodo.empty()) tls_cap.metodo = metodo;
    if (reqHeaders != "{}") tls_cap.reqHeaders = reqHeaders;
    if (!reqBody.empty()) {
        tls_cap.reqBody = reqBody;
    }
    // Si extraerRequestVolley no obtuvo body (getBody() ya consumido o nulo),
    // usar el que capturó capturarJsonRequest previamente en este mismo hilo
    const std::string bodyFinal =
        !reqBody.empty() ? reqBody : tls_cap.reqBody;
    // Resetear reqBody en TLS: si no se limpia, el próximo request (ej: GET sin body)
    // recogería este body stale como fallback. El body real está en el mapa global.
    tls_cap.reqBody = reqBody;
    // Almacenar en mapa global: el hilo de red no ve la TLS del hilo caller
    if (tls_cap.url != "(desconocido)" && !tls_cap.url.empty()) {
        const std::lock_guard<std::mutex> lock(g_request_mutex);
        g_request_map[tls_cap.url] = {metodo, bodyFinal};
    }
    tls_cap.activa = true;
    emitirDiag("RequestQueue.add capturado");
}

void capturarOnResponse(jvmtiEnv* jvmti, JNIEnv* env, jthread thread) {
    for (int slot = 0; slot < 16; ++slot) {
        jobject local = nullptr;
        if (jvmti->GetLocalObject(thread, 0, slot, &local) != JVMTI_ERROR_NONE) {
            continue;
        }
        if (local == nullptr) continue;
        const std::string body = objetoRespuestaAString(env, local);
        if (!body.empty() && body.size() > 2) {
            tls_cap.respBody = body;
            tls_cap.activa = true;
            emitirDiag("onResponse body capturado");
            return;
        }
    }
}

int detectarTipoEntrada(jvmtiEnv* jvmti, jmethodID method, const char* nombre, const char* firma) {
    if (nombre == nullptr || firma == nullptr) return kNinguno;

    // Early return para métodos高频 que nunca matchean — evitar GetMethodDeclaringClass.
    if (nombre[0] == 'e' && strcmp(nombre, "equals") == 0) return kNinguno;
    if (nombre[0] == 'g') {
        if (strcmp(nombre, "getClass") == 0) return kNinguno;
        if (strcmp(nombre, "getOutputStream") == 0) return kNinguno;
        if (strcmp(nombre, "getResponseCode") == 0) return kNinguno;
        if (strcmp(nombre, "getInputStream") == 0) return kNinguno;
    }

    // App custom: lambda/método con JSONObject (executeRequestAsync$lambda$14).
    if (firmaContiene(firma, "Lorg/json/JSONObject;") &&
        (claseContiene(jvmti, method, "coordinadora") ||
         claseContiene(jvmti, method, "timgoo") ||
         claseContiene(jvmti, method, "Volley") ||
         (nombre != nullptr &&
          (strstr(nombre, "executeRequest") != nullptr ||
           strstr(nombre, "lambda$") != nullptr)))) {
        return kAppJsonBody;
    }
    // RequestQueue.add(Request) — código app suele tener tabla de locals.
    if (strcmp(nombre, "add") == 0 &&
        firmaContiene(firma, "Lcom/android/volley/Request") &&
        claseContiene(jvmti, method, "RequestQueue")) {
        return kRequestQueueAdd;
    }
    // Listener Volley / callback custom (con Object, NO con OkHttp Response).
    if ((strcmp(nombre, "onResponse") == 0 || strstr(nombre, "onSuccess") != nullptr) &&
        !firmaContiene(firma, "Lokhttp3/Response;") &&
        (claseContiene(jvmti, method, "volley") ||
         claseContiene(jvmti, method, "Volley") ||
         claseContiene(jvmti, method, "coordinadora") ||
         claseContiene(jvmti, method, "Listener") ||
         claseContiene(jvmti, method, "Callback"))) {
        return kVolleyOnResponse;
    }

    // Volley: cualquier implementación de Network (sin exigir "volley" en la clase
    // porque apps con wrapper custom o ProGuard no matchean).
    if (strcmp(nombre, "performRequest") == 0 &&
        firmaContiene(firma, "Lcom/android/volley/Request") &&
        firmaContiene(firma, "NetworkResponse")) {
        return kVolleyPerformRequest;
    }
    // HurlStack / BaseHttpStack / OkHttpStack / cualquier *Stack de Volley.
    if (strcmp(nombre, "executeRequest") == 0 &&
        firmaContiene(firma, "Lcom/android/volley/Request") &&
        firmaContiene(firma, "HttpResponse")) {
        return kVolleyExecuteRequest;
    }
    if (strcmp(nombre, "execute") == 0 && firmaContiene(firma, "okhttp3/Response") &&
        claseContiene(jvmti, method, "RealCall")) {
        return kOkHttpExecute;
    }
    // RealCall.enqueue(Callback) — async OkHttp
    if (strcmp(nombre, "enqueue") == 0 &&
        firmaContiene(firma, "Lokhttp3/Callback;") &&
        claseContiene(jvmti, method, "RealCall")) {
        return kOkHttpEnqueue;
    }
    // okhttp3.Callback.onResponse(Call, Response) — async callback
    if (strcmp(nombre, "onResponse") == 0 &&
        firmaContiene(firma, "Lokhttp3/Call;") &&
        firmaContiene(firma, "Lokhttp3/Response;")) {
        return kCallbackOnResponse;
    }
    // okhttp3.Callback.onFailure(Call, IOException) — limpiar mapa
    if (strcmp(nombre, "onFailure") == 0 &&
        firmaContiene(firma, "Lokhttp3/Call;") &&
        firmaContiene(firma, "Ljava/io/IOException;")) {
        return kCallbackOnFailure;
    }
    // Volley Request.getUrl() — capturar URL (respaldar cuando GetLocalObject falla).
    // Matchea también clases anónimas que heredan Request (claseContiene falla en esas).
    if (strcmp(nombre, "getUrl") == 0 &&
        strcmp(firma, "()Ljava/lang/String;") == 0 &&
        (tls_pendiente.tipo == kVolleyPerformRequest ||
         tls_pendiente.tipo == kVolleyExecuteRequest ||
         claseContiene(jvmti, method, "Request"))) {
        return kVolleyGetUrl;
    }
    // Volley Request.getHeaders() — capturar headers (Authorization Bearer incluido).
    if (strcmp(nombre, "getHeaders") == 0 &&
        firmaContiene(firma, "()Ljava/util/Map") &&
        (tls_pendiente.tipo == kVolleyPerformRequest ||
         tls_pendiente.tipo == kVolleyExecuteRequest ||
         claseContiene(jvmti, method, "Request"))) {
        return kVolleyGetHeaders;
    }
    // URL.openConnection() → guarda conexión (GetLocalObject no funciona en métodos nativos).
    if (strcmp(nombre, "openConnection") == 0 &&
        firmaContiene(firma, "Ljava/net/URLConnection")) {
        return kUrlOpenConnection;
    }
    return kNinguno;
}

bool guardarEntrada(jvmtiEnv* jvmti, JNIEnv* jni, jthread thread, int tipo) {
    const int slotPreferido = 0;
    jobject local = nullptr;
    jvmtiError rc = JVMTI_ERROR_INVALID_SLOT;
    for (int slot = slotPreferido; slot <= slotPreferido + 1; ++slot) {
        rc = jvmti->GetLocalObject(thread, 0, slot, &local);
        if (rc == JVMTI_ERROR_NONE && local != nullptr) break;
        local = nullptr;
    }
    if (local == nullptr) {
        return false;
    }
    limpiarPendiente(jni);
    tls_pendiente.objetivo = jni->NewGlobalRef(local);
    tls_pendiente.tipo = tipo;
    tls_pendiente.inicio = std::chrono::steady_clock::now();
    return true;
}

bool esVolleyRequest(JNIEnv* env, jobject obj) {
    if (obj == nullptr) return false;
    const jclass reqCls = env->FindClass("com/android/volley/Request");
    if (reqCls == nullptr) {
        logErrorExtraccion(env, "esVolleyRequest", "FindClass Request");
        env->ExceptionClear();
        return false;
    }
    return env->IsInstanceOf(obj, reqCls) == JNI_TRUE;
}

bool esJavaMap(JNIEnv* env, jobject obj) {
    if (obj == nullptr) return false;
    const jclass mapCls = env->FindClass("java/util/Map");
    if (mapCls == nullptr) {
        logErrorExtraccion(env, "esJavaMap", "FindClass Map");
        env->ExceptionClear();
        return false;
    }
    return env->IsInstanceOf(obj, mapCls) == JNI_TRUE;
}

// En ART, GetLocalObject falla en MethodEntry pero suele funcionar en MethodExit.
jobject buscarRequestEnLocals(jvmtiEnv* jvmti, JNIEnv* jni, jthread thread) {
    for (int slot = 0; slot <= 4; ++slot) {
        jobject local = nullptr;
        if (jvmti->GetLocalObject(thread, 0, slot, &local) != JVMTI_ERROR_NONE) {
            continue;
        }
        if (local != nullptr && esVolleyRequest(jni, local)) {
            return local;
        }
    }
    return nullptr;
}

jobject buscarOkHttpResponseEnLocals(jvmtiEnv* jvmti, JNIEnv* jni, jthread thread) {
    const jclass respCls = jni->FindClass("okhttp3/Response");
    if (respCls == nullptr) {
        jni->ExceptionClear();
        return nullptr;
    }
    for (int slot = 0; slot <= 6; ++slot) {
        jobject local = nullptr;
        if (jvmti->GetLocalObject(thread, 0, slot, &local) != JVMTI_ERROR_NONE) {
            continue;
        }
        if (local != nullptr && jni->IsInstanceOf(local, respCls) == JNI_TRUE) {
            return local;
        }
    }
    return nullptr;
}

jobject buscarMapAdicionalEnLocals(jvmtiEnv* jvmti, JNIEnv* jni, jthread thread) {
    for (int slot = 0; slot <= 4; ++slot) {
        jobject local = nullptr;
        if (jvmti->GetLocalObject(thread, 0, slot, &local) != JVMTI_ERROR_NONE) {
            continue;
        }
        if (local != nullptr && esJavaMap(jni, local) && !esVolleyRequest(jni, local)) {
            return local;
        }
    }
    return nullptr;
}

void marcarVolleyPendiente(int tipo) {
    if (tls_pendiente.tipo == kNinguno) {
        tls_pendiente.tipo = tipo;
        tls_pendiente.inicio = std::chrono::steady_clock::now();
    }
}

void limpiarConexionAbierta(JNIEnv* env);

void procesarVolleyAlSalir(
    jvmtiEnv* jvmti,
    JNIEnv* jni,
    jthread thread,
    const char* nombre,
    jvalue returnValue,
    int64_t ms) {
    __android_log_print(ANDROID_LOG_INFO, kTag,
        "VOLLEY: procesarVolleyAlSalir nombre=%s tipo=%d returnValue.l=%p ms=%lld",
        nombre ? nombre : "?", tls_pendiente.tipo,
        static_cast<void*>(returnValue.l),
        static_cast<long long>(ms));
    // GetLocalObject suele fallar en ART para MethodEntry, pero funciona en
    // MethodExit. Si falla, request==null → emitirVolley* usa nullptr y extrae
    // body desde returnValue.l (NetworkResponse.data / HttpResponse.getData()).
    const jobject request = buscarRequestEnLocals(jvmti, jni, thread);
    if (request == nullptr) {
        emitirDiag("Volley MethodExit: sin Request en locals; body desde returnValue");
    }
    if (tls_pendiente.tipo == kVolleyPerformRequest &&
        strcmp(nombre, "performRequest") == 0) {
        emitirVolleyPerformRequest(jni, request, returnValue.l, ms);
        emitirDiag("Volley performRequest capturado (status+body)");
    } else if (tls_pendiente.tipo == kVolleyExecuteRequest &&
               strcmp(nombre, "executeRequest") == 0) {
        const jobject hdrExtra = request != nullptr
            ? buscarMapAdicionalEnLocals(jvmti, jni, thread) : nullptr;
        emitirVolleyExecuteRequest(jni, request, returnValue.l, hdrExtra, ms);
        emitirDiag("Volley executeRequest capturado (status+body)");
    }
    reiniciarCaptura();
    limpiarConexionAbierta(jni);
    tls_statusHttpPendiente = 0;
}

void limpiarConexionAbierta(JNIEnv* env) {
    if (tls_conexionAbierta != nullptr) {
        env->DeleteGlobalRef(tls_conexionAbierta);
        tls_conexionAbierta = nullptr;
    }
}

// Al salir getResponseCode: usa la conexión guardada por openConnection().
void procesarGetResponseCodeSalida(JNIEnv* jni, int status) {
    if (tls_conexionAbierta == nullptr && !tls_cap.activa) return;
    const int64_t ms = tls_cap.inicio.time_since_epoch().count() != 0
                           ? millisDesde(tls_cap.inicio)
                           : millisDesde(tls_conexionInicio);
    emitirCapturaCompleta(jni, status, ms);
    limpiarConexionAbierta(jni);
    tls_statusHttpPendiente = 0;
}

void JNICALL alEntrarMetodo(
    jvmtiEnv* jvmti,
    JNIEnv* jni,
    jthread thread,
    jmethodID method) {
    char* nombre = nullptr;
    char* firma = nullptr;
    if (jvmti->GetMethodName(method, &nombre, &firma, nullptr) != JVMTI_ERROR_NONE) {
        return;
    }
    if (nombre == nullptr) {
        jvmti->Deallocate(reinterpret_cast<unsigned char*>(firma));
        return;
    }
    // Filtro rápido por primer carácter — el 95% de los métodos no pasa.
    switch (nombre[0]) {
        case 'p': case 'e': case 'o':
        case 'g': case 'a': case 'd':
            break;
        default:
            jvmti->Deallocate(reinterpret_cast<unsigned char*>(nombre));
            jvmti->Deallocate(reinterpret_cast<unsigned char*>(firma));
            return;
    }

    const int tipo = detectarTipoEntrada(jvmti, method, nombre, firma);

    if (nombre != nullptr &&
        (strstr(nombre, "performRequest") != nullptr ||
         strstr(nombre, "executeRequest") != nullptr ||
         strstr(nombre, "volley") != nullptr)) {
        char buf[384];
        snprintf(
            buf,
            sizeof(buf),
            "metodo visto: %s tipo=%d firma=%s",
            nombre,
            tipo,
            firma != nullptr ? firma : "?");
        emitirDiag(buf);
    }

    // Volley: solo marcar inicio (Request se lee en MethodExit).
    if (tipo == kUrlOpenConnection) {
        tls_conexionInicio = std::chrono::steady_clock::now();
        capturarUrlOpenConnection(jvmti, jni, thread);
    } else if (tipo == kAppJsonBody || tipo == kRequestQueueAdd || tipo == kVolleyOnResponse) {
        if (tls_cap.inicio.time_since_epoch().count() == 0) {
            tls_cap.inicio = std::chrono::steady_clock::now();
        }
        tls_cap.activa = true;
        char buf[128];
        snprintf(buf, sizeof(buf), "captura app tipo=%d en %s", tipo, nombre);
        emitirDiag(buf);
    } else if (tipo == kVolleyPerformRequest || tipo == kVolleyExecuteRequest) {
        marcarVolleyPendiente(tipo);
        char buf[128];
        snprintf(buf, sizeof(buf), "volley pendiente tipo=%d en %s", tipo, nombre);
        emitirDiag(buf);
    } else if ((tipo == kOkHttpExecute || tipo == kOkHttpEnqueue) && tls_pendiente.tipo == kNinguno) {
        if (guardarEntrada(jvmti, jni, thread, tipo)) {
            char buf[128];
            snprintf(buf, sizeof(buf), "hook activo tipo=%d en %s", tipo, nombre);
            emitirDiag(buf);
            // OkHttp async: guardar identityHash(RealCall) → start time para correlación
            if (tipo == kOkHttpEnqueue && tls_pendiente.objetivo != nullptr) {
                const jint hash = identidadHash(jni, tls_pendiente.objetivo);
                if (hash != 0) {
                    const std::lock_guard<std::mutex> lock(g_okhttp_mutex);
                    g_okhttp_enqueue_start[hash] = tls_pendiente.inicio;
                }
            }
        }
    } else if (tipo == kCallbackOnResponse) {
        // Async OkHttp: capturar respuesta desde el callback onResponse
        if (tls_pendiente.tipo == kNinguno && guardarEntrada(jvmti, jni, thread, tipo)) {
            char buf[128];
            snprintf(buf, sizeof(buf), "okhttp onResponse hook en %s", nombre);
            emitirDiag(buf);
        }
    } else if (tipo == kCallbackOnFailure) {
        // Cleanup del mapa al fallar
        if (tls_pendiente.tipo == kNinguno && guardarEntrada(jvmti, jni, thread, tipo)) {
            char buf[128];
            snprintf(buf, sizeof(buf), "okhttp onFailure hook en %s", nombre);
            emitirDiag(buf);
        }
    } else if (nombre != nullptr && firma != nullptr &&
               (strcmp(nombre, "performRequest") == 0 ||
                strcmp(nombre, "executeRequest") == 0)) {
        char buf[256];
        snprintf(buf, sizeof(buf), "Volley sin match: %s %s", nombre, firma);
        emitirDiag(buf);
    }

    // Throttle: demora de subida antes de requests síncronos
    if (obtenerUpDelayMs() > 0 &&
        (tipo == kOkHttpExecute || tipo == kOkHttpEnqueue ||
         tipo == kVolleyPerformRequest || tipo == kVolleyExecuteRequest)) {
        usleep(obtenerUpDelayMs() * 1000);
    }
    // Throttle: demora de descarga antes de procesar respuesta async
    if (obtenerDownDelayMs() > 0 && tipo == kCallbackOnResponse) {
        usleep(obtenerDownDelayMs() * 1000);
    }

    jvmti->Deallocate(reinterpret_cast<unsigned char*>(nombre));
    jvmti->Deallocate(reinterpret_cast<unsigned char*>(firma));
}

bool esSalidaHook(const char* nombre, int tipo) {
    if (nombre == nullptr) return false;
    switch (tipo) {
        case kOkHttpExecute:
            return strcmp(nombre, "execute") == 0;
        case kOkHttpEnqueue:
            return strcmp(nombre, "enqueue") == 0;
        case kVolleyPerformRequest:
            return strcmp(nombre, "performRequest") == 0;
        case kVolleyExecuteRequest:
            return strcmp(nombre, "executeRequest") == 0;
        default:
            return false;
    }
}

void procesarSalida(JNIEnv* jni, const char* nombre, jboolean wasPopByException, jvalue returnValue, int64_t ms) {
    if (wasPopByException) return;

    switch (tls_pendiente.tipo) {
        case kVolleyExecuteRequest:
            if (strcmp(nombre, "executeRequest") == 0) {
                emitirVolleyExecuteRequest(
                    jni, tls_pendiente.objetivo, returnValue.l, nullptr, ms);
                limpiarConexionAbierta(jni);
            }
            break;
        case kVolleyPerformRequest:
            if (strcmp(nombre, "performRequest") == 0) {
                emitirVolleyPerformRequest(
                    jni, tls_pendiente.objetivo, returnValue.l, ms);
                limpiarConexionAbierta(jni);
            }
            break;
        case kOkHttpExecute:
            if (strcmp(nombre, "execute") == 0) {
                emitirDesdeOkHttpResponse(jni, returnValue.l, ms);
            }
            break;
        case kOkHttpEnqueue:
            // enqueue es void, no hay returnValue; nada que emitir aquí.
            break;
        default:
            break;
    }
}

void JNICALL alSalirMetodo(
    jvmtiEnv* jvmti,
    JNIEnv* jni,
    jthread thread,
    jmethodID method,
    jboolean wasPopByException,
    jvalue returnValue) {
    char* nombre = nullptr;
    char* firma = nullptr;
    if (jvmti->GetMethodName(method, &nombre, &firma, nullptr) != JVMTI_ERROR_NONE) {
        return;
    }
    if (nombre == nullptr) {
        jvmti->Deallocate(reinterpret_cast<unsigned char*>(firma));
        return;
    }
    // Filtro rápido por primer carácter — el 95% de los métodos no pasa.
    switch (nombre[0]) {
        case 'p': case 'e': case 'o':
        case 'g': case 'a': case 'd':
            break;
        default:
            jvmti->Deallocate(reinterpret_cast<unsigned char*>(nombre));
            jvmti->Deallocate(reinterpret_cast<unsigned char*>(firma));
            return;
    }

    if (!wasPopByException) {
        const int tipoSalida = detectarTipoEntrada(jvmti, method, nombre, firma);
        if (tipoSalida == kAppJsonBody) {
            capturarJsonRequest(jvmti, jni, thread);
        } else if (tipoSalida == kRequestQueueAdd) {
            capturarRequestQueueAdd(jvmti, jni, thread);
        } else if (tipoSalida == kVolleyOnResponse) {
            capturarOnResponse(jvmti, jni, thread);
        } else if (tipoSalida == kVolleyGetUrl && returnValue.l != nullptr) {
            tls_cap.url = jstringAStd(jni, static_cast<jstring>(returnValue.l));
            tls_cap.activa = true;
        } else if (tipoSalida == kVolleyGetHeaders && returnValue.l != nullptr) {
            const std::string hdrs = mapAJsonObjeto(jni, returnValue.l);
            if (hdrs != "{}") {
                tls_cap.reqHeaders = hdrs;
                tls_cap.activa = true;
                emitirDiag("headers capturados desde Request.getHeaders()");
            }
            if (jni->ExceptionCheck()) jni->ExceptionClear();
        }
    }

    // URL.openConnection() → guarda conexión y captura URL desde ella.
    // Durante Volley: captura solo la URL (necesaria) sin almacenar el global ref
    // de la conexión (para evitar que getResponseCode exit dispare emitirCapturaCompleta).
    if (!wasPopByException && nombre != nullptr &&
        strcmp(nombre, "openConnection") == 0 && returnValue.l != nullptr) {
        const bool esVolley = tls_pendiente.tipo == kVolleyPerformRequest ||
                              tls_pendiente.tipo == kVolleyExecuteRequest;
        if (!esVolley) {
            limpiarConexionAbierta(jni);
            tls_conexionAbierta = jni->NewGlobalRef(returnValue.l);
        }
        // Capturar URL desde la conexión (GetLocalObject falla en MethodEntry)
        const jclass connCls = jni->GetObjectClass(returnValue.l);
        const jmethodID midGetURL = jni->GetMethodID(connCls, "getURL", "()Ljava/net/URL;");
        if (midGetURL != nullptr) {
            const jobject urlObj = jni->CallObjectMethod(returnValue.l, midGetURL);
            if (!jni->ExceptionCheck() && urlObj != nullptr) {
                tls_cap.url = objetoAString(jni, urlObj);
                tls_cap.activa = true;
                emitirDiag("url capturada desde conexion en openConnection exit");
            } else {
                jni->ExceptionClear();
            }
        } else {
            jni->ExceptionClear();
        }
    }

    // Capturar body de HttpURLConnection (NO para Volley: éste lee NetworkResponse.data).
    // Si g_httpUrlConnectionBodyCapture es false, NO se consume el stream (no rompe la app).
    if (!wasPopByException && nombre != nullptr && firma != nullptr &&
        strcmp(nombre, "getInputStream") == 0 &&
        strcmp(firma, "()Ljava/io/InputStream;") == 0 && returnValue.l != nullptr &&
        tls_cap.respBody.empty() &&
        tls_pendiente.tipo != kVolleyPerformRequest &&
        tls_pendiente.tipo != kVolleyExecuteRequest &&
        g_httpUrlConnectionBodyCapture.load()) {
        tls_cap.respBody = leerInputStream(jni, returnValue.l);
        if (!tls_cap.respBody.empty()) {
            tls_cap.activa = true;
            emitirDiag("resp body capturado en getInputStream");
        }
    }

    // getResponseCode → emite flow completo con status + bodies acumulados.
    // NO interferir si Volley está activo (usa HttpURLConnection internamente).
    if (!wasPopByException && nombre != nullptr && firma != nullptr &&
        strcmp(nombre, "getResponseCode") == 0 && strcmp(firma, "()I") == 0 &&
        tls_pendiente.tipo != kVolleyPerformRequest &&
        tls_pendiente.tipo != kVolleyExecuteRequest &&
        (tls_conexionAbierta != nullptr || tls_cap.activa)) {
        procesarGetResponseCodeSalida(jni, returnValue.i);
    }

    // Volley library (si GetLocalObject funciona).
    if (!wasPopByException && tls_pendiente.tipo != kNinguno &&
        (tls_pendiente.tipo == kVolleyPerformRequest ||
         tls_pendiente.tipo == kVolleyExecuteRequest) &&
        esSalidaHook(nombre, tls_pendiente.tipo)) {
        const int64_t ms = millisDesde(tls_pendiente.inicio);
        if (obtenerDownDelayMs() > 0) {
            usleep(obtenerDownDelayMs() * 1000);
        }
        procesarVolleyAlSalir(jvmti, jni, thread, nombre, returnValue, ms);
        limpiarPendiente(jni);
    } else if (tls_pendiente.objetivo != nullptr &&
               (tls_pendiente.tipo == kOkHttpExecute ||
                tls_pendiente.tipo == kOkHttpEnqueue)) {
        const int64_t ms = millisDesde(tls_pendiente.inicio);
        if (esSalidaHook(nombre, tls_pendiente.tipo)) {
            if (obtenerDownDelayMs() > 0 && tls_pendiente.tipo == kOkHttpExecute) {
                usleep(obtenerDownDelayMs() * 1000);
            }
            procesarSalida(jni, nombre, wasPopByException, returnValue, ms);
            limpiarPendiente(jni);
        }
    } else if (!wasPopByException && tls_pendiente.tipo == kCallbackOnResponse &&
               strcmp(nombre, "onResponse") == 0) {
        // Async OkHttp: buscar Response en locales y emitir
        const jobject resp = buscarOkHttpResponseEnLocals(jvmti, jni, thread);
        if (resp != nullptr) {
            int64_t ms = millisDesde(tls_pendiente.inicio);
            // Intentar correlacionar con enqueue para duración precisa
            jobject call = nullptr;
            if (jvmti->GetLocalObject(thread, 0, 1, &call) == JVMTI_ERROR_NONE && call != nullptr) {
                const jint hash = identidadHash(jni, call);
                if (hash != 0) {
                    const std::lock_guard<std::mutex> lock(g_okhttp_mutex);
                    const auto it = g_okhttp_enqueue_start.find(hash);
                    if (it != g_okhttp_enqueue_start.end()) {
                        ms = millisDesde(it->second);
                        g_okhttp_enqueue_start.erase(it);
                    }
                }
                jni->DeleteLocalRef(call);
            }
            emitirDesdeOkHttpResponse(jni, resp, ms);
            emitirDiag("okhttp async onResponse capturado");
        }
        limpiarPendiente(jni);
    } else if (!wasPopByException && tls_pendiente.tipo == kCallbackOnFailure &&
               strcmp(nombre, "onFailure") == 0) {
        // Cleanup del mapa global
        jobject call = nullptr;
        if (jvmti->GetLocalObject(thread, 0, 1, &call) == JVMTI_ERROR_NONE && call != nullptr) {
            const jint hash = identidadHash(jni, call);
            if (hash != 0) {
                const std::lock_guard<std::mutex> lock(g_okhttp_mutex);
                g_okhttp_enqueue_start.erase(hash);
            }
            jni->DeleteLocalRef(call);
        }
        limpiarPendiente(jni);
    }

    jvmti->Deallocate(reinterpret_cast<unsigned char*>(nombre));
    jvmti->Deallocate(reinterpret_cast<unsigned char*>(firma));
}

}  // namespace

void registrarHooksUrlConnection(jvmtiEnv* jvmti, JavaVM* vm) {
    g_jvmti = jvmti;
    g_vm = vm;

    jvmtiEventCallbacks callbacks{};
    callbacks.MethodEntry = alEntrarMetodo;
    callbacks.MethodExit = alSalirMetodo;
    jvmti->SetEventCallbacks(&callbacks, sizeof(callbacks));
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_METHOD_ENTRY, nullptr);
    jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_METHOD_EXIT, nullptr);

    __android_log_print(
        ANDROID_LOG_INFO, kTag,
        "Hooks globales + filtro primer-char: "
        "Volley perfReq/execReq, URL.openConn, "
        "OkHttp exec/enqueue, Callback.onResp/onFailure");
}
