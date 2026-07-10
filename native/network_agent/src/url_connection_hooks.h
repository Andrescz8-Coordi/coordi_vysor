#pragma once

#include <jvmti.h>

/// Registra los callbacks MethodEntry/MethodExit (quedan inactivos hasta
/// llamar a activarCaptura — evita pagar el costo de deopt global de la VM
/// mientras no se está grabando activamente).
void registrarHooksUrlConnection(jvmtiEnv* jvmti, JavaVM* vm);

/// Habilita o deshabilita el despacho de MethodEntry/MethodExit ya
/// registrados. Debe llamarse después de registrarHooksUrlConnection.
void activarCaptura(jvmtiEnv* jvmti, bool activar);
