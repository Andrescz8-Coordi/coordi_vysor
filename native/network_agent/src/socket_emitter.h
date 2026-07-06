#pragma once

#include <string>

/// Emite una línea JSON por Logcat (tag CoordiNetAgent) y por socket TCP local.
void emitirJson(const std::string& json);

/// Mensaje de diagnóstico (Logcat tag DIAG + JSON type=diag).
void emitirDiag(const std::string& mensaje);

/// Inicia el cliente TCP hacia el host (adb reverse). Idempotente.
void iniciarSocket(int puerto);
