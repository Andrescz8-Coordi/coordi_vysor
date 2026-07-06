# Agente JVMTI — Coordi Net Agent

Biblioteca nativa (`libcoordi_net_agent.so`) inyectada en apps Android debug
mediante:

```bash
adb shell cmd activity attach-agent <package> \
  /data/local/tmp/libcoordi_net_agent.so=port:9876
```

## Ciclo de vida

| Callback | Acción |
|---|---|
| `Agent_OnLoad` | Registro inicial (arranque con `-agentpath`) |
| `Agent_OnAttach` | Inicia socket TCP, registra hooks JVMTI, emite `agent_ready` |
| `Agent_OnUnload` | Limpieza al desadjuntar |

## Salida

Cada petición se emite como JSON:

- **Logcat**: tag `CoordiNetAgent`, prefijo `FLOW `
- **Socket**: TCP `127.0.0.1:<port>` (reenviado al host con `adb reverse`)

## Compilar

```bash
export ANDROID_NDK_HOME=/ruta/al/ndk
./build.sh
```

Genera `.so` para `arm64-v8a`, `armeabi-v7a` y `x86_64` en `assets/agents/`.

## Hooks

El agente detecta `okhttp3` en runtime y registra hooks JVMTI sobre
`HttpURLConnection` / OkHttp (best-effort). El enfoque es el mismo que usa
Android Studio internamente vía App Inspection, pero expuesto como attach externo.
