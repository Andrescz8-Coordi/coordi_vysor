/// Petición/respuesta HTTP(S) capturada por el agente JVMTI.
class NetworkFlow {
  final String id;
  final String method;
  final String url;
  final int status;
  final Map<String, String> reqHeaders;
  final String reqBody;
  final Map<String, String> respHeaders;
  final String respBody;
  final int durationMs;
  final DateTime ts;

  NetworkFlow({
    required this.id,
    required this.method,
    required this.url,
    required this.status,
    required this.reqHeaders,
    required this.reqBody,
    required this.respHeaders,
    required this.respBody,
    required this.durationMs,
    required this.ts,
  });

  /// Host portion of [url], for compact display.
  String get host {
    final u = Uri.tryParse(url);
    return u?.host ?? url;
  }

  /// Path (+query) portion of [url], for compact display.
  String get path {
    final u = Uri.tryParse(url);
    if (u == null) return url;
    final q = u.query.isEmpty ? '' : '?${u.query}';
    return '${u.path}$q';
  }

  /// Hora local en que se lanzó la petición, con segundos (HH:mm:ss).
  String get timeLabel {
    final t = ts.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Token Bearer del header Authorization en la petición, o null.
  String? get requestBearerToken => _bearerFrom(reqHeaders);

  /// Token Bearer del header Authorization en la respuesta, o null.
  String? get responseBearerToken => _bearerFrom(respHeaders);

  /// Extrae el token de un header `Authorization: Bearer <token>` (insensible
  /// a mayúsculas), o null si no hay un bearer token en [headers].
  ///
  /// Tolera que el valor venga envuelto como lista (`[Bearer xxx]`), tal como
  /// lo serializa `HttpURLConnection.getRequestProperties()` (Map<String,List>).
  static String? _bearerFrom(Map<String, String> headers) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() != 'authorization') continue;
      var value = e.value.trim();
      if (value.startsWith('[') && value.endsWith(']')) {
        value = value.substring(1, value.length - 1).trim();
      }
      final lower = value.toLowerCase();
      final idx = lower.indexOf('bearer ');
      if (idx >= 0) {
        return value.substring(idx + 'bearer '.length).trim();
      }
    }
    return null;
  }

  static Map<String, String> _headers(dynamic raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  factory NetworkFlow.fromJson(Map<String, dynamic> j) {
    final tsRaw = j['ts'];
    final ts = tsRaw is num
        ? DateTime.fromMillisecondsSinceEpoch((tsRaw * 1000).round())
        : DateTime.now();
    return NetworkFlow(
      id: (j['id'] ?? '').toString(),
      method: (j['method'] ?? '').toString(),
      url: (j['url'] ?? '').toString(),
      status: (j['status'] is num) ? (j['status'] as num).toInt() : 0,
      reqHeaders: _headers(j['reqHeaders']),
      reqBody: (j['reqBody'] ?? '').toString(),
      respHeaders: _headers(j['respHeaders']),
      respBody: (j['respBody'] ?? '').toString(),
      durationMs:
          (j['durationMs'] is num) ? (j['durationMs'] as num).toInt() : 0,
      ts: ts,
    );
  }
}
