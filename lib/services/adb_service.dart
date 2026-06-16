import 'dart:async';
import 'dart:io';

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

  /// Route the device's traffic through a local proxy (`host:port`).
  /// Applies device-wide to Wi-Fi/cellular HTTP(S).
  Future<void> setDeviceProxy(String serial, String hostPort) async {
    final adb = await _bin.adb();
    final r = await Process.run(adb,
        ['-s', serial, 'shell', 'settings', 'put', 'global', 'http_proxy', hostPort]);
    if (r.exitCode != 0) {
      throw AdbException((r.stderr as String).trim());
    }
  }

  /// Remove the device proxy set by [setDeviceProxy].
  Future<void> clearDeviceProxy(String serial) async {
    final adb = await _bin.adb();
    await Process.run(adb,
        ['-s', serial, 'shell', 'settings', 'put', 'global', 'http_proxy', ':0']);
  }

  /// Read the current device proxy (`host:port`, or empty/`:0` if none).
  Future<String> getDeviceProxy(String serial) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'shell', 'settings', 'get', 'global', 'http_proxy']);
    return (r.stdout as String).trim();
  }

  /// Best-effort host LAN IPv4 (so the device can reach the local proxy).
  /// Returns null if it can't be determined.
  Future<String?> hostLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {/* fall through */}
    return null;
  }

  /// Resolve an installed app's Linux UID from its package name.
  /// Returns null if the package isn't found.
  Future<int?> packageUid(String serial, String package) async {
    final adb = await _bin.adb();
    final r = await Process.run(
        adb, ['-s', serial, 'shell', 'dumpsys', 'package', package]);
    final m = RegExp(r'userId=(\d+)').firstMatch(r.stdout as String);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Resolve the UID owning the socket with device-local source [port], by
  /// scanning /proc/net/tcp{,6}. Returns null if not found (e.g. socket closed,
  /// or the device masks UIDs for the shell user).
  Future<int?> uidForPort(String serial, int port) async {
    if (port == 0) return null;
    final adb = await _bin.adb();
    final hexPort = port.toRadixString(16).toUpperCase().padLeft(4, '0');
    for (final proc in const ['/proc/net/tcp6', '/proc/net/tcp']) {
      final r =
          await Process.run(adb, ['-s', serial, 'shell', 'cat', proc]);
      final uid = _scanProcNet(r.stdout as String, hexPort);
      if (uid != null) return uid;
    }
    return null;
  }

  /// Parse /proc/net/tcp output; return UID for the row whose local port
  /// (hex, after the last ':') matches [hexPort]. Columns are whitespace
  /// separated: sl local rem st tx:rx tr:when retrnsmt uid timeout inode.
  int? _scanProcNet(String text, String hexPort) {
    for (final line in text.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 8) continue;
      final local = parts[1];
      final colon = local.lastIndexOf(':');
      if (colon < 0) continue;
      if (local.substring(colon + 1).toUpperCase() != hexPort) continue;
      return int.tryParse(parts[7]);
    }
    return null;
  }

  /// Push the mitmproxy CA cert to the device and open Settings so the user
  /// can install it as a user CA. This is a manual step — HTTPS decryption
  /// only works for debug apps that trust user CAs.
  Future<void> pushCaCert(String serial, String certPath) async {
    final adb = await _bin.adb();
    const remote = '/sdcard/Download/mitmproxy-ca-cert.cer';
    final push =
        await Process.run(adb, ['-s', serial, 'push', certPath, remote]);
    if (push.exitCode != 0) {
      throw AdbException((push.stderr as String).trim());
    }
    // Open the "install certificate" Settings screen (best-effort across OEMs).
    await Process.run(adb, [
      '-s', serial, 'shell', 'am', 'start',
      '-a', 'android.settings.SECURITY_SETTINGS'
    ]);
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
