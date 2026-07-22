import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String? changelog;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
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

      return UpdateInfo(
        version: latestVersion,
        downloadUrl: url,
        changelog: data['changelog'] as String?,
      );
    } catch (_) {
      return null;
    }
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
