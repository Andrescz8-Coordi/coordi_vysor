import 'dart:io';
import 'package:path/path.dart' as p;

/// Resolves paths to the `adb` and `scrcpy` executables.
///
/// Strategy:
/// 1. Bundled binaries next to the app (`bin/<os>/`) — preferred for
///    sharing with the team (zero install).
/// 2. Fallback to whatever is on the system PATH.
class BinaryResolver {
  String? _adbPath;
  String? _scrcpyPath;
  String? _mitmdumpPath;

  String get exeSuffix => Platform.isWindows ? '.exe' : '';

  /// Directory that ships bundled binaries, relative to the running executable.
  /// Layout: `appDir/bin/{windows|macos|linux}/{adb,scrcpy}`.
  Directory get _bundledDir {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final os = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : 'linux';
    return Directory(p.join(exeDir, 'bin', os));
  }

  Future<String> adb() async => _adbPath ??= await _resolve('adb');
  Future<String> scrcpy() async => _scrcpyPath ??= await _resolve('scrcpy');
  Future<String> mitmdump() async =>
      _mitmdumpPath ??= await _resolve('mitmdump');

  /// Path to the bundled `scrcpy-server`, if it ships next to the app.
  /// scrcpy pushes this file to the device; without it scrcpy can't mirror.
  String? get _bundledScrcpyServer {
    final f = File(p.join(_bundledDir.path, 'scrcpy-server'));
    return f.existsSync() ? f.path : null;
  }

  Future<String> _resolve(String name) async {
    final exe = '$name$exeSuffix';

    // 1. Bundled.
    final bundled = File(p.join(_bundledDir.path, exe));
    if (await bundled.exists()) return bundled.path;

    // 2. PATH lookup.
    final which = Platform.isWindows ? 'where' : 'which';
    try {
      final r = await Process.run(which, [name]);
      if (r.exitCode == 0) {
        final out = (r.stdout as String).trim().split('\n').first.trim();
        if (out.isNotEmpty) return out;
      }
    } catch (_) {/* fall through */}

    // 3. Last resort: bare name, let the OS try.
    return name;
  }

  /// Environment passed to scrcpy so it can find its bundled adb.
  Future<Map<String, String>> environment() async {
    final env = Map<String, String>.from(Platform.environment);
    final adbPath = await adb();
    // scrcpy honours ADB to locate the adb binary.
    env['ADB'] = adbPath;
    // When shipping a bundled scrcpy, point it at the bundled server too;
    // otherwise scrcpy looks in its default install prefix (not present here).
    final server = _bundledScrcpyServer;
    if (server != null) env['SCRCPY_SERVER_PATH'] = server;
    return env;
  }
}
