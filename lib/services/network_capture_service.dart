import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../models/network_flow.dart';
import 'binary_resolver.dart';

/// Runs a local mitmproxy (`mitmdump`) and parses its addon output into
/// [NetworkFlow]s. Mirrors the process-lifecycle pattern of ScrcpyService.
class NetworkCaptureService {
  NetworkCaptureService(this._bin);

  final BinaryResolver _bin;

  Process? _process;
  int _port = 8080;

  final _flows = StreamController<NetworkFlow>.broadcast();
  final _changes = StreamController<void>.broadcast();

  /// Emits each captured request/response pair.
  Stream<NetworkFlow> get flows => _flows.stream;

  /// Emits whenever capture starts or stops.
  Stream<void> get changes => _changes.stream;

  bool get isRunning => _process != null;
  int get port => _port;

  /// Copy the bundled addon asset to a temp file so mitmdump can `-s` it.
  Future<String> _addonPath() async {
    final dir = await Directory.systemTemp.createTemp('scrcpy_gui_mitm');
    final file = File(p.join(dir.path, 'flow_dump.py'));
    final data = await rootBundle.loadString('assets/mitm/flow_dump.py');
    await file.writeAsString(data);
    return file.path;
  }

  /// Start mitmdump on [port]. Throws if already running.
  Future<void> start({int port = 8080}) async {
    if (_process != null) {
      throw StateError('capture already running');
    }
    _port = port;
    final exe = await _bin.mitmdump();
    final addon = await _addonPath();

    final process = await Process.start(
      exe,
      ['-s', addon, '--listen-port', '$port', '-q'],
      runInShell: false,
    );
    _process = process;
    _changes.add(null);

    // Each addon record is one JSON line on stdout.
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    // mitmproxy diagnostics go to stderr; ignored, but drained to avoid stall.
    process.stderr.transform(utf8.decoder).listen((_) {});

    process.exitCode.then((_) {
      _process = null;
      _changes.add(null);
    });
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('{')) return;
    try {
      final json = jsonDecode(trimmed) as Map<String, dynamic>;
      _flows.add(NetworkFlow.fromJson(json));
    } catch (_) {
      // Non-JSON noise from mitmdump; skip.
    }
  }

  /// Stop the running capture, if any.
  Future<void> stop() async {
    final proc = _process;
    if (proc == null) return;
    proc.kill(ProcessSignal.sigterm);
  }

  void dispose() {
    stop();
    _flows.close();
    _changes.close();
  }
}
