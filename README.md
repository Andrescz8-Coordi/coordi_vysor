# COORDI VYSOR

GUI multiplataforma (Windows / macOS / Linux) para controlar dispositivos Android
con [scrcpy](https://github.com/Genymobile/scrcpy) sin escribir comandos.

La app es un **panel de lanzamiento**: lista los dispositivos conectados (USB o
Wi-Fi), permite ajustar opciones de forma visual (resolución, bitrate, FPS,
grabación, etc.) y abre el mirror de scrcpy. El video se muestra en la ventana
propia de scrcpy.

## Requisitos para desarrollar

- Flutter 3.44+ con desktop habilitado.
- `adb` y `scrcpy` disponibles (en el PATH durante desarrollo, o bundleados para
  distribuir — ver abajo).
- Android NDK r26+ — para compilar el agente JVMTI del inspector de red.

## Ejecutar en desarrollo

```bash
flutter pub get
flutter run -d macos     # o -d windows / -d linux
```

En desarrollo, la app busca `adb` y `scrcpy` en el PATH del sistema. Instálalos:

- macOS: `brew install scrcpy android-platform-tools`
- Linux: `sudo apt install scrcpy adb` (o el gestor de tu distro)
- Windows: descarga el zip de scrcpy (incluye adb) y agrégalo al PATH.

## Cómo se localizan los binarios

`lib/services/binary_resolver.dart` resuelve en este orden:

1. **Bundleados**: `<carpeta del ejecutable>/bin/<windows|macos|linux>/{adb,scrcpy}`
2. **PATH** del sistema (`which` / `where`)
3. Nombre pelado (último recurso)

Para compartir con el equipo sin que instalen nada, bundlea los binarios (paso 1).

## Bundlear binarios para distribuir

Coloca los binarios de cada plataforma así (cada quien compila en su SO, o
preparas los tres):

```
bin/
  macos/    adb  scrcpy  (+ libs / scrcpy-server que scrcpy necesite)
  windows/  adb.exe  scrcpy.exe  (+ dlls del zip oficial)
  linux/    adb  scrcpy
```

### macOS

Después de `flutter build macos --release`, copia los binarios dentro del `.app`:

```bash
APP=build/macos/Build/Products/Release/scrcpy_gui.app
mkdir -p "$APP/Contents/MacOS/bin/macos"
cp "$(which adb)" "$(which scrcpy)" "$APP/Contents/MacOS/bin/macos/"
# scrcpy de brew necesita su scrcpy-server; cópialo junto o exporta SCRCPY_SERVER_PATH
```

> El resolver usa la carpeta del ejecutable (`Contents/MacOS/`), por eso
> `bin/macos/` va ahí.

### Windows

Descarga el zip oficial de scrcpy (trae `scrcpy.exe`, `adb.exe`, dlls y
`scrcpy-server`). Tras `flutter build windows --release`, copia todo el contenido
del zip a `…\Release\bin\windows\` junto al `scrcpy_gui.exe`.

### Linux

Tras `flutter build linux --release`, copia `adb` y `scrcpy` a
`build/linux/x64/release/bundle/bin/linux/`.

> Nota: scrcpy necesita su `scrcpy-server` (jar). Si el binario bundleado no lo
> encuentra, exporta `SCRCPY_SERVER_PATH` apuntando al jar, o usa el paquete
> portable oficial que ya lo incluye.

## Funcionalidad

- Lista de dispositivos con auto-refresco cada 3 s (USB y Wi-Fi).
- Conectar por Wi-Fi (`adb connect IP:puerto`).
- Iniciar / detener mirror por dispositivo (un proceso scrcpy por serial).
- Opciones visuales: resolución máx, bitrate, FPS, pantalla completa, sin bordes,
  siempre encima, mantener despierto, apagar pantalla del teléfono, sin audio,
  solo-ver.
- Vista previa del comando `scrcpy` equivalente.
- **Inspector de red** (botón de red en la barra superior): inyecta un agente
  JVMTI vía ADB attach-agent y muestra peticiones de apps debug.

## Inspector de red

Captura peticiones HTTP(S) de **una app debug** inyectando un agente JVMTI
desde fuera, igual que Android Studio — **sin modificar el código de la app**.

### Flujo

1. La app corre con `android:debuggable=true` (build debug).
2. Coordi Vysor empuja `libcoordi_net_agent.so` a `/data/local/tmp/` en el dispositivo.
3. `adb reverse tcp:9876` expone el socket del agente al host.
4. `adb shell cmd activity attach-agent <package> /data/local/tmp/libcoordi_net_agent.so=port:9876`
5. El agente recibe `Agent_OnAttach`, registra hooks JVMTI (inactivos hasta
   grabar) y, al pulsar **Grabar**, emite cada flow como JSON por **Logcat**
   (`CoordiNetAgent`) y por el **socket local**.

### Uso en la GUI

1. Abre **Inspector de red** (icono LAN).
2. Elige el dispositivo.
3. Abre la app debug en el teléfono (debe aparecer como «En ejecución»).
4. Pulsa **Adjuntar agente**.
5. Pulsa **Grabar** — el attach por sí solo deja los hooks JVMTI registrados
   pero inactivos (evita pagar el costo de deopt global de la VM cuando no
   se está capturando); sin este paso no aparece ninguna petición.
6. Las peticiones aparecen en la lista (request/response).
7. Pulsa **Pausar grabación** cuando termines de reproducir el caso.

### Compilar el agente nativo

Requiere Android NDK r26+:

```bash
export ANDROID_NDK_HOME=/ruta/al/ndk
./native/network_agent/build.sh
```

Los `.so` se copian a `assets/agents/<abi>/`. Añádelos a `pubspec.yaml` (ver
`assets/agents/README.md`).

### Limitaciones

- Solo apps **debug** en ejecución (ART rechaza attach en release).
- OkHttp / HttpsURLConnection (como el Network Inspector de Studio).
- Apps con certificate pinning pueden seguir bloqueando HTTPS.
- El agente no requiere CA de usuario ni proxy global del dispositivo.
- **Algunos builds Samsung One UI (verificado en Android 16 retail) bloquean
  en silencio el despacho de `MethodEntry`/`MethodExit`**: todas las llamadas
  JVMTI (`AddCapabilities`, `SetEventCallbacks`, `SetEventNotificationMode`)
  devuelven éxito (`rc=0`) y la app se pone más lenta (evidencia de que ART sí
  intenta el deopt), pero los hooks nunca disparan — probablemente hardening
  de ART/Knox contra tooling de instrumentación. Verificado que el mismo
  flujo sí funciona en un emulador AOSP (`google_apis_playstore`, misma API).
  Si no ves peticiones en un Samsung, probá en otro fabricante o un
  emulador antes de asumir que el agente está roto.

## Estructura

```
lib/
  main.dart                 arranque + tema
  app_controller.dart       estado central (ChangeNotifier), polling adb
  models/
    device.dart             dispositivo adb
    scrcpy_options.dart     opciones -> args CLI
    network_flow.dart       petición/response capturada
  services/
    binary_resolver.dart    localiza adb/scrcpy/ffmpeg
    adb_service.dart        devices, attach-agent, apps debug, reverse
    agent_network_service.dart  inyección JVMTI + socket/logcat
    scrcpy_service.dart     lanza/mata procesos scrcpy
  screens/
    home_screen.dart        lista de dispositivos
    options_panel.dart      panel de opciones
    network_inspector_screen.dart  inspector de red (payload/response)
assets/
  agents/                   libcoordi_net_agent.so por ABI (compilar con build.sh)
native/
  network_agent/            agente JVMTI (C++/NDK)
```

## Notas

- macOS: el App Sandbox está **desactivado** (`macos/Runner/*.entitlements`)
  porque la app debe lanzar binarios externos y usar la red local. Es una
  herramienta interna, no para la App Store.
- Cada plataforma se compila en su propio SO (Flutter no hace cross-compile de
  desktop).
```
