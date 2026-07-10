import 'dart:convert';
import 'dart:io';

/// Persists user preferences (options panel selections) to a JSON file in
/// the user's home directory, so they survive app restarts.
class PreferencesService {
  static const _fileName = 'preferences.json';

  File? _file;

  Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;

    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final dir = Directory('$home${Platform.pathSeparator}.coordi_tools');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
    _file = file;
    return file;
  }

  /// Reads stored preferences, or `{}` if none exist yet / file is corrupt.
  Future<Map<String, dynamic>> load() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return {};
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return {};
    } catch (_) {
      return {};
    }
  }

  /// Overwrites the stored preferences with [data].
  Future<void> save(Map<String, dynamic> data) async {
    try {
      final file = await _resolveFile();
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // Persistence is best-effort; a write failure shouldn't crash the app.
    }
  }
}
