import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Lector con buffer para un socket: una sola suscripción, múltiples lecturas.
class _BufferedReader {
  _BufferedReader(this._socket) {
    _sub = _socket.listen(_onData, onError: (_) => _closeCompleters(),
        onDone: () => _closeCompleters());
  }

  final Socket _socket;
  StreamSubscription<Uint8List>? _sub;
  final _buffer = <int>[];
  Completer<void>? _dataCompleter;
  bool _closed = false;

  void _onData(Uint8List chunk) {
    _buffer.addAll(chunk);
    _dataCompleter?.complete();
  }

  void _closeCompleters() {
    _closed = true;
    _dataCompleter?.complete();
  }

  Future<void> _fillBuffer() async {
    if (_buffer.isNotEmpty || _closed) return;
    _dataCompleter = Completer<void>();
    await _dataCompleter!.future;
    _dataCompleter = null;
  }

  Future<String> readLine() async {
    while (true) {
      final idx = _buffer.indexOf(10);
      if (idx >= 0) {
        final line = utf8.decode(_buffer.sublist(0, idx)).trim();
        _buffer.removeRange(0, idx + 1);
        return line;
      }
      if (_closed) return '';
      await _fillBuffer();
    }
  }

  Future<List<int>> readBytes(int count) async {
    while (_buffer.length < count) {
      if (_closed) break;
      await _fillBuffer();
    }
    final n = count < _buffer.length ? count : _buffer.length;
    if (n == 0) return [];
    final data = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return data;
  }

  void close() {
    _closed = true;
    _sub?.cancel();
    _sub = null;
    _dataCompleter?.complete();
  }
}

/// Proxy HTTP local con limitación de ancho de banda y latencia.
///
/// Sin root. Usa `adb reverse` + `settings put global http_proxy` para
/// redirigir el tráfico del dispositivo a través de este proxy.
class ThrottlingProxyServer {
  ServerSocket? _server;
  bool _running = false;
  final _connections = <Socket>{};

  int uploadBps = 0;
  int downloadBps = 0;
  int latencyMs = 0;

  StreamController<String>? _diagCtrl;
  Stream<String>? get diagnostics => _diagCtrl?.stream;

  bool get isRunning => _running;
  int get port => _port;
  int _port = 0;

  Future<int> start({int port = 0, int? upBps, int? downBps, int? latency}) async {
    if (_running) return _port;
    uploadBps = upBps ?? uploadBps;
    downloadBps = downBps ?? downloadBps;
    latencyMs = latency ?? latencyMs;
    _diagCtrl = StreamController<String>.broadcast();

    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _port = _server!.port;
    _running = true;
    _server!.listen(_onConnection, onError: (_) => stop());
    _emit('proxy: iniciado en puerto $_port');
    return _port;
  }

  Future<void> stop() async {
    _running = false;
    for (final c in _connections) {
      try { c.destroy(); } catch (_) {}
    }
    _connections.clear();
    await _server?.close();
    _server = null;
    await _diagCtrl?.close();
    _diagCtrl = null;
    _port = 0;
  }

  void updateLimits({int? upBps, int? downBps, int? latency}) {
    uploadBps = upBps ?? uploadBps;
    downloadBps = downBps ?? downloadBps;
    latencyMs = latency ?? latencyMs;
  }

  void _emit(String msg) {
    _diagCtrl?.add(msg);
  }

  int _totalConns = 0;
  int _totalBytes = 0;

  void _onConnection(Socket client) {
    _connections.add(client);
    _totalConns++;
    final connId = _totalConns;
    final connStart = DateTime.now();
    final limits = <String>[];
    if (uploadBps > 0) limits.add('↑${uploadBps}b/s');
    if (downloadBps > 0) limits.add('↓${downloadBps}b/s');
    if (latencyMs > 0) limits.add('±${latencyMs}ms');
    final limitStr = limits.isEmpty ? 'sin límites' : limits.join(' ');
    _emit('proxy: ⚡ #$connId conexión desde ${client.remoteAddress} — $limitStr');
    client.done.then((_) {
      _connections.remove(client);
      final elapsed = DateTime.now().difference(connStart).inMilliseconds;
      _emit('proxy:   #$connId finalizada — ${elapsed}ms bytes=$_totalBytes');
    });
    _handleProxy(client);
  }

  void _handleProxy(Socket client) {
    final reader = _BufferedReader(client);
    _handleProxyWithReader(client, reader).then((_) {
      reader.close();
      try { client.destroy(); } catch (_) {}
    }, onError: (_) {
      reader.close();
      try { client.destroy(); } catch (_) {}
    });
  }

  Future<void> _handleProxyWithReader(
      Socket client, _BufferedReader reader) async {
    final header = await reader.readLine();
    if (header.isEmpty) {
      _emit('proxy: ✗ header vacío — conexión sin datos');
      return;
    }

    final parts = header.split(' ');
    if (parts.length < 3) {
      _emit('proxy: ✗ header malformado: "$header"');
      return;
    }

    final method = parts[0];
    final rawUrl = parts[1];
    _emit('proxy: ▶ $method $rawUrl');

    if (method == 'CONNECT') {
      _emit('proxy:   └─ tipo=CONNECT host=$rawUrl');
      await _handleConnect(client, rawUrl);
    } else {
      _emit('proxy:   └─ tipo=HTTP method=$method url=$rawUrl');
      await _handleHttpRequest(client, reader, rawUrl, parts);
    }
  }

