#pragma once

#include <jvmti.h>

// Materializa el helper coordi.probe.Probe (jar embebido) a disco y lo agrega al
// bootstrap classloader vía JVMTI, de modo que el bytecode reescrito por slicer
// en okhttp/Volley pueda resolver Lcoordi/probe/Probe;. Idempotente: una sola
// carga efectiva por proceso. Devuelve true si el classloader search quedó
// configurado.
bool cargarProbeEnBootstrap(jvmtiEnv* jvmti);
