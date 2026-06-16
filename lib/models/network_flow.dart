/// One captured HTTP(S) request/response pair, emitted by the mitmproxy addon.
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

  /// Device-side source port of the connection to the proxy. Used to map the
  /// flow back to the owning app UID via /proc/net on the device.
  final int clientPort;

  /// Resolved owning app UID, or null if it couldn't be determined.
  int? appUid;

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
    required this.clientPort,
    this.appUid,
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
      clientPort:
          (j['clientPort'] is num) ? (j['clientPort'] as num).toInt() : 0,
    );
  }
}
