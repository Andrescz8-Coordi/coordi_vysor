#include "dex_instrument.h"

#include "socket_emitter.h"

#include <android/log.h>
#include <cstring>
#include <string>

#include "slicer/dex_ir.h"
#include "slicer/instrumentation.h"
#include "slicer/reader.h"
#include "slicer/writer.h"

namespace {

constexpr const char* kTag = "CoordiNetAgent";

// Métodos objetivo: puntos de entrada de red en okhttp y Volley.
//
// Volley: mismo patrón entry+exit que OkHttp, sobre
// BasicNetwork.performRequest(Request) — único choke point (todo
// RequestQueue/NetworkDispatcher pasa por acá con el Network estándar).
// Devuelve NetworkResponse (status/headers/body) pero no referencia al
// Request original, así que el EntryHook (ArrayParams, guarda el Request) y
// el ExitHook (ReturnAsObject, recibe el NetworkResponse) se correlacionan
// por ThreadLocal en Probe.java — ver ahí. RequestQueue.add/HurlStack.exec
// NO se instrumentan: quedarían como filas duplicadas incompletas junto a la
// de performRequest, que ya cubre el caso estándar completo.
//
// OkHttp: tanto RealCall.execute() (síncrono) como RealCall$AsyncCall (async,
// enqueue) llaman internamente a RealCall.getResponseWithInterceptorChain()
// antes de devolver/despachar el Response — es el único choke point común a
// ambos casos. Se instrumenta con DOS transformaciones sobre ese mismo
// método: un EntryHook (Tweak::ThisAsObject, sin params) que solo marca el
// timestamp de inicio, y un ExitHook (Tweak::ReturnAsObject) que recibe el
// Response ya completo (con .request() adentro) y emite el flow entero.
// Probe.<hook> vive en el bootstrap classloader (ver probe_loader), así que
// las clases de la app pueden resolverlo. El flow se emite por Log.i con tag
// CoordiNetAgent (`FLOW {json}`), que el host parsea desde logcat/socket.
enum class TipoHook {
    kEntryArrayParams,  // Volley: EntryHook + ArrayParams -> Probe.<hook>(Object[])
    kEntryTimestamp,    // OkHttp: EntryHook + ThisAsObject -> Probe.<hook>(Object), marca inicio
    kExitResult,        // OkHttp: ExitHook + ReturnAsObject -> Probe.<hook>(Object), flow completo
};

struct Objetivo {
    const char* claseDescriptor;  // forma "Lokhttp3/internal/connection/RealCall;"
    const char* metodo;
    const char* hook;  // método estático en Lcoordi/probe/Probe;
    TipoHook tipo;
};
constexpr Objetivo kObjetivos[] = {
    // "$okhttp": Kotlin sufija así los métodos `internal` (mangling de ABI) —
    // confirmado en vivo (Samsung A55, wms.dev):
    // getResponseWithInterceptorChain$okhttp. Se deja también el nombre sin
    // sufijo por si alguna versión/variante de OkHttp lo compila distinto
    // (p.ej. OkHttp 3.x, escrito en Java puro, sin mangling de Kotlin).
    {"Lokhttp3/RealCall;", "getResponseWithInterceptorChain$okhttp", "onOkHttpEntry",
     TipoHook::kEntryTimestamp},
    {"Lokhttp3/RealCall;", "getResponseWithInterceptorChain$okhttp", "onOkHttpResult",
     TipoHook::kExitResult},
    {"Lokhttp3/RealCall;", "getResponseWithInterceptorChain", "onOkHttpEntry",
     TipoHook::kEntryTimestamp},
    {"Lokhttp3/RealCall;", "getResponseWithInterceptorChain", "onOkHttpResult",
     TipoHook::kExitResult},
    {"Lokhttp3/internal/connection/RealCall;", "getResponseWithInterceptorChain$okhttp",
     "onOkHttpEntry", TipoHook::kEntryTimestamp},
    {"Lokhttp3/internal/connection/RealCall;", "getResponseWithInterceptorChain$okhttp",
     "onOkHttpResult", TipoHook::kExitResult},
    {"Lokhttp3/internal/connection/RealCall;", "getResponseWithInterceptorChain",
     "onOkHttpEntry", TipoHook::kEntryTimestamp},
    {"Lokhttp3/internal/connection/RealCall;", "getResponseWithInterceptorChain",
     "onOkHttpResult", TipoHook::kExitResult},
    {"Lcom/android/volley/toolbox/BasicNetwork;", "performRequest", "onVolleyEntry",
     TipoHook::kEntryArrayParams},
    {"Lcom/android/volley/toolbox/BasicNetwork;", "performRequest", "onVolleyResult",
     TipoHook::kExitResult},
    // BasicNetwork.performRequest NO retorna normalmente para status HTTP de
    // error: lanza ServerError/ClientError/AuthFailureError (subclases de
    // VolleyError), así que el ExitHook de arriba (que solo instrumenta
    // returns normales, no unwind de excepción) nunca dispara para 4xx/5xx —
    // esas requests quedaban invisibles en el inspector. NetworkDispatcher.run()
    // atrapa el VolleyError y siempre llama a Request.parseNetworkError(error)
    // antes de entregarlo (parseAndDeliverNetworkError) — ese es un choke point
    // de retorno NORMAL con el Request original como "this" y el VolleyError
    // como único parámetro (que trae el NetworkResponse real en su campo
    // `networkResponse` si el error vino de una respuesta HTTP real).
    {"Lcom/android/volley/Request;", "parseNetworkError", "onVolleyErrorEntry",
     TipoHook::kEntryArrayParams},
};

constexpr const char* kProbeClase = "Lcoordi/probe/Probe;";

// Writer::Allocator respaldado por jvmti->Allocate: ART toma posesión del
// buffer devuelto por el ClassFileLoadHook, así que debe salir de JVMTI.
class AsignadorJvmti : public dex::Writer::Allocator {
 public:
    explicit AsignadorJvmti(jvmtiEnv* jvmti) : jvmti_(jvmti) {}
    void* Allocate(size_t size) override {
        unsigned char* mem = nullptr;
        if (jvmti_->Allocate(static_cast<jlong>(size), &mem) != JVMTI_ERROR_NONE) {
            return nullptr;
        }
        return mem;
    }
    void Free(void* ptr) override {
        if (ptr != nullptr) jvmti_->Deallocate(static_cast<unsigned char*>(ptr));
    }

