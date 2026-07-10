#include "probe_loader.h"
#include "socket_emitter.h"
#include "url_connection_hooks.h"

#include <android/log.h>
#include <atomic>
#include <jvmti.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

namespace {

constexpr const char* kTag = "CoordiNetAgent";
constexpr int kPuertoPredeterminado = 9876;

JavaVM* g_vm = nullptr;
jvmtiEnv* g_jvmti = nullptr;
// Un solo attach-agent real por proceso: reintentos de attachAgentVerified
// (probar package + cada PID) pueden invocar Agent_OnAttach varias veces
// sobre el mismo proceso ya instrumentado. Cada llamada pediría un jvmtiEnv
// nuevo y volvería a registrar MethodEntry/MethodExit global — dos jvmtiEnv
// activos despachan el mismo evento dos veces a alEntrarMetodo/alSalirMetodo,
// pisando tls_pendiente (global ref JNI) entre sí → use-after-free / crash.
std::atomic<bool> g_hooksRegistrados{false};

int parsearPuerto(const char* opciones) {
    if (opciones == nullptr) return kPuertoPredeterminado;
    const char* clave = strstr(opciones, "port:");
    if (clave == nullptr) return kPuertoPredeterminado;
    return atoi(clave + 5);
}

// "record:1" arranca grabando; ausente o "record:0" deja los hooks inactivos
// (attach por sí solo no debe pagar el costo de deopt global de la VM).
bool parsearGrabar(const char* opciones) {
    if (opciones == nullptr) return false;
    const char* clave = strstr(opciones, "record:");
    if (clave == nullptr) return false;
    return atoi(clave + 7) != 0;
}

void emitirAgenteListo(int puerto) {
    char buffer[256];
    snprintf(
        buffer,
        sizeof(buffer),
        R"({"type":"agent_ready","port":%d,"tag":"CoordiNetAgent"})",
        puerto);
    emitirJson(buffer);
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL Agent_OnLoad(JavaVM* vm, char* options, void* reserved) {
    (void)options;
    (void)reserved;
    g_vm = vm;
    __android_log_print(ANDROID_LOG_INFO, kTag, "Agent_OnLoad");
    return JNI_OK;
}

#include <unistd.h>

namespace {

void* hiloAutoPrueba(void*) {
    sleep(2);
    emitirDiag("autoprueba: agente vivo en el proceso");
    emitirJson(
        R"({"id":"selftest","method":"TEST","url":"agent://pipeline-ok","status":200,"reqHeaders":{},"reqBody":"","respHeaders":{},"respBody":"","durationMs":0,"ts":0})");
    return nullptr;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM* vm, char* options, void* reserved) {
    (void)reserved;
    g_vm = vm;

    const int puerto = parsearPuerto(options);
    const bool grabar = parsearGrabar(options);
    __android_log_print(
        ANDROID_LOG_INFO, kTag, "Agent_OnAttach puerto=%d grabar=%d", puerto, grabar);

    iniciarSocket(puerto);

    if (g_hooksRegistrados.exchange(true)) {
        // Proceso ya instrumentado (reintento de attachAgentVerified, o toggle
        // de grabación desde la UI): NO pedir un jvmtiEnv nuevo ni volver a
        // registrar callbacks (eso fue lo que causaba el doble-dispatch/crash).
        // Solo ajustar si los hooks ya registrados están activos o no.
        __android_log_print(
            ANDROID_LOG_WARN, kTag,
            "Agent_OnAttach repetido en este proceso: solo se ajusta grabacion");
        if (g_jvmti != nullptr) activarCaptura(g_jvmti, grabar);
        emitirAgenteListo(puerto);
        return JNI_OK;
    }

    jvmtiEnv* jvmti = nullptr;
    const jint rc = vm->GetEnv(reinterpret_cast<void**>(&jvmti), JVMTI_VERSION_1_2);
    if (rc != JNI_OK || jvmti == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "GetEnv JVMTI falló: %d", rc);
        emitirAgenteListo(puerto);
        return JNI_OK;
    }
    g_jvmti = jvmti;

    // Qué capabilities soporta este ART (Samsung One UI puede recortarlas).
    jvmtiCapabilities pot{};
    jvmti->GetPotentialCapabilities(&pot);
    {
        char buf[224];
        snprintf(
            buf, sizeof(buf),
            "caps potenciales: methodEntry=%d methodExit=%d localVars=%d "
            "retransform=%d retransformAny=%d redefine=%d allClassHook=%d",
            pot.can_generate_method_entry_events, pot.can_generate_method_exit_events,
            pot.can_access_local_variables, pot.can_retransform_classes,
            pot.can_retransform_any_class, pot.can_redefine_classes,
            pot.can_generate_all_class_hook_events);
        emitirDiag(buf);
    }

    // AddCapabilities es atómico: si una cap del set no está disponible, falla
    // TODO el set. Se piden en grupos separados para aislar qué soporta el
    // dispositivo (una cap no válida no debe tumbar las demás).
    jvmtiCapabilities capsTrace{};
    capsTrace.can_generate_method_entry_events = 1;
    capsTrace.can_generate_method_exit_events = 1;
    capsTrace.can_access_local_variables = 1;
    const jvmtiError rcTrace = jvmti->AddCapabilities(&capsTrace);

    jvmtiCapabilities capsRetr{};
    capsRetr.can_retransform_classes = 1;
    const jvmtiError rcRetr = jvmti->AddCapabilities(&capsRetr);

    // Grupo propio y separado: ClassFileLoadHook durante RetransformClasses de
    // una clase ya cargada solo necesita can_retransform_classes, pero el
    // despacho del hook para clases HTTP cargadas por primera vez DESPUÉS de
    // que el agente ya está activo (el caso normal: el usuario graba y recién
    // ahí navega) requiere can_generate_all_class_hook_events. Sin esta cap,
    // probarRetransform() puede reportar ok>0 sobre lo ya cargado pero nunca
    // instrumentar nada de lo que se cargue después → cero flows.
    jvmtiCapabilities capsClassHook{};
    capsClassHook.can_generate_all_class_hook_events = 1;
    const jvmtiError rcClassHook = jvmti->AddCapabilities(&capsClassHook);

    {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "AddCapabilities trace_rc=%d retransform_rc=%d classhook_rc=%d",
                 rcTrace, rcRetr, rcClassHook);
        emitirDiag(buf);
    }
    if (rcTrace != JVMTI_ERROR_NONE) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "AddCapabilities trace falló: %d", rcTrace);
    }
    if (rcRetr != JVMTI_ERROR_NONE) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "AddCapabilities retransform falló: %d", rcRetr);
    }
    if (rcClassHook != JVMTI_ERROR_NONE) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "AddCapabilities classhook falló: %d", rcClassHook);
    }

    // Cargar el helper Probe en el bootstrap classloader ANTES de instrumentar:
    // el bytecode reescrito referencia Lcoordi/probe/Probe;, y si una clase se
    // verifica sin que Probe sea resoluble, ART rechaza la reescritura.
    cargarProbeEnBootstrap(jvmti);

    registrarHooksUrlConnection(jvmti, vm);
    activarCaptura(jvmti, grabar);
    emitirAgenteListo(puerto);

    pthread_t prueba;
    pthread_create(&prueba, nullptr, hiloAutoPrueba, nullptr);
    pthread_detach(prueba);

    return JNI_OK;
}

extern "C" JNIEXPORT void JNICALL Agent_OnUnload(JavaVM* vm) {
    (void)vm;
    __android_log_print(ANDROID_LOG_INFO, kTag, "Agent_OnUnload");
}
