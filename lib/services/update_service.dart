import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String? binaryUrl;
  final String? changelog;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    this.binaryUrl,
    this.changelog,
  });
}

class UpdateService {
  static const _versionUrl =
      'https://storage.googleapis.com/apkgoo/coordi-tools-mobile/version.json';

  final http.Client _client = http.Client();

  Future<UpdateInfo?> check() async {
    try {
      final res = await _client
          .get(Uri.parse(_versionUrl))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final latestVersion = data['version'] as String;

      final info = await PackageInfo.fromPlatform();
      final currentVersion = '${info.version}+${info.buildNumber}';

      if (!_isNewer(latestVersion, currentVersion)) return null;

      final platform = _platformKey();
      String? url;
      if (data['platforms'] is Map<String, dynamic>) {
        url = data['platforms'][platform] as String?;
      }
      url ??= data['download_url'] as String?;
      if (url == null || url.isEmpty) return null;

      String? binaryUrl;
      if (data['binaries'] is Map<String, dynamic>) {
        binaryUrl = data['binaries'][platform] as String?;
      }

      return UpdateInfo(
        version: latestVersion,
        downloadUrl: url,
        binaryUrl: binaryUrl,
        changelog: data['changelog'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    void Function(String message)? onMessage,
  }) async {
    final binaryUrl = info.binaryUrl ?? info.downloadUrl;

    onMessage?.call('Descargando...');

    final tempDir = Directory.systemTemp.createTempSync('coordi_update_');
    final parsed = Uri.parse(binaryUrl);
    final fileName = p.basename(parsed.path);
    final tempFile = File(p.join(tempDir.path, fileName));

    final request = http.Request('GET', parsed);
    final response = await _client.send(request);

    final total = response.contentLength ?? -1;
    var received = 0;

    final sink = tempFile.openWrite();
    await for (final chunk in response.stream) {
      received += chunk.length;
      sink.add(chunk);
      if (total > 0) {
        onProgress?.call(received / total);
      }
    }
    await sink.close();

    onMessage?.call('Instalando...');

    if (Platform.isLinux) {
      await _installLinux(tempFile);
    } else if (Platform.isMacOS) {
      await _installMacOS(tempDir, tempFile);
    } else if (Platform.isWindows) {
      await _installWindows(tempFile);
    }
  }

  Future<void> _installLinux(File downloaded) async {
    final exe = Platform.resolvedExecutable;
    final updater = '''#!/bin/bash
sleep 1
while lsof "\$EXE" 2>/dev/null; do sleep 0.5; done
cp "\$TEMP" "\$EXE"
chmod +x "\$EXE"
exec "\$EXE"
''';

    final script = File(p.join(downloaded.parent.path, 'updater.sh'));
    await script.writeAsString(updater);
    await Process.run('chmod', ['+x', script.path]);

    await Process.start(script.path, [], environment: {
      'EXE': exe,
      'TEMP': downloaded.path,
    });

    exit(0);
  }

  Future<void> _installMacOS(Directory tempDir, File downloaded) async {
    final appPath = _macOSAppPath();
    String? extractedApp;

    if (downloaded.path.endsWith('.dmg')) {
      final mount = await Process.run('hdiutil', [
        'attach', '-nobrowse', '-mountrandom', '/tmp', downloaded.path,
      ]);
      final mountLine = mount.stdout
          .toString()
          .split('\n')
          .lastWhere((l) => l.contains('/Volumes/'));
      final mountPath = mountLine.split('\t').last.trim();
      final apps = Directory(mountPath)
          .listSync()
          .where((e) => e.path.endsWith('.app'))
          .toList();
      if (apps.isNotEmpty) {
        extractedApp = p.join(tempDir.path, p.basename(apps.first.path));
        await Process.run('ditto', [apps.first.path, extractedApp]);
      }
      await Process.run('hdiutil', ['detach', mountPath, '-quiet']);
    } else if (downloaded.path.endsWith('.zip')) {
      await Process.run('unzip', ['-o', downloaded.path, '-d', tempDir.path]);
      final apps = tempDir
          .listSync()
          .where((e) => e.path.endsWith('.app'))
          .toList();
      if (apps.isNotEmpty) {
        extractedApp = apps.first.path;
      }
    }

    if (extractedApp == null) {
      throw Exception('No se encontró .app en el instalador');
    }

    final updater = '''#!/bin/bash
sleep 1
while pgrep -f "\${APP}/Contents/MacOS" > /dev/null 2>&1; do sleep 0.5; done
rm -rf "\$APP"
mv "\$NEW_APP" "\$APP"
open "\$APP"
''';

    final script = File(p.join(tempDir.path, 'updater.sh'));
    await script.writeAsString(updater);
    await Process.run('chmod', ['+x', script.path]);

    await Process.start(script.path, [], environment: {
      'APP': appPath,
      'NEW_APP': extractedApp,
    });

    exit(0);
  }

  Future<void> _installWindows(File downloaded) async {
    final exe = Platform.resolvedExecutable;

    final exeName = p.basename(exe);
    final updater = '''@echo off
timeout /t 2 /nobreak >nul
:loop
tasklist /fi "IMAGENAME eq $exeName" 2>nul | find /i "$exeName" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto loop
)
copy /y "\$TEMP" "\$EXE"
start "" "\$EXE"
''';

    final script = File(p.join(downloaded.parent.path, 'updater.bat'));
    await script.writeAsString(updater);

    await Process.start(script.path, [], environment: {
      'EXE': exe,
      'TEMP': downloaded.path,
    });

    exit(0);
  }

  String _macOSAppPath() {
    final exe = Platform.resolvedExecutable;
    final parts = exe.split('/');
    final appIndex = parts.lastIndexWhere((p) => p.endsWith('.app'));
    return appIndex >= 0 ? parts.take(appIndex + 1).join('/') : exe;
  }

  bool _isNewer(String latest, String current) {
    final latestParts = latest.split('+');
    final currentParts = current.split('+');

    final latestVer =
        latestParts[0].split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final currentVer =
        currentParts[0].split('.').map((e) => int.tryParse(e) ?? 0).toList();

    for (int i = 0; i < 3; i++) {
      final l = i < latestVer.length ? latestVer[i] : 0;
      final c = i < currentVer.length ? currentVer[i] : 0;
      if (l != c) return l > c;
    }

    final latestBuild =
        latestParts.length > 1 ? int.tryParse(latestParts[1]) ?? 0 : 0;
    final currentBuild =
        currentParts.length > 1 ? int.tryParse(currentParts[1]) ?? 0 : 0;
    return latestBuild > currentBuild;
  }

  String _platformKey() {
    if (Platform.isMacOS) return 'mac';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return '';
  }

  Future<void> openDownload(UpdateInfo info) async {
    final uri = Uri.parse(info.downloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
