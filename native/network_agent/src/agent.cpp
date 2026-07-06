#include "socket_emitter.h"
#include "url_connection_hooks.h"

#include <android/log.h>
#include <jvmti.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

namespace {

constexpr const char* kTag = "CoordiNetAgent";
constexpr int kPuertoPredeterminado = 9876;

JavaVM* g_vm = nullptr;
jvmtiEnv* g_jvmti = nullptr;

int parsearPuerto(const char* opciones) {
    if (opciones == nullptr) return kPuertoPredeterminado;
    const char* clave = strstr(opciones, "port=");
    if (clave == nullptr) return kPuertoPredeterminado;
    return atoi(clave + 5);
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
    __android_log_print(ANDROID_LOG_INFO, kTag, "Agent_OnAttach puerto=%d", puerto);

    iniciarSocket(puerto);

    jvmtiEnv* jvmti = nullptr;
    const jint rc = vm->GetEnv(reinterpret_cast<void**>(&jvmti), JVMTI_VERSION_1_2);
    if (rc != JNI_OK || jvmti == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "GetEnv JVMTI falló: %d", rc);
        emitirAgenteListo(puerto);
        return JNI_OK;
    }
    g_jvmti = jvmti;

    jvmtiCapabilities caps{};
    caps.can_generate_method_entry_events = 1;
    caps.can_generate_method_exit_events = 1;
    caps.can_access_local_variables = 1;
    caps.can_retransform_classes = 1;
    const jvmtiError capRc = jvmti->AddCapabilities(&caps);
    if (capRc != JVMTI_ERROR_NONE) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "AddCapabilities falló: %d", capRc);
        char buf[64];
        snprintf(buf, sizeof(buf), "AddCapabilities error=%d", capRc);
        emitirDiag(buf);
    } else {
        emitirDiag("JVMTI capabilities OK");
    }

    registrarHooksUrlConnection(jvmti, vm);
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
