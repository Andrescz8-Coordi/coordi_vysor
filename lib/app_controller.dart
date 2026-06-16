import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models/device.dart';
import 'models/network_flow.dart';
import 'models/scrcpy_options.dart';
import 'services/adb_service.dart';
import 'services/binary_resolver.dart';
import 'services/network_capture_service.dart';
import 'services/scrcpy_service.dart';

/// Central app state: holds services, polls for devices, owns shared options.
class AppController extends ChangeNotifier {
  AppController() : _resolver = BinaryResolver() {
    _adb = AdbService(_resolver);
    scrcpy = ScrcpyService(_resolver);
    capture = NetworkCaptureService(_resolver);
    scrcpy.changes.listen((_) => notifyListeners());
    capture.changes.listen((_) => notifyListeners());
    capture.flows.listen(_onFlow);
  }

  final BinaryResolver _resolver;
  late AdbService _adb;
  late ScrcpyService scrcpy;
  late NetworkCaptureService capture;

  Timer? _poll;
  List<Device> devices = [];
  String? error;
  bool loading = false;

  ScrcpyOptions options = const ScrcpyOptions(
    maxSize: 0,
    bitrateMbps: 8,
    maxFps: 60,
    stayAwake: true,
  );

  Future<void> init() async {
    await _adb.startServer();
    await refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      devices = await _adb.listDevices();
      error = null;
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<String> connectTcp(String hostPort) async {
    final msg = await _adb.connectTcp(hostPort);
    await refresh();
    return msg;
  }

  Future<String> disconnectTcp(String hostPort) async {
    final msg = await _adb.disconnectTcp(hostPort);
    await refresh();
    return msg;
  }

  /// USB-connected, ready devices (candidates for Wi-Fi setup).
  List<Device> get usbDevices => devices
      .where((d) => d.isReady && AdbService.isUsbSerial(d.serial))
      .toList();

  /// Wi-Fi wizard step 1: enable TCP/IP mode on a USB device.
  Future<String> enableTcpip(String serial, {int port = 5555}) async {
    final msg = await _adb.tcpip(serial, port: port);
    await refresh();
    return msg;
  }

  /// Wi-Fi wizard helper: auto-detect the device's Wi-Fi IP.
  Future<String?> detectDeviceIp(String serial) => _adb.deviceIp(serial);

  void updateOptions(ScrcpyOptions next) {
    options = next;
    notifyListeners();
  }

  bool isRunning(String serial) => scrcpy.isRunning(serial);

  Future<void> launch(Device device) async {
    try {
      await scrcpy.launch(device.serial, options);
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> stop(String serial) => scrcpy.stop(serial);

  // ── Network capture ──────────────────────────────────────────────────────

  List<NetworkFlow> flows = [];
  String? captureSerial;
  String? captureError;

  /// App filter by package name (Opción A: UID via /proc/net).
  String? targetPackage;
  int? targetUid;
  bool onlyTargetApp = false;
  final Map<int, int> _portUidCache = {};

  bool get capturing => capture.isRunning;

  /// Flows shown in the UI, optionally filtered to the target app's UID.
  List<NetworkFlow> get visibleFlows {
    if (!onlyTargetApp || targetUid == null) return flows;
    return flows.where((f) => f.appUid == targetUid).toList();
  }

  /// Resolve each flow's owning app UID (best-effort) before listing it.
  Future<void> _onFlow(NetworkFlow f) async {
    final serial = captureSerial;
    if (serial != null && f.clientPort != 0) {
      var uid = _portUidCache[f.clientPort];
      if (uid == null) {
        uid = await _adb.uidForPort(serial, f.clientPort);
        if (uid != null) _portUidCache[f.clientPort] = uid;
      }
      f.appUid = uid;
    }
    flows.add(f);
    notifyListeners();
  }

  /// Set/clear the package whose traffic we want to isolate. Resolves its UID
  /// against the capturing device.
  Future<void> setTargetPackage(String? package) async {
    final pkg = (package == null || package.trim().isEmpty)
        ? null
        : package.trim();
    targetPackage = pkg;
    targetUid = null;
    final serial = captureSerial;
    if (pkg != null && serial != null) {
      targetUid = await _adb.packageUid(serial, pkg);
    }
    notifyListeners();
  }

  void setOnlyTargetApp(bool value) {
    onlyTargetApp = value;
    notifyListeners();
  }

  /// Default mitmproxy CA cert location (generated on first mitmdump run).
  String get caCertPath =>
      p.join(_homeDir, '.mitmproxy', 'mitmproxy-ca-cert.cer');

  String get _homeDir =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';

  /// Start mitmdump and point [device]'s proxy at the local host.
  Future<void> startCapture(Device device, {int port = 8080}) async {
    captureError = null;
    try {
      final host = await _adb.hostLanIp();
      if (host == null) {
        throw Exception('No se pudo determinar la IP LAN del host.');
      }
      await capture.start(port: port);
      await _adb.setDeviceProxy(device.serial, '$host:$port');
      captureSerial = device.serial;
      _portUidCache.clear();
      // Resolve the target UID now that we know which device is capturing.
      if (targetPackage != null) {
        targetUid = await _adb.packageUid(device.serial, targetPackage!);
      }
    } catch (e) {
      captureError = e.toString();
      await capture.stop();
    }
    notifyListeners();
  }

  /// Stop capture and clear the device proxy.
  Future<void> stopCapture() async {
    final serial = captureSerial;
    await capture.stop();
    if (serial != null) {
      try {
        await _adb.clearDeviceProxy(serial);
      } catch (_) {/* best effort */}
    }
    captureSerial = null;
    notifyListeners();
  }

  void clearFlows() {
    flows = [];
    _portUidCache.clear();
    notifyListeners();
  }

  /// Push mitmproxy CA cert to [serial] and open Settings to install it.
  Future<void> installCaCert(String serial) =>
      _adb.pushCaCert(serial, caCertPath);

  @override
  void dispose() {
    _poll?.cancel();
    scrcpy.dispose();
    capture.dispose();
    super.dispose();
  }
}