  Future<void> _handleConnect(Socket client, String hostPort) async {
    final idx = hostPort.lastIndexOf(':');
    if (idx <= 0) return;
    final host = hostPort.substring(0, idx);
    final port = int.tryParse(hostPort.substring(idx + 1)) ?? 443;

    Socket? origin;
    try {
      _emit('proxy:   CONNECT conectando a $host:$port…');
      origin = await Socket.connect(host, port,
          timeout: const Duration(seconds: 15));
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await client.flush();
      _emit('proxy:   CONNECT establecido $host:$port — relayando tráfico TLS');

      final relayStart = DateTime.now();
      await Future.wait([
        _relayThrottled(client, origin, uploadBps),
        _relayThrottled(origin, client, downloadBps),
      ]);
      final elapsed = DateTime.now().difference(relayStart).inMilliseconds;
      _emit('proxy:   CONNECT $host:$port cerrado en ${elapsed}ms');
    } catch (e) {
      _emit('proxy:   ✗ CONNECT $host:$port error: $e');
    } finally {
      origin?.destroy();
    }
  }

  Future<void> _handleHttpRequest(
      Socket client, _BufferedReader reader,
      String rawUrl, List<String> firstLineParts) async {
    final method = firstLineParts[0];
    final headers = <String>[];
    while (true) {
      final line = await reader.readLine();
      if (line.isEmpty) break;
      headers.add(line);
    }

    int contentLength = 0;
    for (final h in headers) {
      if (h.toLowerCase().startsWith('content-length:')) {
        contentLength = int.tryParse(h.split(':').last.trim()) ?? 0;
        break;
      }
    }

    List<int>? body;
    if (contentLength > 0) {
      body = await reader.readBytes(contentLength);
    }

    _emit('proxy:   headers recibidos → ${headers.length} líneas');

    // Parsear URL absoluta del proxy
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      _emit('proxy: ✗ URL inválida: $rawUrl');
      return;
    }

    final originHost = uri.host;
    final originPort = uri.port > 0 ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final originPath = '${uri.path}${uri.query.isNotEmpty ? '?${uri.query}' : ''}';
    final path = originPath.isEmpty ? '/' : originPath;
    _emit('proxy:   destino=$originHost:$originPort ruta=$path body=${contentLength}B');

    // Conectar al servidor origen
    Socket? origin;
    try {
      origin = await Socket.connect(originHost, originPort,
          timeout: const Duration(seconds: 15));
      _emit('proxy: conectado a $originHost:$originPort');
    } catch (e) {
      _emit('proxy: error conexión $originHost:$originPort — $e');
      return;
    }

    // Latencia antes de reenviar
    if (latencyMs > 0) {
      await Future.delayed(Duration(milliseconds: latencyMs));
    }

    // Reconstruir request con ruta relativa (NO absoluta)
    final request = StringBuffer();
    request.writeln('$method $path HTTP/1.1');
    for (final h in headers) {
      final hl = h.toLowerCase();
      if (hl.startsWith('proxy-') || hl.startsWith('keep-alive')) continue;
      request.writeln(h);
    }
    if (!headers.any((h) => h.toLowerCase().startsWith('host:'))) {
      request.writeln('Host: $originHost${originPort != 80 && originPort != 443 ? ':$originPort' : ''}');
    }
    // Conexión close para evitar keep-alive del proxy
    request.writeln('Connection: close');
    request.writeln();

    final reqBytes = utf8.encode(request.toString());
    _totalBytes += reqBytes.length;
    await _writeThrottled(origin, reqBytes, uploadBps);

    if (body != null && body.isNotEmpty) {
      _totalBytes += body.length;
      await _writeThrottled(origin, body, uploadBps);
    }
    await origin.flush();
    _emit('proxy: request enviado ($method $path)');

    // Reenviar respuesta al cliente con throttling
    final relayStart = DateTime.now();
    await _relayThrottled(origin, client, downloadBps);
    final relayEnd = DateTime.now();
    origin.destroy();
    final elapsed = relayEnd.difference(relayStart).inMilliseconds;
    _emit('proxy:   ✓ respuesta reenviada en ${elapsed}ms — total bytes=$_totalBytes');
  }

  Future<void> _relayThrottled(Socket from, Socket to, int bps) async {
    try {
      if (bps <= 0) {
        await for (final data in from) {
          _totalBytes += data.length;
          to.add(data);
          await to.flush();
        }
        return;
      }

      const minChunk = 256;
      final chunkSize = (bps ~/ 8).clamp(minChunk, 16384);
      final delayMs = (chunkSize / bps * 1000).round().clamp(50, 5000);

      await for (final data in from) {
        _totalBytes += data.length;
        int offset = 0;
        while (offset < data.length) {
          final end = (offset + chunkSize).clamp(0, data.length);
          to.add(data.sublist(offset, end));
          offset = end;
          await to.flush();
          if (end < data.length) {
            await Future.delayed(Duration(milliseconds: delayMs));
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _writeThrottled(Socket sock, List<int> data, int bps) async {
    if (bps <= 0 || data.length < 256) {
      sock.add(data);
      return;
    }

    const minChunk = 256;
    final chunkSize = (bps ~/ 8).clamp(minChunk, 16384);
    final delayMs = (chunkSize / bps * 1000).round().clamp(50, 5000);

    int offset = 0;
    while (offset < data.length) {
      final end = (offset + chunkSize).clamp(0, data.length);
      sock.add(data.sublist(offset, end));
      offset = end;
      await sock.flush();
      if (end < data.length) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
  }
}
