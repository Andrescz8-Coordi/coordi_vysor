import 'dart:async';
import 'dart:io';

import '../models/network_status.dart';
import 'binary_resolver.dart';

class NetworkMonitorService {
  NetworkMonitorService(this._bin);

  final BinaryResolver _bin;

  Timer? _timer;
  String? _serial;

  final _statusCtrl = StreamController<NetworkStatus>.broadcast();
  Stream<NetworkStatus> get status => _statusCtrl.stream;

  bool get isRunning => _timer != null;

  // Previous /proc/net/dev counters for speed calculation
  int _prevRxBytes = 0;
  int _prevTxBytes = 0;
  DateTime _prevTime = DateTime.now();
  bool _hasPrevReading = false;

  void start(String serial) {
    _serial = serial;
    _prevRxBytes = 0;
    _prevTxBytes = 0;
    _prevTime = DateTime.now();
    _hasPrevReading = false;
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _serial = null;
  }

  void dispose() {
    stop();
    _statusCtrl.close();
  }

  Future<String> _sh(String cmd) async {
    final serial = _serial;
    if (serial == null) return '';
    final adb = await _bin.adb();
    final r = await Process.run(adb, ['-s', serial, 'shell', cmd]);
    if (r.exitCode != 0) return '';
    return (r.stdout as String).trim();
  }

  void _poll() async {
    final serial = _serial;
    if (serial == null) return;

    try {
      final status = await _readStatus();
      _statusCtrl.add(status);
    } catch (_) {}
  }

  Future<NetworkStatus> _readStatus() async {
    // 1. Connectivity info — transports puede ser "WIFI, CELLULAR" (comma-separated)
    //    SignalStrength es nivel 0–4 para celular en dumpsys connectivity
    final connOut = await _sh(
        'dumpsys connectivity 2>/dev/null | grep -oE "Transports: [A-Z_, ]+|Capabilities: [A-Z_ ]+|Link[UD]pBandwidth>=?[0-9]+|InterfaceName: [a-z0-9]+|RSSI: [-0-9]+|SSID: \\"[^\\"]*\\"|SignalStrength: [-0-9]+"');

    // 2. Interface stats for speed (todo el archivo, parseamos en Dart)
    final netOut = await _sh('cat /proc/net/dev 2>/dev/null');

    // 3. Carrier name
    final carrier = await _sh('getprop gsm.operator.alpha 2>/dev/null');

    // 4. SIM activa para datos (0=SIM1, 1=SIM2)
    final dataSim = await _sh('settings get global multi_sim_data_call 2>/dev/null');

    // 5. Generación de red (gprs/edge/umts/hspa/lte/nr)
    final netType = await _sh('getprop gsm.network.type 2>/dev/null');

    // 6. Señal móvil: extraemos cualquier número razonable desde telephony.registry
    //    (formato variable según API: mGsmSignalStrength=15, mLteSignalStrength=20,
    //     o valores dentro de SignalStrength[{...}])
    final signalRaw = await _sh(
        'dumpsys telephony.registry 2>/dev/null | grep -i "SignalStrength" | head -5');

    return _parse(connOut, netOut, carrier, dataSim, netType, signalRaw);
  }

  NetworkStatus _parse(String connOut, String netOut, String carrier, String dataSim, String netType, String signalRaw) {
    final lines = connOut.split('\n');

    String ssid = '';
    int rssi = 0;
    String linkSpeed = '';

    // Detectar transports (pueden venir comma-separated: "WIFI, CELLULAR")
    bool hasCellularTransport = false;
    bool hasWifiTransport = false;
    for (final line in lines) {
      if (line.startsWith('Transports: ')) {
        final ts = line.substring('Transports: '.length);
        if (ts.contains('CELLULAR')) hasCellularTransport = true;
        if (ts.contains('WIFI')) hasWifiTransport = true;
      }
      if (line.contains('SSID:')) {
        final m = RegExp(r'SSID: "([^"]*)"').firstMatch(line);
        if (m != null) ssid = m.group(1) ?? '';
      }
      if (line.contains('RSSI:')) {
        final m = RegExp(r'RSSI: ([-0-9]+)').firstMatch(line);
        if (m != null) {
          rssi = int.tryParse(m.group(1) ?? '0') ?? 0;
        }
      }
    }

    // Determinar tipo de red activo
    // Prioridad: WiFi conectado > gsm.network.type (puede ser residual)
    final hasMobileData = netType.isNotEmpty;
    NetworkType type;
    String typeLabel;
    if (hasWifiTransport) {
      type = NetworkType.wifi;
      typeLabel = 'WiFi';
    } else if (hasMobileData || hasCellularTransport) {
      type = NetworkType.mobile;
      typeLabel = 'Red Móvil';
    } else {
      type = NetworkType.none;
      typeLabel = 'Desconectado';
    }

    // Speed from /proc/net/dev (todas las interfaces excepto loopback)
    final now = DateTime.now();
    double rxKbps = 0, txKbps = 0;

    final netLines = netOut.split('\n');
    int curRx = 0, curTx = 0;
    for (final line in netLines) {
      if (!line.contains(':')) continue;
      final trimmed = line.trim();
      if (trimmed.startsWith('Inter') || trimmed.startsWith('face')) continue;
      final iface = trimmed.split(':')[0].trim();
      if (iface == 'lo') continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length >= 10) {
        curRx += int.tryParse(parts[1]) ?? 0;
        curTx += int.tryParse(parts[9]) ?? 0;
      }
    }

