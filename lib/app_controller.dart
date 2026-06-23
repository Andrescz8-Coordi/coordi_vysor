import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
    scrcpy.changes.listen(_onScrcpyChange);
    capture.changes.listen((_) => notifyListeners());
    capture.flows.listen(_onFlow);
  }

  void _onScrcpyChange(_) {
    _checkDisconnectedRecordings();
    notifyListeners();
  }

  final BinaryResolver _resolver;
  late AdbService _adb;
  late ScrcpyService scrcpy;
  late NetworkCaptureService capture;

  Timer? _poll;
  List<Device> devices = [];
  String? error;
  bool loading = false;
  ThemeMode themeMode = ThemeMode.dark;

  bool get isDark => themeMode == ThemeMode.dark;

  void toggleTheme() {
    themeMode = isDark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
  }

  ScrcpyOptions options = const ScrcpyOptions(
    maxSize: 1280,
    bitrateMbps: 3,
    maxFps: 30,
    videoCodec: 'h265',
    compress: true,
    compressCrf: 28,
    stayAwake: true,
  );

  Future<void> init() async {
    await _adb.startServer();
    await refresh();
    unawaited(listScreens());
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

  // ── Recording ─────────────────────────────────────────────────────────────

  final Set<String> _recordingSerials = {};
  final Map<String, String> _recordingPaths = {};
  Timer? _recordTimer;
  Duration _recordElapsed = Duration.zero;
  bool _restartingRecording = false;

  bool isRecording(String serial) => _recordingSerials.contains(serial);
  Duration get recordElapsed => _recordElapsed;

  /// Returns a unique temp path for a new recording.
  String _tempRecordPath() {
    final tmp = Platform.environment['TMPDIR'] ??
        Platform.environment['TEMP'] ??
        Platform.environment['TMP'] ??
        '/tmp';
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '$tmp/scrcpy_rec_$ts.mp4';
  }

  /// Native save dialog – returns chosen path or null if cancelled.
  Future<String?> _showSaveDialog({String? suggested}) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final defaultName = suggested ?? 'scrcpy_$ts.mp4';

    if (Platform.isMacOS) {
      final r = await Process.run('osascript', [
        '-e', 'try',
        '-e', 'set f to choose file name with prompt "Guardar grabación" '
            'default name "$defaultName"',
        '-e', 'return POSIX path of f',
        '-e', 'end try',
      ]);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim();
        if (p.isNotEmpty) return p;
      }
      return null;
    }

    if (Platform.isLinux) {
      final r = await Process.run('zenity', [
        '--file-selection', '--save', '--confirm-overwrite',
        '--filename=$defaultName',
        '--title=Guardar grabación',
      ]);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim();
        if (p.isNotEmpty) return p;
      }
      return null;
    }

    if (Platform.isWindows) {
      final script =
          'Add-Type -AssemblyName System.Windows.Forms; '
          r'$f=new-object System.Windows.Forms.SaveFileDialog; '
          r'$f.Filter="MP4 Files (*.mp4)|*.mp4"; '
          r'$f.FileName="'"$defaultName"'"; '
          r'if($f.ShowDialog()){$f.FileName}';
      final r = await Process.run('powershell', ['-Command', script]);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim();
        if (p.isNotEmpty) return p;
      }
      return null;
    }

    return null;
  }

  /// Auto-save a recording file to Desktop with a timestamp name.
  Future<void> _autoSaveRecording(String tempPath) async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final dest = '$home/Desktop/scrcpy_${DateTime.now().millisecondsSinceEpoch}.mp4';
    if (await File(tempPath).exists()) {
      try {
        await File(tempPath).rename(dest);
      } catch (_) {
        try {
          await File(tempPath).copy(dest);
          await File(tempPath).delete();
        } catch (_) {}
      }
    }
  }

  /// Called from scrcpy changes listener – cleans up recordings that ended
  /// unexpectedly (device disconnected, scrcpy window closed, etc.).
  void _checkDisconnectedRecordings() {
    if (_restartingRecording) return;
    for (final serial in _recordingSerials.toList()) {
      if (!scrcpy.isRunning(serial)) {
        _recordingSerials.remove(serial);
        final tempPath = _recordingPaths.remove(serial);
        if (tempPath != null) {
          _autoSaveRecording(tempPath);
        }
      }
    }
    if (_recordingSerials.isEmpty) {
      _stopTimer();
    }
  }

  /// Dynamically start recording on an already-running mirror.
  Future<void> startRecording(String serial) async {
    if (isRecording(serial) || !scrcpy.isRunning(serial)) return;

    final path = _tempRecordPath();
    _recordingSerials.add(serial);
    _recordingPaths[serial] = path;

    _restartingRecording = true;
    await scrcpy.stopAndWait(serial);
    _restartingRecording = false;

    final recOpts = options.copyWith(record: true, recordPath: path);
    await scrcpy.launch(serial, recOpts);

    _resetTimer();
    notifyListeners();
  }

  /// Stop recording and ask where to save the file.
  Future<void> stopRecording(String serial) async {
    if (!isRecording(serial)) return;
    _recordingSerials.remove(serial);
    final tempPath = _recordingPaths.remove(serial);
    _stopTimer();

    await scrcpy.stopAndWait(serial);

    if (tempPath != null && await File(tempPath).exists()) {
      String? finalPath = tempPath;
      if (options.compress) {
        finalPath = await _compressVideo(tempPath);
      }

      if (finalPath != null && await File(finalPath).exists()) {
        final dest = await _showSaveDialog(
          suggested: 'scrcpy_${DateTime.now().millisecondsSinceEpoch}.mp4',
        );
        if (dest != null) {
          try {
            await File(finalPath).rename(dest);
          } catch (_) {
            await File(finalPath).copy(dest);
            await File(finalPath).delete();
          }
        } else {
          await _autoSaveRecording(finalPath);
        }
      }
    }

    notifyListeners();
  }

  /// Re-encode video with ffmpeg to reduce file size.
  Future<String?> _compressVideo(String sourcePath) async {
    final ffmpeg = await _resolver.ffmpeg();
    if (ffmpeg.isEmpty) return null;

    final compressedPath = '${sourcePath}_compressed.mp4';
    try {
      final r = await Process.run(ffmpeg, [
        '-i', sourcePath,
        '-c:v', 'libx265',
        '-crf', options.compressCrf.toString(),
        '-preset', 'fast',
        '-tag:v', 'hvc1',
        '-c:a', 'aac',
        '-b:a', '64k',
        '-movflags', '+faststart',
        '-y',
        compressedPath,
      ]);
      if (r.exitCode != 0) return null;
      final srcSize = File(sourcePath).lengthSync();
      final dstSize = File(compressedPath).lengthSync();
      if (dstSize >= srcSize) {
        await File(compressedPath).delete();
        return sourcePath;
      }
      await File(sourcePath).delete();
      return compressedPath;
    } catch (_) {
      return null;
    }
  }

  /// Cancel recording and delete the temp file.
  Future<void> cancelRecording(String serial) async {
    if (!isRecording(serial)) return;
    _recordingSerials.remove(serial);
    _recordingPaths.remove(serial);
    _stopTimer();
    await scrcpy.stopAndDelete(serial);
    notifyListeners();
  }

  void _startTimer() {
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordElapsed += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  void _resetTimer() {
    _recordElapsed = Duration.zero;
    _startTimer();
  }

  void _stopTimer() {
    _recordTimer?.cancel();
    _recordTimer = null;
  }

  // ── Screen capture (desktop) ─────────────────────────────────────────────

  Process? _screenCapProcess;
  String? _screenCapPath;
  bool _screenCapturing = false;
  Timer? _screenCapTimer;
  Duration _screenCapElapsed = Duration.zero;
  List<String> _screenList = [];
  int _selectedScreen = 1;

  bool get isScreenCapturing => _screenCapturing;
  Duration get screenCapElapsed => _screenCapElapsed;
  List<String> get availableScreens => _screenList;
  int get selectedScreen => _selectedScreen;

  set selectedScreen(int v) {
    _selectedScreen = v;
    notifyListeners();
  }

  /// Detect available screens by querying ffmpeg avfoundation.
  Future<void> listScreens() async {
    final ffmpeg = await _resolver.ffmpeg();
    if (ffmpeg.isEmpty) return;
    try {
      final r = await Process.run(ffmpeg, [
        '-f', 'avfoundation', '-list_devices', 'true', '-i', '',
      ]);
      final stderr = (r.stderr as String?) ?? '';
      final screens = <String>[];
      final reg = RegExp(r'\[(\d+)\]\s+Capture screen');
      for (final m in reg.allMatches(stderr)) {
        final idx = int.parse(m.group(1)!);
        screens.add('Pantalla ${screens.length + 1} (índice $idx)');
      }
      if (screens.isEmpty) {
        screens.add('Pantalla principal');
      }
      _screenList = screens;
      if (_selectedScreen >= _screenList.length) {
        _selectedScreen = screens.length > 1 ? 1 : 0;
      }
      notifyListeners();
    } catch (_) {
      if (_screenList.isEmpty) _screenList = ['Pantalla principal'];
    }
  }

  /// Start recording the selected desktop display using ffmpeg.
  Future<void> startScreenCapture() async {
    if (_screenCapturing) return;
    final ffmpeg = await _resolver.ffmpeg();
    if (ffmpeg.isEmpty) return;

    final tmp = Platform.environment['TMPDIR'] ??
        Platform.environment['TEMP'] ??
        '/tmp';
    final ts = DateTime.now().millisecondsSinceEpoch;
    _screenCapPath = '$tmp/screencap_$ts.mp4';

    try {
      _screenCapProcess = await Process.start(ffmpeg, [
        '-f', 'avfoundation',
        '-i', '$_selectedScreen',
        '-c:v', 'libx265',
        '-crf', '28',
        '-preset', 'fast',
        '-tag:v', 'hvc1',
        '-c:a', 'aac',
        '-b:a', '64k',
        '-movflags', '+faststart',
        '-y',
        _screenCapPath!,
      ]);
      _screenCapturing = true;
      _resetScreenCapTimer();
      notifyListeners();
    } catch (_) {
      _screenCapPath = null;
    }
  }

  /// Stop ffmpeg process (modal is handled by the UI).
  Future<void> stopScreenCaptureProcess() async {
    if (!_screenCapturing) return;
    _screenCapturing = false;
    _stopScreenCapTimer();
    _screenCapProcess?.kill(ProcessSignal.sigterm);
    await _screenCapProcess?.exitCode;
    _screenCapProcess = null;
    notifyListeners();
  }

  /// After process stops, show save dialog and handle the file.
  Future<void> saveScreenCapture() async {
    final path = _screenCapPath;
    _screenCapPath = null;
    if (path != null && await File(path).exists()) {
      final dest = await _showSaveDialog(
        suggested: 'pantalla_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      if (dest != null) {
        try {
          await File(path).rename(dest);
        } catch (_) {
          await File(path).copy(dest);
          await File(path).delete();
        }
      } else {
        await _autoSaveRecording(path);
      }
    }
  }

  void _startScreenCapTimer() {
    _screenCapTimer?.cancel();
    _screenCapTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _screenCapElapsed += const Duration(seconds: 1);
      notifyListeners();
    });
  }

  void _resetScreenCapTimer() {
    _screenCapElapsed = Duration.zero;
    _startScreenCapTimer();
  }

  void _stopScreenCapTimer() {
    _screenCapTimer?.cancel();
    _screenCapTimer = null;
  }

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
    _screenCapTimer?.cancel();
    if (_screenCapturing) {
      _screenCapProcess?.kill(ProcessSignal.sigterm);
    }
    scrcpy.dispose();
    capture.dispose();
    super.dispose();
  }
}
