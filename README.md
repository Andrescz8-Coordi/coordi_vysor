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
- `mitmdump` (paquete `mitmproxy`) en el PATH — solo para el **Inspector de red**.
  macOS: `brew install mitmproxy`.

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
- **Inspector de red** (botón de red en la barra superior): captura el tráfico
  HTTP(S) del dispositivo vía un proxy local `mitmdump` y muestra payload y
  response de cada petición.

## Inspector de red

Arranca un `mitmdump` local y apunta el proxy global del dispositivo a la IP LAN
del host (`adb shell settings put global http_proxy <host>:8080`). El addon
`assets/mitm/flow_dump.py` emite cada flow como JSON por stdout; la app lo parsea
y lo lista. Al detener, el proxy del dispositivo se limpia.

- **HTTP plano**: funciona directo.
- **HTTPS**: la app debe ser **debug** y confiar en el CA de usuario de
  mitmproxy. Desde Android 7+ solo se confía en CAs de usuario si el
  `network_security_config` lo permite (los builds debug suelen permitirlo). Usa
  el botón **Instalar CA** para enviar el cert
  (`~/.mitmproxy/mitmproxy-ca-cert.cer`, generado en el primer arranque de
  mitmdump) e instálalo en Ajustes > Seguridad > CA. Apps release o con
  certificate pinning **no** se descifran.

### Filtrar por app (package)

El proxy es device-wide, así que se ve el tráfico de **todo** el dispositivo.
Para aislar una app debug por su package:

1. Escribe el package (`com.ejemplo.app`) y pulsa **Resolver UID**
   (`adb shell dumpsys package <pkg>` → `userId=NNNN`).
2. Marca **Solo esta app**.

Cada flow se atribuye a un UID mapeando su puerto origen contra
`/proc/net/tcp{,6}` del dispositivo. Es **best-effort**: en Android 10+ el
usuario `shell` puede ver los UIDs enmascarados (los flows quedan como `uid ?`),
y conexiones keep-alive ya cerradas pueden no resolverse. Sin root no hay forma
nativa de proxy por-app.

> No replica el App Inspection de Android Studio (agente JVMTI no expuesto). Es
> una captura por proxy.

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
    binary_resolver.dart    localiza adb/scrcpy/mitmdump
    adb_service.dart        `adb devices`, connect, proxy/CA del device
    scrcpy_service.dart     lanza/mata procesos scrcpy
    network_capture_service.dart  lanza mitmdump, parsea flows
  screens/
    home_screen.dart        lista de dispositivos
    options_panel.dart      panel de opciones
    network_inspector_screen.dart  inspector de red (payload/response)
assets/
  mitm/flow_dump.py         addon mitmproxy -> JSON por stdout
```

## Notas

- macOS: el App Sandbox está **desactivado** (`macos/Runner/*.entitlements`)
  porque la app debe lanzar binarios externos y usar la red local. Es una
  herramienta interna, no para la App Store.
- Cada plataforma se compila en su propio SO (Flutter no hace cross-compile de
  desktop).
```
