import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_paths.dart';
import 'models.dart';
import 'settings_models.dart';

class LibraryStore {
  LibraryStore({FlutterSecureStorage? secureStorage})
    : _secureStorage =
          secureStorage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _serversKey = 'servers';
  static const _customTracksKey = 'custom_tracks';
  static const _settingsKey = 'app_settings';
  static const _selectedServerKey = 'selected_server_id';
  static const _loginServerUrlKey = 'login_server_url';
  static const _themeModeKey = 'theme_mode';
  static const _playbackSessionKey = 'playback_session';
  static const _dailyRecommendationKey = 'daily_recommendation';

  final FlutterSecureStorage _secureStorage;

  Future<List<ServerConfig>> loadServers() async {
    final rawValue = await _readString(_serversKey);
    if (rawValue == null || rawValue.isEmpty) {
      return [];
    }

    final values = jsonDecode(rawValue);
    if (values is! List) {
      return [];
    }

    final restored = <ServerConfig>[];
    final seenUrls = <String>{};
    for (final value in values.whereType<Map>()) {
      if (value['type'] == 'webdav' ||
          value['id'].toString().startsWith('webdav:')) {
        continue;
      }

      final legacyId = value['id']?.toString() ?? '';
      final server = ServerConfig.fromJson(Map<String, Object?>.from(value));
      if (server.id.isEmpty || !seenUrls.add(server.id)) {
        continue;
      }

      final password =
          await _readSecret(_passwordKey(server.id)) ??
          await _readSecret(_passwordKey(legacyId)) ??
          server.password;
      if (password.isNotEmpty) {
        await _writeSecret(_passwordKey(server.id), password);
      }
      restored.add(server.copyWith(password: password));
    }

    return restored;
  }

  Future<void> saveServers(List<ServerConfig> servers) async {
    for (final server in servers) {
      await _writeSecret(_passwordKey(server.id), server.password);
    }

    final rawValue = jsonEncode(
      servers.map((value) {
        final json = value.toJson();
        json.remove('password');
        return json;
      }).toList(),
    );
    await _writeString(_serversKey, rawValue);
  }

