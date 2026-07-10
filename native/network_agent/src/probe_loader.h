#pragma once

#include <jni.h>
#include <jvmti.h>

// Materializa el helper coordi.probe.Probe (jar embebido) a disco y lo agrega al
// bootstrap classloader vía JVMTI, de modo que el bytecode reescrito por slicer
// en okhttp/Volley pueda resolver Lcoordi/probe/Probe;. Idempotente: una sola
// carga efectiva por proceso. Devuelve true si el classloader search quedó
// configurado.
bool cargarProbeEnBootstrap(jvmtiEnv* jvmti);

// Vincula Probe.nativeEmit(String) a la emisión nativa (socket_emitter), para
// que los flows con body+headers grandes salgan por el socket TCP (sin límite
// de tamaño) en vez de depender solo de Log.i — un solo log entry de Android
// trunca silenciosamente alrededor de ~4KB (LOGGER_ENTRY_MAX_PAYLOAD), y un
// FLOW con Authorization Bearer + body JSON puede superar eso fácilmente,
// llegando cortado (JSON inválido) al host y descartándose sin aviso.
// Requiere que Probe ya esté en el bootstrap classloader (cargarProbeEnBootstrap).
bool registrarNativosProbe(JNIEnv* env);
