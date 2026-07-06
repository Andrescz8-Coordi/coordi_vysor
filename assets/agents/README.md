# Agente JVMTI para inspector de red

Compila `libcoordi_net_agent.so` y cópialo aquí por ABI:

```
assets/agents/
  arm64-v8a/libcoordi_net_agent.so
  armeabi-v7a/libcoordi_net_agent.so
  x86_64/libcoordi_net_agent.so
```

```bash
./native/network_agent/build.sh   # detecta NDK en ~/Library/Android/sdk/ndk
# o: export ANDROID_NDK_HOME=/ruta/al/ndk && ./native/network_agent/build.sh
```

Los `.so` quedan en `assets/agents/<abi>/` y ya están declarados en `pubspec.yaml`.
Tras compilar el agente, ejecuta `flutter pub get` y vuelve a lanzar/build la app.
