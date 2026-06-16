"""mitmproxy addon: emit one JSON line per completed HTTP(S) flow on stdout.

Loaded via `mitmdump -s flow_dump.py`. The Dart side (network_capture_service)
reads stdout line by line and parses each JSON object into a NetworkFlow.

Bodies are decoded as UTF-8 when possible; binary bodies are reported as a
short placeholder so the stream stays line-delimited JSON.
"""
import json
import sys

# Cap body size so a large download doesn't flood the UI / stdout pipe.
MAX_BODY = 256 * 1024


def _headers(fields):
    out = {}
    try:
        for k, v in fields.items():
            out[str(k)] = str(v)
    except Exception:
        pass
    return out


def _body(message):
    if message is None:
        return ""
    raw = message.raw_content or b""
    if not raw:
        return ""
    if len(raw) > MAX_BODY:
        return "<%d bytes — truncated>" % len(raw)
    try:
        return raw.decode("utf-8")
    except Exception:
        return "<%d bytes — binary>" % len(raw)


def response(flow):
    req = flow.request
    resp = flow.response
    duration_ms = 0
    try:
        if resp and req and resp.timestamp_end and req.timestamp_start:
            duration_ms = int((resp.timestamp_end - req.timestamp_start) * 1000)
    except Exception:
        duration_ms = 0

    client_port = 0
    try:
        peer = flow.client_conn.peername
        if peer:
            client_port = int(peer[1])
    except Exception:
        client_port = 0

    record = {
        "id": flow.id,
        "method": req.method,
        "url": req.pretty_url,
        "status": resp.status_code if resp else 0,
        "clientPort": client_port,
        "reqHeaders": _headers(req.headers),
        "reqBody": _body(req),
        "respHeaders": _headers(resp.headers) if resp else {},
        "respBody": _body(resp) if resp else "",
        "durationMs": duration_ms,
        "ts": req.timestamp_start if req else 0,
    }
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()
