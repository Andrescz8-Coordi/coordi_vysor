package coordi.probe;

import android.util.Log;

import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Helper inyectado en el bootstrap classloader (via JVMTI
 * AddToBootstrapClassLoaderSearch).
 *
 * OkHttp: el bytecode reescrito por slicer en
 * RealCall.getResponseWithInterceptorChain() (choke point común a
 * execute() síncrono y a AsyncCall async) llama a dos hooks sobre ese mismo
 * método:
 *   - onOkHttpEntry(Object this): marca timestamp de inicio (ThreadLocal).
 *   - onOkHttpResult(Object response): recibe el Response ya completo — trae
 *     .request() adentro — arma el flow entero (request+response) y lo
 *     emite. Debe devolver el mismo objeto que recibe (Tweak ReturnAsObject
 *     de slicer sustituye el valor de retorno real por el que este método
 *     devuelva).
 *
 * Volley: mismo patrón entry+exit, sobre BasicNetwork.performRequest(Request)
 * (el único choke point: todo RequestQueue/NetworkDispatcher pasa por acá para
 * cualquier Network estándar) — devuelve NetworkResponse, que trae
 * status/headers/body pero NO referencia al Request original, así que
 * onVolleyEntry guarda el Request (vía tweak ArrayParams: args[2] es el
 * primer parámetro real) en un ThreadLocal a la espera de onVolleyResult.
 *
 * Toda la extracción es por reflexión: Probe vive en bootstrap y
 * okhttp/volley en el classloader de la app, pero getClass()/getMethod()
 * resuelven en runtime sin problema de visibilidad. Emite el flujo como
 * `FLOW {json}` por Log.i con el tag CoordiNetAgent, que el host ya parsea
 * desde logcat/socket.
 */
public final class Probe {
    private static final String TAG = "CoordiNetAgent";
    // Cada emisión necesita id único: el host dedupe por id, si no todas las
    // peticiones comparten "okdex" y solo se ve la primera.
    private static final AtomicLong SEQ = new AtomicLong(0);
    // Límite de cuerpo para no emitir payloads gigantes por logcat.
    private static final int MAX_BODY = 4 * 1024;
    // Timestamps de entrada por hilo: execute() y su AsyncCall interna
    // corren enteros en un mismo hilo (el de la app o el del dispatcher de
    // OkHttp), así que no hace falta correlacionar entre hilos. Pila (no un
    // solo valor) por si hay una llamada okhttp anidada dentro de otra en el
    // mismo hilo.
    private static final ThreadLocal<java.util.ArrayDeque<Long>> START_STACK =
            ThreadLocal.withInitial(java.util.ArrayDeque::new);
    // Pila de [Request, Long startNanos] por hilo — performRequest(Request) es
    // síncrono, entrada y salida corren en el mismo hilo (el del
    // NetworkDispatcher que procesó esa petición).
    private static final ThreadLocal<java.util.ArrayDeque<Object[]>> VOLLEY_STACK =
            ThreadLocal.withInitial(java.util.ArrayDeque::new);
    // Un log entry de Android trunca en silencio ~4KB (LOGGER_ENTRY_MAX_PAYLOAD):
    // un FLOW con Authorization Bearer + body JSON puede superarlo fácil y
    // llegar cortado (JSON inválido) al host, que lo descarta sin aviso. El
    // agente nativo vincula este método a la emisión por socket (sin ese
    // límite) via RegisterNatives — ver probe_loader.cpp. Si por lo que sea
    // no quedó vinculado (RegisterNatives falló), cae a Log.i como antes.
    private static native void nativeEmit(String json);
    private static volatile boolean nativeDisponible = true;

    private Probe() {}

    private static void enviar(String json) {
        if (nativeDisponible) {
            try {
                nativeEmit(json);
                return;
            } catch (Throwable t) {
                nativeDisponible = false;
                Log.i(TAG, "DIAG probe nativeEmit no disponible, fallback a Log.i: " + t);
            }
        }
        Log.i(TAG, "FLOW " + json);
    }

    public static void onOkHttpEntry(Object thisCall) {
        START_STACK.get().push(System.nanoTime());
    }

    public static Object onOkHttpResult(Object response) {
        try {
            emitirDesdeOkHttpResponse(response);
        } catch (Throwable t) {
            Log.i(TAG, "DIAG probe onOkHttpResult err: " + t);
        }
        return response;
    }

