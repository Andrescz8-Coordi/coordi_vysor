import 'dart:async';
import 'dart:io';

import '../models/network_condition.dart';
import 'adb_service.dart';
import 'binary_resolver.dart';
import 'throttling_proxy.dart';

/// Aplica condiciones de red simuladas (ancho de banda, latencia, intensidad
/// de señal) en un dispositivo Android vía ADB + proxy local.
///
/// Sin necesidad de root:
/// - Bandwidth/latencia → proxy HTTP local con limitación de velocidad
/// - Intensidad de señal → `settings put global preferred_network_mode`
class NetworkConditionService {
  NetworkConditionService(this._bin);

  final BinaryResolver _bin;
  final ThrottlingProxyServer _proxy = ThrottlingProxyServer();

  Future<String> _runAdb(List<String> args) async {
    final adb = await _bin.adb();
    final r = await Process.run(adb, args);
    if (r.exitCode != 0) {
      throw AdbException((r.stderr as String).trim());
    }
    return (r.stdout as String).trim();
  }

  Future<void> _runAdbBestEffort(List<String> args) async {
    try {
      final adb = await _bin.adb();
      await Process.run(adb, args);
    } catch (_) {}
  }

  Future<int> _deviceApiLevel(String serial) async {
    try {
      final r = await _runAdb([
        '-s', serial, 'shell', 'getprop', 'ro.build.version.sdk',
      ]);
      return int.tryParse(r.trim()) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Aplica las condiciones de red en el dispositivo [serial].
  Future<List<String>> apply(String serial, NetworkCondition condition) async {
    final diag = <String>[];
    if (!condition.enabled || !condition.hasAnyEffect) {
      await _resetAll(serial, diag);
      return diag;
    }

    diag.addAll(await _applySignalStrength(serial, condition));

    if (condition.hasSpeedLimits || condition.hasLatency) {
      diag.addAll(await _applyProxy(serial, condition));
    } else {
      await _resetAll(serial, diag);
    }

    return diag;
  }

  /// Limpia todas las condiciones.
  Future<List<String>> reset(String serial) async {
    final diag = <String>[];
    await _resetAll(serial, diag);
    return diag;
  }

  /// Stream de diagnóstico del proxy.
  Stream<String>? get proxyDiagnostics => _proxy.diagnostics;

  /// Verifica si el dispositivo tiene un proxy HTTP stale configurado
  /// (por una sesión anterior que no se limpió correctamente).
  Future<bool> hasStaleProxy(String serial) async {
    try {
      final r = await _runAdb([
        '-s', serial, 'shell', 'settings', 'get', 'global', 'http_proxy',
      ]);
      final v = r.trim();
      return v.isNotEmpty && v != ':0' && v != 'null';
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> _applySignalStrength(
    String serial,
    NetworkCondition condition,
  ) async {
    final diag = <String>[];
    final sig = condition.signalStrength;
    if (sig == SignalStrength.full) return diag;

    final apiLevel = await _deviceApiLevel(serial);

    if (apiLevel >= 17) {
      final mode = sig.preferredNetworkMode;
      if (mode != null) {
        try {
          final check = await _runAdb([
            '-s', serial, 'shell',
            'settings', 'get', 'global', 'preferred_network_mode',
          ]);
          if (check.trim().isNotEmpty && check.trim() != 'null') {
            await _runAdb([
              '-s', serial, 'shell', 'settings', 'put', 'global',
              'preferred_network_mode', '$mode',
            ]);
            diag.add('red: modo ${sig.label}');
          } else {
            diag.add('red: preferred_network_mode no soportado en este '
                'dispositivo');
          }
        } catch (e) {
          diag.add('red: error — ${e.toString().trim()}');
        }
      }
    } else {
      diag.add('red: Android < 4.2, settings no disponible');
    }

    if (sig == SignalStrength.poor) {
      try {
        await _runAdb([
          '-s', serial, 'shell', 'svc', 'wifi', 'disable',
        ]);
        diag.add('red: WiFi desactivado');
      } catch (e) {
        diag.add('red: error svc wifi — ${e.toString().trim()}');
      }
    }

    return diag;
  }

  Future<List<String>> _applyProxy(
    String serial,
    NetworkCondition condition,
  ) async {
    final diag = <String>[];

    final apiLevel = await _deviceApiLevel(serial);
    if (apiLevel < 21) {
      diag.add('proxy: adb reverse requiere Android ≥ 5.0 (API 21) — '
          'proxy no disponible');
      return diag;
    }
    if (apiLevel < 23) {
      diag.add('proxy: Android < 6.0, algunos comandos settings no '
          'disponibles');
    }

    // Limpiar proxy anterior si existe (incluye reverse)
    await _removeProxy(serial, diag);

    // Iniciar proxy con límites actuales
    try {
      final port = await _proxy.start(
        upBps: condition.uploadSpeedKbps * 1024 ~/ 8,
        downBps: condition.downloadSpeedKbps * 1024 ~/ 8,
        latency: condition.latencyMs,
      );
      diag.add('proxy: iniciado en puerto $port');

      // Exponer al dispositivo con adb reverse
      try {
        await _runAdb([
          '-s', serial, 'reverse',
          'tcp:$port', 'tcp:$port',
        ]);
        diag.add('proxy: adb reverse tcp:$port → OK');
      } catch (e) {
        diag.add('proxy: error adb reverse — ${e.toString().trim()}');
        await _proxy.stop();
        return diag;
      }

      // Configurar proxy HTTP en el dispositivo
      try {
        await _runAdb([
          '-s', serial, 'shell', 'settings', 'put', 'global',
          'http_proxy', '127.0.0.1:$port',
        ]);
        diag.add('proxy: http_proxy → 127.0.0.1:$port');

        final check = await _runAdb([
          '-s', serial, 'shell', 'settings', 'get', 'global', 'http_proxy',
        ]);
        diag.add('proxy: verificación http_proxy → $check');
      } catch (e) {
        diag.add('proxy: error http_proxy — ${e.toString().trim()}');
      }

      diag.add(
        'límites: descarga ↓ ${condition.downloadSpeedKbps} kbps · '
        'subida ↑ ${condition.uploadSpeedKbps} kbps'
        '${condition.latencyMs > 0 ? ' · latencia ${condition.latencyMs}ms' : ''}',
      );
    } catch (e) {
      diag.add('proxy: error al iniciar — ${e.toString().trim()}');
    }

    return diag;
  }

  /// Limpia proxy: detiene servidor, elimina reverse mappings y http_proxy.
  Future<void> _removeProxy(String serial, List<String> diag) async {
    await _proxy.stop();

    final apiLevel = await _deviceApiLevel(serial);

    await _runAdbBestEffort([
      '-s', serial, 'reverse', '--remove-all',
    ]);
    diag.add('proxy: adb reverse --remove-all');

    // Limpiar http_proxy: delete (API 23+) + put :0
    if (apiLevel >= 23) {
      await _runAdbBestEffort([
        '-s', serial, 'shell', 'settings', 'delete', 'global', 'http_proxy',
      ]);
    }

    await _runAdbBestEffort([
      '-s', serial, 'shell', 'settings', 'put', 'global',
      'http_proxy', ':0',
    ]);

    // También limpiar campos separados host/port por si acaso
    await _runAdbBestEffort([
      '-s', serial, 'shell', 'settings', 'put', 'global',
      'global_http_proxy_host', '',
    ]);
    await _runAdbBestEffort([
      '-s', serial, 'shell', 'settings', 'put', 'global',
      'global_http_proxy_port', '0',
    ]);

    // Verificar
    try {
      final check = await _runAdb([
        '-s', serial, 'shell', 'settings', 'get', 'global', 'http_proxy',
      ]);
      final v = check.trim();
      if (v.isEmpty || v == ':0' || v == 'null') {
        diag.add('proxy: verificación OK');
      } else {
        diag.add('proxy: ¡aún configurado! valor=$v — reintentando…');
        await _runAdbBestEffort([
          '-s', serial, 'shell', 'settings', 'put', 'global',
          'http_proxy', ':0',
        ]);
      }
    } catch (_) {}
  }

  Future<void> _resetAll(String serial, List<String> diag) async {
    final apiLevel = await _deviceApiLevel(serial);

    // Restaurar modo de red automático (si el setting existe)
    if (apiLevel >= 17) {
      try {
        final check = await _runAdb([
          '-s', serial, 'shell',
          'settings', 'get', 'global', 'preferred_network_mode',
        ]);
        if (check.trim().isNotEmpty && check.trim() != 'null') {
          await _runAdb([
            '-s', serial, 'shell', 'settings', 'put', 'global',
            'preferred_network_mode', '0',
          ]);
          diag.add('red: modo automático');
        }
      } catch (e) {
        diag.add('red: error al restaurar — ${e.toString().trim()}');
      }
    }

    // Reactivar WiFi por si se desactivó
    await _runAdbBestEffort([
      '-s', serial, 'shell', 'svc', 'wifi', 'enable',
    ]);

    // Forzar refresco de conectividad (API 29+)
    if (apiLevel >= 29) {
      await _runAdbBestEffort([
        '-s', serial, 'shell', 'cmd', 'connectivity', 'proxy', 'clear',
      ]);
    }

    // Limpiar proxy (lo principal que puede dejar sin internet)
    await _removeProxy(serial, diag);
  }

  void dispose() {
    unawaited(_proxy.stop());
  }

  Future<List<String>> checkAvailability(String serial) async {
    final diag = <String>[];
    diag.add('✓ proxy local (sin root) disponible');
    try {
      await _runAdb([
        '-s', serial, 'shell', 'settings', 'get', 'global', 'airplane_mode_on',
      ]);
      diag.add('✓ settings OK');
    } catch (_) {
      diag.add('✗ settings no disponible');
    }
    return diag;
  }
}
