import 'dart:async';
import 'dart:io';

import '../models/agent_attach_result.dart';
import '../models/debug_app.dart';
import '../models/device.dart';
import 'binary_resolver.dart';

/// Talks to adb to list connected devices.
class AdbService {
  AdbService(this._bin);

  final BinaryResolver _bin;

  /// Run `adb devices -l` and parse the output.
  Future<List<Device>> listDevices() async {
    final adb = await _bin.adb();
    final result = await Process.run(adb, ['devices', '-l']);
    if (result.exitCode != 0) {
      throw AdbException((result.stderr as String).trim());
    }
    return _parse(result.stdout as String);
  }

  /// Start the adb server (cheap no-op if already running).
  Future<void> startServer() async {
    final adb = await _bin.adb();
    await Process.run(adb, ['start-server']);
  }

  /// Connect to a device over TCP/IP (host:port).
  Future<String> connectTcp(String hostPort) async {
    final adb = await _bin.adb();
    final r = await Process.run(adb, ['connect', hostPort]);
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    return out.isNotEmpty ? out : err;
  }

  /// Disconnect a TCP/IP device (host:port).
  Future<String> disconnectTcp(String hostPort) async {
    final adb = await _bin.adb();
    final r = await Process.run(adb, ['disconnect', hostPort]);
    return (r.stdout as String).trim();
  }

  /// Step 1 of Wi-Fi setup: restart the device's adb daemon in TCP/IP mode.
  /// Device must be connected over USB. Returns adb's message.
  Future<String> tcpip(String serial, {int port = 5555}) async {
    final adb = await _bin.adb();
    final r = await Process.run(adb, ['-s', serial, 'tcpip', '$port']);
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    if (r.exitCode != 0) throw AdbException(err.isNotEmpty ? err : out);
    return out.isNotEmpty ? out : 'modo TCP/IP activado en puerto $port';
  }

  /// Best-effort: read the device's Wi-Fi (wlan0) IPv4 address so the user
  /// doesn't have to type it. Returns null if it can't be determined.
  Future<String?> deviceIp(String serial) async {
    final adb = await _bin.adb();

    // Preferred: `ip route` shows the src IP of the wlan interface.
    final route = await Process.run(
        adb, ['-s', serial, 'shell', 'ip', '-f', 'inet', 'addr', 'show', 'wlan0']);
    final ip = _firstIpv4((route.stdout as String));
    if (ip != null) return ip;

    // Fallback: parse `ip route`.
    final route2 =
        await Process.run(adb, ['-s', serial, 'shell', 'ip', 'route']);
    final m = RegExp(r'src (\d+\.\d+\.\d+\.\d+)')
        .firstMatch(route2.stdout as String);
    return m?.group(1);
  }

  String? _firstIpv4(String text) {
    final m = RegExp(r'inet (\d+\.\d+\.\d+\.\d+)').firstMatch(text);
    return m?.group(1);
  }

