#pragma once

#include <jvmti.h>

/// Registra hooks JVMTI sobre java.net.HttpURLConnection (best-effort).
void registrarHooksUrlConnection(jvmtiEnv* jvmti, JavaVM* vm);