  Future<String?> loadSelectedServerId() async {
    final value = await _readString(_selectedServerKey);
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> saveSelectedServerId(String? id) async {
    if (id == null || id.isEmpty) {
      await _removeString(_selectedServerKey);
      return;
    }
    await _writeString(_selectedServerKey, id);
  }

  Future<String?> loadLoginServerUrl() async {
    final value = await _readString(_loginServerUrlKey);
    return value == null || value.trim().isEmpty ? null : value.trim();
  }

  Future<void> saveLoginServerUrl(String value) async {
    await _writeString(_loginServerUrlKey, value.trim());
  }

  Future<String> loadThemeMode() async {
    return await _readString(_themeModeKey) ?? 'system';
  }

  Future<void> saveThemeMode(String value) async {
    await _writeString(_themeModeKey, value);
  }

  Future<PlaybackSession?> loadPlaybackSession() async {
    final rawValue = await _readString(_playbackSessionKey);
    if (rawValue == null || rawValue.isEmpty) {
      return null;
    }

    try {
      final value = jsonDecode(rawValue);
      if (value is! Map) {
        return null;
      }
      return PlaybackSession.fromJson(Map<String, Object?>.from(value));
    } catch (_) {
      return null;
    }
  }

  Future<void> savePlaybackSession(PlaybackSession session) async {
    await _writeString(_playbackSessionKey, jsonEncode(session.toJson()));
  }

  Future<void> clearPlaybackSession() async {
    await _removeString(_playbackSessionKey);
  }

  Future<DailyRecommendationCache?> loadDailyRecommendation() async {
    final rawValue = await _readString(_dailyRecommendationKey);
    if (rawValue == null || rawValue.isEmpty) {
      return null;
    }

    try {
      final value = jsonDecode(rawValue);
      if (value is! Map) {
        return null;
      }
      return DailyRecommendationCache.fromJson(
        Map<String, Object?>.from(value),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDailyRecommendation(
    DailyRecommendationCache recommendation,
  ) async {
    await _writeString(
      _dailyRecommendationKey,
      jsonEncode(recommendation.toJson()),
    );
  }

  Future<void> clearDailyRecommendation() async {
    await _removeString(_dailyRecommendationKey);
  }

  Future<void> deleteServerPassword(String id) async {
    await _deleteSecret(_passwordKey(id));
  }

  Future<List<Track>> loadCustomTracks() async {
    final rawValue = await _readString(_customTracksKey);
    if (rawValue == null || rawValue.isEmpty) {
      return [];
    }

    final values = jsonDecode(rawValue);
    if (values is! List) {
      return [];
    }

    return values
        .whereType<Map>()
        .where((value) => value['sourceType'] != 'webdav')
        .where((value) => !value['id'].toString().startsWith('webdav:'))
        .map((value) => Track.fromJson(Map<String, Object?>.from(value)))
        .where((value) => value.streamUrl.isNotEmpty)
        .toList();
  }

  Future<void> saveCustomTracks(List<Track> tracks) async {
    final rawValue = jsonEncode(tracks.map((value) => value.toJson()).toList());
    await _writeString(_customTracksKey, rawValue);
  }

  Future<AppSettings> loadSettings() async {
    final rawValue = await _readString(_settingsKey);
    if (rawValue == null || rawValue.isEmpty) {
      return const AppSettings();
    }

    final value = jsonDecode(rawValue);
    if (value is! Map) {
      return const AppSettings();
    }
    return AppSettings.fromJson(Map<String, Object?>.from(value));
  }

  Future<void> saveSettings(AppSettings settings) async {
    await _writeString(_settingsKey, jsonEncode(settings.toJson()));
  }

  Future<String?> _readString(String key) async {
    final installedValues = await _readInstalledValues();
    if (installedValues != null) {
      final value = installedValues[key];
      return value is String ? value : null;
    }
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(key);
  }

  Future<void> _writeString(String key, String value) async {
    final installedValues = await _readInstalledValues();
    if (installedValues != null) {
      installedValues[key] = value;
      await _writeInstalledValues(installedValues);
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, value);
  }

  Future<void> _removeString(String key) async {
    final installedValues = await _readInstalledValues();
    if (installedValues != null) {
      installedValues.remove(key);
      await _writeInstalledValues(installedValues);
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(key);
  }

  Future<String?> _readSecret(String key) async {
    final installedValues = await _readInstalledValues();
    if (installedValues != null) {
      final value = installedValues[key];
      return value is String ? value : null;
    }
    return _secureStorage.read(key: key);
  }

  Future<void> _writeSecret(String key, String value) async {
    final installedValues = await _readInstalledValues();
    if (installedValues != null) {
      installedValues[key] = value;
      await _writeInstalledValues(installedValues);
      return;
    }
    await _secureStorage.write(key: key, value: value);
  }

  Future<void> _deleteSecret(String key) async {
    final installedValues = await _readInstalledValues();
    if (installedValues != null) {
      installedValues.remove(key);
      await _writeInstalledValues(installedValues);
      return;
    }
    await _secureStorage.delete(key: key);
  }

  Future<Map<String, Object?>?> _readInstalledValues() async {
    if (!shouldUseInstallDirectoryData()) {
      return null;
    }
    final file = installStoreFile();
    if (!await file.exists()) {
      return <String, Object?>{};
    }
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      return <String, Object?>{};
    }
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      return <String, Object?>{};
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<void> _writeInstalledValues(Map<String, Object?> values) async {
    final file = installStoreFile();
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(values), flush: true);
  }

  String _passwordKey(String id) => 'server_password_$id';
}

class PlaybackSession {
  const PlaybackSession({
    required this.queue,
    required this.currentIndex,
    required this.playbackMode,
  });

  final List<Track> queue;
  final int? currentIndex;
  final PlaybackMode playbackMode;

  Map<String, Object?> toJson() {
    return {
      'queue': queue.map((track) => track.toJson()).toList(),
      'currentIndex': currentIndex,
      'playbackMode': playbackMode.name,
    };
  }

  factory PlaybackSession.fromJson(Map<String, Object?> json) {
    final rawQueue = json['queue'];
    final queue = rawQueue is List
        ? rawQueue
              .whereType<Map>()
              .map((value) => Track.fromJson(Map<String, Object?>.from(value)))
              .toList()
        : <Track>[];
    final rawIndex = json['currentIndex'];
    final parsedIndex = rawIndex is int
        ? rawIndex
        : int.tryParse(rawIndex?.toString() ?? '');
    final currentIndex = queue.isEmpty
        ? null
        : parsedIndex != null && parsedIndex >= 0 && parsedIndex < queue.length
        ? parsedIndex
        : 0;
    final playbackModeName = json['playbackMode']?.toString();
    final playbackMode = PlaybackMode.values.firstWhere(
      (mode) => mode.name == playbackModeName,
      orElse: () => PlaybackMode.sequential,
    );

    return PlaybackSession(
      queue: queue,
      currentIndex: currentIndex,
      playbackMode: playbackMode,
    );
  }
}

class DailyRecommendationCache {
  const DailyRecommendationCache({required this.dateKey, required this.tracks});

  final String dateKey;
  final List<Track> tracks;

  Map<String, Object?> toJson() {
    return {
      'dateKey': dateKey,
      'tracks': tracks.map((track) => track.toJson()).toList(),
    };
  }

  factory DailyRecommendationCache.fromJson(Map<String, Object?> json) {
    final rawTracks = json['tracks'];
    final tracks = rawTracks is List
        ? rawTracks
              .whereType<Map>()
              .map((value) => Track.fromJson(Map<String, Object?>.from(value)))
              .toList()
        : <Track>[];
    return DailyRecommendationCache(
      dateKey: json['dateKey']?.toString() ?? '',
      tracks: tracks,
    );
  }
}
