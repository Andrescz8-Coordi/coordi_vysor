import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../models/network_flow.dart';
import 'adb_service.dart';
import 'binary_resolver.dart';

/// Captura tráfico HTTP(S) inyectando un agente JVMTI (.so) vía
/// `adb shell cmd activity attach-agent`, sin modificar la app objetivo.
///
/// El agente emite flows JSON por Logcat (tag CoordiNetAgent) y por un socket
/// TCP local en el dispositivo (reenviado al host con `adb reverse`).
class AgentNetworkService {
  AgentNetworkService(this._bin, this._adb);

  final BinaryResolver _bin;
  final AdbService _adb;

  static const int defaultPort = 9876;
  static const String agentRemotePath = '/data/local/tmp/libcoordi_net_agent.so';
  static const String logcatTag = 'CoordiNetAgent';

  ServerSocket? _server;
  Process? _logcat;
  StreamSubscription<String>? _logcatSub;
  Socket? _deviceSocket;

  String? _serial;
  String? _package;
  int _port = defaultPort;
  bool _socketConnected = false;
  bool _recording = false;
  // No null == "sin advertencia": el último retransform sí instrumentó algo.
  // No null == mensaje claro para mostrar en la UI sin tener que expandir el
  // panel de diagnóstico (ver setRecording()).
  String? _recordingWarning;
  // Ruta del .so en el dispositivo usada en el attach inicial: reattach para
  // toggle de grabación debe apuntar a la MISMA ruta (mismo inodo) — el
  // agente detecta "ya instrumentado" por proceso, no por ruta.
  String? _agentPathUsed;

  /// Cada flow se emite por Logcat y por socket: se descarta el id repetido.
  final Set<String> _seenFlowIds = <String>{};

  final _flows = StreamController<NetworkFlow>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final _status = StreamController<String>.broadcast();
  final _diagnostics = StreamController<String>.broadcast();

  /// Buffer para el framing con prefijo de longitud (C++ socket emitter).
  final List<int> _frameBuffer = [];
  bool _readingLength = true;
  int _expectedLength = 0;

  Stream<NetworkFlow> get flows => _flows.stream;
  Stream<void> get changes => _changes.stream;
  Stream<String> get status => _status.stream;
  Stream<String> get diagnostics => _diagnostics.stream;

  bool get isRunning => _serial != null;
  bool get socketConnected => _socketConnected;
  bool get recording => _recording;
  String? get recordingWarning => _recordingWarning;
  String? get serial => _serial;
  String? get package => _package;
  int get port => _port;

  /// Copia el .so bundleado (según ABI del dispositivo) a un archivo temporal
  /// en el host y lo empuja al dispositivo.
  Future<void> _pushAgent(String serial) async {
    final abi = await _adb.deviceAbi(serial);
    final assetPath = 'assets/agents/$abi/libcoordi_net_agent.so';
    try {
      final data = await rootBundle.load(assetPath);
      final tmp = await Directory.systemTemp.createTemp('coordi_agent_');
      final local = File(p.join(tmp.path, 'libcoordi_net_agent.so'));
      await local.writeAsBytes(data.buffer.asUint8List());
      await _adb.pushFile(serial, local.path, agentRemotePath);
      await _adb.shellChmod(serial, agentRemotePath, '644');
    } catch (e) {
      throw StateError(
        'No se encontró el agente para ABI $abi. '
        'Compila con native/network_agent/build.sh',
      );
    }
  }

  /// Inicia captura: socket en el host, reverse, push del agente y attach.
  Future<void> start({
    required String serial,
    required String package,
    int port = defaultPort,
  }) async {
    if (_serial != null) {
      throw StateError('agent capture already running');
    }
    _port = port;
    _serial = serial;
    _package = package;

    _status.add('Comprobando app debug…');
    final debuggable = await _adb.isDebuggable(serial, package);
    if (!debuggable) {
      throw StateError(
        '$package no es debuggable. Usa un build debug '
        '(android:debuggable=true).',
      );
    }

    final running = await _adb.isAppRunning(serial, package);
    if (!running) {
      throw StateError(
        '$package no está en ejecución. Ábrela en el dispositivo primero.',
      );
    }

    _status.add('Preparando socket local…');
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_onDeviceConnect);

    _status.add('adb reverse tcp:$port…');
    await _adb.reversePort(serial, port, port);

    _status.add('Empujando agente…');
    await _pushAgent(serial);

    _status.add('Escuchando Logcat…');
    await _startLogcat(serial);

    _status.add('Inyectando agente (attach-agent)…');
    final attachResult = await _adb.attachAgentVerified(
      serial: serial,
      package: package,
      tmpAgentPath: agentRemotePath,
      agentOptions: 'port:$port',
    );