    private static void emitirDesdeOkHttpResponse(Object response) throws Exception {
        final java.util.ArrayDeque<Long> stack = START_STACK.get();
        final Long startNanos = stack.isEmpty() ? null : stack.pop();
        if (response == null) return;

        final Class<?> respCls = response.getClass();
        final Object request = respCls.getMethod("request").invoke(response);
        if (request == null) return;
        final Class<?> reqCls = request.getClass();
        final Object method = reqCls.getMethod("method").invoke(request);
        final Object url = reqCls.getMethod("url").invoke(request);
        final String reqHeaders = headersJson(reqCls.getMethod("headers").invoke(request));
        final String reqBody = okhttpRequestBody(request, reqCls);

        final int status = (Integer) respCls.getMethod("code").invoke(response);
        final String respHeaders = headersJson(respCls.getMethod("headers").invoke(response));
        final String respBody = okhttpResponseBody(response, respCls);
        final long durationMs = startNanos == null
                ? 0L : (System.nanoTime() - startNanos) / 1_000_000L;

        emitirCompleto("okdex", String.valueOf(method), String.valueOf(url), status,
                reqHeaders, reqBody, respHeaders, respBody, durationMs);
    }

    // Cuerpo del response vía Response.peekBody(limit) — OJO: peekBody vive en
    // Response, NO en ResponseBody (a diferencia de lo que uno esperaría por
    // analogía con RequestBody.writeTo). Copia no destructiva, el stream real
    // que la app va a leer queda intacto.
    private static String okhttpResponseBody(Object response, Class<?> respCls) {
        try {
            final Object peeked = respCls.getMethod("peekBody", long.class)
                    .invoke(response, (long) MAX_BODY);
            if (peeked == null) {
                Log.i(TAG, "DIAG probe okhttpResponseBody: peekBody devolvio null");
                return "";
            }
            String s = (String) peeked.getClass().getMethod("string").invoke(peeked);
            if (s == null) return "";
            if (s.length() > MAX_BODY) s = s.substring(0, MAX_BODY) + "…(truncado)";
            return s;
        } catch (Throwable t) {
            Log.i(TAG, "DIAG probe okhttpResponseBody err: " + t
                    + (t.getCause() != null ? " cause=" + t.getCause() : ""));
            return "";
        }
    }

    private static void emitirCompleto(String prefijo, String method, String url, int status,
                               String reqHeaders, String reqBody,
                               String respHeaders, String respBody, long durationMs) {
        final StringBuilder json = new StringBuilder(768);
        json.append("{\"id\":\"").append(prefijo).append('-').append(SEQ.incrementAndGet())
            .append("\",\"method\":\"").append(esc(method))
            .append("\",\"url\":\"").append(esc(url))
            .append("\",\"status\":").append(status)
            .append(",\"reqHeaders\":")
            .append(reqHeaders == null || reqHeaders.isEmpty() ? "{}" : reqHeaders)
            .append(",\"reqBody\":\"").append(esc(reqBody == null ? "" : reqBody))
            .append("\",\"respHeaders\":")
            .append(respHeaders == null || respHeaders.isEmpty() ? "{}" : respHeaders)
            .append(",\"respBody\":\"").append(esc(respBody == null ? "" : respBody))
            .append("\",\"durationMs\":").append(durationMs)
            .append(",\"ts\":").append(tsAhora())
            .append('}');
        enviar(json.toString());
    }

    // Segundos desde epoch (con fracción, como emitirFlowCompleto en el lado
    // C++) — antes esto quedaba fijo en "ts":0, así que el host mostraba
    // 1970 (o la hora que sea que 0 mapee en el huso local) para TODAS las
    // peticiones en vez de cuándo se lanzaron de verdad. Locale.US fuerza el
    // punto decimal: con la coma de otros locales el JSON queda inválido.
    private static String tsAhora() {
        return String.format(java.util.Locale.US, "%.3f", System.currentTimeMillis() / 1000.0);
    }

