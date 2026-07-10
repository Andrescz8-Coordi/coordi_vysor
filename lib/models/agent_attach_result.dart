/// Resultado de intentar inyectar el agente JVMTI en un proceso Android.
class AgentAttachResult {
  final bool agentDetectedInLogcat;
  final String attemptsLog;
  final String agentPathUsed;
  final String? processInfo;
  final String logcatSnippet;

  const AgentAttachResult({
    required this.agentDetectedInLogcat,
    required this.attemptsLog,
    required this.agentPathUsed,
    this.processInfo,
    required this.logcatSnippet,
  });
}

/// El agente se empujó e intentó adjuntar, pero nunca apareció en Logcat.
///
/// Estructurado (en vez de un String armado) para que la UI muestre el
/// consejo accionable (abrir la app) separado de los detalles técnicos
/// (proceso, logcat, comando manual), no todo junto como un solo bloque.
class AgentAttachError implements Exception {
  final String package;
  final String processInfo;
  final String logcatSnippet;
  final String manualCommand;

  const AgentAttachError({
    required this.package,
    required this.processInfo,
    required this.logcatSnippet,
    required this.manualCommand,
  });

  @override
  String toString() =>
      'El agente no apareció en Logcat tras attach-agent ($package).';
}
