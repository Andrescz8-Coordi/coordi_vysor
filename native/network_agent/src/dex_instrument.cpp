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

// Métodos objetivo: puntos de entrada de red en okhttp y Volley. Al entrar, se
// inyecta (vía slicer EntryHook con tweak ArrayParams) una llamada a
// coordi.probe.Probe.<hook>(Object[]), que extrae URL/método por reflexión y
// emite `FLOW {json}` por Log.i (el host lo parsea desde logcat/socket).
// El helper vive en el bootstrap classloader (ver probe_loader), así que las
// clases de la app pueden resolverlo.
struct Objetivo {
    const char* claseDescriptor;  // forma "Lokhttp3/internal/connection/RealCall;"
    const char* metodo;
    const char* hook;  // método estático en Lcoordi/probe/Probe;
};
constexpr Objetivo kObjetivos[] = {
    {"Lokhttp3/RealCall;", "execute", "onOkHttp"},
    {"Lokhttp3/RealCall;", "enqueue", "onOkHttp"},
    {"Lokhttp3/internal/connection/RealCall;", "execute", "onOkHttp"},
    {"Lokhttp3/internal/connection/RealCall;", "enqueue", "onOkHttp"},
    {"Lcom/android/volley/RequestQueue;", "add", "onVolley"},
    {"Lcom/android/volley/toolbox/BasicNetwork;", "performRequest", "onVolley"},
    {"Lcom/android/volley/toolbox/HurlStack;", "executeRequest", "onVolley"},
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

const char* hookPara(const char* claseDesc, const char* metodo) {
    for (const auto& o : kObjetivos) {
        if (strcmp(o.claseDescriptor, claseDesc) == 0 &&
            strcmp(o.metodo, metodo) == 0) {
            return o.hook;
        }
    }
    return nullptr;
}

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
    for (auto& m : dex_ir->encoded_methods) {
        if (m->code == nullptr) continue;  // abstracto/nativo
        const char* claseM = m->decl->parent->descriptor->c_str();
        const char* nombreM = m->decl->name->c_str();
        const char* hook = hookPara(claseM, nombreM);
        if (hook == nullptr) continue;

        slicer::MethodInstrumenter mi(dex_ir);
        // ArrayParams: reenvía [firma, this, params...] como Object[] a
        // Probe.<hook>(Object[]) — una sola firma sirve para todos los overloads.
        mi.AddTransformation<slicer::EntryHook>(
            ir::MethodId(kProbeClase, hook),
            slicer::EntryHook::Tweak::ArrayParams);
        if (mi.InstrumentMethod(m.get())) {
            ++instrumentados;
            char buf[256];
            snprintf(buf, sizeof(buf), "DEX hook %s: %s->%s", hook, claseM, nombreM);
            emitirDiag(buf);
        }
    }

    if (instrumentados == 0) return false;

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