    // okhttp Headers → objeto JSON {"name":"value",...} (size()/name(i)/value(i)).
    private static String headersJson(Object headers) {
        if (headers == null) return "{}";
        try {
            final Class<?> c = headers.getClass();
            final int n = (Integer) c.getMethod("size").invoke(headers);
            final Method name = c.getMethod("name", int.class);
            final Method value = c.getMethod("value", int.class);
            final StringBuilder b = new StringBuilder("{");
            for (int i = 0; i < n; i++) {
                if (i > 0) b.append(',');
                b.append('"').append(esc(String.valueOf(name.invoke(headers, i))))
                 .append("\":\"").append(esc(String.valueOf(value.invoke(headers, i))))
                 .append('"');
            }
            return b.append('}').toString();
        } catch (Throwable t) {
            return "{}";
        }
    }

    // Lee el cuerpo del okhttp RequestBody copiándolo a un okio.Buffer (igual que
    // HttpLoggingInterceptor). Solo si NO es one-shot/duplex (leerlo ahí rompería
    // el request real). okio se carga con el classloader de la app (Probe vive en
    // bootstrap y no lo ve).
    private static String okhttpRequestBody(Object request, Class<?> reqCls) {
        try {
            final Object body = reqCls.getMethod("body").invoke(request);
            if (body == null) return "";
            final Class<?> bodyCls = body.getClass();
            if (esVerdadero(bodyCls, body, "isOneShot")) return "";
            if (esVerdadero(bodyCls, body, "isDuplex")) return "";

            final ClassLoader cl = request.getClass().getClassLoader();
            final Class<?> bufferCls = cl.loadClass("okio.Buffer");
            final Class<?> sinkCls = cl.loadClass("okio.BufferedSink");
            final Object buffer = bufferCls.getConstructor().newInstance();
            bodyCls.getMethod("writeTo", sinkCls).invoke(body, buffer);
            String s = (String) bufferCls.getMethod("readUtf8").invoke(buffer);
            if (s == null) return "";
            if (s.length() > MAX_BODY) s = s.substring(0, MAX_BODY) + "…(truncado)";
            return s;
        } catch (Throwable t) {
            return "";
        }
    }

    private static boolean esVerdadero(Class<?> cls, Object obj, String metodo) {
        try {
            return Boolean.TRUE.equals(cls.getMethod(metodo).invoke(obj));
        } catch (Throwable t) {
            return false;  // método ausente (okhttp viejo) → asumir seguro
        }
    }

    /**
     * BasicNetwork.performRequest(Request) — entrada. args[0]=firma,
     * args[1]="this" (BasicNetwork), args[2]=Request. Guarda el Request y el
     * timestamp para que onVolleyResult arme el flow completo al salir.
     */
    public static void onVolleyEntry(Object[] args) {
        try {
            if (args == null || args.length < 3 || args[2] == null) return;
            VOLLEY_STACK.get().push(new Object[]{args[2], System.nanoTime()});
        } catch (Throwable t) {
            Log.i(TAG, "DIAG probe onVolleyEntry err: " + t);
        }
    }

    /**
     * BasicNetwork.performRequest(Request) — salida. Recibe el
     * com.android.volley.NetworkResponse (status/headers/body, pero sin
     * referencia al Request original — por eso la correlación con
     * onVolleyEntry). Debe devolver el mismo objeto que recibe (contrato del
     * ExitHook de slicer).
     */
    public static Object onVolleyResult(Object networkResponse) {
        try {
            final java.util.ArrayDeque<Object[]> stack = VOLLEY_STACK.get();
            final Object[] entrada = stack.isEmpty() ? null : stack.pop();
            if (entrada != null) {
                emitirDesdeVolley(entrada[0], (Long) entrada[1], networkResponse);
            }
        } catch (Throwable t) {
            Log.i(TAG, "DIAG probe onVolleyResult err: " + t);
        }
        return networkResponse;
    }

