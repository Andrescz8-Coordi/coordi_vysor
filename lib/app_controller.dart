import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'models/agent_attach_result.dart';
import 'models/debug_app.dart';
import 'models/device.dart';
import 'models/network_flow.dart';
import 'models/network_status.dart';
import 'models/save_result.dart';
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

  SaveResult? _pendingSaveResult;

  /// Result of a recording that ended without the user pressing stop (device
  /// unplugged, ffmpeg died, ffmpeg missing). Nobody is awaiting those, so the
  /// UI picks the result up here, shows it once and consumes it.
  SaveResult? get pendingSaveResult => _pendingSaveResult;

  void consumePendingSaveResult() => _pendingSaveResult = null;

  /// Returns a unique temp path for a new recording.
  String _tempRecordPath() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return p.join(Directory.systemTemp.path, 'scrcpy_rec_$ts.mp4');
  }

  /// Native save dialog – returns chosen path or null if cancelled.
  Future<String?> _showSaveDialog({String? suggested}) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final defaultName = suggested ?? 'scrcpy_$ts.mp4';

    try {
      final location = await getSaveLocation(
        suggestedName: defaultName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'MP4', extensions: ['mp4']),
        ],
      );
      return location?.path;
    } catch (_) {
      // Dialog unavailable (headless session, missing portal…). The caller
      // falls back to auto-saving so the recording is never lost.
      return null;
    }
  }

  /// Move [src] to [dest], falling back to copy+delete when `rename` can't
  /// cross volumes (very common on Windows: TEMP on C:, target elsewhere).
  /// Returns the final path, or null if the file could not be moved at all.
  Future<String?> _moveTo(String src, String dest) async {
    try {
      final f = await File(src).rename(dest);
      return f.path;
    } catch (_) {
      try {
        await File(src).copy(dest);
        await File(src).delete();
        return dest;
      } catch (_) {
        return null;
      }
    }
  }

  /// Open the system file manager with [path] selected.
  Future<void> revealInFileManager(String path) async {
    try {
      if (Platform.isWindows) {
        // explorer only honours /select when path is part of the same token.
        await Process.run('explorer', ['/select,$path']);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [p.dirname(path)]);
      }
    } catch (_) {/* nothing else we can do */}
  }

  /// Folder used when the user cancels the save dialog (or it can't be shown).
  /// Deliberately not the Desktop: with OneDrive Known Folder Move the local
  /// `%USERPROFILE%\Desktop` often doesn't exist and the copy fails.
  String _fallbackSaveDir() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    final videos = Platform.isMacOS ? 'Movies' : 'Videos';
    return p.join(home, videos, 'CoordiVysor');
  }

  /// Auto-save a recording to the fallback folder. Never loses the file: if the
  /// move fails it leaves it in temp and returns that path instead.
  Future<String?> _autoSaveRecording(String tempPath,
      {String prefix = 'scrcpy'}) async {
    if (!await File(tempPath).exists()) return null;

    final name = '${prefix}_${DateTime.now().millisecondsSinceEpoch}.mp4';
    try {
      final dir = Directory(_fallbackSaveDir());
      await dir.create(recursive: true);
      final moved = await _moveTo(tempPath, p.join(dir.path, name));
      if (moved != null) return moved;
    } catch (_) {/* fall through – file stays in temp */}

    return tempPath;
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
          unawaited(_autoSaveRecording(tempPath).then((saved) {
            _pendingSaveResult = saved != null
                ? SaveResult.saved(saved)
                : const SaveResult.failed(
                    'La grabación se interrumpió y no dejó ningún archivo.');
            notifyListeners();
          }));
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
  Future<SaveResult> stopRecording(String serial) async {
    if (!isRecording(serial)) {
      return const SaveResult.failed('No hay una grabación en curso.');
    }
    _recordingSerials.remove(serial);
    final tempPath = _recordingPaths.remove(serial);
    _stopTimer();

    // Grab the session first: stopAndWait drops it from the service's map, but
    // the object keeps the log lines, including whatever scrcpy printed while
    // shutting down.
    final session = scrcpy.session(serial);
    await scrcpy.stopAndWait(serial);
    final log = session?.logLines.join();

    try {
      if (tempPath == null || !await File(tempPath).exists()) {
        return SaveResult.failed(
          'scrcpy no generó el archivo de video.',
          details: log,
        );
      }
      if (await File(tempPath).length() == 0) {
        await File(tempPath).delete();
        return SaveResult.failed(
          'La grabación quedó vacía (0 bytes).',
          details: log,
        );
      }

      String finalPath = tempPath;
      if (options.compress) {
        finalPath = await _compressVideo(tempPath) ?? tempPath;
      }

      return await _saveTo(finalPath, log);
    } finally {
      notifyListeners();
    }
  }

  /// Ask the user where to put [tempFile]; auto-save on cancel. Always reports
  /// the real final path so the UI can show it.
  Future<SaveResult> _saveTo(String tempFile, String? log,
      {String prefix = 'scrcpy'}) async {
    final dest = await _showSaveDialog(
      suggested: '${prefix}_${DateTime.now().millisecondsSinceEpoch}.mp4',
    );

    if (dest != null) {
      final moved = await _moveTo(tempFile, dest);
      if (moved != null) return SaveResult.saved(moved);
      // Chosen location rejected the write (permissions, read-only drive…).
      // Don't drop the video: park it in the fallback folder.
    }

    final auto = await _autoSaveRecording(tempFile, prefix: prefix);
    if (auto != null) return SaveResult.saved(auto);
    return SaveResult.failed('No se pudo guardar el video.', details: log);
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
  /// Tail of the ffmpeg output for the current capture, kept for diagnostics.
  final List<String> _screenCapLog = [];
  /// Set when ffmpeg dies on its own, before the user pressed stop.
  String? _screenCapCrash;
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
      // gdigrab + libx265 on a 1080p+ desktop can't keep up at the default
      // frame rate; capping it keeps the encoder from falling behind.
      return ['-f', 'gdigrab', '-framerate', '15', '-i', 'desktop'];
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
    if (ffmpeg.isEmpty) {
      _pendingSaveResult =
          const SaveResult.failed('No se encontró ffmpeg.');
      notifyListeners();
      return;
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    _screenCapPath = p.join(Directory.systemTemp.path, 'screencap_$ts.mp4');
    _screenCapLog.clear();
    _screenCapCrash = null;

    try {
      final proc = await Process.start(ffmpeg, [
        '-hide_banner',
        '-nostdin',
        '-nostats',
        '-loglevel', 'error',
        ..._captureArgs(),
        '-c:v', 'libx265',
        '-crf', '28',
        '-preset', 'fast',
        // x265 has its own logger, unaffected by ffmpeg's -loglevel; left
        // chatty it is the main source of output on this pipe.
        '-x265-params', 'log-level=error',
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
      _screenCapProcess = proc;

      // ffmpeg's pipes MUST be drained. Left unread they fill up (a few KB on
      // Windows) and ffmpeg blocks writing to stderr, silently freezing the
      // capture.
      proc.stdout.transform(const SystemEncoding().decoder).listen(_logCapture);
      proc.stderr.transform(const SystemEncoding().decoder).listen(_logCapture);

      // ffmpeg exiting on its own means the capture died (bad device, codec,
      // disk). Surface it instead of leaving a timer running over nothing.
      proc.exitCode.then((code) async {
        if (!identical(_screenCapProcess, proc)) return; // normal stop
        _screenCapProcess = null;
        _screenCapturing = false;
        _stopScreenCapTimer();
        _screenCapCrash = 'ffmpeg terminó inesperadamente (código $code).';
        // Keep whatever was captured before the crash – the mp4 is fragmented,
        // so a partial file is still playable. No save dialog here: the user
        // didn't ask to stop, so popping one would be jarring.
        _pendingSaveResult = await _finishCapture(prompt: false);
        notifyListeners();
      });

      _screenCapturing = true;
      _resetScreenCapTimer();
      notifyListeners();
    } catch (e) {
      _screenCapPath = null;
      _screenCapCrash = null;
      _pendingSaveResult =
          SaveResult.failed('No se pudo iniciar ffmpeg.', details: '$e');
      notifyListeners();
    }
  }

  void _logCapture(String chunk) {
    _screenCapLog.add(chunk);
    if (_screenCapLog.length > 100) _screenCapLog.removeAt(0);
  }

  /// Stop ffmpeg process (modal is handled by the UI).
  Future<void> stopScreenCaptureProcess() async {
    if (!_screenCapturing) return;
    _screenCapturing = false;
    _stopScreenCapTimer();
    final proc = _screenCapProcess;
    _screenCapProcess = null; // marks this as a deliberate stop, not a crash
    if (proc != null) {
      // Output uses fragmented mp4 (frag_keyframe+empty_moov), so a hard
      // kill can't corrupt it — no need for a graceful stdin 'q' handshake,
      // which never reached ffmpeg on Windows anyway (piped stdin isn't a
      // real console, so ffmpeg's keyboard-input polling never sees it).
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode;
    }
    notifyListeners();
  }

  /// After process stops, show save dialog and handle the file.
  Future<SaveResult> saveScreenCapture() => _finishCapture(prompt: true);

  Future<SaveResult> _finishCapture({required bool prompt}) async {
    final path = _screenCapPath;
    _screenCapPath = null;
    final log = _screenCapLog.join();
    final crash = _screenCapCrash;
    _screenCapCrash = null;

    if (path == null || !await File(path).exists()) {
      return SaveResult.failed(
        crash ?? 'ffmpeg no generó el archivo de video.',
        details: log,
      );
    }
    if (await File(path).length() == 0) {
      await File(path).delete();
      return SaveResult.failed(
        crash ?? 'La grabación quedó vacía (0 bytes).',
        details: log,
      );
    }

    if (!prompt) {
      final auto = await _autoSaveRecording(path, prefix: 'pantalla');
      if (auto != null) return SaveResult.saved(auto);
      return SaveResult.failed(
        crash ?? 'No se pudo guardar el video.',
        details: log,
      );
    }

    return _saveTo(path, log, prefix: 'pantalla');
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
      final proc = _screenCapProcess;
      // Clear first: the exitCode handler treats a still-set process as a
      // crash and would notify listeners on a disposed controller.
      _screenCapProcess = null;
      _screenCapturing = false;
      proc?.kill(ProcessSignal.sigterm);
    }
    scrcpy.dispose();
    agentCapture.dispose();
    networkMonitor.dispose();
    super.dispose();
  }
}