    if (_hasPrevReading) {
      final dt = now.difference(_prevTime).inMilliseconds;
      if (dt > 0) {
        rxKbps = (curRx - _prevRxBytes) * 8.0 / dt;
        txKbps = (curTx - _prevTxBytes) * 8.0 / dt;
      }
    }
    _prevRxBytes = curRx;
    _prevTxBytes = curTx;
    _prevTime = now;
    _hasPrevReading = true;

    // === Señal WiFi ===
    final wifiQuality = rssi != 0
        ? NetworkStatus.qualityFromRssi(rssi)
        : SignalQuality.none;
    final wifiLevel = rssi != 0
        ? NetworkStatus.levelFromRssi(rssi)
        : 0;

    // === Señal móvil (siempre, aunque estemos en WiFi) ===
    int mobileLevel = 0;
    SignalQuality mobileQuality = SignalQuality.none;

    // 1. Intentar dumpsys telephony.registry (cualquier ASU 1-31)
    final asuNumbers = RegExp(r'[0-9]+')
        .allMatches(signalRaw)
        .map((m) => int.tryParse(m.group(0) ?? '99') ?? 99)
        .where((n) => n >= 1 && n <= 31)
        .toList();
    if (asuNumbers.isNotEmpty) {
      mobileLevel = asuNumbers.first ~/ 8 + 1;
      if (mobileLevel > 4) mobileLevel = 4;
    }

    // 2. Fallback: SignalStrength nivel 0-4 desde dumpsys connectivity
    if (mobileLevel == 0) {
      for (final line in lines) {
        if (line.contains('SignalStrength:')) {
          final m = RegExp(r'SignalStrength: ([-0-9]+)').firstMatch(line);
          if (m != null) {
            final v = int.tryParse(m.group(1) ?? '-1') ?? -1;
            if (v >= 0 && v <= 4) {
              mobileLevel = v;
              break;
            }
            if (v < 0) {
              mobileLevel = NetworkStatus.levelFromRssi(v);
              break;
            }
          }
        }
      }
    }
    if (mobileLevel >= 1 && mobileLevel <= 4) {
      const levels = [
        SignalQuality.none,
        SignalQuality.poor,
        SignalQuality.regular,
        SignalQuality.good,
        SignalQuality.excellent,
      ];
      mobileQuality = levels[mobileLevel];
    }

    // SIM activa para datos
    int simSlot = -1;
    if (dataSim.isNotEmpty) {
      simSlot = int.tryParse(dataSim) ?? -1;
    }

    // Etiqueta de generación de red
    String generation = '';
    if (netType.isNotEmpty) {
      final t = netType.toUpperCase();
      if (t.contains('NR') || t.contains('5G')) {
        generation = '5G';
      } else if (t.contains('LTE')) {
        generation = '4G';
      } else if (t.contains('HSPA') || t.contains('HSDPA') || t.contains('HSUPA') || t.contains('UMTS')) {
        generation = '3G';
      } else if (t.contains('EDGE') || t.contains('GPRS')) {
        generation = '2G';
      }
    }

    return NetworkStatus(
      type: type,
      typeLabel: typeLabel,
      ssid: ssid,
      rssiDbm: rssi,
      wifiSignalQuality: wifiQuality,
      wifiSignalLevel: wifiLevel,
      carrier: carrier.isNotEmpty ? carrier : '',
      mobileSignalLevel: mobileLevel,
      mobileSignalQuality: mobileQuality,
      dataSimSlot: simSlot,
      networkGeneration: generation,
      downloadSpeedKbps: rxKbps,
      uploadSpeedKbps: txKbps,
      linkSpeedMbps: linkSpeed,
    );
  }
}
