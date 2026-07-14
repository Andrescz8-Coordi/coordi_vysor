enum NetworkType { wifi, mobile, none }

enum SignalQuality {
  excellent,
  good,
  regular,
  poor,
  none;

  String get label {
    switch (this) {
      case SignalQuality.excellent:
        return 'Excelente';
      case SignalQuality.good:
        return 'Buena';
      case SignalQuality.regular:
        return 'Regular';
      case SignalQuality.poor:
        return 'Mala';
      case SignalQuality.none:
        return 'Sin señal';
    }
  }
}

class NetworkStatus {
  final NetworkType type;
  final String typeLabel;

  // WiFi info (siempre disponible si WiFi conectado)
  final String ssid;
  final int rssiDbm;
  final SignalQuality wifiSignalQuality;
  final int wifiSignalLevel; // 0-4

  // Mobile info (siempre disponible si hay transporte celular)
  final String carrier;
  final int mobileSignalLevel; // 0-4, 0 = no disponible
  final SignalQuality mobileSignalQuality;
  final int dataSimSlot; // -1 desconocido, 0 = SIM1, 1 = SIM2
  final String networkGeneration; // ej. "4G", "5G", ""

  // Señal de la red activa (compatibilidad hacia atrás)
  int get signalLevel => type == NetworkType.wifi ? wifiSignalLevel : mobileSignalLevel;
  SignalQuality get signalQuality => type == NetworkType.wifi ? wifiSignalQuality : mobileSignalQuality;

  // Speed
  final double downloadSpeedKbps;
  final double uploadSpeedKbps;
  final String linkSpeedMbps;

  const NetworkStatus({
    this.type = NetworkType.none,
    this.typeLabel = 'Desconectado',
    this.ssid = '',
    this.rssiDbm = 0,
    this.wifiSignalQuality = SignalQuality.none,
    this.wifiSignalLevel = 0,
    this.carrier = '',
    this.mobileSignalLevel = 0,
    this.mobileSignalQuality = SignalQuality.none,
    this.dataSimSlot = -1,
    this.networkGeneration = '',
    this.downloadSpeedKbps = 0,
    this.uploadSpeedKbps = 0,
    this.linkSpeedMbps = '',
  });

  String get signalIcon {
    final lvl = signalLevel;
    switch (lvl) {
      case 4:
        return '▂▄▆█';
      case 3:
        return '▂▄▆';
      case 2:
        return '▂▄';
      case 1:
        return '▂';
      default:
        return '✕';
    }
  }

  String get downloadSpeedLabel {
    if (downloadSpeedKbps >= 1000) {
      return '${(downloadSpeedKbps / 1000).toStringAsFixed(1)} Mbps';
    }
    return '${downloadSpeedKbps.toStringAsFixed(0)} kbps';
  }

  String get uploadSpeedLabel {
    if (uploadSpeedKbps >= 1000) {
      return '${(uploadSpeedKbps / 1000).toStringAsFixed(1)} Mbps';
    }
    return '${uploadSpeedKbps.toStringAsFixed(0)} kbps';
  }

  static SignalQuality qualityFromRssi(int rssi) {
    if (rssi >= -50) return SignalQuality.excellent;
    if (rssi >= -60) return SignalQuality.good;
    if (rssi >= -70) return SignalQuality.regular;
    return SignalQuality.poor;
  }

  static int levelFromRssi(int rssi) {
    if (rssi >= -50) return 4;
    if (rssi >= -60) return 3;
    if (rssi >= -70) return 2;
    return 1;
  }
}