    private static void emitirDesdeVolley(Object request, long startNanos, Object networkResponse)
            throws Exception {
        final Class<?> cls = request.getClass();
        final Object url = cls.getMethod("getUrl").invoke(request);
        String method = "GET";
        try {
            final Object m = cls.getMethod("getMethod").invoke(request);
            method = metodoVolley(m instanceof Integer ? (Integer) m : 0);
        } catch (Throwable ignore) { }

        String reqHeaders = "{}";
        try {
            reqHeaders = mapJson(cls.getMethod("getHeaders").invoke(request));
        } catch (Throwable ignore) { }

        String reqBody = "";
        try {
            final Object b = cls.getMethod("getBody").invoke(request);
            if (b instanceof byte[]) {
                reqBody = bytesATexto((byte[]) b);
            }
        } catch (Throwable ignore) { }

        int status = 0;
        String respHeaders = "{}";
        String respBody = "";
        if (networkResponse != null) {
            final Class<?> respCls = networkResponse.getClass();
            try {
                status = respCls.getField("statusCode").getInt(networkResponse);
            } catch (Throwable ignore) { }
            try {
                // Campo deprecado pero siempre presente (Volley lo sigue
                // poblando junto a allHeaders para compat) — mismo mapJson
                // que ya usa el request.
                respHeaders = mapJson(respCls.getField("headers").get(networkResponse));
            } catch (Throwable ignore) { }
            try {
                final Object data = respCls.getField("data").get(networkResponse);
                if (data instanceof byte[]) {
                    respBody = bytesATexto((byte[]) data);
                }
            } catch (Throwable ignore) { }
        }

        final long durationMs = (System.nanoTime() - startNanos) / 1_000_000L;
        emitirCompleto("voldex", method, String.valueOf(url), status,
                reqHeaders, reqBody, respHeaders, respBody, durationMs);
    }

    /**
     * Request.parseNetworkError(VolleyError) — entrada. Choke point de
     * retorno NORMAL (a diferencia de performRequest, que lanza la excepción y
     * nunca llega a onVolleyResult) llamado por NetworkDispatcher para TODO
     * VolleyError atrapado de performRequest. args[1]=Request (this),
     * args[2]=VolleyError. Si el error trae NetworkResponse real (viene de un
     * status HTTP de error, ej. 500) se emite igual que un flow exitoso;
     * si no (NoConnectionError/TimeoutError: sin respuesta real) se ignora.
     */
    public static void onVolleyErrorEntry(Object[] args) {
        try {
            if (args == null || args.length < 3 || args[1] == null || args[2] == null) return;
            final Object request = args[1];
            final Object volleyError = args[2];
            final Object networkResponse = volleyError.getClass()
                    .getField("networkResponse").get(volleyError);
            if (networkResponse == null) return;

            long startNanos = System.nanoTime();
            final java.util.ArrayDeque<Object[]> stack = VOLLEY_STACK.get();
            final Object[] entrada = stack.isEmpty() ? null : stack.pop();
            if (entrada != null) {
                startNanos = entrada[0] == request ? (Long) entrada[1] : startNanos;
            }
            emitirDesdeVolley(request, startNanos, networkResponse);
        } catch (Throwable t) {
            Log.i(TAG, "DIAG probe onVolleyErrorEntry err: " + t);
        }
    }

    private static String bytesATexto(byte[] bytes) throws Exception {
        int n = Math.min(bytes.length, MAX_BODY);
        String s = new String(bytes, 0, n, "UTF-8");
        if (bytes.length > MAX_BODY) s += "…(truncado)";
        return s;
    }

    // Map<String,String> → objeto JSON.
    private static String mapJson(Object map) {
        if (!(map instanceof java.util.Map)) return "{}";
        try {
            final StringBuilder b = new StringBuilder("{");
            boolean primero = true;
            for (Object e : ((java.util.Map<?, ?>) map).entrySet()) {
                final java.util.Map.Entry<?, ?> en = (java.util.Map.Entry<?, ?>) e;
                if (!primero) b.append(',');
                primero = false;
                b.append('"').append(esc(String.valueOf(en.getKey())))
                 .append("\":\"").append(esc(String.valueOf(en.getValue())))
                 .append('"');
            }
            return b.append('}').toString();
        } catch (Throwable t) {
            return "{}";
        }
    }


    private static String metodoVolley(int c) {
        switch (c) {
            case 0: return "GET";
            case 1: return "POST";
            case 2: return "PUT";
            case 3: return "DELETE";
            case 4: return "HEAD";
            case 5: return "OPTIONS";
            case 6: return "TRACE";
            case 7: return "PATCH";
            default: return "GET";
        }
    }

    private static String esc(String s) {
        if (s == null) return "";
        final StringBuilder out = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            final char c = s.charAt(i);
            switch (c) {
                case '\\': out.append("\\\\"); break;
                case '"': out.append("\\\""); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                default: out.append(c); break;
            }
        }
        return out.toString();
    }
}
