import 'dart:async';
import 'dart:io';

import '../models/scrcpy_options.dart';
import 'binary_resolver.dart';

/// One running scrcpy mirror session.
class ScrcpySession {
  final String serial;
  final Process process;
  final List<String> logLines = [];
  String? recordPath;

  ScrcpySession({required this.serial, required this.process, this.recordPath});

  int get pid => process.pid;
}

/// Launches and tracks scrcpy processes, one per device serial.
class ScrcpyService {
  ScrcpyService(this._bin);

  final BinaryResolver _bin;
  final Map<String, ScrcpySession> _sessions = {};

  final _changes = StreamController<void>.broadcast();

  /// Emits whenever a session starts or stops.
  Stream<void> get changes => _changes.stream;

  bool isRunning(String serial) => _sessions.containsKey(serial);

  ScrcpySession? session(String serial) => _sessions[serial];

  Iterable<ScrcpySession> get sessions => _sessions.values;

  /// Launch scrcpy for [serial] with [options]. Throws if already running.
  Future<ScrcpySession> launch(String serial, ScrcpyOptions options) async {
    if (_sessions.containsKey(serial)) {
      throw StateError('scrcpy already running for $serial');
    }

    final exe = await _bin.scrcpy();
    final env = await _bin.environment();
    final args = options.toArgs(serial);

    final process = await Process.start(
      exe,
      args,
      environment: env,
      runInShell: false,
    );

    final session = ScrcpySession(
      serial: serial,
      process: process,
      recordPath: options.recordPath,
    );
    _sessions[serial] = session;
    _changes.add(null);

    // Capture logs (handy for the team when something fails).
    process.stdout
        .transform(const SystemEncoding().decoder)
        .listen((d) => session.logLines.add(d));
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((d) => session.logLines.add(d));

    // Cleanup when scrcpy exits (window closed, device unplugged, etc.).
    process.exitCode.then((_) {
      _sessions.remove(serial);
      _changes.add(null);
    });

    return session;
  }

  /// Stop the session for [serial], if any.
  Future<void> stop(String serial) async {
    final s = _sessions[serial];
    if (s == null) return;
    s.process.kill(ProcessSignal.sigterm);
  }

  /// Stop and wait for the process to fully exit before returning.
  Future<void> stopAndWait(String serial) async {
    final s = _sessions[serial];
    if (s == null) return;
    s.process.kill(ProcessSignal.sigterm);
    await s.process.exitCode;
    // The cleanup (.then on exitCode) runs in a microtask after await.
    // Yield to let it execute before we return.
    await Future.microtask(() {});
  }

  Future<void> stopAll() async {
    for (final s in _sessions.values.toList()) {
      s.process.kill(ProcessSignal.sigterm);
    }
  }

  /// Stop and delete the recorded file (cancel).
  Future<void> stopAndDelete(String serial) async {
    final s = _sessions[serial];
    if (s == null) return;
    s.process.kill(ProcessSignal.sigterm);
    if (s.recordPath != null) {
      try {
        await File(s.recordPath!).delete();
      } catch (_) {}
    }
  }

  void dispose() {
    stopAll();
    _changes.close();
  }
}
