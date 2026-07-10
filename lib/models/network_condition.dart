enum SignalStrength {
  full('Normal — sin cambios', null),
  high('4G/LTE', 11),
  medium('3G', 2),
  low('2G/GSM', 1),
  poor('Mala señal (2G + latencia)', 1);

  final String label;
  final int? preferredNetworkMode;
  const SignalStrength(this.label, this.preferredNetworkMode);
}

class NetworkCondition {
  final bool enabled;
  final int uploadSpeedKbps;
  final int downloadSpeedKbps;
  final int latencyMs;
  final int packetLossPercent;
  final SignalStrength signalStrength;

  const NetworkCondition({
    this.enabled = false,
    this.uploadSpeedKbps = 20,
    this.downloadSpeedKbps = 50,
    this.latencyMs = 0,
    this.packetLossPercent = 0,
    this.signalStrength = SignalStrength.full,
  });

  NetworkCondition copyWith({
    bool? enabled,
    int? uploadSpeedKbps,
    int? downloadSpeedKbps,
    int? latencyMs,
    int? packetLossPercent,
    SignalStrength? signalStrength,
  }) {
    return NetworkCondition(
      enabled: enabled ?? this.enabled,
      uploadSpeedKbps: uploadSpeedKbps ?? this.uploadSpeedKbps,
      downloadSpeedKbps: downloadSpeedKbps ?? this.downloadSpeedKbps,
      latencyMs: latencyMs ?? this.latencyMs,
      packetLossPercent: packetLossPercent ?? this.packetLossPercent,
      signalStrength: signalStrength ?? this.signalStrength,
    );
  }

  bool get hasSpeedLimits =>
      uploadSpeedKbps > 0 || downloadSpeedKbps > 0;

  bool get hasLatency => latencyMs > 0 || packetLossPercent > 0;

  bool get hasSignalChange => signalStrength != SignalStrength.full;

  bool get hasAnyEffect =>
      enabled && (hasSpeedLimits || hasLatency || hasSignalChange);
}
