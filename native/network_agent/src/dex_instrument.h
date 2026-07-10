#pragma once

#include <jvmti.h>

// Instrumentación DEX vía slicer (AOSP dexter). Se invoca desde el
// ClassFileLoadHook: recibe el DEX crudo de UNA clase y, si es una clase
// objetivo (okhttp/Volley), devuelve un DEX nuevo con un Log.i inyectado al
// entrar a los métodos de red. Path para Samsung One UI, donde MethodEntry/Exit
// no despacha pero RetransformClasses/ClassFileLoadHook sí (ver memoria).
//
// nombreClase llega en forma VM ("okhttp3/RealCall", sin L; ni ;).
// Devuelve true si reescribió: entonces *nuevoDatos/*nuevoLen quedan con un
// buffer asignado por jvmti->Allocate (ART toma posesión). Si devuelve false,
// no tocar los out-params (ART usa el DEX original).
bool instrumentarDex(
    jvmtiEnv* jvmti,
    const char* nombreClase,
    const unsigned char* datos,
    jint len,
    unsigned char** nuevoDatos,
    jint* nuevoLen);
