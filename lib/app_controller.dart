import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'models/agent_attach_result.dart';
import 'models/debug_app.dart';
import 'models/device.dart';
import 'models/network_flow.dart';
import 'models/network_status.dart';
import 'models/scrcpy_options.dart';
import 'services/agent_network_service.dart';
import 'services/adb_service.dart';
import 'services/binary_resolver.dart';
import 'services/network_monitor_service.dart';
import 'services/preferences_service.dart';
import 'services/scrcpy_service.dart';
import 'services/update_service.dart';

/// Central app state: holds services, polls for devices, owns shared options.
class AppController extends ChangeNotifier {
  AppController() : _resolver = BinaryResolver() {
    _adb = AdbService(_resolver);
    scrcpy = ScrcpyService(_resolver);
    agentCapture = AgentNetworkService(_resolver, _adb);
    networkMonitor = NetworkMonitorService(_resolver);
    scrcpy.changes.listen(_onScrcpyChange);
    agentCapture.changes.listen((_) => notifyListeners());
    agentCapture.flows.listen(_onFlow);
    agentCapture.status.listen((msg) {
      agentStatus = msg;
      _appendAgentDiag(msg);
      notifyListeners();
    });
    agentCapture.diagnostics.listen(_appendAgentDiag);
    networkMonitor.status.listen((s) {
      _networkStatus = s;
      notifyListeners();
    });
  }

  void _onScrcpyChange(_) {
    _checkDisconnectedRecordings();
    notifyListeners();
  }

  final BinaryResolver _resolver;
  final PreferencesService _prefs = PreferencesService();
  late AdbService _adb;
  late ScrcpyService scrcpy;
  late AgentNetworkService agentCapture;
  late NetworkMonitorService networkMonitor;

  Timer? _poll;
  List<Device> devices = [];
  String? error;
  bool loading = false;
  ThemeMode themeMode = ThemeMode.light;

  bool get isDark => themeMode == ThemeMode.dark;