    for (final line in attachResult.attemptsLog.split('\n')) {
      if (line.trim().isNotEmpty) _diagnostics.add(line.trim());
    }
    _diagnostics.add('Ruta agente: ${attachResult.agentPathUsed}');
    _agentPathUsed = attachResult.agentPathUsed;
    _recording = false;

    if (!attachResult.agentDetectedInLogcat) {
      _diagnostics.add(attachResult.logcatSnippet);
      throw StateError(
        'El agente no apareció en Logcat tras attach-agent.\n'
        'Procesos:\n${attachResult.processInfo ?? "?"}\n\n'
        '${attachResult.logcatSnippet}\n\n'
        'Prueba manual:\n'
        'adb logcat -c\n'
        'adb shell cmd activity attach-agent $package '
        '${attachResult.agentPathUsed}=port:$port\n'
        'adb logcat -s CoordiNetAgent:I',
      );
    }

    _status.add('Agente confirmado en Logcat — esperando tráfico…');
    _diagnostics.add(
      'Deberías ver TEST agent://pipeline-ok en ~3s si el host recibe Logcat/socket.',
    );
    _changes.add(null);
  }

  void _onDeviceConnect(Socket socket) {
    _socketConnected = true;
    _status.add('Socket conectado (adb reverse OK)');
    _diagnostics.add('socket: dispositivo conectado al host en puerto $_port');
    _deviceSocket?.destroy();
    _deviceSocket = socket;
    _frameBuffer.clear();
    _readingLength = true;
    _expectedLength = 0;
    socket.listen(_onSocketData);
  }

  void _onSocketData(List<int> data) {
    _frameBuffer.addAll(data);
    _processFrameBuffer();
  }

  void _processFrameBuffer() {
    while (true) {
      if (_readingLength) {
        if (_frameBuffer.length < 4) break;
        _expectedLength = (_frameBuffer[0] << 24) |
            (_frameBuffer[1] << 16) |
            (_frameBuffer[2] << 8) |
            _frameBuffer[3];
        _frameBuffer.removeRange(0, 4);
        _readingLength = false;
      }
      if (_frameBuffer.length < _expectedLength) break;
      final frameBytes = _frameBuffer.sublist(0, _expectedLength);
      _frameBuffer.removeRange(0, _expectedLength);
      _readingLength = true;
      try {
        final line = utf8.decode(frameBytes);
        _parseAgentLine(line);
      } catch (_) {
        // Frame inválido (encoding); descartar
      }
    }
  }

  void _parseAgentLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    var payload = trimmed;
    final flowIdx = trimmed.indexOf('FLOW ');
    if (flowIdx >= 0) {
      payload = trimmed.substring(flowIdx + 5).trim();
    } else if (trimmed.contains('FLOW {')) {
      payload = trimmed.substring(trimmed.indexOf('FLOW ') + 5).trim();
    } else if (trimmed.contains('DIAG ')) {
      final msg = trimmed.substring(trimmed.indexOf('DIAG ') + 5).trim();
      _diagnostics.add(msg);
      return;
    } else if (trimmed.contains('{')) {
      payload = trimmed.substring(trimmed.indexOf('{'));
    } else {
      return;
    }

    _parseFlow(payload);
  }

  void _parseFlow(String jsonLine) {
    try {
      final json = jsonDecode(jsonLine) as Map<String, dynamic>;
      final type = json['type'];
      if (type == 'agent_ready') {
        _status.add('Agente listo (puerto ${json['port']})');
        return;
      }
      if (type == 'diag') {
        _diagnostics.add(json['msg']?.toString() ?? jsonLine);
        return;
      }
      final flow = NetworkFlow.fromJson(json);
      if (flow.id.isNotEmpty && !_seenFlowIds.add(flow.id)) {
        return;
      }
      _flows.add(flow);
      if (json['url'] == 'agent://pipeline-ok') {
        _status.add('Autoprueba OK — pipeline host↔agente funciona');
      }
    } catch (_) {
      // Línea no JSON del agente; ignorar.
    }
  }

  Future<void> _startLogcat(String serial) async {
    final adb = await _bin.adb();
    await Process.run(adb, ['-s', serial, 'logcat', '-c']);
    _logcat = await Process.start(
      adb,
      ['-s', serial, 'logcat', '-v', 'brief', '-s', '$logcatTag:I', '*:S'],
      runInShell: false,
    );
    _logcatSub = _logcat!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_parseAgentLine);
    _logcat!.stderr.transform(utf8.decoder).listen((_) {});
  }

  /// Lee Logcat del dispositivo y devuelve líneas relevantes del agente.
  Future<String> fetchDeviceLogSnapshot() async {
    final serial = _serial;
    if (serial == null) return 'Captura no activa';
    final raw = await _adb.recentLogcat(serial, lines: 500);
    final relevant = _adb.relevantLogcatForUi(raw);
    if (relevant.isNotEmpty) return relevant;
    if (raw.trim().isEmpty) return 'Logcat vacío';
    return 'Sin CoordiNetAgent/jvmti en las últimas 500 líneas.\n\n'
        'Últimas 15 líneas de logcat:\n'
        '${raw.split('\n').where((l) => l.trim().isNotEmpty).take(15).join('\n')}';
  }

  /// Activa o pausa la instrumentación real (MethodEntry/Exit) en el
  /// dispositivo sin desadjuntar el agente. Los hooks JVMTI quedan inactivos
  /// tras el attach inicial — grabar es global a la VM del proceso destino y
  /// puede volver la app notablemente más lenta mientras está activo, así
  /// que solo corre cuando el usuario explícitamente lo pide.
  Future<void> setRecording(bool value) async {
    final serial = _serial;
    final package = _package;
    final path = _agentPathUsed;
    if (serial == null || package == null || path == null) return;

    // Samsung One UI: `attach-agent` es no-op silencioso (exit=0, sin
    // Agent_OnAttach) cuando la app objetivo está en background/congelada, así
    // que el toggle de grabación nunca llegaba y la UI mentía "Grabando".
    // Traer la app a foreground hace que el attach entregue.
    await _adb.bringAppToForeground(serial, package);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // Escuchar la confirmación nueva del agente ANTES de adjuntar: emite
    // "grabacion iniciada/detenida" por socket y logcat. Suscribir antes evita
    // perder el evento y no da falsos positivos de toggles anteriores.
    //
    // Al grabar, ese string se emite ANTES de que el agente corra
    // probarRetransform() (ver url_connection_hooks.cpp activarCaptura), así
    // que por sí solo NO dice si el DEX-rewrite realmente instrumentó algo.
    // Por eso, al grabar, también se espera la línea "retransform: ..." que
    // el mismo activarCaptura(true) emite sincrónicamente a continuación, y se
    // parsea instrumentables=/CFLH_disparos= para no mentir "Grabando" con
    // cero clases instrumentadas.
    final esperado = value ? 'grabacion iniciada' : 'grabacion detenida';
    final retransformRe = RegExp(
      r'retransform: instrumentables=(\d+).*?ok=(\d+).*?CFLH_disparos=(\d+)',
    );
    final confirmacion = Completer<bool>();
    bool vistoInicio = !value;
    RegExpMatch? retransformMatch;
    final sub = _diagnostics.stream.listen((msg) {
      if (msg.contains(esperado)) vistoInicio = true;
      if (value) {
        retransformMatch ??= retransformRe.firstMatch(msg);
      }
      if (!confirmacion.isCompleted &&
          vistoInicio &&
          (!value || retransformMatch != null)) {
        confirmacion.complete(true);
      }
    });

    await _adb.attachAgent(
      serial,
      package,
      '$path=port:$_port,record:${value ? 1 : 0}',
    );

    final confirmado = await confirmacion.future
        .timeout(Duration(seconds: value ? 5 : 4), onTimeout: () => false);
    await sub.cancel();

    if (confirmado) {
      _recording = value;
      if (value && retransformMatch != null) {
        final instrumentables = int.parse(retransformMatch!.group(1)!);
        if (instrumentables == 0) {
          _recordingWarning =
              'Agente grabando, pero no se detectó tráfico HTTP cargado '
              'todavía. Navegá en la app para disparar una petición.';
          _diagnostics.add(_recordingWarning!);
          _status.add(_recordingWarning!);
        } else {
          _recordingWarning = null;
          _status.add('Grabando en el dispositivo');
        }
      } else {
        _recordingWarning = null;
        _status.add(value ? 'Grabando en el dispositivo' : 'Grabación pausada');
      }
    } else {
      // No mentir el estado: dejar _recording como estaba y avisar.
      _recordingWarning = null;
      _diagnostics.add(
        'No se confirmó ${value ? "el inicio" : "la pausa"} de grabación tras '
        'attach-agent. La app objetivo puede estar en background o congelada '
        '(típico en Samsung): abrila en el dispositivo y reintentá.',
      );
    }
    _changes.add(null);
  }

  /// Detiene captura, cierra socket y limpia reverse.
  Future<void> stop() async {
    final serial = _serial;
    _serial = null;
    _package = null;
    _socketConnected = false;
    _recording = false;
    _agentPathUsed = null;
    _seenFlowIds.clear();
    _frameBuffer.clear();
    _readingLength = true;

    await _logcatSub?.cancel();
    _logcatSub = null;
    _logcat?.kill(ProcessSignal.sigterm);
    _logcat = null;

    _deviceSocket?.destroy();
    _deviceSocket = null;
    await _server?.close();
    _server = null;

    if (serial != null) {
      try {
        await _adb.removeReverse(serial, _port);
      } catch (_) {/* best effort */}
    }
    _changes.add(null);
  }

  void dispose() {
    stop();
    _flows.close();
    _changes.close();
    _status.close();
    _diagnostics.close();
  }
}