  /// Push a file to the device.
  Future<void> pushFile(String serial, String localPath, String remotePath) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'push', localPath, remotePath]);
    if (r.exitCode != 0) {
      throw AdbException((r.stderr as String).trim());
    }
  }

  /// chmod on device (best-effort).
  Future<void> shellChmod(String serial, String path, String mode) async {
    final adb = await _bin.adb();
    await Process.run(adb, ['-s', serial, 'shell', 'chmod', mode, path]);
  }

  /// Primary ABI of the device (e.g. arm64-v8a).
  Future<String> deviceAbi(String serial) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'shell', 'getprop', 'ro.product.cpu.abi']);
    final abi = (r.stdout as String).trim();
    if (abi.isEmpty) return 'arm64-v8a';
    return abi;
  }

  /// Whether [package] is marked debuggable in its manifest.
  Future<bool> isDebuggable(String serial, String package) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'shell', 'dumpsys', 'package', package]);
    final out = r.stdout as String;
    return RegExp(r'\bDEBUGGABLE\b').hasMatch(out);
  }

  /// Whether [package] has a running process.
  Future<bool> isAppRunning(String serial, String package) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'shell', 'pidof', package]);
    return (r.stdout as String).trim().isNotEmpty;
  }

  /// List installed debuggable packages (best-effort via pm + dumpsys).
  Future<List<DebugApp>> listDebuggableApps(String serial) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'shell', 'pm', 'list', 'packages']);
    final packages = <String>[];
    for (final line in (r.stdout as String).split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('package:')) continue;
      packages.add(trimmed.substring('package:'.length));
    }
    final apps = <DebugApp>[];
    for (final pkg in packages) {
      if (!await isDebuggable(serial, pkg)) continue;
      final running = await isAppRunning(serial, pkg);
      apps.add(DebugApp(package: pkg, isRunning: running));
    }
    apps.sort((a, b) {
      if (a.isRunning != b.isRunning) return a.isRunning ? -1 : 1;
      return a.package.compareTo(b.package);
    });
    return apps;
  }

  /// Forward host port to device port (`adb reverse`).
  Future<void> reversePort(String serial, int devicePort, int hostPort) async {
    final adb = await _bin.adb();
    final r = await Process.run(adb, [
      '-s', serial, 'reverse',
      'tcp:$devicePort', 'tcp:$hostPort',
    ]);
    if (r.exitCode != 0) {
      throw AdbException((r.stderr as String).trim());
    }
  }

  /// Remove a reverse port mapping.
  Future<void> removeReverse(String serial, int port) async {
    final adb = await _bin.adb();
    await Process.run(adb, ['-s', serial, 'reverse', '--remove', 'tcp:$port']);
  }

  /// PIDs de procesos cuyo nombre contiene [package].
  Future<List<int>> processPids(String serial, String package) async {
    final adb = await _bin.adb();
    final pids = <int>{};

    final pidof = await Process.run(adb, ['-s', serial, 'shell', 'pidof', package]);
    for (final tok in (pidof.stdout as String).trim().split(RegExp(r'\s+'))) {
      final n = int.tryParse(tok);
      if (n != null) pids.add(n);
    }

    final ps = await Process.run(
        adb, ['-s', serial, 'shell', 'ps', '-A', '-o', 'PID,NAME']);
    for (final line in (ps.stdout as String).split('\n')) {
      if (!line.contains(package)) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty) continue;
      final n = int.tryParse(parts.first);
      if (n != null) pids.add(n);
    }
    return pids.toList()..sort();
  }

  /// Info legible de procesos del package (para diagnóstico).
  Future<String> processInfo(String serial, String package) async {
    final adb = await _bin.adb();
    final ps = await Process.run(
        adb, ['-s', serial, 'shell', 'ps', '-A', '-o', 'PID,NAME,ARGS']);
    final lines = (ps.stdout as String)
        .split('\n')
        .where((l) => l.contains(package))
        .toList();
    return lines.isEmpty ? 'Sin procesos visibles para $package' : lines.join('\n');
  }

  /// Verifica que el .so exista en el dispositivo.
  Future<String> remoteFileStat(String serial, String remotePath) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'shell', 'ls', '-l', remotePath]);
    return (r.stdout as String).trim().isEmpty
        ? (r.stderr as String).trim()
        : (r.stdout as String).trim();
  }

  /// Copia el agente a un directorio privado de la app debug, legible y
  /// mapeable con permisos de ejecución por el proceso (a diferencia de
  /// /data/local/tmp, donde SELinux bloquea el mmap PROT_EXEC del .so).
  ///
  /// shell lee el .so de /data/local/tmp y lo canaliza hacia run-as, que lo
  /// escribe ya con la identidad (uid + contexto SELinux) de la app.
  /// Devuelve la ruta absoluta en el dispositivo, o null si falla.
  Future<({String? path, String detail})> pushAgentToAppCacheWithDetail(
    String serial,
    String package,
    String tmpRemotePath,
  ) async {
    final adb = await _bin.adb();
    final log = StringBuffer();

    // code_cache puede no existir aún; se prueban varios destinos privados.
    const destDirs = ['code_cache', 'files', 'cache'];

    final base = await _appDataDir(serial, package);
    if (base == null) {
      log.writeln('run-as pwd falló: la app no es debuggable o run-as no '
          'está disponible para $package');
      return (path: null, detail: log.toString().trim());
    }
    log.writeln('app dir: $base');

    for (final dir in destDirs) {
      final rel = '$dir/coordi_net_agent.so';
      // Una sola invocación run-as: crear dir, volcar stdin, marcar ejecutable.
      final script =
          'mkdir -p $dir && cat > $rel && chmod 700 $rel && wc -c < $rel';
      final copy = await Process.run(adb, [
        '-s',
        serial,
        'shell',
        'cat $tmpRemotePath | run-as $package sh -c "$script"',
      ]);
      final out = (copy.stdout as String).trim();
      final err = (copy.stderr as String).trim();
      final bytes = int.tryParse(out.split(RegExp(r'\s+')).last) ?? 0;
      log.writeln('run-as → $dir/: exit=${copy.exitCode} bytes=$bytes'
          '${err.isEmpty ? "" : " err=$err"}');
      if (copy.exitCode == 0 && bytes > 0) {
        final full = '$base/$rel';
        log.writeln('ruta final: $full');
        return (path: full, detail: log.toString().trim());
      }
    }

    return (path: null, detail: log.toString().trim());
  }

  /// Directorio de datos privado de la app (vía run-as pwd), o null.
  Future<String?> _appDataDir(String serial, String package) async {
    final adb = await _bin.adb();
    final pwd =
        await Process.run(adb, ['-s', serial, 'shell', 'run-as', package, 'pwd']);
    if (pwd.exitCode != 0) return null;
    final base = (pwd.stdout as String).trim();
    return base.isEmpty ? null : base;
  }

  Future<String?> pushAgentToAppCache(
    String serial,
    String package,
    String tmpRemotePath,
  ) async {
    final r = await pushAgentToAppCacheWithDetail(serial, package, tmpRemotePath);
    return r.path;
  }

  Future<int> deviceApiLevel(String serial) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'shell', 'getprop', 'ro.build.version.sdk']);
    return int.tryParse((r.stdout as String).trim()) ?? 0;
  }

  String relevantLogcatForUi(String log) => _relevantLogcatLines(log);

  /// Un intento de attach-agent.
  Future<String> _attachOnce(
    String adb,
    String serial,
    String processOrPid,
    String agentPathWithOptions,
  ) async {
    final r = await Process.run(adb, [
      '-s', serial, 'shell', 'cmd', 'activity', 'attach-agent',
      processOrPid, agentPathWithOptions,
    ]);
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    final code = r.exitCode;
    return 'cmd activity attach-agent $processOrPid → exit=$code '
        '${out.isEmpty ? "" : "out=$out "}${err.isEmpty ? "" : "err=$err"}';
  }

  /// Fallback Android más antiguo.
  Future<String> _attachAm(
    String adb,
    String serial,
    String package,
    String agentPathWithOptions,
  ) async {
    final r = await Process.run(adb, [
      '-s', serial, 'shell', 'am', 'attach-agent', package, agentPathWithOptions,
    ]);
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    return 'am attach-agent → exit=${r.exitCode} out=$out err=$err';
  }

  /// Logcat reciente sin filtrar (últimas [lines] líneas).
  Future<String> recentLogcat(String serial, {int lines = 400}) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'logcat', '-d', '-t', '$lines']);
    return (r.stdout as String);
  }

  bool _logcatShowsAgent(String log) {
    return log.contains('CoordiNetAgent') ||
        log.contains('Agent_OnAttach') ||
        log.contains('Agent_OnLoad');
  }

  String _relevantLogcatLines(String log) {
    const keys = [
      'CoordiNetAgent',
      'Agent_OnAttach',
      'attach-agent',
      'attach agent',
      'jvmti',
      'openjdkjvmti',
      'dlopen',
      'couldn\'t map',
      'permission denied',
      'agent attach failed',
      'nativeloader',
      'Unable to attach',
      'not debuggable',
    ];
    final out = <String>[];
    for (final line in log.split('\n')) {
      final lower = line.toLowerCase();
      for (final k in keys) {
        if (lower.contains(k.toLowerCase())) {
          out.add(line.trim());
          break;
        }
      }
    }
    if (out.isEmpty) {
      return 'Sin líneas relevantes en logcat (attach/jvmti/agent).\n'
          'El agente .so probablemente no se cargó en ningún proceso.';
    }
    return out.take(30).join('\n');
  }

  /// Inyecta el agente probando varias rutas y procesos; verifica en logcat.
  Future<AgentAttachResult> attachAgentVerified({
    required String serial,
    required String package,
    required String tmpAgentPath,
    required String agentOptions,
    Duration verifyTimeout = const Duration(seconds: 10),
  }) async {
    final adb = await _bin.adb();
    final log = StringBuffer();
    var pathUsed = tmpAgentPath;

    final api = await deviceApiLevel(serial);
    log.writeln('API SDK: $api (attach-agent requiere ≥28, cmd activity ≥29)');

    final stat = await remoteFileStat(serial, tmpAgentPath);
    log.writeln('ls tmp: $stat');

    final cacheResult =
        await pushAgentToAppCacheWithDetail(serial, package, tmpAgentPath);
    log.writeln(cacheResult.detail);
    if (cacheResult.path != null) {
      pathUsed = cacheResult.path!;
      log.writeln('Usando code_cache (legible por la app)');
    } else {
      log.writeln(
        'ADVERTENCIA: run-as falló; /data/local/tmp puede ser ilegible '
        'para la app en Android 10+',
      );
      await shellChmod(serial, tmpAgentPath, '755');
    }

    final agentArg = '$pathUsed=$agentOptions';
    final pids = await processPids(serial, package);
    log.writeln('PIDs: ${pids.isEmpty ? "ninguno" : pids.join(", ")}');
    log.writeln(await processInfo(serial, package));

    await Process.run(adb, ['-s', serial, 'logcat', '-c']);

    final targets = <String>[package, ...pids.map((p) => '$p')];
    var detected = false;
    var lastSnap = '';

    for (final target in targets) {
      log.writeln(await _attachOnce(adb, serial, target, agentArg));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      lastSnap = await recentLogcat(serial, lines: 300);
      if (_logcatShowsAgent(lastSnap)) {
        detected = true;
        break;
      }
    }

    if (!detected) {
      log.writeln(await _attachAm(adb, serial, package, agentArg));
      final deadline = DateTime.now().add(verifyTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        lastSnap = await recentLogcat(serial, lines: 400);
        if (_logcatShowsAgent(lastSnap)) {
          detected = true;
          break;
        }
      }
    }

    return AgentAttachResult(
      agentDetectedInLogcat: detected,
      attemptsLog: log.toString().trim(),
      agentPathUsed: pathUsed,
      processInfo: await processInfo(serial, package),
      logcatSnippet: _relevantLogcatLines(lastSnap),
    );
  }

  /// Attach simple (legacy).
  Future<String> attachAgent(
    String serial,
    String package,
    String agentPathWithOptions,
  ) async {
    final adb = await _bin.adb();
    final r = await Process.run(adb, [
      '-s', serial, 'shell', 'cmd', 'activity', 'attach-agent',
      package, agentPathWithOptions,
    ]);
    final out = (r.stdout as String).trim();
    final err = (r.stderr as String).trim();
    return [out, err].where((s) => s.isNotEmpty).join('\n');
  }

  /// Whether [serial] looks like a USB device (not an ip:port endpoint).
  static bool isUsbSerial(String serial) =>
      !RegExp(r'^\d+\.\d+\.\d+\.\d+:\d+$').hasMatch(serial);

  List<Device> _parse(String stdout) {
    final lines = stdout.split('\n');
    final devices = <Device>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('List of devices')) continue;
      if (line.startsWith('*')) continue; // daemon messages

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;

      final serial = parts[0];
      final state = parts[1];
      String? model;
      for (final tok in parts.skip(2)) {
        if (tok.startsWith('model:')) {
          model = tok.substring('model:'.length).replaceAll('_', ' ');
        }
      }
      devices.add(Device(serial: serial, state: state, model: model));
    }
    return devices;
  }
}

class AdbException implements Exception {
  final String message;
  AdbException(this.message);
  @override
  String toString() => 'AdbException: $message';
}
