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
