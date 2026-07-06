/// App Android instalada y marcada como debuggable en el manifiesto.
class DebugApp {
  final String package;
  final String? label;
  final bool isRunning;

  const DebugApp({
    required this.package,
    this.label,
    this.isRunning = false,
  });
}
