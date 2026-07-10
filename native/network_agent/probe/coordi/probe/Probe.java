package coordi.probe;

import android.util.Log;

import java.lang.reflect.Method;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Helper inyectado en el bootstrap classloader (via JVMTI
 * AddToBootstrapClassLoaderSearch). El bytecode reescrito por slicer en
 * okhttp3.RealCall.execute/enqueue llama a onOkHttp(...) con los argumentos del
 * método envueltos en un Object[] (tweak ArrayParams de slicer):
 *   args[0] = firma del método (String)
 *   args[1] = "this" (la RealCall) para métodos de instancia
 *   args[2..] = parámetros originales
 *
 * Toda la extracción es por reflexión: Probe vive en bootstrap y okhttp en el
 * classloader de la app, pero getClass()/getMethod() resuelven en runtime sin
 * problema de visibilidad. Emite el flujo como `FLOW {json}` por Log.i con el
 * tag CoordiNetAgent, que el host ya parsea desde logcat/socket.
 */
public final class Probe {
    private static final String TAG = "CoordiNetAgent";
    // Cada emisión necesita id único: el host dedupe por id, si no todas las
    // peticiones comparten "okdex" y solo se ve la primera.
    private static final AtomicLong SEQ = new AtomicLong(0);
    // Límite de cuerpo para no emitir payloads gigantes por logcat.
    private static final int MAX_BODY = 4 * 1024;

    private Probe() {}

    public static void onOkHttp(Object[] args) {
        try {
            if (args == null || args.length < 2 || args[1] == null) return;
            final Object call = args[1];
            final Object request = call.getClass().getMethod("request").invoke(call);
            if (request == null) return;
            final Class<?> reqCls = request.getClass();
            final Object method = reqCls.getMethod("method").invoke(request);
            final Object url = reqCls.getMethod("url").invoke(request);
            final String reqHeaders = headersJson(reqCls.getMethod("headers").invoke(request));
            final String reqBody = okhttpRequestBody(request, reqCls);

            emitir("okdex", String.valueOf(method), String.valueOf(url),
                   reqHeaders, reqBody);
        } catch (Throwable t) {
            Log.i(TAG, "DIAG probe onOkHttp err: " + t);
        }
    }

    private static void emitir(String prefijo, String method, String url,
                               String reqHeaders, String reqBody) {
        final StringBuilder json = new StringBuilder(512);
        json.append("{\"id\":\"").append(prefijo).append('-').append(SEQ.incrementAndGet())
            .append("\",\"method\":\"").append(esc(method))
            .append("\",\"url\":\"").append(esc(url))
            .append("\",\"status\":0,\"reqHeaders\":")
            .append(reqHeaders == null || reqHeaders.isEmpty() ? "{}" : reqHeaders)
            .append(",\"reqBody\":\"").append(esc(reqBody == null ? "" : reqBody))
            .append("\",\"respHeaders\":{},\"respBody\":\"\",\"durationMs\":0,\"ts\":0}");
        Log.i(TAG, "FLOW " + json);
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
     * Volley: el método instrumentado recibe el Request como parámetro.
     * args[0]=firma, args[1]="this" (RequestQueue/BasicNetwork/HurlStack),
     * args[2..]=params. Se busca el primer arg que tenga getUrl(): ese es el
     * com.android.volley.Request.
     */
    public static void onVolley(Object[] args) {
        try {
            if (args == null) return;
            Object request = null;
            for (int i = 2; i < args.length; i++) {
                if (args[i] != null && tieneMetodo(args[i], "getUrl")) {
                    request = args[i];
                    break;
                }
            }
            if (request == null) return;
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
                    byte[] bytes = (byte[]) b;
                    int n = Math.min(bytes.length, MAX_BODY);
                    reqBody = new String(bytes, 0, n, "UTF-8");
                    if (bytes.length > MAX_BODY) reqBody += "…(truncado)";
                }
            } catch (Throwable ignore) { }

            emitir("voldex", method, String.valueOf(url), reqHeaders, reqBody);
        } catch (Throwable t) {
            Log.i(TAG, "DIAG probe onVolley err: " + t);
        }
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

    private static boolean tieneMetodo(Object o, String nombre) {
        try {
            o.getClass().getMethod(nombre);
            return true;
        } catch (Throwable t) {
            return false;
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
