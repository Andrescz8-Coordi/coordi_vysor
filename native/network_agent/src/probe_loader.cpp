#include "probe_loader.h"

#include "probe_dex.h"
#include "socket_emitter.h"

#include <android/log.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>

namespace {

constexpr const char* kTag = "CoordiNetAgent";
std::atomic<bool> g_probeCargado{false};

// Directorio donde ART cargó nuestra .so (típicamente <data>/code_cache): es
// escribible por el uid de la app y buen lugar para dejar el jar del helper.
// Se lee de /proc/self/maps buscando la línea de libcoordi_net_agent.so.
std::string dirDeLaSo() {
    FILE* f = fopen("/proc/self/maps", "re");
    if (f == nullptr) return {};
    char linea[1024];
    std::string ruta;
    while (fgets(linea, sizeof(linea), f) != nullptr) {
        const char* p = strstr(linea, "coordi_net_agent.so");
        if (p == nullptr) continue;
        // La ruta es el último campo de la línea (empieza en el primer '/').
        const char* slash = strchr(linea, '/');
        if (slash == nullptr) continue;
        ruta.assign(slash);
        // quitar newline final
        while (!ruta.empty() && (ruta.back() == '\n' || ruta.back() == '\r')) {
            ruta.pop_back();
        }
        break;
    }
    fclose(f);
    if (ruta.empty()) return {};
    const size_t barra = ruta.find_last_of('/');
    if (barra == std::string::npos) return {};
    return ruta.substr(0, barra);
}

bool escribirArchivo(const std::string& ruta, const unsigned char* datos, size_t len) {
    FILE* f = fopen(ruta.c_str(), "wbe");
    if (f == nullptr) return false;
    const size_t n = fwrite(datos, 1, len, f);
    fclose(f);
    return n == len;
}

}  // namespace

namespace {

std::string jstringAUtf8(JNIEnv* env, jstring s) {
    if (s == nullptr) return {};
    const char* chars = env->GetStringUTFChars(s, nullptr);
    if (chars == nullptr) return {};
    std::string out(chars);
    env->ReleaseStringUTFChars(s, chars);
    return out;
}

void JNICALL nativeEmitirFlow(JNIEnv* env, jclass, jstring json) {
    emitirJson(jstringAUtf8(env, json));
}

}  // namespace

bool registrarNativosProbe(JNIEnv* env) {
    if (env == nullptr) return false;
    const jclass claseProbe = env->FindClass("coordi/probe/Probe");
    if (claseProbe == nullptr || env->ExceptionCheck()) {
        env->ExceptionClear();
        emitirDiag("probe: FindClass coordi/probe/Probe fallo (nativeEmit no quedo disponible)");
        return false;
    }
    JNINativeMethod metodos[] = {
        {const_cast<char*>("nativeEmit"), const_cast<char*>("(Ljava/lang/String;)V"),
         reinterpret_cast<void*>(nativeEmitirFlow)},
    };
    const jint rc = env->RegisterNatives(claseProbe, metodos, 1);
    char buf[96];
    snprintf(buf, sizeof(buf), "probe: RegisterNatives nativeEmit rc=%d", rc);
    emitirDiag(buf);
    return rc == JNI_OK;
}

bool cargarProbeEnBootstrap(jvmtiEnv* jvmti) {
    if (jvmti == nullptr) return false;
    if (g_probeCargado.exchange(true)) return true;  // ya cargado en este proceso

    const std::string dir = dirDeLaSo();
    if (dir.empty()) {
        emitirDiag("probe: no se pudo ubicar el dir de la .so");
        g_probeCargado.store(false);
        return false;
    }
    const std::string jarPath = dir + "/coordi_probe.jar";

    if (!escribirArchivo(jarPath, g_probeJar, g_probeJar_len)) {
        char buf[256];
        snprintf(buf, sizeof(buf), "probe: fallo al escribir %s", jarPath.c_str());
        emitirDiag(buf);
        g_probeCargado.store(false);
        return false;
    }

    const jvmtiError rc = jvmti->AddToBootstrapClassLoaderSearch(jarPath.c_str());
    char buf[256];
    snprintf(buf, sizeof(buf), "probe: AddToBootstrapClassLoaderSearch(%s) rc=%d",
             jarPath.c_str(), rc);
    emitirDiag(buf);
    __android_log_print(ANDROID_LOG_INFO, kTag, "%s", buf);

    if (rc != JVMTI_ERROR_NONE) {
        g_probeCargado.store(false);
        return false;
    }
    return true;
}