 private:
    jvmtiEnv* jvmti_;
};

}  // namespace

bool instrumentarDex(
    jvmtiEnv* jvmti,
    const char* nombreClase,
    const unsigned char* datos,
    jint len,
    unsigned char** nuevoDatos,
    jint* nuevoLen) {
    if (nombreClase == nullptr || datos == nullptr || len <= 0) return false;

    // Descriptor VM "okhttp3/RealCall" → "Lokhttp3/RealCall;".
    std::string desc = "L";
    desc += nombreClase;
    desc += ";";

    bool claseInteresa = false;
    for (const auto& o : kObjetivos) {
        if (desc == o.claseDescriptor) {
            claseInteresa = true;
            break;
        }
    }
    if (!claseInteresa) return false;

    dex::Reader reader(datos, static_cast<size_t>(len));
    const dex::u4 idx = reader.FindClassIndex(desc.c_str());
    if (idx == dex::kNoIndex) return false;
    reader.CreateClassIr(idx);
    auto dex_ir = reader.GetIr();

    int instrumentados = 0;
    // Si 0 métodos matchean, esto queda vacío de diagnóstico: sin esto no hay
    // forma de distinguir "la clase no cargó" de "cargó pero el nombre del
    // método objetivo no coincide" (p.ej. Kotlin manglea nombres internal con
    // sufijo $moduleName en algunas versiones de una lib) — se acumulan los
    // nombres reales vistos en la clase para emitirlos si no hubo match.
    std::string metodosVistos;
    bool pistaInterceptorChain = false;
    for (auto& m : dex_ir->encoded_methods) {
        if (m->code == nullptr) continue;  // abstracto/nativo
        const char* claseM = m->decl->parent->descriptor->c_str();
        const char* nombreM = m->decl->name->c_str();

        if (strcmp(claseM, desc.c_str()) == 0) {
            if (strstr(nombreM, "InterceptorChain") != nullptr) pistaInterceptorChain = true;
            if (metodosVistos.size() < 3000) {
                if (!metodosVistos.empty()) metodosVistos += ",";
                metodosVistos += nombreM;
            }
        }

        // Un mismo método puede llevar varias transformaciones (OkHttp: entry
        // de timestamp + exit de resultado) — se agregan todas al mismo
        // MethodInstrumenter antes de aplicar (así el IR se recodifica una
        // sola vez por método, no una vez por transformación).
        slicer::MethodInstrumenter mi(dex_ir);
        bool algunaCoincide = false;
        char hooksAplicados[128] = {0};
        for (const auto& o : kObjetivos) {
            if (strcmp(o.claseDescriptor, claseM) != 0 || strcmp(o.metodo, nombreM) != 0) {
                continue;
            }
            switch (o.tipo) {
                case TipoHook::kEntryArrayParams:
                    mi.AddTransformation<slicer::EntryHook>(
                        ir::MethodId(kProbeClase, o.hook),
                        slicer::EntryHook::Tweak::ArrayParams);
                    break;
                case TipoHook::kEntryTimestamp:
                    mi.AddTransformation<slicer::EntryHook>(
                        ir::MethodId(kProbeClase, o.hook),
                        slicer::EntryHook::Tweak::ThisAsObject);
                    break;
                case TipoHook::kExitResult:
                    mi.AddTransformation<slicer::ExitHook>(
                        ir::MethodId(kProbeClase, o.hook),
                        slicer::ExitHook::Tweak::ReturnAsObject);
                    break;
            }
            algunaCoincide = true;
            strncat(hooksAplicados, o.hook, sizeof(hooksAplicados) - strlen(hooksAplicados) - 2);
            strncat(hooksAplicados, "+", sizeof(hooksAplicados) - strlen(hooksAplicados) - 1);
        }
        if (!algunaCoincide) continue;

        if (mi.InstrumentMethod(m.get())) {
            ++instrumentados;
            char buf[256];
            snprintf(buf, sizeof(buf), "DEX hook %s: %s->%s", hooksAplicados, claseM, nombreM);
            emitirDiag(buf);
        }
    }

    if (instrumentados == 0) {
        std::string msg = "DEX sin match en " + desc + " (0 metodos, InterceptorChain=" +
                           (pistaInterceptorChain ? "SI" : "no") +
                           "). Metodos con codigo: " + metodosVistos;
        emitirDiag(msg);
        return false;
    }

    AsignadorJvmti asignador(jvmti);
    dex::Writer writer(dex_ir);
    size_t nuevoTam = 0;
    dex::u1* imagen = writer.CreateImage(&asignador, &nuevoTam);
    if (imagen == nullptr || nuevoTam == 0) {
        __android_log_print(ANDROID_LOG_ERROR, kTag,
            "DEX writer falló para %s", desc.c_str());
        return false;
    }

    *nuevoDatos = imagen;
    *nuevoLen = static_cast<jint>(nuevoTam);
    __android_log_print(ANDROID_LOG_INFO, kTag,
        "DEX reescrito %s: %d metodos, %zu bytes", desc.c_str(), instrumentados, nuevoTam);
    return true;
}