  void toggleTheme() {
    themeMode = isDark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
    unawaited(_persistPreferences());
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
    await _loadPreferences();
    await _adb.startServer();
    await refresh();
    unawaited(checkForUpdate());
    unawaited(listScreens());
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  final UpdateService updateService = UpdateService();
  UpdateInfo? pendingUpdate;

  Future<UpdateInfo?> checkForUpdate() async {
    final info = await updateService.check();
    if (info != null) {
      pendingUpdate = info;
    } else {
      pendingUpdate = null;
    }
    notifyListeners();
    return info;
  }

  /// Loads previously saved options-panel + theme preferences, if any.
  Future<void> _loadPreferences() async {
    final saved = await _prefs.load();
    if (saved.isEmpty) return;
    final savedOptions = saved['options'];
    if (savedOptions is Map<String, dynamic>) {
      options = ScrcpyOptions.fromJson(savedOptions);
    }
    if (saved['themeMode'] == 'dark') {
      themeMode = ThemeMode.dark;
    } else if (saved['themeMode'] == 'light') {
      themeMode = ThemeMode.light;
    }
    notifyListeners();
  }

  /// Saves the current options-panel + theme selections to disk.
  Future<void> _persistPreferences() async {
    await _prefs.save({
      'options': options.toJson(),
      'themeMode': isDark ? 'dark' : 'light',
    });
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
    unawaited(_persistPreferences());
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
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/tmp';
    final sep = Platform.isWindows ? r'\' : '/';
    final dest = '$home${sep}Desktop${sep}scrcpy_${DateTime.now().millisecondsSinceEpoch}.mp4';
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
      String finalPath = tempPath;
      if (options.compress) {
        finalPath = await _compressVideo(tempPath) ?? tempPath;
      }

      if (await File(finalPath).exists()) {
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
        // hvc1 tag is Apple-specific; only needed for macOS/iOS compatibility
        if (Platform.isMacOS) ...['-tag:v', 'hvc1'],
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
  // Linux only: detected monitors [{name, x, y, w, h}]
  final List<Map<String, dynamic>> _linuxMonitors = [];

  bool get isScreenCapturing => _screenCapturing;
  Duration get screenCapElapsed => _screenCapElapsed;
  List<String> get availableScreens => _screenList;
  int get selectedScreen => _selectedScreen;

  set selectedScreen(int v) {
    _selectedScreen = v;
    notifyListeners();
  }

  /// Detect available screens using ffmpeg (platform-specific).
  Future<void> listScreens() async {
    if (Platform.isLinux) {
      await _listScreensLinux();
      return;
    }
    final ffmpeg = await _resolver.ffmpeg();
    if (ffmpeg.isEmpty) {
      if (_screenList.isEmpty) _screenList = ['Pantalla principal'];
      return;
    }
    try {
      final args = _screenListArgs();
      if (args == null) {
        if (_screenList.isEmpty) _screenList = ['Pantalla principal'];
        return;
      }
      final r = await Process.run(ffmpeg, args);
      final stderr = (r.stderr as String?) ?? '';
      _screenList = _parseScreenList(stderr);
      if (_screenList.isEmpty) _screenList = ['Pantalla principal'];
      if (_selectedScreen >= _screenList.length) {
        _selectedScreen = _screenList.length > 1 ? 1 : 0;
      }
      notifyListeners();
    } catch (_) {
      if (_screenList.isEmpty) _screenList = ['Pantalla principal'];
    }
  }

  Future<void> _listScreensLinux() async {
    _linuxMonitors.clear();
    final isWayland = Platform.environment['WAYLAND_DISPLAY'] != null &&
        Platform.environment['DISPLAY'] == null;
    if (!isWayland) {
      try {
        final r = await Process.run('xrandr', ['--listmonitors']);
        if (r.exitCode == 0) {
          // Line format: " 0: +*eDP-1 1920/344x1080/194+0+0  eDP-1"
          final re = RegExp(
              r'\s*\d+:\s+[+*]*\S+\s+(\d+)/\d+x(\d+)/\d+\+(\d+)\+(\d+)\s+(\S+)');
          for (final m in re.allMatches(r.stdout as String)) {
            _linuxMonitors.add({
              'w': int.parse(m.group(1)!),
              'h': int.parse(m.group(2)!),
              'x': int.parse(m.group(3)!),
              'y': int.parse(m.group(4)!),
              'name': m.group(5)!,
            });
          }
        }
      } catch (_) {}
    }
    if (_linuxMonitors.isNotEmpty) {
      _screenList = _linuxMonitors
          .asMap()
          .entries
          .map((e) => 'Pantalla ${e.key + 1} (${e.value['name']})')
          .toList();
    } else if (isWayland) {
      _screenList = ['Pantalla principal (Wayland/Pipewire)'];
    } else {
      _screenList = ['Pantalla principal'];
    }
    if (_selectedScreen >= _screenList.length) _selectedScreen = 0;
    notifyListeners();
  }

  List<String>? _screenListArgs() {
    if (Platform.isMacOS) {
      return ['-f', 'avfoundation', '-list_devices', 'true', '-i', ''];
    }
    if (Platform.isWindows) {
      return ['-f', 'gdigrab', '-list_devices', 'true', '-i', ''];
    }
    return null;
  }

  List<String> _parseScreenList(String stderr) {
    if (Platform.isMacOS) {
      final screens = <String>[];
      final reg = RegExp(r'\[(\d+)\]\s+Capture screen');
      for (final m in reg.allMatches(stderr)) {
        final idx = int.parse(m.group(1)!);
        screens.add('Pantalla ${screens.length + 1} (índice $idx)');
      }
      return screens;
    }
    if (Platform.isWindows) {
      final screens = <String>[];
      if (stderr.contains('desktop')) {
        screens.add('Pantalla completa');
      }
      return screens;
    }
    return [];
  }

  List<String> _captureArgs() {
    if (Platform.isMacOS) {
      return ['-f', 'avfoundation', '-i', '$_selectedScreen'];
    }
    if (Platform.isWindows) {
      return ['-f', 'gdigrab', '-i', 'desktop'];
    }
    if (Platform.isLinux) {
      final isWayland = Platform.environment['WAYLAND_DISPLAY'] != null &&
          Platform.environment['DISPLAY'] == null;
      if (isWayland) {
        // pipewire screen capture – requires ffmpeg built with libpipewire
        return ['-f', 'pipewire', '-i', '0'];
      }
      final display = Platform.environment['DISPLAY'] ?? ':0.0';
      if (_linuxMonitors.isNotEmpty &&
          _selectedScreen < _linuxMonitors.length) {
        final m = _linuxMonitors[_selectedScreen];
        return [
          '-f', 'x11grab',
          '-framerate', '30',
          '-video_size', '${m['w']}x${m['h']}',
          '-i', '$display+${m['x']},${m['y']}',
        ];
      }
      return ['-f', 'x11grab', '-framerate', '30', '-i', display];
    }
    return ['-f', 'avfoundation', '-i', '1'];
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
        ..._captureArgs(),
        '-c:v', 'libx265',
        '-crf', '28',
        '-preset', 'fast',
        // hvc1 tag is Apple-specific; only needed for macOS/iOS compatibility
        if (Platform.isMacOS) ...['-tag:v', 'hvc1'],
        '-c:a', 'aac',
        '-b:a', '64k',
        // Fragmented mp4: file stays valid even if the process is
        // hard-killed mid-recording (no final moov atom needed).
        '-movflags', 'frag_keyframe+empty_moov',
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
    final proc = _screenCapProcess;
    if (proc != null) {
      // Output uses fragmented mp4 (frag_keyframe+empty_moov), so a hard
      // kill can't corrupt it — no need for a graceful stdin 'q' handshake,
      // which never reached ffmpeg on Windows anyway (piped stdin isn't a
      // real console, so ffmpeg's keyboard-input polling never sees it).
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode;
    }
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

  // ── Network capture (agente JVMTI) ───────────────────────────────────────

  List<NetworkFlow> flows = [];
  String? captureSerial;
  String? capturePackage;
  String? captureError;
  /// Cuando el fallo es "agente no detectado en Logcat" (el caso más común,
  /// casi siempre por tener la app cerrada/en background), se guarda acá en
  /// vez de en [captureError] para que la UI muestre el consejo accionable
  /// separado de los detalles técnicos, no un solo bloque de texto.
  AgentAttachError? captureAttachError;
  String? agentStatus;
  List<String> agentDiagnostics = [];
  String? agentLogSnapshot;
  List<DebugApp> debugApps = [];
  bool loadingDebugApps = false;
  NetworkStatus _networkStatus = const NetworkStatus();

  NetworkStatus get networkStatus => _networkStatus;

  bool get capturing => agentCapture.isRunning;
  bool get recording => agentCapture.recording;
  String? get recordingWarning => agentCapture.recordingWarning;

  /// Activa/pausa la instrumentación real en el dispositivo (ver
  /// AgentNetworkService.setRecording). startAgentCapture ya la activa sola
  /// tras el attach — el tracing global lento (MethodEntry/Exit) está
  /// deshabilitado del lado del agente (native/network_agent), así que grabar
  /// ya no vuelve la app lenta; este método queda para pausar/reanudar manual.
  Future<void> setRecording(bool value) async {
    await agentCapture.setRecording(value);
    notifyListeners();
  }

  List<NetworkFlow> get visibleFlows => flows;

  /// Lista apps debug instaladas en [serial].
  Future<void> refreshDebugApps(String serial) async {
    loadingDebugApps = true;
    notifyListeners();
    try {
      debugApps = await _adb.listDebuggableApps(serial);
    } catch (_) {
      debugApps = [];
    } finally {
      loadingDebugApps = false;
      notifyListeners();
    }
  }

  void _onFlow(NetworkFlow f) {
    flows.add(f);
    notifyListeners();
  }

  void _appendAgentDiag(String msg) {
    agentDiagnostics.add(msg);
    if (agentDiagnostics.length > 40) {
      agentDiagnostics.removeAt(0);
    }
    notifyListeners();
  }

  /// Inyecta el agente JVMTI en [package] del [device] (app debug en ejecución).
  Future<void> startAgentCapture(Device device, String package) async {
    captureError = null;
    captureAttachError = null;
    agentStatus = null;
    agentDiagnostics = [];
    agentLogSnapshot = null;
    notifyListeners();
    try {
      await agentCapture.start(serial: device.serial, package: package);
      captureSerial = device.serial;
      capturePackage = package;
      networkMonitor.start(device.serial);
      notifyListeners();
      // Auto-arranca grabación: ya no paga el costo de tracing global lento
      // (deshabilitado en el agente, ver activarCaptura/kMethodTracingHabilitado),
      // así que no hace falta un click aparte en "Grabar" para ver tráfico.
      await agentCapture.setRecording(true);
    } catch (e) {
      if (e is AgentAttachError) {
        captureAttachError = e;
      } else {
        captureError = e.toString();
      }
      await agentCapture.stop();
    }
    notifyListeners();
  }

  Future<void> stopCapture() async {
    await agentCapture.stop();
    networkMonitor.stop();
    captureSerial = null;
    capturePackage = null;
    notifyListeners();
  }

  void clearFlows() {
    flows = [];
    notifyListeners();
  }

  /// Lee Logcat del dispositivo (líneas CoordiNetAgent) para depuración.
  Future<void> refreshAgentLogSnapshot() async {
    agentLogSnapshot = await agentCapture.fetchDeviceLogSnapshot();
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _screenCapTimer?.cancel();
    if (_screenCapturing) {
      _screenCapProcess?.kill(ProcessSignal.sigterm);
    }
    scrcpy.dispose();
    agentCapture.dispose();
    networkMonitor.dispose();
    super.dispose();
  }
}
