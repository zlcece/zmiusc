import 'dart:convert';
import 'dart:async';
import 'dart:io'
    show
        ContentType,
        Directory,
        File,
        HttpClient,
        HttpHeaders,
        HttpOverrides,
        HttpServer,
        HttpStatus,
        InternetAddress,
        Platform;
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zmusic/src/app.dart';
import 'package:zmusic/src/app_controller.dart';
import 'package:zmusic/src/app_update.dart';
import 'package:zmusic/src/artwork_cache.dart';
import 'package:zmusic/src/audio_cache.dart';
import 'package:zmusic/src/compact_switch.dart';
import 'package:zmusic/src/desktop_integration.dart';
import 'package:zmusic/src/library_store.dart';
import 'package:zmusic/src/lyrics_timeline.dart';
import 'package:zmusic/src/local_library.dart';
import 'package:zmusic/src/settings_models.dart';
import 'package:zmusic/src/models.dart';
import 'package:zmusic/src/player_controller.dart';
import 'package:zmusic/src/playlist_sync.dart';
import 'package:zmusic/src/playlist_tools_page.dart';
import 'package:zmusic/src/protected_export_codec.dart';
import 'package:zmusic/src/source_config_codec.dart';
import 'package:zmusic/src/streaming_audio_cache_source.dart';
import 'package:zmusic/src/subsonic_api.dart';
import 'package:zmusic/src/system_media_controls.dart';

http.Response _subsonicJsonResponse(Map<String, Object?> payload) {
  return http.Response.bytes(
    utf8.encode(
      jsonEncode({
        'subsonic-response': {'status': 'ok', ...payload},
      }),
    ),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _MemoryLibraryStore extends LibraryStore {
  List<ServerConfig> savedServers = [];
  String? savedSelectedServerId;
  String? savedLoginServerUrl;
  AppSettings? savedSettings;
  PlaybackSession? savedPlaybackSession;
  DailyRecommendationCache? savedDailyRecommendation;

  @override
  Future<void> saveServers(List<ServerConfig> servers) async {
    savedServers = List<ServerConfig>.from(servers);
  }

  @override
  Future<void> saveSelectedServerId(String? id) async {
    savedSelectedServerId = id;
  }

  @override
  Future<void> saveLoginServerUrl(String value) async {
    savedLoginServerUrl = value;
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    savedSettings = settings;
  }

  @override
  Future<PlaybackSession?> loadPlaybackSession() async => savedPlaybackSession;

  @override
  Future<void> savePlaybackSession(PlaybackSession session) async {
    savedPlaybackSession = session;
  }

  @override
  Future<void> clearPlaybackSession() async {
    savedPlaybackSession = null;
  }

  @override
  Future<DailyRecommendationCache?> loadDailyRecommendation() async {
    return savedDailyRecommendation;
  }

  @override
  Future<void> saveDailyRecommendation(
    DailyRecommendationCache recommendation,
  ) async {
    savedDailyRecommendation = recommendation;
  }

  @override
  Future<void> clearDailyRecommendation() async {
    savedDailyRecommendation = null;
  }

  @override
  Future<void> deleteServerPassword(String id) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PackageInfo.setMockInitialValues(
    appName: 'Zmusic',
    packageName: 'com.zmusic.app',
    version: '1.0.14',
    buildNumber: '19',
    buildSignature: '',
  );

  test('normalizes server URL', () {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com/',
      username: 'demo',
      password: 'secret',
    );

    expect(server.normalizedBaseUrl, 'https://music.example.com');
  });

  test('login keeps one verified account and logout clears it', () async {
    final store = _MemoryLibraryStore();
    final player = _RecordingPlayerController();
    final controller = AppController(store: store, player: player);
    controller.apiClientFactory = (server) => SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        final method = request.url.pathSegments.last.replaceAll('.view', '');
        final payload = switch (method) {
          'getArtists' => {
            'artists': {'index': []},
          },
          'getAlbumList2' => {
            'albumList2': {'album': []},
          },
          'getPlaylists' => {
            'playlists': {'playlist': []},
          },
          'getStarred2' => {'starred2': <String, Object?>{}},
          'getInternetRadioStations' => {
            'internetRadioStations': <String, Object?>{},
          },
          _ => <String, Object?>{},
        };
        return _subsonicJsonResponse(payload);
      }),
    );

    await controller.login(
      username: 'demo',
      password: 'secret',
      baseUrl: 'https://fnnav.zuitimes.com/',
    );
    await _waitFor(() => !controller.isRefreshingLibrary);

    expect(controller.isAuthenticated, isTrue);
    expect(controller.servers, hasLength(1));
    expect(controller.selectedUsername, 'demo');
    expect(controller.loginServerUrl, defaultMusicServerUrl);
    expect(store.savedLoginServerUrl, defaultMusicServerUrl);
    expect(store.savedServers.single.id, '$defaultMusicServerUrl|demo');

    await controller.logout();

    expect(player.stopped, isTrue);
    expect(controller.isAuthenticated, isFalse);
    expect(controller.servers, isEmpty);
    expect(store.savedServers, isEmpty);
    expect(store.savedSelectedServerId, isNull);
  });

  test('uses normalized URL and username as server id when deserializing', () {
    final server = ServerConfig.fromJson({
      'id': 'legacy-id',
      'name': 'Navidrome',
      'baseUrl': 'https://music.example.com/',
      'username': 'demo',
      'password': 'secret',
    });

    expect(server.id, 'https://music.example.com|demo');
  });

  test('serializes local folder source config', () {
    const source = ServerConfig(
      id: 'local:D:\\Music',
      name: '本地音乐',
      baseUrl: '',
      username: '',
      password: '',
      sourceKind: MusicSourceKind.localFolder,
      localPath: 'D:\\Music',
    );

    final restored = ServerConfig.fromJson(source.toJson());

    expect(restored.id, 'local:D:\\Music');
    expect(restored.name, '本地音乐');
    expect(restored.sourceKind, MusicSourceKind.localFolder);
    expect(restored.localPath, 'D:\\Music');
    expect(restored.normalizedBaseUrl, '');
  });

  test('adds a same URL source with another account separately', () async {
    final existing = ServerConfig(
      id: remoteSourceId('https://music.example.com', 'alice'),
      name: 'one',
      baseUrl: 'https://music.example.com',
      username: 'alice',
      password: '',
    );
    const added = ServerConfig(
      id: 'https://music.example.com',
      name: 'two',
      baseUrl: 'https://music.example.com/',
      username: 'bob',
      password: '',
    );
    final store = _MemoryLibraryStore();
    final controller = AppController(store: store, player: PlayerController())
      ..servers = [existing]
      ..selectedServerId = existing.id;

    await controller.saveServer(added);

    expect(controller.servers.map((server) => server.id), [
      'https://music.example.com|alice',
      'https://music.example.com|bob',
    ]);
    expect(controller.selectedServerId, existing.id);
    expect(store.savedSelectedServerId, existing.id);
  });

  test('decodes protected export text with ZHANGLONG prefix', () {
    expect(
      decodeProtectedExportText('V2toQlRrZE1UMDVIWVdKalpHVm1adz09'),
      'abcdefg',
    );
    expect(
      encodeProtectedExportText('abcdefg'),
      'V2toQlRrZE1UMDVIWVdKalpHVm1adz09',
    );
  });

  test('exports and imports source config as protected base64 json', () {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );

    final encoded = encodeSourceConfig(
      servers: [server],
      selectedServerId: server.id,
    );
    final rawJson = jsonDecode(decodeProtectedExportText(encoded)) as Map;
    final restored = decodeSourceConfig(encoded);

    expect(rawJson['version'], 1);
    expect(restored.selectedServerUrl, 'https://music.example.com');
    expect(restored.servers.single.id, 'https://music.example.com|demo');
    expect(restored.servers.single.password, 'secret');
  });

  test('rejects legacy source config base64 json', () {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final legacy = base64Encode(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'selectedServerUrl': server.id,
          'servers': [server.toJson()],
        }),
      ),
    );

    expect(() => decodeSourceConfig(legacy), throwsFormatException);
  });

  test('serializes subsonic track', () {
    const track = Track(
      id: 'song-1',
      title: 'Song',
      artist: 'Station',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-1',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      duration: Duration(seconds: 185),
      lyrics: 'line one\nline two',
      sourceServerId: 'https://music.example.com',
      sourceItemId: 'song-1',
      audioFormat: 'MP3',
    );

    final restored = Track.fromJson(track.toJson());

    expect(restored.title, 'Song');
    expect(restored.sourceType, MusicSourceType.subsonic);
    expect(restored.duration, const Duration(seconds: 185));
    expect(restored.lyrics, 'line one\nline two');
    expect(restored.sourceServerId, 'https://music.example.com');
    expect(restored.sourceItemId, 'song-1');
    expect(restored.audioFormat, 'MP3');
  });

  test('uses playback stream URLs without json response format', () {
    const server = ServerConfig(
      id: 'http://192.168.1.176:4533',
      name: '176',
      baseUrl: 'http://192.168.1.176:4533',
      username: 'admin',
      password: 'secret',
    );
    final uri = SubsonicApiClient(server: server).streamUri('song-1');
    final apeUri = SubsonicApiClient(
      server: server,
    ).streamUri('song-ape', audioFormat: 'APE');
    final flacUri = SubsonicApiClient(
      server: server,
    ).streamUri('song-flac', audioFormat: 'FLAC');

    expect(uri.queryParameters['id'], 'song-1');
    expect(uri.queryParameters.containsKey('f'), isFalse);
    expect(uri.queryParameters.containsKey('format'), isFalse);
    expect(uri.queryParameters.containsKey('maxBitRate'), isFalse);
    expect(flacUri.queryParameters.containsKey('f'), isFalse);
    expect(flacUri.queryParameters.containsKey('format'), isFalse);
    expect(flacUri.queryParameters.containsKey('maxBitRate'), isFalse);
    expect(apeUri.queryParameters.containsKey('f'), isFalse);
    expect(apeUri.queryParameters.containsKey('format'), isFalse);
    expect(apeUri.queryParameters.containsKey('maxBitRate'), isFalse);
    expect(shouldRequestSubsonicMp3Transcode('APE'), isFalse);
    expect(shouldRequestSubsonicMp3Transcode('FLAC'), isFalse);
  });

  test('normalizes audio format labels', () {
    expect(readAudioFormat('ape'), 'APE');
    expect(readAudioFormat('.mp3'), 'MP3');
    expect(readAudioFormat('audio/mpeg'), 'MP3');
    expect(readAudioFormat('audio/x-flac; charset=utf-8'), 'FLAC');
    expect(readAudioFormat('application/octet-stream'), isNull);
  });

  test('parses update manifest and tolerates a trailing comma', () async {
    expect(
      appUpdateManifestUri,
      Uri.parse('https://file.zuitimes.com/zmusic/0/update.json'),
    );
    final requests = <Uri>[];
    final service = AppUpdateService(
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response.bytes(
          utf8.encode('''
            {
              "appName": "zmusic",
              "platforms": {
                "windows": {
                  "latestVersion": "1.0.10",
                  "versionCode": 110,
                  "downloadUrl": "https://file.zuitimes.com/zmusic/1.0.10/zmusic-windows-x64.exe",
                  "fileName": "zmusic-windows-x64.exe",
                  "updateContent": ["修复播放", "优化启动"],
                  "releaseTime": "2026-07-14"
                },
              }
            }
          '''),
          200,
        );
      }),
    );

    final update = await service.fetchForPlatform('windows');

    expect(requests, [appUpdateManifestUri]);
    expect(update.latestVersion, '1.0.10');
    expect(update.versionCode, 110);
    expect(update.fileName, 'zmusic-windows-x64.exe');
    expect(update.updateContent, ['修复播放', '优化启动']);
    expect(update.releaseTime, '2026-07-14');
  });

  test('downloads update files with progress callbacks', () async {
    final downloadUri = Uri.parse(
      'https://file.zuitimes.com/zmusic/1.0.11/zmusic-windows-x64.exe',
    );
    final tempDir = Directory.systemTemp.createTempSync('zmusic-update-test-');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    final service = AppUpdateService(
      httpClient: MockClient((request) async {
        expect(request.url, downloadUri);
        return http.Response.bytes([1, 2, 3, 4], 200);
      }),
    );
    final progress = <AppUpdateDownloadProgress>[];

    final file = await service.downloadUpdate(
      AppUpdateInfo(
        latestVersion: '1.0.11',
        versionCode: 16,
        downloadUri: downloadUri,
        fileName: r'..\zmusic-windows-x64.exe',
        updateContent: const [],
        releaseTime: '',
      ),
      destinationDirectory: tempDir,
      onProgress: progress.add,
    );

    expect(file.path, endsWith('.._zmusic-windows-x64.exe'));
    expect(file.readAsBytesSync(), [1, 2, 3, 4]);
    expect(progress.first.receivedBytes, 0);
    expect(progress.last.receivedBytes, 4);
    expect(progress.last.totalBytes, 4);
    expect(progress.last.fraction, 1);
  });

  test('compares semantic update versions without using build codes', () {
    expect(isNewerAppVersion('1.0.10', '1.0.9'), isTrue);
    expect(isNewerAppVersion('1.1.0', '1.0.999'), isTrue);
    expect(isNewerAppVersion('1.0.9', '1.0.9'), isFalse);
    expect(isNewerAppVersion('1.0.8', '1.0.9'), isFalse);
  });

  test('loads categorized subsonic search results', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final requests = <Uri>[];
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'searchResult3': {
                'song': [
                  {
                    'id': 'song-1',
                    'title': 'Song',
                    'artist': 'Artist',
                    'album': 'Album',
                    'duration': 180,
                    'coverArt': 'song-cover',
                    'suffix': 'ape',
                  },
                ],
                'artist': [
                  {
                    'id': 'artist-1',
                    'name': 'Artist',
                    'artistImageUrl': 'https://images.example.com/artist.jpg',
                  },
                ],
                'album': [
                  {
                    'id': 'album-1',
                    'name': 'Album',
                    'artist': 'Artist',
                    'coverArt': 'album-cover',
                  },
                ],
              },
            },
          }),
          200,
        );
      }),
    );

    final results = await client.search('demo');
    await client.search('demo', scope: LibrarySearchScope.artists);
    await client.search(
      'demo',
      scope: LibrarySearchScope.songs,
      songOffset: 60,
    );

    expect(requests[0].queryParameters['songCount'], '60');
    expect(requests[0].queryParameters['songOffset'], '0');
    expect(requests[0].queryParameters['artistCount'], '30');
    expect(requests[0].queryParameters['albumCount'], '30');
    expect(requests[1].queryParameters['songCount'], '0');
    expect(requests[1].queryParameters['artistCount'], '30');
    expect(requests[1].queryParameters['albumCount'], '0');
    expect(requests[2].queryParameters['songOffset'], '60');
    expect(results.songs.single.title, 'Song');
    expect(results.songs.single.audioFormat, 'APE');
    expect(
      results.artists.single.coverUrl,
      'https://images.example.com/artist.jpg',
    );
    expect(results.albums.single.subtitle, 'Artist');
  });

  test(
    'remote suggestions request five results without replacing full search',
    () async {
      const server = ServerConfig(
        id: 'https://music.example.com',
        name: 'Navidrome',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      const existingResults = LibrarySearchResults(
        albums: [
          LibrarySectionItem(
            id: 'existing-album',
            title: 'Existing Album',
            type: LibrarySectionType.albums,
          ),
        ],
      );
      Uri? requestUri;
      final controller =
          AppController(store: LibraryStore(), player: PlayerController())
            ..servers = const [server]
            ..selectedServerId = server.id
            ..searchResults = existingResults
            ..apiClientFactory = (source) => SubsonicApiClient(
              server: source,
              httpClient: MockClient((request) async {
                requestUri = request.url;
                return _subsonicJsonResponse({
                  'searchResult3': <String, Object?>{},
                });
              }),
            );

      final suggestions = await controller.searchRemoteSuggestions('abc');

      expect(suggestions.isEmpty, isTrue);
      expect(requestUri?.queryParameters['query'], 'abc');
      expect(requestUri?.queryParameters['songCount'], '2');
      expect(requestUri?.queryParameters['artistCount'], '2');
      expect(requestUri?.queryParameters['albumCount'], '1');
      expect(controller.searchResults, same(existingResults));
      expect(controller.isBusy, isFalse);
    },
  );

  test(
    'paginates full remote song search while keeping artists and albums',
    () async {
      const server = ServerConfig(
        id: 'https://music.example.com',
        name: 'Navidrome',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      final requests = <Uri>[];
      final player = PlayerController();
      addTearDown(player.dispose);
      final controller = AppController(store: LibraryStore(), player: player)
        ..servers = const [server]
        ..selectedServerId = server.id
        ..apiClientFactory = (source) => SubsonicApiClient(
          server: source,
          httpClient: MockClient((request) async {
            requests.add(request.url);
            final offset = int.parse(
              request.url.queryParameters['songOffset']!,
            );
            final count = offset == 0 ? searchSongPageSize + 1 : 3;
            return _subsonicJsonResponse({
              'searchResult3': {
                'song': [
                  for (var index = 0; index < count; index++)
                    {
                      'id': 'song-${offset + index}',
                      'title': 'Song ${offset + index}',
                    },
                ],
                'artist': [
                  {'id': 'artist-1', 'name': 'Artist'},
                ],
                'album': [
                  {'id': 'album-1', 'name': 'Album'},
                ],
              },
            });
          }),
        );

      await controller.searchSelectedServer('demo');

      expect(controller.searchResults.songs, hasLength(searchSongPageSize));
      expect(controller.searchResults.artists, hasLength(1));
      expect(controller.searchResults.albums, hasLength(1));
      expect(controller.searchSongPageIndex, 0);
      expect(controller.hasNextSearchSongPage, isTrue);
      expect(requests.single.queryParameters['songCount'], '61');
      expect(requests.single.queryParameters['songOffset'], '0');

      await controller.searchSelectedServerPage('demo', pageIndex: 1);

      expect(controller.searchResults.songs, hasLength(3));
      expect(controller.searchResults.songs.first.title, 'Song 60');
      expect(controller.searchResults.artists, hasLength(1));
      expect(controller.searchResults.albums, hasLength(1));
      expect(controller.searchSongPageIndex, 1);
      expect(controller.hasNextSearchSongPage, isFalse);
      expect(requests.last.queryParameters['songOffset'], '60');
    },
  );

  test(
    'fetches and matches an external playlist by title and artist',
    () async {
      final syncService = PlaylistSyncService(
        httpClient: MockClient((request) async {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'playlist': {
                  'name': '测试歌单',
                  'trackIds': [
                    {'id': 101},
                  ],
                  'tracks': [
                    {
                      'id': 101,
                      'name': '光年之外',
                      'ar': [
                        {'name': 'G.E.M.邓紫棋'},
                      ],
                      'al': {'name': '新的心跳'},
                    },
                  ],
                },
              }),
            ),
            200,
          );
        }),
      );
      final playlist = await syncService.fetchPlaylist(
        'https://music.163.com/playlist?id=123',
      );
      const server = ServerConfig(
        id: 'https://music.example.com|demo',
        name: 'Zmusic',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      final client = SubsonicApiClient(
        server: server,
        httpClient: MockClient((request) async {
          return _subsonicJsonResponse({
            'searchResult3': {
              'song': [
                {
                  'id': 'wrong-artist',
                  'title': '光年之外',
                  'artist': '其他歌手',
                  'album': '翻唱',
                  'suffix': 'mp3',
                },
                {
                  'id': 'correct-artist',
                  'title': '光年之外',
                  'artist': 'G.E.M.邓紫棋',
                  'album': '新的心跳',
                  'suffix': 'flac',
                },
              ],
            },
          });
        }),
      );
      final progress = <PlaylistSyncProgress>[];

      final result = await syncService.matchPlaylist(
        playlist,
        client,
        onProgress: progress.add,
      );

      expect(playlist.name, '测试歌单');
      expect(playlist.platformName, '网易云音乐');
      expect(result.matchedTracks.single.sourceItemId, 'correct-artist');
      expect(result.missingTracks, isEmpty);
      expect(progress.last.completed, 1);
      expect(progress.last.fraction, 1);
    },
  );

  test('playlist sync can prefer quality or playback compatibility', () async {
    const playlist = ExternalPlaylist(
      name: '品质测试',
      platformName: '测试平台',
      tracks: [ExternalPlaylistTrack(title: '同一首歌', artists: '测试歌手')],
    );
    const server = ServerConfig(
      id: 'https://music.example.com|demo',
      name: 'Zmusic',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        return _subsonicJsonResponse({
          'searchResult3': {
            'song': [
              {
                'id': 'flac',
                'title': '同一首歌',
                'artist': '测试歌手',
                'suffix': 'flac',
              },
              {'id': 'mp3', 'title': '同一首歌', 'artist': '测试歌手', 'suffix': 'mp3'},
              {'id': 'ape', 'title': '同一首歌', 'artist': '测试歌手', 'suffix': 'ape'},
            ],
          },
        });
      }),
    );
    final service = PlaylistSyncService();

    final compatible = await service.matchPlaylist(
      playlist,
      client,
      preferHighQuality: false,
    );
    final highQuality = await service.matchPlaylist(
      playlist,
      client,
      preferHighQuality: true,
    );

    expect(compatible.matchedTracks.single.sourceItemId, 'mp3');
    expect(highQuality.matchedTracks.single.sourceItemId, 'ape');
  });

  test(
    'playlist sync can optionally match a same title by another artist',
    () async {
      const playlist = ExternalPlaylist(
        name: '同名测试',
        platformName: '测试平台',
        tracks: [ExternalPlaylistTrack(title: '同名歌曲', artists: '原唱')],
      );
      const server = ServerConfig(
        id: 'https://music.example.com|demo',
        name: 'Zmusic',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      final client = SubsonicApiClient(
        server: server,
        httpClient: MockClient((request) async {
          return _subsonicJsonResponse({
            'searchResult3': {
              'song': [
                {
                  'id': 'cover',
                  'title': '同名歌曲',
                  'artist': '翻唱歌手',
                  'suffix': 'flac',
                },
              ],
            },
          });
        }),
      );
      final service = PlaylistSyncService();

      final strict = await service.matchPlaylist(playlist, client);
      final relaxed = await service.matchPlaylist(
        playlist,
        client,
        allowDifferentArtistSameTitle: true,
      );

      expect(strict.matchedTracks, isEmpty);
      expect(strict.missingTracks, hasLength(1));
      expect(relaxed.matchedTracks.single.sourceItemId, 'cover');
    },
  );

  test('builds local library overview from local tracks', () {
    const tracks = [
      Track(
        id: 'local:D:\\Music\\a.mp3',
        title: '第一首',
        artist: '歌手甲',
        album: '专辑一',
        streamUrl: 'file:///D:/Music/a.mp3',
        sourceType: MusicSourceType.localFile,
        sourceName: '本地音乐',
      ),
      Track(
        id: 'local:D:\\Music\\b.flac',
        title: '第二首',
        artist: '歌手甲',
        album: '专辑一',
        streamUrl: 'file:///D:/Music/b.flac',
        sourceType: MusicSourceType.localFile,
        sourceName: '本地音乐',
      ),
      Track(
        id: 'local:D:\\Music\\c.wav',
        title: '第三首',
        artist: '歌手乙',
        album: '',
        streamUrl: 'file:///D:/Music/c.wav',
        sourceType: MusicSourceType.localFile,
        sourceName: '本地音乐',
      ),
    ];

    final overview = buildLocalLibraryOverview(tracks);

    expect(overview.songCount, 3);
    expect(overview.artists.map((value) => value.title), ['歌手甲', '歌手乙']);
    expect(overview.artists.first.subtitle, '2 首');
    expect(overview.albums.single.title, '专辑一');
    expect(overview.albums.single.subtitle, '歌手甲 · 2 首');
  });

  test('searches local tracks by scope', () {
    const tracks = [
      Track(
        id: 'local:D:\\Music\\a.mp3',
        title: '自由飞翔',
        artist: '凤凰传奇',
        album: '吉祥如意',
        streamUrl: 'file:///D:/Music/a.mp3',
        sourceType: MusicSourceType.localFile,
        sourceName: '本地音乐',
      ),
      Track(
        id: 'local:D:\\Music\\b.flac',
        title: '海阔天空',
        artist: 'Beyond',
        album: '乐与怒',
        streamUrl: 'file:///D:/Music/b.flac',
        sourceType: MusicSourceType.localFile,
        sourceName: '本地音乐',
      ),
    ];

    final all = searchLocalLibrary(tracks, '凤凰', scope: LibrarySearchScope.all);
    final artists = searchLocalLibrary(
      tracks,
      'beyond',
      scope: LibrarySearchScope.artists,
    );
    final albums = searchLocalLibrary(
      tracks,
      '吉祥',
      scope: LibrarySearchScope.albums,
    );

    expect(all.songs.single.title, '自由飞翔');
    expect(all.artists.single.title, '凤凰传奇');
    expect(all.albums.single.title, '吉祥如意');
    expect(artists.songs, isEmpty);
    expect(artists.artists.single.title, 'Beyond');
    expect(albums.albums.single.title, '吉祥如意');
  });

  test('ignores unrealistic reported playback duration', () {
    const trackDuration = Duration(minutes: 4, seconds: 8);

    expect(
      displayPlaybackDuration(
        reportedDuration: const Duration(hours: 256204778, minutes: 48),
        trackDuration: trackDuration,
      ),
      trackDuration,
    );
    expect(
      displayPlaybackDuration(
        reportedDuration: const Duration(minutes: 4, seconds: 9),
        trackDuration: trackDuration,
      ),
      const Duration(minutes: 4, seconds: 9),
    );
    expect(
      displayPlaybackDuration(
        reportedDuration: const Duration(hours: 256204778, minutes: 48),
        trackDuration: null,
      ),
      isNull,
    );
  });

  test('uses playback mode rules when completed queue advances', () {
    expect(
      shouldAutoAdvanceOnPlaybackCompleted(
        playbackMode: PlaybackMode.sequential,
        currentIndex: 0,
        queueLength: 1,
      ),
      isFalse,
    );
    expect(
      shouldAutoAdvanceOnPlaybackCompleted(
        playbackMode: PlaybackMode.sequential,
        currentIndex: 0,
        queueLength: 2,
      ),
      isTrue,
    );
    expect(
      shouldAutoAdvanceOnPlaybackCompleted(
        playbackMode: PlaybackMode.sequential,
        currentIndex: 1,
        queueLength: 2,
      ),
      isFalse,
    );
    expect(
      sequentialNextIndexOnPlaybackCompleted(currentIndex: 0, queueLength: 2),
      1,
    );
    expect(
      sequentialNextIndexOnPlaybackCompleted(currentIndex: 1, queueLength: 2),
      1,
    );
    expect(
      shouldReplayCurrentOnPlaybackCompleted(
        playbackMode: PlaybackMode.repeatOne,
        currentIndex: 0,
        queueLength: 1,
      ),
      isTrue,
    );
    expect(
      shouldReplayCurrentOnPlaybackCompleted(
        playbackMode: PlaybackMode.repeatAll,
        currentIndex: 0,
        queueLength: 1,
      ),
      isTrue,
    );
    expect(
      repeatAllNextIndexOnPlaybackCompleted(currentIndex: 1, queueLength: 2),
      0,
    );
    expect(
      shouldAutoAdvanceOnPlaybackCompleted(
        playbackMode: PlaybackMode.shuffle,
        currentIndex: 0,
        queueLength: 1,
      ),
      isFalse,
    );
    expect(
      shouldAutoAdvanceOnPlaybackCompleted(
        playbackMode: PlaybackMode.shuffle,
        currentIndex: 0,
        queueLength: 2,
      ),
      isTrue,
    );
    expect(
      shouldAutoAdvanceOnPlaybackCompleted(
        playbackMode: PlaybackMode.sequential,
        currentIndex: null,
        queueLength: 2,
      ),
      isFalse,
    );
  });

  test(
    'plays a transient next track without adding it to the visible queue',
    () async {
      final engine = _CompletionPlaybackEngine();
      final player = PlayerController(
        playbackEngine: engine,
        startupRecoveryTimeout: Duration.zero,
      );
      addTearDown(player.dispose);
      const tracks = [
        Track(
          id: 'a',
          title: 'A',
          artist: 'Artist',
          album: 'Album',
          streamUrl: 'https://music.example.com/a.mp3',
          sourceType: MusicSourceType.subsonic,
          sourceName: 'Navidrome',
        ),
        Track(
          id: 'b',
          title: 'B',
          artist: 'Artist',
          album: 'Album',
          streamUrl: 'https://music.example.com/b.mp3',
          sourceType: MusicSourceType.subsonic,
          sourceName: 'Navidrome',
        ),
        Track(
          id: 'c',
          title: 'C',
          artist: 'Artist',
          album: 'Album',
          streamUrl: 'https://music.example.com/c.mp3',
          sourceType: MusicSourceType.subsonic,
          sourceName: 'Navidrome',
        ),
      ];
      const transient = Track(
        id: 'next',
        title: 'Next',
        artist: 'Artist',
        album: 'Album',
        streamUrl: 'https://music.example.com/next.mp3',
        sourceType: MusicSourceType.subsonic,
        sourceName: 'Navidrome',
      );

      await player.playTracks(tracks, 0);
      await player.playTrackNext(transient);

      expect(player.currentTrack?.title, 'A');
      expect(player.pendingNextTrack?.title, 'Next');
      expect(player.queue.map((track) => track.title), ['A', 'B', 'C']);

      engine.completeCurrent();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(player.currentTrack?.title, 'Next');
      expect(player.pendingNextTrack, isNull);
      expect(player.queue.map((track) => track.title), ['A', 'B', 'C']);

      engine.completeCurrent();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(player.currentTrack?.title, 'B');
      expect(player.queue.map((track) => track.title), ['A', 'B', 'C']);
      expect(engine.openedUrls, [
        'https://music.example.com/a.mp3',
        'https://music.example.com/next.mp3',
        'https://music.example.com/b.mp3',
      ]);
    },
  );

  test('uses streaming cache progress when calculating buffered position', () {
    final buffered = cacheProgressBufferedPosition(
      duration: const Duration(minutes: 4),
      cacheProgress: 0.25,
      fallback: const Duration(minutes: 4),
    );

    expect(buffered, const Duration(minutes: 1));
  });

  test('keeps playback ticks off the global player notifier', () async {
    final engine = _PlaybackTickEngine();
    final player = PlayerController(
      playbackEngine: engine,
      startupRecoveryTimeout: Duration.zero,
    );
    addTearDown(player.dispose);
    var notifications = 0;
    player.addListener(() => notifications += 1);

    engine.emitPosition(const Duration(milliseconds: 250));
    engine.emitBufferedPosition(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);

    expect(notifications, 0);

    engine.emitBuffering(true);
    await Future<void>.delayed(Duration.zero);

    expect(notifications, 1);
  });

  test('publishes system media state and routes media commands', () async {
    const channel = MethodChannel('com.zmusic.app/media_session_test');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    final player = _SystemMediaPlayerController();
    final controls = SystemMediaControls(
      player,
      channel: channel,
      supported: true,
    );
    addTearDown(() async {
      controls.dispose();
      await Future<void>.delayed(Duration.zero);
      player.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await controls.initialize();

    expect(calls.map((call) => call.method), ['initialize', 'updateState']);
    final initialState = calls.last.arguments as Map<Object?, Object?>;
    expect(initialState['hasTrack'], isTrue);
    expect(initialState['isPlaying'], isTrue);
    expect(initialState['canSkipPrevious'], isTrue);
    expect(initialState['canSkipNext'], isTrue);
    expect(initialState['title'], 'System Song');
    expect(initialState['artist'], 'System Artist');
    expect(initialState['album'], 'System Album');

    await controls.handleMediaCommand('play');
    await controls.handleMediaCommand('pause');
    await controls.handleMediaCommand('playPause');
    await controls.handleMediaCommand('next');
    await controls.handleMediaCommand('previous');

    expect(player.playCalls, 1);
    expect(player.pauseCalls, 1);
    expect(player.toggleCalls, 1);
    expect(player.nextCalls, 1);
    expect(player.previousCalls, 1);

    player.setPlaying(false);
    await Future<void>.delayed(Duration.zero);
    final updatedState = calls.last.arguments as Map<Object?, Object?>;
    expect(calls.last.method, 'updateState');
    expect(updatedState['isPlaying'], isFalse);
  });

  test('resumes playback after seek only when playback was active', () {
    const track = Track(
      id: 'song',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
    );

    expect(
      shouldResumePlaybackAfterSeek(wasPlaying: true, currentTrack: track),
      isTrue,
    );
    expect(
      shouldResumePlaybackAfterSeek(wasPlaying: false, currentTrack: track),
      isFalse,
    );
    expect(
      shouldResumePlaybackAfterSeek(wasPlaying: true, currentTrack: null),
      isFalse,
    );
  });

  test('rejects stale playback requests', () {
    expect(
      shouldApplyPlaybackRequest(
        requestId: 1,
        latestRequestId: 2,
        requestedIndex: 0,
        currentIndex: 0,
      ),
      isFalse,
    );
    expect(
      shouldApplyPlaybackRequest(
        requestId: 2,
        latestRequestId: 2,
        requestedIndex: 0,
        currentIndex: 1,
      ),
      isFalse,
    );
    expect(
      shouldApplyPlaybackRequest(
        requestId: 2,
        latestRequestId: 2,
        requestedIndex: 0,
        currentIndex: 0,
      ),
      isTrue,
    );
  });

  test('retries a stalled playback startup once', () async {
    final engine = _StalledStartupPlaybackEngine();
    final player = PlayerController(
      playbackEngine: engine,
      startupRecoveryTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(player.dispose);
    const track = Track(
      id: 'stalled-song',
      title: 'Stalled Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/stream/stalled-song.mp3',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
    );

    await player.playTrack(track);
    await _waitFor(() => engine.openCount == 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(engine.openCount, 2);
    expect(player.currentTrack?.id, track.id);
    expect(player.queue, [track]);
    expect(player.playSessionId, 1);
  });

  test('does not retry a stalled startup after the user pauses', () async {
    final engine = _StalledStartupPlaybackEngine();
    final player = PlayerController(
      playbackEngine: engine,
      startupRecoveryTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(player.dispose);
    const track = Track(
      id: 'paused-stalled-song',
      title: 'Paused Stalled Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/stream/paused-stalled-song.mp3',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
    );

    await player.playTrack(track);
    await player.togglePlay();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(engine.openCount, 1);
    expect(player.isPlaying, isFalse);
    expect(player.playSessionId, 1);
  });

  test('paginates library section items with bounded page indexes', () {
    final items = List.generate(
      13,
      (index) => LibrarySectionItem(
        id: 'artist-$index',
        title: 'Artist $index',
        subtitle: '歌手',
        type: LibrarySectionType.artists,
      ),
    );

    expect(libraryPageCount(items.length, 5), 3);
    expect(libraryPageItems(items, 0, 5).map((item) => item.id), [
      'artist-0',
      'artist-1',
      'artist-2',
      'artist-3',
      'artist-4',
    ]);
    expect(libraryPageItems(items, 2, 5).map((item) => item.id), [
      'artist-10',
      'artist-11',
      'artist-12',
    ]);
    expect(libraryPageItems(items, 99, 5).map((item) => item.id), [
      'artist-10',
      'artist-11',
      'artist-12',
    ]);
    expect(libraryPageItems(items, -1, 5).map((item) => item.id), [
      'artist-0',
      'artist-1',
      'artist-2',
      'artist-3',
      'artist-4',
    ]);
    expect(libraryPageCount(0, 5), 0);
    expect(libraryPageItems(items, 0, 0), isEmpty);
  });

  test('paginates library browse pages with the shared page size', () {
    final items = List.generate(
      37,
      (index) => LibrarySectionItem(
        id: 'album-$index',
        title: 'Album $index',
        subtitle: 'Artist',
        type: LibrarySectionType.albums,
      ),
    );

    expect(libraryBrowsePageCount(items.length), 3);
    expect(
      libraryBrowsePageItems(items, 0).map((item) => item.id).first,
      'album-0',
    );
    expect(
      libraryBrowsePageItems(items, 1).map((item) => item.id).first,
      'album-18',
    );
    expect(libraryBrowsePageItems(items, 2).map((item) => item.id), [
      'album-36',
    ]);
  });

  test('library overview tracks total song count', () {
    const overview = LibraryOverview(songCount: 42);

    expect(overview.songCount, 42);
    expect(overview.isEmpty, isFalse);
  });

  test('splits personal and public playlists', () {
    const overview = LibraryOverview(
      playlists: [
        LibrarySectionItem(
          id: 'private-playlist',
          title: 'Private',
          type: LibrarySectionType.playlists,
          isPublic: false,
        ),
        LibrarySectionItem(
          id: 'public-playlist',
          title: 'Public',
          type: LibrarySectionType.playlists,
          isPublic: true,
        ),
      ],
    );

    expect(overview.myPlaylists.map((playlist) => playlist.id), [
      'private-playlist',
    ]);
    expect(overview.publicPlaylists.map((playlist) => playlist.id), [
      'public-playlist',
    ]);
  });

  test('orders owned playlists before public read-only playlists', () {
    const privatePlaylist = LibrarySectionItem(
      id: 'private-playlist',
      title: 'Private',
      type: LibrarySectionType.playlists,
      isPublic: false,
      owner: 'demo',
    );
    const ownPublicPlaylist = LibrarySectionItem(
      id: 'own-public-playlist',
      title: 'Own Public',
      type: LibrarySectionType.playlists,
      isPublic: true,
      owner: 'demo',
    );
    const sharedPlaylist = LibrarySectionItem(
      id: 'shared-playlist',
      title: 'Shared',
      type: LibrarySectionType.playlists,
      isPublic: true,
      owner: 'other',
    );

    expect(
      orderPlaylistsForUser([
        sharedPlaylist,
        ownPublicPlaylist,
        privatePlaylist,
      ], 'demo').map((playlist) => playlist.id),
      ['own-public-playlist', 'private-playlist', 'shared-playlist'],
    );
    expect(isUserOwnedPlaylist(ownPublicPlaylist, 'demo'), isTrue);
    expect(isUserOwnedPlaylist(sharedPlaylist, 'demo'), isFalse);
  });

  test('loads artist artwork from subsonic artist fields', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        final method = request.url.pathSegments.last.replaceAll('.view', '');
        final payload = switch (method) {
          'getArtists' => {
            'artists': {
              'index': [
                {
                  'artist': [
                    {
                      'id': 'artist-image-url',
                      'name': 'Image Url Artist',
                      'artistImageUrl': 'https://images.example.com/a.jpg',
                      'coverArt': 'ignored-cover',
                    },
                    {
                      'id': 'artist-cover-art',
                      'name': 'Cover Art Artist',
                      'coverArt': 'cover-artist',
                    },
                  ],
                },
              ],
            },
          },
          'getAlbumList2' => {
            'albumList2': {'album': []},
          },
          'getPlaylists' => {
            'playlists': {'playlist': []},
          },
          _ => <String, Object?>{},
        };
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'subsonic-response': {'status': 'ok', ...payload},
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final overview = await client.libraryOverview();

    expect(overview.artists[0].coverUrl, 'https://images.example.com/a.jpg');
    expect(
      Uri.parse(overview.artists[1].coverUrl!).queryParameters['id'],
      'cover-artist',
    );
  });

  test('uses album artwork when subsonic artist artwork is missing', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        final method = request.url.pathSegments.last.replaceAll('.view', '');
        final query = request.url.queryParameters;
        final payload = switch (method) {
          'getArtists' => {
            'artists': {
              'index': [
                {
                  'artist': [
                    {'id': 'artist-without-art', 'name': 'Fallback Artist'},
                  ],
                },
              ],
            },
          },
          'getAlbumList2' when query['type'] == 'newest' => {
            'albumList2': {
              'album': [
                {
                  'id': 'album-art',
                  'name': 'Album Art',
                  'artist': 'Fallback Artist',
                  'coverArt': 'album-cover',
                },
              ],
            },
          },
          'getAlbumList2' => {
            'albumList2': {'album': []},
          },
          'getPlaylists' => {
            'playlists': {'playlist': []},
          },
          _ => <String, Object?>{},
        };
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'subsonic-response': {'status': 'ok', ...payload},
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final overview = await client.libraryOverview();

    expect(
      Uri.parse(overview.artists.single.coverUrl!).queryParameters['id'],
      'album-cover',
    );
  });

  test('loads total song count from paged album song counts', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        final method = request.url.pathSegments.last.replaceAll('.view', '');
        final query = request.url.queryParameters;
        final payload = switch (method) {
          'getArtists' => {
            'artists': {'index': []},
          },
          'getAlbumList2' when query['type'] == 'newest' => {
            'albumList2': {
              'album': [
                {
                  'id': 'recent-album',
                  'name': 'Recent Album',
                  'artist': 'Artist',
                  'songCount': 2,
                },
              ],
            },
          },
          'getAlbumList2' when query['offset'] == '0' => {
            'albumList2': {
              'album': List.generate(
                500,
                (index) => {
                  'id': 'album-$index',
                  'name': 'Album $index',
                  'songCount': 1,
                },
              ),
            },
          },
          'getAlbumList2' when query['offset'] == '500' => {
            'albumList2': {
              'album': [
                {'id': 'album-3', 'name': 'Album 3', 'songCount': 4},
              ],
            },
          },
          'getPlaylists' => {
            'playlists': {'playlist': []},
          },
          _ => <String, Object?>{},
        };
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'subsonic-response': {'status': 'ok', ...payload},
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final overview = await client.libraryOverview();

    expect(overview.albums.single.title, 'Recent Album');
    expect(overview.songCount, 504);
  });

  test('loads discovery lists favorites and radio from subsonic', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        final method = request.url.pathSegments.last.replaceAll('.view', '');
        final query = request.url.queryParameters;
        final payload = switch (method) {
          'getArtists' => {
            'artists': {'index': []},
          },
          'getAlbumList2' when query['type'] == 'newest' => {
            'albumList2': {
              'album': [
                {'id': 'newest', 'name': 'Newest Album', 'artist': 'Artist'},
              ],
            },
          },
          'getAlbumList2' when query['type'] == 'recent' => {
            'albumList2': {
              'album': [
                {'id': 'recent', 'name': 'Recent Album', 'artist': 'Artist'},
              ],
            },
          },
          'getAlbumList2' when query['type'] == 'frequent' => {
            'albumList2': {
              'album': [
                {
                  'id': 'frequent',
                  'name': 'Frequent Album',
                  'artist': 'Artist',
                },
              ],
            },
          },
          'getAlbumList2' when query['type'] == 'random' => {
            'albumList2': {
              'album': [
                {'id': 'random', 'name': 'Random Album', 'artist': 'Artist'},
              ],
            },
          },
          'getAlbumList2' => {
            'albumList2': {'album': []},
          },
          'getStarred2' => {
            'starred2': {
              'song': [
                {
                  'id': 'favorite-song',
                  'title': 'Favorite Song',
                  'artist': 'Singer',
                  'album': 'Album',
                  'suffix': 'flac',
                },
              ],
            },
          },
          'getInternetRadioStations' => {
            'internetRadioStations': {
              'internetRadioStation': [
                {
                  'id': 'radio-1',
                  'name': 'Jazz Radio',
                  'streamUrl': 'https://radio.example.com/live.mp3',
                },
              ],
            },
          },
          'getPlaylists' => {
            'playlists': {
              'playlist': [
                {
                  'id': 'private-playlist',
                  'name': 'Private Playlist',
                  'songCount': 3,
                  'public': false,
                },
                {
                  'id': 'public-playlist',
                  'name': 'Public Playlist',
                  'songCount': 8,
                  'public': true,
                },
              ],
            },
          },
          _ => <String, Object?>{},
        };
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'subsonic-response': {'status': 'ok', ...payload},
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final overview = await client.libraryOverview();

    expect(overview.latestAlbums.single.title, 'Newest Album');
    expect(overview.recentAlbums.single.title, 'Recent Album');
    expect(overview.frequentAlbums.single.title, 'Frequent Album');
    expect(overview.randomAlbums.single.title, 'Random Album');
    expect(overview.favoriteTracks.single.title, 'Favorite Song');
    expect(overview.favoriteTracks.single.audioFormat, 'FLAC');
    expect(overview.radioStations.single.title, 'Jazz Radio');
    expect(overview.myPlaylists.single.id, 'private-playlist');
    expect(overview.publicPlaylists.single.id, 'public-playlist');
  });

  test('parses m3u and pls radio playlist stream urls', () {
    expect(
      radioPlaylistStreamUrl(
        '#EXTM3U\n#EXTINF:-1,Jazz\nhttps://radio.example.com/live.mp3',
        Uri.parse('https://radio.example.com/list.m3u'),
      ),
      'https://radio.example.com/live.mp3',
    );
    expect(
      radioPlaylistStreamUrl(
        '[playlist]\nNumberOfEntries=1\nFile1=https://radio.example.com/live',
        Uri.parse('https://radio.example.com/list.pls'),
      ),
      'https://radio.example.com/live',
    );
    expect(
      radioPlaylistStreamUrl(
        '#EXTM3U\nstreams/live.mp3',
        Uri.parse('https://radio.example.com/path/list.m3u'),
      ),
      'https://radio.example.com/path/streams/live.mp3',
    );
  });

  test('refreshes favorites playlists and radio independently', () async {
    final requestedMethods = <String>[];
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final controller =
        AppController(store: _MemoryLibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..apiClientFactory = (server) => SubsonicApiClient(
            server: server,
            httpClient: MockClient((request) async {
              final method = request.url.pathSegments.last.replaceAll(
                '.view',
                '',
              );
              requestedMethods.add(method);
              final payload = switch (method) {
                'getStarred2' => {
                  'starred2': {
                    'song': [
                      {
                        'id': 'favorite-song',
                        'title': 'Favorite Song',
                        'artist': 'Singer',
                        'album': 'Album',
                      },
                    ],
                  },
                },
                'getPlaylists' => {
                  'playlists': {
                    'playlist': [
                      {'id': 'playlist-1', 'name': 'Road Mix', 'songCount': 2},
                    ],
                  },
                },
                'getInternetRadioStations' => {
                  'internetRadioStations': {
                    'internetRadioStation': [
                      {
                        'id': 'radio-1',
                        'name': 'Jazz Radio',
                        'streamUrl': 'https://radio.example.com/live.mp3',
                      },
                    ],
                  },
                },
                _ => <String, Object?>{},
              };
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode({
                    'subsonic-response': {'status': 'ok', ...payload},
                  }),
                ),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }),
          );
    addTearDown(controller.dispose);

    await controller.refreshFavoriteTracks();
    await controller.refreshRemotePlaylists();
    await controller.refreshRadioStations();

    expect(requestedMethods, [
      'getStarred2',
      'getPlaylists',
      'getInternetRadioStations',
    ]);
    expect(
      controller.libraryOverview.favoriteTracks.single.title,
      'Favorite Song',
    );
    expect(controller.visiblePlaylists.single.title, 'Road Mix');
    expect(controller.libraryOverview.radioStations.single.title, 'Jazz Radio');
  });

  test('loads remote overview parts as each request completes', () async {
    final artistsResponse = Completer<http.Response>();
    final albumsResponse = Completer<http.Response>();
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final controller =
        AppController(store: _MemoryLibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..apiClientFactory = (server) => SubsonicApiClient(
            server: server,
            httpClient: MockClient((request) {
              final method = request.url.pathSegments.last.replaceAll(
                '.view',
                '',
              );
              final query = request.url.queryParameters;
              if (method == 'getArtists') {
                return artistsResponse.future;
              }
              if (method == 'getAlbumList2' && query['type'] == 'newest') {
                return albumsResponse.future;
              }

              final payload = switch (method) {
                'getPlaylists' => {
                  'playlists': {
                    'playlist': [
                      {'id': 'playlist-1', 'name': 'Road Mix', 'songCount': 2},
                    ],
                  },
                },
                'getAlbumList2' => {
                  'albumList2': {'album': []},
                },
                'getStarred2' => {
                  'starred2': {'song': []},
                },
                'getInternetRadioStations' => {
                  'internetRadioStations': {'internetRadioStation': []},
                },
                _ => <String, Object?>{},
              };
              return Future.value(_subsonicJsonResponse(payload));
            }),
          );
    addTearDown(controller.dispose);

    final loadFuture = controller.loadLibraryOverview();
    await _waitFor(() => controller.libraryOverview.playlists.isNotEmpty);

    expect(controller.libraryOverview.playlists.single.title, 'Road Mix');
    expect(controller.libraryOverview.artists, isEmpty);

    artistsResponse.complete(
      _subsonicJsonResponse({
        'artists': {
          'index': [
            {
              'artist': [
                {'id': 'artist-1', 'name': 'Singer'},
              ],
            },
          ],
        },
      }),
    );
    albumsResponse.complete(
      _subsonicJsonResponse({
        'albumList2': {
          'album': [
            {'id': 'album-1', 'name': 'Album', 'artist': 'Singer'},
          ],
        },
      }),
    );
    await loadFuture;

    expect(controller.libraryOverview.artists.single.title, 'Singer');
    expect(controller.libraryOverview.albums.single.title, 'Album');
  });

  test('skips hidden home module requests during a full refresh', () async {
    const server = ServerConfig(
      id: 'https://music.example.com|demo',
      name: 'Zmusic',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final requests = <({String method, String? type})>[];
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..settings = const AppSettings(
            showDailyRecommendation: false,
            hiddenHomeShortcuts: {
              HomeShortcutSection.favorites,
              HomeShortcutSection.myPlaylists,
              HomeShortcutSection.publicPlaylists,
              HomeShortcutSection.publicRadio,
            },
            hiddenHomeDiscoveries: {
              HomeDiscoverySection.latestAlbums,
              HomeDiscoverySection.randomAlbums,
              HomeDiscoverySection.recentAlbums,
              HomeDiscoverySection.frequentAlbums,
            },
            showMyPlaylistSection: false,
            showPublicPlaylistSection: false,
          )
          ..apiClientFactory = (server) => SubsonicApiClient(
            server: server,
            httpClient: MockClient((request) async {
              final method = request.url.pathSegments.last.replaceAll(
                '.view',
                '',
              );
              requests.add((
                method: method,
                type: request.url.queryParameters['type'],
              ));
              return _subsonicJsonResponse({
                if (method == 'getAlbumList2') 'albumList2': {'album': []},
              });
            }),
          );
    addTearDown(controller.dispose);

    await controller.loadLibraryOverview();

    expect(requests, [(method: 'getAlbumList2', type: 'alphabeticalByName')]);
  });

  test('loads subsonic playlist tracks by playlist id', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        final method = request.url.pathSegments.last.replaceAll('.view', '');
        final query = request.url.queryParameters;
        final payload = switch (method) {
          'getArtists' => {
            'artists': {'index': []},
          },
          'getAlbumList2' => {
            'albumList2': {'album': []},
          },
          'getPlaylists' => {
            'playlists': {
              'playlist': [
                {'id': 'playlist-1', 'name': 'Road Mix', 'songCount': 1},
              ],
            },
          },
          'getPlaylist' when query['id'] == 'playlist-1' => {
            'playlist': {
              'id': 'playlist-1',
              'name': 'Road Mix',
              'entry': [
                {
                  'id': 'song-1',
                  'title': 'Road Song',
                  'artist': 'Singer',
                  'album': 'Album',
                  'duration': 180,
                  'suffix': 'mp3',
                },
              ],
            },
          },
          _ => <String, Object?>{},
        };
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'subsonic-response': {'status': 'ok', ...payload},
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final overview = await client.libraryOverview();
    final tracks = await client.playlistTracks(overview.playlists.single.id);

    expect(overview.playlists.single.title, 'Road Mix');
    expect(tracks.single.id, 'https://music.example.com:song-1');
    expect(tracks.single.title, 'Road Song');
    expect(tracks.single.audioFormat, 'MP3');
  });

  test('updates subsonic playlist metadata and tracks', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final requests = <Uri>[];
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({
            'subsonic-response': {'status': 'ok'},
          }),
          200,
        );
      }),
    );

    await client.updatePlaylist(
      playlistId: 'playlist-1',
      name: '我的歌单',
      comment: '简介',
      isPublic: true,
      songIdsToAdd: const ['song-2', 'song-3'],
      songIndexesToRemove: const [4, 1],
    );

    final uri = requests.single;
    expect(uri.pathSegments.last, 'updatePlaylist.view');
    expect(uri.queryParameters['playlistId'], 'playlist-1');
    expect(uri.queryParameters['name'], '我的歌单');
    expect(uri.queryParameters['comment'], '简介');
    expect(uri.queryParameters['public'], 'true');
    expect(uri.queryParametersAll['songIdToAdd'], ['song-2', 'song-3']);
    expect(uri.queryParametersAll['songIndexToRemove'], ['4', '1']);
  });

  test('creates and deletes subsonic playlists', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final requests = <Uri>[];
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        requests.add(request.url);
        final method = request.url.pathSegments.last.replaceAll('.view', '');
        final payload = method == 'createPlaylist'
            ? {
                'playlist': {
                  'id': 'created-playlist',
                  'name': '新歌单',
                  'songCount': 2,
                },
              }
            : <String, Object?>{};
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'subsonic-response': {'status': 'ok', ...payload},
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final playlist = await client.createPlaylist(
      name: '新歌单',
      songIds: const ['song-1', 'song-2'],
    );
    await client.deletePlaylist('created-playlist');

    expect(playlist?.id, 'created-playlist');
    expect(playlist?.title, '新歌单');
    expect(requests[0].pathSegments.last, 'createPlaylist.view');
    expect(requests[0].queryParameters['name'], '新歌单');
    expect(requests[0].queryParametersAll['songId'], ['song-1', 'song-2']);
    expect(requests[1].pathSegments.last, 'deletePlaylist.view');
    expect(requests[1].queryParameters['id'], 'created-playlist');
  });

  test('merges playlists without adding duplicate songs', () async {
    const server = ServerConfig(
      id: 'https://music.example.com|demo',
      name: 'Zmusic',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    const target = LibrarySectionItem(
      id: 'target',
      title: '目标歌单',
      type: LibrarySectionType.playlists,
      isPublic: false,
      owner: 'demo',
    );
    const source = LibrarySectionItem(
      id: 'source',
      title: '来源歌单',
      type: LibrarySectionType.playlists,
      isPublic: false,
      owner: 'demo',
    );
    Uri? updateRequest;
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..libraryOverview = const LibraryOverview(playlists: [target, source])
          ..apiClientFactory = (sourceConfig) => SubsonicApiClient(
            server: sourceConfig,
            httpClient: MockClient((request) async {
              final method = request.url.pathSegments.last.replaceAll(
                '.view',
                '',
              );
              if (method == 'updatePlaylist') {
                updateRequest = request.url;
                return _subsonicJsonResponse({});
              }
              final playlistId = request.url.queryParameters['id'];
              final ids = playlistId == 'target'
                  ? const ['song-1']
                  : const ['song-1', 'song-2'];
              return _subsonicJsonResponse({
                'playlist': {
                  'entry': [
                    for (final id in ids)
                      {
                        'id': id,
                        'title': id,
                        'artist': 'Artist',
                        'album': 'Album',
                        'suffix': 'mp3',
                      },
                  ],
                },
              });
            }),
          );

    final result = await controller.mergeRemotePlaylists(
      target: target,
      sources: const [source],
    );

    expect(result.sourceTrackCount, 2);
    expect(result.addedCount, 1);
    expect(result.skippedCount, 1);
    expect(updateRequest?.queryParametersAll['songIdToAdd'], ['song-2']);
  });

  test('stars and unstars subsonic songs by id', () async {
    final methods = <String>[];
    final ids = <String?>[];
    final client = SubsonicApiClient(
      server: const ServerConfig(
        id: 'https://music.example.com',
        name: 'Navidrome',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      ),
      httpClient: MockClient((request) async {
        final uri = request.url;
        methods.add(uri.pathSegments.last.replaceFirst('.view', ''));
        ids.add(uri.queryParameters['id']);
        return http.Response(
          jsonEncode({
            'subsonic-response': {'status': 'ok'},
          }),
          200,
        );
      }),
    );

    await client.starTrack('song-1');
    await client.unstarTrack('song-1');

    expect(methods, ['star', 'unstar']);
    expect(ids, ['song-1', 'song-1']);
  });

  test('scrobbles subsonic songs with submission flag', () async {
    final requests = <Uri>[];
    final client = SubsonicApiClient(
      server: const ServerConfig(
        id: 'https://music.example.com',
        name: 'Navidrome',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      ),
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({
            'subsonic-response': {'status': 'ok'},
          }),
          200,
        );
      }),
    );

    await client.scrobbleTrack('song-1', submission: false);
    await client.scrobbleTrack(
      'song-1',
      submission: true,
      time: DateTime.fromMillisecondsSinceEpoch(123456),
    );

    expect(
      requests.map((uri) => uri.pathSegments.last.replaceFirst('.view', '')),
      ['scrobble', 'scrobble'],
    );
    expect(requests.map((uri) => uri.queryParameters['id']), [
      'song-1',
      'song-1',
    ]);
    expect(requests.map((uri) => uri.queryParameters['submission']), [
      'false',
      'true',
    ]);
    expect(requests.last.queryParameters['time'], '123456');
  });

  test('uses 30 seconds or half duration as playback scrobble threshold', () {
    expect(
      shouldSubmitPlaybackScrobble(
        position: const Duration(seconds: 29),
        duration: const Duration(minutes: 4),
      ),
      isFalse,
    );
    expect(
      shouldSubmitPlaybackScrobble(
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 4),
      ),
      isTrue,
    );
    expect(
      shouldSubmitPlaybackScrobble(
        position: const Duration(seconds: 14),
        duration: const Duration(seconds: 30),
      ),
      isFalse,
    );
    expect(
      shouldSubmitPlaybackScrobble(
        position: const Duration(seconds: 15),
        duration: const Duration(seconds: 30),
      ),
      isTrue,
    );
  });

  test('scrobbles current subsonic playback once after threshold', () async {
    final player = _ScrobblePlayerController();
    final requests = <Uri>[];
    final controller = AppController(store: LibraryStore(), player: player)
      ..servers = const [
        ServerConfig(
          id: 'https://music.example.com',
          name: 'Navidrome',
          baseUrl: 'https://music.example.com',
          username: 'demo',
          password: 'secret',
        ),
      ]
      ..selectedServerId = 'https://music.example.com'
      ..apiClientFactory = (server) => SubsonicApiClient(
        server: server,
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode({
              'subsonic-response': {'status': 'ok'},
            }),
            200,
          );
        }),
      );
    addTearDown(controller.dispose);

    const track = Track(
      id: 'https://music.example.com:song-1',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-1',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      duration: Duration(minutes: 4),
      lyrics: 'loaded',
      sourceServerId: 'https://music.example.com',
      sourceItemId: 'song-1',
    );

    player.start(track);
    await Future<void>.delayed(Duration.zero);
    player.emitPosition(const Duration(seconds: 10));
    await Future<void>.delayed(Duration.zero);
    player.emitPosition(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);
    player.emitPosition(const Duration(seconds: 45));
    await Future<void>.delayed(Duration.zero);

    expect(
      requests.map((uri) => uri.pathSegments.last.replaceFirst('.view', '')),
      ['scrobble', 'scrobble'],
    );
    expect(requests.map((uri) => uri.queryParameters['submission']), [
      'false',
      'true',
    ]);
    expect(requests.map((uri) => uri.queryParameters['id']), [
      'song-1',
      'song-1',
    ]);
  });

  test('does not scrobble local files or radio streams', () async {
    final player = _ScrobblePlayerController();
    final requests = <Uri>[];
    final controller = AppController(store: LibraryStore(), player: player)
      ..servers = const [
        ServerConfig(
          id: 'https://music.example.com',
          name: 'Navidrome',
          baseUrl: 'https://music.example.com',
          username: 'demo',
          password: 'secret',
        ),
      ]
      ..selectedServerId = 'https://music.example.com'
      ..apiClientFactory = (server) => SubsonicApiClient(
        server: server,
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode({
              'subsonic-response': {'status': 'ok'},
            }),
            200,
          );
        }),
      );
    addTearDown(controller.dispose);

    player.start(
      const Track(
        id: 'local-song',
        title: 'Local',
        artist: 'Artist',
        album: 'Album',
        streamUrl: 'file:///D:/Music/local.mp3',
        sourceType: MusicSourceType.localFile,
        sourceName: '本地音乐',
        duration: Duration(minutes: 4),
        sourceItemId: r'D:\Music\local.mp3',
      ),
    );
    player.emitPosition(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);

    player.start(
      const Track(
        id: 'radio:https://music.example.com:radio-1',
        title: 'Radio',
        artist: '电台',
        album: '电台',
        streamUrl: 'https://radio.example.com/live.mp3',
        sourceType: MusicSourceType.customStream,
        sourceName: 'Navidrome',
        duration: Duration(minutes: 4),
        sourceServerId: 'https://music.example.com',
        sourceItemId: 'radio:radio-1',
      ),
    );
    player.emitPosition(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);

    expect(requests, isEmpty);
  });

  test('parses timestamped lyrics and finds current line', () {
    final lines = parseLyricsTimeline('''
[00:10.00]First line
[00:12.50]Second line
[00:01:05.250]Third line
[00:20.00][00:22.00]Repeated line
plain text
''');

    expect(lines.map((line) => line.text), [
      'First line',
      'Second line',
      'Repeated line',
      'Repeated line',
      'Third line',
    ]);
    expect(lines[0].time, const Duration(seconds: 10));
    expect(lines[1].time, const Duration(seconds: 12, milliseconds: 500));
    expect(
      lines[4].time,
      const Duration(minutes: 1, seconds: 5, milliseconds: 250),
    );

    expect(currentLyricIndex(lines, const Duration(seconds: 9)), -1);
    expect(currentLyricIndex(lines, const Duration(seconds: 12)), 0);
    expect(
      currentLyricIndex(lines, const Duration(seconds: 12, milliseconds: 500)),
      1,
    );
    expect(currentLyricIndex(lines, const Duration(seconds: 21)), 2);
    expect(currentLyricIndex(lines, const Duration(minutes: 2)), 4);
  });

  test('loads structured synced lyrics as lrc text', () async {
    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'Navidrome',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final client = SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'lyricsList': {
                'structuredLyrics': [
                  {
                    'synced': true,
                    'line': [
                      {'start': 10500, 'value': 'First line'},
                      {'start': 12500, 'value': 'Second line'},
                    ],
                  },
                ],
              },
            },
          }),
          200,
        );
      }),
    );

    final lyrics = await client.lyricsForTrack(
      const Track(
        id: 'song-1',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        streamUrl: 'https://music.example.com/rest/stream.view?id=song-1',
        sourceType: MusicSourceType.subsonic,
        sourceName: 'Navidrome',
        sourceItemId: 'song-1',
      ),
    );

    expect(lyrics, '[00:10.50]First line\n[00:12.50]Second line');
  });

  test('limits cache size settings to 10GB', () {
    const settings = AppSettings(cacheSizeBytes: 32 * gb);

    expect(settings.normalized.cacheSizeBytes, 10 * gb);
  });

  test('stores app logo and background paths independently', () {
    const settings = AppSettings(
      logoPath: 'C:/images/logo.png',
      backgroundPath: 'C:/images/background.jpg',
    );

    final restored = AppSettings.fromJson(settings.toJson());
    final logoOnly = AppSettings.fromJson(
      const AppSettings(logoPath: 'logo-only.png').toJson(),
    );
    final legacy = AppSettings.fromJson(const {'logoPath': 'legacy.png'});

    expect(restored.logoPath, 'C:/images/logo.png');
    expect(restored.backgroundPath, 'C:/images/background.jpg');
    expect(logoOnly.backgroundPath, isEmpty);
    expect(legacy.logoPath, 'legacy.png');
    expect(legacy.backgroundPath, 'legacy.png');
  });

  test('stores and normalizes the configurable home layout', () {
    const settings = AppSettings(
      showDailyRecommendation: false,
      homeShortcutOrder: [
        HomeShortcutSection.publicRadio,
        HomeShortcutSection.favorites,
        HomeShortcutSection.publicPlaylists,
        HomeShortcutSection.myPlaylists,
      ],
      hiddenHomeShortcuts: {HomeShortcutSection.publicPlaylists},
      homeDiscoveryOrder: [
        HomeDiscoverySection.frequentAlbums,
        HomeDiscoverySection.latestAlbums,
        HomeDiscoverySection.recentAlbums,
        HomeDiscoverySection.randomAlbums,
      ],
      hiddenHomeDiscoveries: {HomeDiscoverySection.randomAlbums},
      showMyPlaylistSection: false,
      showPublicPlaylistSection: true,
      checkUpdatesOnStartup: true,
    );

    final restored = AppSettings.fromJson(settings.toJson());
    final malformed = AppSettings.fromJson(const {
      'homeShortcutOrder': ['publicRadio', 'publicRadio', 'unknown'],
      'homeDiscoveryOrder': ['frequentAlbums'],
    });
    final legacy = AppSettings.fromJson(const {});

    expect(restored.homeShortcutOrder, settings.homeShortcutOrder);
    expect(restored.hiddenHomeShortcuts, settings.hiddenHomeShortcuts);
    expect(restored.homeDiscoveryOrder, settings.homeDiscoveryOrder);
    expect(restored.hiddenHomeDiscoveries, settings.hiddenHomeDiscoveries);
    expect(restored.showDailyRecommendation, isFalse);
    expect(restored.showMyPlaylistSection, isFalse);
    expect(restored.showPublicPlaylistSection, isTrue);
    expect(restored.checkUpdatesOnStartup, isTrue);
    expect(restored.shouldLoadHomePlaylists, isTrue);
    expect(const AppSettings().checkUpdatesOnStartup, isTrue);
    expect(legacy.checkUpdatesOnStartup, isTrue);
    expect(malformed.homeShortcutOrder, [
      HomeShortcutSection.publicRadio,
      HomeShortcutSection.favorites,
      HomeShortcutSection.myPlaylists,
      HomeShortcutSection.publicPlaylists,
    ]);
    expect(malformed.homeDiscoveryOrder, [
      HomeDiscoverySection.frequentAlbums,
      HomeDiscoverySection.latestAlbums,
      HomeDiscoverySection.randomAlbums,
      HomeDiscoverySection.recentAlbums,
    ]);
    expect(legacy.homeShortcutOrder, defaultHomeShortcutOrder);
    expect(legacy.homeDiscoveryOrder, defaultHomeDiscoveryOrder);
    expect(legacy.visibleHomeShortcutOrder, defaultHomeShortcutOrder);
    expect(legacy.visibleHomeDiscoveryOrder, defaultHomeDiscoveryOrder);
    expect(legacy.showDailyRecommendation, isTrue);
  });

  test('builds daily recommendations with quality dedupe and exclusions', () {
    Track track({
      required String id,
      required String title,
      required String artist,
      required String format,
    }) {
      return Track(
        id: id,
        title: title,
        artist: artist,
        album: '专辑',
        streamUrl: 'https://music.example.com/$id',
        sourceType: MusicSourceType.subsonic,
        sourceName: 'Navidrome',
        sourceServerId: 'server',
        sourceItemId: id,
        audioFormat: format,
      );
    }

    final duplicateMp3 = track(
      id: 'duplicate-mp3',
      title: '同一首歌',
      artist: '歌手一',
      format: 'MP3',
    );
    final duplicateFlac = track(
      id: 'duplicate-flac',
      title: '同一首歌',
      artist: '歌手一',
      format: 'FLAC',
    );
    final excluded = track(
      id: 'excluded',
      title: '队列歌曲',
      artist: '歌手二',
      format: 'FLAC',
    );
    final randomTracks = List.generate(
      40,
      (index) => track(
        id: 'random-$index',
        title: '随机歌曲 $index',
        artist: '随机歌手 ${index % 10}',
        format: 'MP3',
      ),
    );

    final recommendations = buildDailyRecommendationTracks(
      favorites: [duplicateMp3, duplicateFlac, excluded],
      related: const [],
      habitual: const [],
      randomTracks: randomTracks,
      excludedTracks: [excluded],
      seed: 20260716,
    );

    expect(recommendations, hasLength(30));
    expect(recommendations, isNot(contains(excluded)));
    expect(
      recommendations
          .where((track) => track.title == '同一首歌')
          .single
          .audioFormat,
      'FLAC',
    );
    expect(
      recommendations
          .map((track) => '${track.artist}\u0000${track.title}')
          .toSet(),
      hasLength(recommendations.length),
    );
    for (var index = 1; index < recommendations.length; index++) {
      expect(
        recommendations[index].artist,
        isNot(recommendations[index - 1].artist),
      );
    }
  });

  test('reuses in-flight cache size requests', () async {
    final cacheManager = _CountingAudioCacheManager();
    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
      cacheManager: cacheManager,
    );
    addTearDown(controller.dispose);

    final first = controller.cacheSize();
    final second = controller.cacheSize();

    expect(identical(first, second), isTrue);
    expect(cacheManager.cacheSizeCalls, 1);

    cacheManager.completeNext(128);
    expect(await first, 128);
    expect(await second, 128);

    final third = controller.cacheSize();
    expect(cacheManager.cacheSizeCalls, 2);
    cacheManager.completeNext(256);
    expect(await third, 256);
  });

  test('uses bundled executable icon before development icon', () {
    final iconPath = resolveDesktopIconPath(
      configuredIconPath: '',
      executableDirectory: r'D:\App\zmusic-windows-x64',
      workingDirectory: r'D:\work\D\miusc',
      fileExists: (path) =>
          path == r'D:\App\zmusic-windows-x64\app_icon.ico' ||
          path == r'D:\work\D\miusc\windows\runner\resources\app_icon.ico',
    );

    expect(iconPath, r'D:\App\zmusic-windows-x64\app_icon.ico');
  });

  testWidgets('keeps the native tray menu stable while playback changes', (
    tester,
  ) async {
    const windowChannel = MethodChannel('window_manager');
    const trayChannel = MethodChannel('tray_manager');
    const windowsSettingsChannel = MethodChannel(
      'com.zmusic.app/windows_settings',
    );
    final trayCalls = <MethodCall>[];
    final popupClosed = Completer<void>();

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (_) async => true,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      trayChannel,
      (call) async {
        trayCalls.add(call);
        if (call.method == 'popUpContextMenu') {
          await popupClosed.future;
        }
        return true;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowsSettingsChannel,
      (_) async => null,
    );

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );
    final integration = DesktopIntegration(controller);
    addTearDown(() async {
      await integration.dispose();
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        trayChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowsSettingsChannel,
        null,
      );
    });

    await integration.initialize();
    expect(
      trayCalls.where((call) => call.method == 'setContextMenu'),
      hasLength(1),
    );

    controller.player.setPlaybackMode(PlaybackMode.shuffle);
    await tester.pump();
    expect(
      trayCalls.where((call) => call.method == 'setContextMenu'),
      hasLength(1),
    );

    final firstPopup = integration.onTrayIconRightMouseDown();
    await tester.pump();
    final secondPopup = integration.onTrayIconRightMouseDown();
    await tester.pump();

    final popupCalls = trayCalls
        .where((call) => call.method == 'popUpContextMenu')
        .toList();
    expect(popupCalls, hasLength(1));
    expect(
      (popupCalls.single.arguments as Map<Object?, Object?>)['bringAppToFront'],
      Platform.isWindows,
    );

    popupClosed.complete();
    await firstPopup;
    await secondPopup;
  });

  test('prepares uncached network tracks for streaming cache', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    var requested = false;
    final manager = AudioCacheManager(
      httpClient: MockClient((_) async {
        requested = true;
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    const track = Track(
      id: 'song-mp3',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl:
          'https://music.example.com/rest/stream.view?id=song-mp3&format=mp3&maxBitRate=320',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceItemId: 'song-mp3',
      audioFormat: 'MP3',
    );

    final resolved = await manager.resolveForPlayback(
      track,
      AppSettings(cacheDirectory: tempDirectory.path),
    );

    expect(requested, isFalse);
    expect(resolved.track.streamUrl, track.streamUrl);
    expect(resolved.streamingCacheFile, isNotNull);
    expect(resolved.streamingCacheFile!.existsSync(), isFalse);
    expect(
      audioCachePartialMarker(resolved.streamingCacheFile!).existsSync(),
      isTrue,
    );
    expect(resolved.streamingCacheFile!.path.toLowerCase(), endsWith('.mp3'));
  });

  test('prepares subsonic lossless streams for streaming cache proxy', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    final manager = AudioCacheManager();
    const track = Track(
      id: 'song-ape',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl:
          'https://music.example.com/rest/stream.view?id=song-ape&format=mp3&maxBitRate=320',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceItemId: 'song-ape',
      audioFormat: 'APE',
    );

    final resolved = await manager.resolveForPlayback(
      track,
      AppSettings(cacheDirectory: tempDirectory.path),
    );

    expect(resolved.track.streamUrl, track.streamUrl);
    expect(resolved.streamingCacheFile, isNotNull);
    expect(
      audioCachePartialMarker(resolved.streamingCacheFile!).existsSync(),
      isTrue,
    );

    const flacTrack = Track(
      id: 'song-flac',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-flac',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceItemId: 'song-flac',
      audioFormat: 'FLAC',
    );

    final flacResolved = await manager.resolveForPlayback(
      flacTrack,
      AppSettings(cacheDirectory: tempDirectory.path),
    );

    expect(flacResolved.track.streamUrl, flacTrack.streamUrl);
    expect(flacResolved.streamingCacheFile, isNotNull);
    expect(
      audioCachePartialMarker(flacResolved.streamingCacheFile!).existsSync(),
      isTrue,
    );
    expect(
      flacResolved.streamingCacheFile!.path.toLowerCase(),
      endsWith('.flac'),
    );
  });

  test('prepares raw ape and flac for streaming cache proxy', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    final manager = AudioCacheManager();
    const rawApeTrack = Track(
      id: 'song-ape',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-ape',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceItemId: 'song-ape',
      audioFormat: 'APE',
    );
    const rawFlacTrack = Track(
      id: 'song-flac',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-flac',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceItemId: 'song-flac',
      audioFormat: 'FLAC',
    );

    final rawApeResolved = await manager.resolveForPlayback(
      rawApeTrack,
      AppSettings(cacheDirectory: tempDirectory.path),
    );
    final rawFlacResolved = await manager.resolveForPlayback(
      rawFlacTrack,
      AppSettings(cacheDirectory: tempDirectory.path),
    );

    expect(rawApeResolved.track.streamUrl, rawApeTrack.streamUrl);
    expect(rawApeResolved.streamingCacheFile, isNotNull);
    expect(
      rawApeResolved.streamingCacheFile!.path.toLowerCase(),
      endsWith('.ape'),
    );
    expect(rawFlacResolved.track.streamUrl, rawFlacTrack.streamUrl);
    expect(rawFlacResolved.streamingCacheFile, isNotNull);
    expect(
      rawFlacResolved.streamingCacheFile!.path.toLowerCase(),
      endsWith('.flac'),
    );
  });

  test('skips streaming cache for radio tracks', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    final manager = AudioCacheManager();
    const track = Track(
      id: 'radio:server:station',
      title: 'Jazz Radio',
      artist: '电台',
      album: '电台',
      streamUrl: 'https://radio.example.com/live.mp3',
      sourceType: MusicSourceType.customStream,
      sourceName: 'Navidrome',
      sourceItemId: 'radio:station',
    );

    final resolved = await manager.resolveForPlayback(
      track,
      AppSettings(cacheDirectory: tempDirectory.path),
    );

    expect(resolved.track.streamUrl, track.streamUrl);
    expect(resolved.streamingCacheFile, isNull);
  });

  test('cancels active streaming cache downloads', () async {
    final originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      HttpOverrides.global = originalHttpOverrides;
      await server.close(force: true);
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    var chunksSent = 0;
    server.listen((request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = 20 * 1024;
      try {
        for (var index = 0; index < 20; index++) {
          chunksSent += 1;
          request.response.add(List<int>.filled(1024, index));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } catch (_) {
        // The test cancels the client connection before all chunks are sent.
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });

    final proxy = StreamingAudioCacheProxy(
      Uri.parse('http://127.0.0.1:${server.port}/song.mp3'),
      cacheFile: File('${tempDirectory.path}${Platform.pathSeparator}song.mp3'),
    );
    addTearDown(proxy.cancel);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(await proxy.start());
    final response = await request.close();
    final subscription = response.listen((_) {});
    addTearDown(subscription.cancel);

    await Future<void>(() async {
      while (chunksSent == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }).timeout(const Duration(seconds: 2));
    await proxy.cancel();
    final chunksAtCancel = chunksSent;
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(chunksAtCancel, lessThan(20));
    expect(chunksSent, lessThan(20));
    final cachedLength = proxy.cacheFile.existsSync()
        ? proxy.cacheFile.lengthSync()
        : 0;
    expect(cachedLength, lessThan(20 * 1024));
  });

  test(
    'throttles streaming cache progress and always emits completion',
    () async {
      final originalHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final tempDirectory = await Directory.systemTemp.createTemp(
        'zmusic-audio-cache-progress-test-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        HttpOverrides.global = originalHttpOverrides;
        await server.close(force: true);
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      const chunkCount = 8;
      server.listen((request) async {
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.contentLength = chunkCount * 1024;
        for (var index = 0; index < chunkCount; index++) {
          request.response.add(List<int>.filled(1024, index));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await request.response.close();
      });

      final proxy = StreamingAudioCacheProxy(
        Uri.parse('http://127.0.0.1:${server.port}/song.mp3'),
        cacheFile: File(
          '${tempDirectory.path}${Platform.pathSeparator}song.mp3',
        ),
        progressUpdateInterval: const Duration(seconds: 1),
      );
      addTearDown(proxy.cancel);
      final progress = <double>[];
      final progressSubscription = proxy.downloadProgressStream.listen(
        progress.add,
      );
      addTearDown(progressSubscription.cancel);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(await proxy.start());
      final response = await request.close();
      await response.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      expect(progress, hasLength(lessThanOrEqualTo(2)));
    },
  );

  test('serves local proxy reads through a single origin request', () async {
    final originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      HttpOverrides.global = originalHttpOverrides;
      await server.close(force: true);
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    var originRequests = 0;
    server.listen((request) async {
      originRequests += 1;
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = 4 * 1024;
      try {
        for (var index = 0; index < 4; index++) {
          request.response.add(List<int>.filled(1024, index));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });

    final proxy = StreamingAudioCacheProxy(
      Uri.parse('http://127.0.0.1:${server.port}/song.mp3'),
      cacheFile: File('${tempDirectory.path}${Platform.pathSeparator}song.mp3'),
    );
    addTearDown(proxy.cancel);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final localUri = await proxy.start();
    final firstRequest = await client.getUrl(localUri);
    final firstResponse = await firstRequest.close();
    final firstChunk = Completer<void>();
    final firstSubscription = firstResponse.listen((_) {
      if (!firstChunk.isCompleted) {
        firstChunk.complete();
      }
    });
    addTearDown(firstSubscription.cancel);

    await firstChunk.future.timeout(const Duration(seconds: 2));

    final rangeRequest = await client.getUrl(localUri);
    rangeRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-511');
    final rangeResponse = await rangeRequest.close();
    final rangeBytes = await rangeResponse.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );

    expect(rangeResponse.statusCode, 206);
    expect(rangeBytes.length, 512);
    expect(originRequests, 1);
  });

  test('serves far range requests from origin while cache continues', () async {
    final originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final payload = List<int>.generate(4096, (index) => index % 251);
    addTearDown(() async {
      HttpOverrides.global = originalHttpOverrides;
      await server.close(force: true);
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final originRanges = <String?>[];
    server.listen((request) async {
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      originRanges.add(rangeHeader);
      request.response.headers.contentType = ContentType('audio', 'flac');
      if (rangeHeader != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 3500-3599/${payload.length}',
        );
        request.response.contentLength = 100;
        request.response.add(payload.sublist(3500, 3600));
        await request.response.close();
        return;
      }

      request.response.contentLength = payload.length;
      request.response.add(payload.sublist(0, 512));
      await request.response.flush();
      await Future<void>.delayed(const Duration(seconds: 5));
      try {
        await request.response.close();
      } catch (_) {}
    });

    final proxy = StreamingAudioCacheProxy(
      Uri.parse('http://127.0.0.1:${server.port}/song.flac'),
      cacheFile: File(
        '${tempDirectory.path}${Platform.pathSeparator}song.flac',
      ),
    );
    addTearDown(proxy.cancel);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final localUri = await proxy.start();
    final request = await client.getUrl(localUri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=3500-3599');
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (value, chunk) => value..addAll(chunk),
    );

    expect(response.statusCode, HttpStatus.partialContent);
    expect(bytes, payload.sublist(3500, 3600));
    expect(originRanges, contains('bytes=3500-3599'));
  });

  test(
    'serves unknown length open ranges as normal streaming responses',
    () async {
      final originalHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final tempDirectory = await Directory.systemTemp.createTemp(
        'zmusic-audio-cache-test-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        HttpOverrides.global = originalHttpOverrides;
        await server.close(force: true);
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      server.listen((request) async {
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.add(List<int>.filled(1024, 7));
        await request.response.close();
      });

      final proxy = StreamingAudioCacheProxy(
        Uri.parse('http://127.0.0.1:${server.port}/song'),
        cacheFile: File(
          '${tempDirectory.path}${Platform.pathSeparator}song.mp3',
        ),
      );
      addTearDown(proxy.cancel);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(await proxy.start());
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (value, chunk) => value..addAll(chunk),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.value(HttpHeaders.contentRangeHeader), isNull);
      expect(bytes.length, 1024);
    },
  );

  test(
    'rejects structured stream error responses instead of caching them',
    () async {
      final originalHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final tempDirectory = await Directory.systemTemp.createTemp(
        'zmusic-audio-cache-test-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        HttpOverrides.global = originalHttpOverrides;
        await server.close(force: true);
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      server.listen((request) async {
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
        );
        request.response.write(
          '<subsonic-response status="failed"><error message="bad"/></subsonic-response>',
        );
        await request.response.close();
      });

      final proxy = StreamingAudioCacheProxy(
        Uri.parse('http://127.0.0.1:${server.port}/song.mp3'),
        cacheFile: File(
          '${tempDirectory.path}${Platform.pathSeparator}song.mp3',
        ),
      );
      addTearDown(proxy.cancel);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(await proxy.start());
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.badGateway);
      expect(proxy.cacheFile.existsSync(), isFalse);
    },
  );

  test(
    'keeps streaming cache files partial until completion is marked',
    () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'zmusic-audio-cache-test-',
      );
      addTearDown(() async {
        if (tempDirectory.existsSync()) {
          await tempDirectory.delete(recursive: true);
        }
      });
      final manager = AudioCacheManager();
      const track = Track(
        id: 'song-partial',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        streamUrl: 'https://music.example.com/rest/stream.view?id=song-partial',
        sourceType: MusicSourceType.subsonic,
        sourceName: 'Navidrome',
        sourceItemId: 'song-partial',
        audioFormat: 'MP3',
      );
      final settings = AppSettings(cacheDirectory: tempDirectory.path);
      final initial = await manager.resolveForPlayback(track, settings);
      final cacheFile = initial.streamingCacheFile!;
      await cacheFile.create(recursive: true);
      await cacheFile.writeAsBytes([1, 2, 3]);
      await File('${cacheFile.path}.mime').writeAsString('audio/mpeg');

      expect(isCompletedAudioCacheFile(cacheFile), isFalse);

      await markAudioCacheComplete(cacheFile);

      expect(isCompletedAudioCacheFile(cacheFile), isTrue);
      expect(audioCachePartialMarker(cacheFile).existsSync(), isFalse);
    },
  );

  test('caches artwork with stable keys when subsonic auth URL changes', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-artwork-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    var requestCount = 0;
    final manager = ArtworkCacheManager(
      httpClient: MockClient((request) async {
        requestCount++;
        return http.Response.bytes([1, 2, 3, 4], 200);
      }),
      cacheDirectoryProvider: () async => tempDirectory,
    );

    final first = await manager.cacheArtwork(
      'https://music.example.com/rest/getCoverArt.view?u=demo&t=one&s=a&v=1.16.1&c=zmusic&f=json&id=album-1&size=600',
    );
    final second = await manager.cacheArtwork(
      'https://music.example.com/rest/getCoverArt.view?u=demo&t=two&s=b&v=1.16.1&c=zmusic&f=json&id=album-1&size=600',
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second!.path, first!.path);
    expect(requestCount, 1);
  });

  test('does not reuse cache files without completion markers', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    final manager = AudioCacheManager();
    const track = Track(
      id: 'song-mp3',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-mp3',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceItemId: 'song-mp3',
      audioFormat: 'MP3',
    );
    final settings = AppSettings(cacheDirectory: tempDirectory.path);
    final initial = await manager.resolveForPlayback(track, settings);
    final cacheFile = initial.streamingCacheFile!;
    await cacheFile.create(recursive: true);
    await cacheFile.writeAsBytes([1, 2, 3]);

    final resolved = await manager.resolveForPlayback(track, settings);

    expect(resolved.track.streamUrl, track.streamUrl);
    expect(resolved.streamingCacheFile!.path, cacheFile.path);
    expect(cacheFile.existsSync(), isFalse);
  });

  test('repairs and reuses completed cache files missing marker', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    final manager = AudioCacheManager();
    const track = Track(
      id: 'song-replay',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-replay',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceItemId: 'song-replay',
      audioFormat: 'MP3',
    );
    final settings = AppSettings(cacheDirectory: tempDirectory.path);
    final initial = await manager.resolveForPlayback(track, settings);
    final cacheFile = initial.streamingCacheFile!;
    await cacheFile.create(recursive: true);
    await cacheFile.writeAsBytes([1, 2, 3]);
    await audioCachePartialMarker(cacheFile).delete();
    await File('${cacheFile.path}.mime').writeAsString('audio/mpeg');

    final resolved = await manager.resolveForPlayback(track, settings);

    expect(Uri.parse(resolved.track.streamUrl).scheme, 'file');
    expect(resolved.streamingCacheFile, isNull);
    expect(audioCacheCompletionMarker(cacheFile).existsSync(), isTrue);
  });

  test('reuses only cache files with completion markers', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    final manager = AudioCacheManager();
    const track = Track(
      id: 'song-mp3',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-mp3',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceItemId: 'song-mp3',
      audioFormat: 'MP3',
    );
    final settings = AppSettings(cacheDirectory: tempDirectory.path);
    final initial = await manager.resolveForPlayback(track, settings);
    final cacheFile = initial.streamingCacheFile!;
    await cacheFile.create(recursive: true);
    await cacheFile.writeAsBytes([1, 2, 3]);
    await audioCacheCompletionMarker(cacheFile).create(recursive: true);

    final resolved = await manager.resolveForPlayback(track, settings);

    expect(Uri.parse(resolved.track.streamUrl).scheme, 'file');
    expect(resolved.streamingCacheFile, isNull);
  });

  test('reuses completed cache when subsonic auth URL changes', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'zmusic-audio-cache-test-',
    );
    addTearDown(() async {
      if (tempDirectory.existsSync()) {
        await tempDirectory.delete(recursive: true);
      }
    });
    final manager = AudioCacheManager();
    const first = Track(
      id: 'https://music.example.com:song-stable',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl:
          'https://music.example.com/rest/stream.view?id=song-stable&t=one&s=aaa&format=mp3',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceServerId: 'https://music.example.com',
      sourceItemId: 'song-stable',
      audioFormat: 'MP3',
    );
    const second = Track(
      id: 'https://music.example.com:song-stable',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      streamUrl:
          'https://music.example.com/rest/stream.view?id=song-stable&t=two&s=bbb&format=mp3',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'Navidrome',
      sourceServerId: 'https://music.example.com',
      sourceItemId: 'song-stable',
      audioFormat: 'MP3',
    );
    final settings = AppSettings(cacheDirectory: tempDirectory.path);
    final initial = await manager.resolveForPlayback(first, settings);
    final cacheFile = initial.streamingCacheFile!;
    await cacheFile.create(recursive: true);
    await cacheFile.writeAsBytes([1, 2, 3]);
    await audioCacheCompletionMarker(cacheFile).create(recursive: true);

    final resolved = await manager.resolveForPlayback(second, settings);

    expect(Uri.parse(resolved.track.streamUrl).scheme, 'file');
    expect(resolved.streamingCacheFile, isNull);
    expect(Uri.parse(resolved.track.streamUrl).toFilePath(), cacheFile.path);
  });

  testWidgets(
    'music home hides source details while top status remains visible',
    (tester) async {
      tester.view.physicalSize = const Size(1264, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const server = ServerConfig(
        id: 'https://music.example.com',
        name: 'cece',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      final controller =
          AppController(store: LibraryStore(), player: PlayerController())
            ..servers = const [server]
            ..selectedServerId = server.id
            ..libraryOverview = const LibraryOverview(songCount: 2176)
            ..statusMessage = '找到 9 首歌曲。';

      await tester.pumpWidget(ZmusicApp(controller: controller));
      await tester.pump();

      expect(find.text('找到 9 首歌曲。'), findsOneWidget);
      expect(find.textContaining('音源：'), findsNothing);
      expect(find.byKey(const ValueKey('music-function-我的歌单')), findsOneWidget);
      expect(find.byKey(const ValueKey('music-function-公开歌单')), findsOneWidget);
    },
  );

  testWidgets('settings page shows account summary without source manager', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'cece',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..libraryOverview = const LibraryOverview(songCount: 2176);
    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('demo'), findsOneWidget);
    expect(find.text('歌曲数：2176'), findsOneWidget);
    expect(find.byKey(const ValueKey('logout-button')), findsOneWidget);
    expect(find.text('音源'), findsNothing);
    expect(find.text('导入'), findsNothing);
    expect(find.text('添加'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('settings customizes the home layout on a narrow screen', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _MemoryLibraryStore();
    final controller = AppController(store: store, player: PlayerController());

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);

    expect(find.text('首页布局'), findsOneWidget);
    expect(compactSwitchScale, 0.8);
    expect(find.text('歌单板块'), findsNothing);
    final favoritesSwitch = find.byKey(
      const ValueKey('home-shortcut-favorites-visible'),
    );
    await tester.ensureVisible(favoritesSwitch);
    await tester.tap(favoritesSwitch);
    await tester.pumpAndSettle();

    expect(
      controller.settings.hiddenHomeShortcuts,
      contains(HomeShortcutSection.favorites),
    );

    final moveRadioUp = find.byKey(
      const ValueKey('home-shortcut-publicRadio-up'),
    );
    await tester.ensureVisible(moveRadioUp);
    await tester.tap(moveRadioUp);
    await tester.pumpAndSettle();

    expect(controller.settings.homeShortcutOrder, [
      HomeShortcutSection.favorites,
      HomeShortcutSection.myPlaylists,
      HomeShortcutSection.publicRadio,
      HomeShortcutSection.publicPlaylists,
    ]);

    final myPlaylistSectionSwitch = find.byKey(
      const ValueKey('home-my-playlists-section-visible'),
    );
    await tester.ensureVisible(myPlaylistSectionSwitch);
    await tester.tap(myPlaylistSectionSwitch);
    await tester.pumpAndSettle();

    expect(controller.settings.showMyPlaylistSection, isFalse);
    expect(store.savedSettings?.showMyPlaylistSection, isFalse);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('home layout master switches toggle and collapse each group', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1264, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _MemoryLibraryStore();
    final controller = AppController(store: store, player: PlayerController());

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    Future<void> tapVisible(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    final shortcutMaster = find.byKey(
      const ValueKey('home-shortcut-all-visible'),
    );
    await tapVisible(shortcutMaster);
    expect(controller.settings.showDailyRecommendation, isFalse);
    expect(
      controller.settings.hiddenHomeShortcuts,
      containsAll(HomeShortcutSection.values),
    );
    expect(
      find.byKey(const ValueKey('home-shortcut-favorites-visible')),
      findsNothing,
    );
    await tapVisible(shortcutMaster);
    expect(controller.settings.showDailyRecommendation, isTrue);
    expect(controller.settings.hiddenHomeShortcuts, isEmpty);

    final discoveryMaster = find.byKey(
      const ValueKey('home-discovery-all-visible'),
    );
    await tapVisible(discoveryMaster);
    expect(
      controller.settings.hiddenHomeDiscoveries,
      containsAll(HomeDiscoverySection.values),
    );
    expect(
      find.byKey(const ValueKey('home-discovery-latestAlbums-visible')),
      findsNothing,
    );
    await tapVisible(discoveryMaster);
    expect(controller.settings.hiddenHomeDiscoveries, isEmpty);

    final playlistMaster = find.byKey(
      const ValueKey('home-playlist-sections-all-visible'),
    );
    await tapVisible(playlistMaster);
    expect(controller.settings.showMyPlaylistSection, isFalse);
    expect(controller.settings.showPublicPlaylistSection, isFalse);
    expect(
      find.byKey(const ValueKey('home-my-playlists-section-visible')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('home-public-playlists-section-visible')),
      findsNothing,
    );
    await tapVisible(playlistMaster);
    expect(controller.settings.showMyPlaylistSection, isTrue);
    expect(controller.settings.showPublicPlaylistSection, isTrue);
    expect(
      find.byKey(const ValueKey('home-my-playlists-section-visible')),
      findsOneWidget,
    );
    expect(find.text('歌单板块'), findsNothing);
    expect(store.savedSettings, isNotNull);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('settings page shows package version without build number', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Zmusic',
      packageName: 'com.zmusic.app',
      version: '9.8.7',
      buildNumber: '42',
      buildSignature: '',
    );
    addTearDown(() {
      PackageInfo.setMockInitialValues(
        appName: 'Zmusic',
        packageName: 'com.zmusic.app',
        version: '1.0.14',
        buildNumber: '19',
        buildSignature: '',
      );
    });

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    expect(find.text('版本：9.8.7'), findsOneWidget);
    expect(find.textContaining('+42'), findsNothing);
  });

  testWidgets('settings can disable startup update checks', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = _MemoryLibraryStore();
    final controller = AppController(store: store, player: PlayerController());

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    final startupCheckSwitch = find.byKey(
      const ValueKey('check-updates-on-startup'),
    );
    expect(find.text('启动时检查更新'), findsOneWidget);
    expect(controller.settings.checkUpdatesOnStartup, isTrue);
    await tester.ensureVisible(startupCheckSwitch);
    await tester.pumpAndSettle();
    await tester.tap(startupCheckSwitch);
    await tester.pumpAndSettle();

    expect(controller.settings.checkUpdatesOnStartup, isFalse);
    expect(store.savedSettings?.checkUpdatesOnStartup, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('startup update check shows remote release information', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var requestCount = 0;
    final service = AppUpdateService(
      httpClient: MockClient((request) async {
        requestCount += 1;
        expect(request.url, appUpdateManifestUri);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'appName': 'zmusic',
              'platforms': {
                'windows': {
                  'latestVersion': '1.0.15',
                  'versionCode': 115,
                  'downloadUrl':
                      'https://file.zuitimes.com/zmusic/1.0.15/zmusic-windows-x64.exe',
                  'fileName': 'zmusic-windows-x64.exe',
                  'updateContent': ['启动自动检查更新'],
                  'releaseTime': '2026-07-16',
                },
              },
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final controller =
        AppController(
            store: LibraryStore(),
            player: PlayerController(),
            updateService: service,
          )
          ..settings = const AppSettings(checkUpdatesOnStartup: true)
          ..isInitialized = true;

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pumpAndSettle();

    expect(requestCount, 1);
    expect(find.text('发现新版本 1.0.15'), findsOneWidget);
    expect(find.text('• 启动自动检查更新'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('settings update check shows remote release information', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var requestCount = 0;
    final downloadUri = Uri.parse(
      'https://file.zuitimes.com/zmusic/1.0.15/zmusic-windows-x64.exe',
    );
    final downloadResponse = Completer<http.Response>();
    addTearDown(() {
      if (!downloadResponse.isCompleted) {
        downloadResponse.complete(http.Response.bytes(const [], 500));
      }
    });
    final service = AppUpdateService(
      httpClient: MockClient((request) async {
        if (request.url == downloadUri) {
          return downloadResponse.future;
        }
        requestCount += 1;
        expect(request.url, appUpdateManifestUri);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'appName': 'zmusic',
              'platforms': {
                'windows': {
                  'latestVersion': '1.0.15',
                  'versionCode': 115,
                  'downloadUrl': downloadUri.toString(),
                  'fileName': 'zmusic-windows-x64.exe',
                  'updateContent': ['修复播放详情跳转', '优化更新检查'],
                  'releaseTime': '2026-07-14',
                },
              },
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
      updateService: service,
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    final checkButton = find.byKey(const ValueKey('check-for-updates'));
    await tester.ensureVisible(checkButton);
    await tester.pumpAndSettle();
    await tester.tap(checkButton);
    await tester.pumpAndSettle();

    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    expect(requestCount, 1);
    expect(visibleText, contains('发现新版本 1.0.15'));
    expect(find.text('当前版本：1.0.14'), findsOneWidget);
    expect(find.text('发布时间：2026-07-14'), findsOneWidget);
    expect(find.text('• 修复播放详情跳转'), findsOneWidget);
    expect(find.text('下载更新'), findsOneWidget);

    await tester.tap(find.text('下载更新'));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('正在下载更新'), findsOneWidget);
    expect(find.text('下载中'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('account settings fit phone width without overflow', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com',
      name: '一个很长的 Navidrome 音源名称',
      baseUrl: 'https://music.example.com/library/navaidrome/very/long/path',
      username: 'demo',
      password: 'secret',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..libraryOverview = const LibraryOverview(songCount: 2176);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    final accountRect = tester.getRect(find.text('demo').first);
    expect(accountRect.left, greaterThanOrEqualTo(0));
    expect(accountRect.right, lessThanOrEqualTo(390));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('logout-button')), findsOneWidget);
    expect(find.text('音源'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android phone settings actions are trailing and borderless', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'cece',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..libraryOverview = const LibraryOverview(songCount: 2176);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    Future<void> expectTrailingAction(String key, String title) async {
      final action = find.byKey(ValueKey<String>(key));
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();

      final button = tester.widget<TextButton>(action);
      final actionRect = tester.getRect(action);
      final titleRect = tester.getRect(find.text(title).first);
      expect(button.style?.side, isNull);
      expect(actionRect.left, greaterThan(titleRect.right));
      expect(actionRect.top, lessThanOrEqualTo(titleRect.bottom));
    }

    await expectTrailingAction('logout-button', 'demo');
    await expectTrailingAction('settings-logo-upload', '应用 Logo');
    await expectTrailingAction('settings-background-upload', '背景图');
    await expectTrailingAction('settings-cache-directory-select', '缓存目录');
    await expectTrailingAction('check-for-updates', '检查更新');

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mobile settings show only account actions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'cece',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..libraryOverview = const LibraryOverview(songCount: 2176);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    expect(find.text('账号'), findsOneWidget);
    expect(find.text('demo'), findsOneWidget);
    expect(find.text('歌曲数：2176'), findsOneWidget);
    expect(find.byKey(const ValueKey('logout-button')), findsOneWidget);
    expect(find.text('导入'), findsNothing);
    expect(find.text('添加'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('login form fits narrow phones and hides the server URL', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..settings = const AppSettings(checkUpdatesOnStartup: false)
          ..isInitialized = true;

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    for (final key in const [
      ValueKey('login-username'),
      ValueKey('login-password'),
      ValueKey('login-submit'),
    ]) {
      final rect = tester.getRect(find.byKey(key));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    }
    final usernameField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('login-username')),
        matching: find.byType(TextField),
      ),
    );
    final passwordField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('login-password')),
        matching: find.byType(TextField),
      ),
    );
    expect(usernameField.decoration?.labelText, isNull);
    expect(usernameField.decoration?.hintText, '账号');
    expect(usernameField.decoration?.prefixIcon, isA<Icon>());
    expect(passwordField.decoration?.labelText, isNull);
    expect(passwordField.decoration?.hintText, '密码');
    expect(passwordField.decoration?.prefixIcon, isA<Icon>());
    expect(passwordField.decoration?.suffixIcon, isA<IconButton>());
    expect(find.byKey(const ValueKey('login-server-url')), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('five title taps reveal and hide the editable server URL', (
    tester,
  ) async {
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..settings = const AppSettings(checkUpdatesOnStartup: false)
          ..isInitialized = true;

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(find.byKey(const ValueKey('login-server-url')), findsNothing);
    expect(find.byKey(const ValueKey('login-logo')), findsNothing);
    final title = find.byKey(const ValueKey('login-title'));
    expect(title, findsOneWidget);
    final titleText = tester.widget<Text>(
      find.descendant(of: title, matching: find.byType(Text)),
    );
    final titleContext = tester.element(title);
    expect(
      titleText.style?.fontSize,
      (Theme.of(titleContext).textTheme.headlineSmall?.fontSize ?? 24) + 2,
    );
    for (var index = 0; index < 5; index += 1) {
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 20));
    }

    final serverField = find.byKey(const ValueKey('login-server-url'));
    expect(serverField, findsOneWidget);
    expect(
      tester.widget<TextFormField>(serverField).controller?.text,
      defaultMusicServerUrl,
    );
    await tester.tap(find.byKey(const ValueKey('login-hide-server-url')));
    await tester.pump();
    expect(find.byKey(const ValueKey('login-server-url')), findsNothing);
    expect(find.byKey(const ValueKey('login-hide-server-url')), findsNothing);
  });

  testWidgets('account settings use HD layout at android sw510dp', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(510, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'cece',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..libraryOverview = const LibraryOverview(songCount: 2176);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    final accountRect = tester.getRect(find.text('demo').first);
    expect(accountRect.left, greaterThanOrEqualTo(0));
    expect(accountRect.right, lessThanOrEqualTo(510));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('logout-button')), findsOneWidget);
    expect(find.text('添加本地'), findsNothing);
    expect(find.text('音源'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android settings never expose local source actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(510, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com',
      name: 'cece',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..libraryOverview = const LibraryOverview(songCount: 2176);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);
    await tester.pumpAndSettle();

    expect(find.text('demo'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('添加本地'), findsNothing);
    expect(find.text('音源'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('uses segmented loading indicator inside seek thumb', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: _BufferingPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final segmentedIndicator = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where(
          (paint) =>
              paint.painter.runtimeType.toString().contains('SegmentedLoading'),
        )
        .single;

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(segmentedIndicator.painter.toString(), contains('segments: 12'));
  });

  testWidgets('uses slider secondary track for cached progress', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: _BufferingPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final slider = tester
        .widgetList<Slider>(find.byType(Slider))
        .singleWhere((slider) => slider.max > 1);
    final sliderTheme = tester.widget<SliderTheme>(
      find.byType(SliderTheme).last,
    );

    expect(slider.secondaryTrackValue, 30000);
    expect(sliderTheme.data.inactiveTrackColor, isNotNull);
    expect(sliderTheme.data.secondaryActiveTrackColor, isNotNull);
    expect(sliderTheme.data.activeTrackColor, isNotNull);
  });

  testWidgets('uses cached progress value ahead of played position', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: _BufferedAheadPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final slider = tester
        .widgetList<Slider>(find.byType(Slider))
        .singleWhere((slider) => slider.max > 1);

    expect(slider.value, 2000);
    expect(slider.secondaryTrackValue, 240000);
  });

  testWidgets('keeps buffered progress track visually thin after seeking', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: _BufferedAheadPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final oversizedBufferedTracks = tester
        .widgetList<Container>(find.byType(Container))
        .where((container) {
          final decoration = container.decoration;
          if (decoration is! BoxDecoration) {
            return false;
          }
          final color = decoration.color;
          final height = container.constraints?.minHeight ?? 0;
          return height > 6 &&
              color != null &&
              color.a >= 0.55 &&
              '${decoration.borderRadius}'.contains('999');
        });

    expect(oversizedBufferedTracks, isEmpty);
  });

  testWidgets('commits progress seek on drag end', (tester) async {
    final controller = AppController(
      store: LibraryStore(),
      player: _BufferedAheadPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final slider = tester
        .widgetList<Slider>(find.byType(Slider))
        .singleWhere((slider) => slider.max > 1);

    expect(slider.onChanged, isNotNull);
    expect(slider.onChangeEnd, isNotNull);
  });

  testWidgets('does not show search input on search results page', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );
    controller.servers = const [
      ServerConfig(
        id: 'local:D:\\Music',
        name: 'Local',
        baseUrl: '',
        username: '',
        password: '',
        sourceKind: MusicSourceKind.localFolder,
        localPath: r'D:\Music',
      ),
    ];
    controller.selectedServerId = 'local:D:\\Music';
    controller.localTracks = const [
      Track(
        id: 'local-song',
        title: '画沙',
        artist: '周杰伦',
        album: 'Album',
        streamUrl: 'file:///D:/Music/song.mp3',
        sourceType: MusicSourceType.localFile,
        sourceName: 'Local',
        sourceItemId: r'D:\Music\song.mp3',
      ),
    ];

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.enterText(find.byType(TextField), '画沙');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('搜索结果'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('歌曲'), findsOneWidget);
    expect(find.text('歌手'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('歌曲 1'), findsNothing);
    expect(find.text('歌手 0'), findsNothing);
    expect(find.text('专辑 0'), findsNothing);
  });

  testWidgets('opens the music tab by default with focused library shortcuts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [
            ServerConfig(
              id: 'https://music.example.com',
              name: 'cece',
              baseUrl: 'https://music.example.com',
              username: 'demo',
              password: 'secret',
            ),
          ]
          ..selectedServerId = 'https://music.example.com'
          ..libraryOverview = const LibraryOverview(songCount: 2176);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(find.textContaining('音源：'), findsNothing);
    expect(find.byKey(const ValueKey('music-function-歌曲')), findsNothing);
    expect(find.byKey(const ValueKey('music-function-专辑')), findsNothing);
    expect(find.byKey(const ValueKey('music-function-歌手')), findsNothing);
    expect(find.byKey(const ValueKey('music-function-公开歌单')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-function-我喜欢的')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-function-我的歌单')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-function-电台')), findsOneWidget);
    expect(find.byTooltip('刷新我喜欢的'), findsOneWidget);
    expect(find.byTooltip('刷新我的歌单'), findsOneWidget);
    expect(find.byTooltip('刷新公开歌单'), findsOneWidget);
    expect(find.byTooltip('刷新电台'), findsOneWidget);
  });

  testWidgets('music tab previews nine playlists and more opens full list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final playlists = List<LibrarySectionItem>.generate(
      10,
      (index) => LibrarySectionItem(
        id: 'playlist-${index + 1}',
        title: '歌单 ${index + 1}',
        subtitle: '${index + 1} 首歌曲',
        type: LibrarySectionType.playlists,
        owner: 'demo',
      ),
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [
            ServerConfig(
              id: 'https://music.example.com',
              name: 'cece',
              baseUrl: 'https://music.example.com',
              username: 'demo',
              password: 'secret',
            ),
          ]
          ..selectedServerId = 'https://music.example.com'
          ..libraryOverview = LibraryOverview(playlists: playlists);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byTooltip('更多歌单'),
      240,
      scrollable: find.byType(Scrollable).first,
    );

    for (var index = 1; index <= 9; index++) {
      expect(find.text('歌单 $index'), findsOneWidget);
    }
    expect(find.text('歌单 10'), findsNothing);
    final createButton = find.byTooltip('新建歌单');
    final createIconButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '新建歌单',
    );
    final moreButton = find.byTooltip('更多歌单');
    expect(createButton, findsOneWidget);
    expect(moreButton, findsOneWidget);
    expect(
      tester
          .widget<IconButton>(createIconButton)
          .style
          ?.backgroundColor
          ?.resolve({}),
      isNull,
    );
    expect(
      tester.getCenter(createButton).dx,
      lessThan(tester.getCenter(moreButton).dx),
    );

    await tester.tap(moreButton);
    await tester.pumpAndSettle();

    expect(find.text('歌单 10'), findsOneWidget);
    expect(find.byTooltip('返回音乐库'), findsOneWidget);
    expect(find.byTooltip('同步外部歌单'), findsOneWidget);
    expect(find.byTooltip('合并歌单'), findsOneWidget);
    expect(find.byTooltip('批量添加歌曲'), findsOneWidget);
    for (final tooltip in const ['同步外部歌单', '合并歌单', '批量添加歌曲']) {
      final toolButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      );
      expect(
        tester
            .widget<IconButton>(toolButton)
            .style
            ?.backgroundColor
            ?.resolve({}),
        isNull,
      );
    }
  });

  testWidgets('playlist tools use pages and transfer only selected tracks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com|demo',
      name: 'Zmusic',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    const source = LibrarySectionItem(
      id: 'source',
      title: '来源列表',
      type: LibrarySectionType.playlists,
      owner: 'demo',
    );
    const target = LibrarySectionItem(
      id: 'target',
      title: '目标列表',
      type: LibrarySectionType.playlists,
      owner: 'demo',
    );
    Map<String, Object?> song(
      String id,
      String title, {
      String suffix = 'flac',
    }) => {
      'id': id,
      'title': title,
      'artist': '测试歌手',
      'album': '不应显示的专辑',
      'suffix': suffix,
    };

    final sourceSongIds = <String>['song-1', 'song-2'];
    final targetSongIds = <String>{'song-2'};
    final searchOffsets = <int>[];
    final updateRequests = <Uri>[];
    final client = MockClient((request) async {
      final method = request.url.pathSegments.last.replaceAll('.view', '');
      if (method == 'getPlaylist') {
        final playlistId = request.url.queryParameters['id'];
        final entries = playlistId == source.id
            ? [
                for (final id in sourceSongIds)
                  song(id, id == 'song-1' ? '来源歌曲一' : '重复歌曲二'),
              ]
            : [
                for (final id in targetSongIds)
                  song(id, switch (id) {
                    'song-1' => '来源歌曲一',
                    'song-2' => '重复歌曲二',
                    _ => '曲库新增歌曲',
                  }),
              ];
        return _subsonicJsonResponse({
          'playlist': {'id': playlistId, 'name': '歌单', 'entry': entries},
        });
      }
      if (method == 'search3') {
        final offset =
            int.tryParse(request.url.queryParameters['songOffset'] ?? '') ?? 0;
        searchOffsets.add(offset);
        final entries = offset == 0
            ? [
                song('song-3', '曲库新增歌曲', suffix: 'ape'),
                for (var index = 4; index <= 62; index += 1)
                  song('song-$index', '曲库歌曲 $index'),
              ]
            : [song('song-63', '第二页歌曲')];
        return _subsonicJsonResponse({
          'searchResult3': {'song': entries},
        });
      }
      if (method == 'updatePlaylist') {
        updateRequests.add(request.url);
        final playlistId = request.url.queryParameters['playlistId'];
        if (playlistId == target.id) {
          targetSongIds.addAll(
            request.url.queryParametersAll['songIdToAdd'] ?? const [],
          );
        } else if (playlistId == source.id) {
          final indexes =
              (request.url.queryParametersAll['songIndexToRemove'] ??
                      const <String>[])
                  .map(int.parse)
                  .toList()
                ..sort((left, right) => right.compareTo(left));
          for (final index in indexes) {
            sourceSongIds.removeAt(index);
          }
        }
        return _subsonicJsonResponse({});
      }
      return _subsonicJsonResponse({});
    });
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..libraryOverview = const LibraryOverview(playlists: [source, target])
          ..apiClientFactory = (config) =>
              SubsonicApiClient(server: config, httpClient: client);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('music-function-我的歌单')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('同步外部歌单'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playlist-sync-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist-sync-name')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final syncUrl = find.byKey(const ValueKey('playlist-sync-url'));
    expect(tester.widget<TextField>(syncUrl).decoration?.labelText, isNull);
    expect(
      tester.getBottomLeft(find.text('网易云音乐 / QQ 音乐歌单地址')).dy,
      lessThanOrEqualTo(tester.getTopLeft(syncUrl).dy),
    );
    expect(tester.getSize(syncUrl).height, lessThan(50));
    expect(
      tester
          .widget<CompactSwitchListTile>(
            find.byKey(const ValueKey('playlist-sync-different-artist')),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<CompactSwitchListTile>(
            find.byKey(const ValueKey('playlist-sync-high-quality')),
          )
          .value,
      isFalse,
    );

    await tester.tap(find.byTooltip('返回我的歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('合并歌单'));
    await tester.pumpAndSettle();

    final mergeLeft = find.byKey(const ValueKey('playlist-merge-source-pane'));
    final mergeRight = find.byKey(const ValueKey('playlist-merge-target-pane'));
    expect(find.byKey(const ValueKey('playlist-merge-page')), findsOneWidget);
    expect(
      tester.getCenter(mergeLeft).dx,
      lessThan(tester.getCenter(mergeRight).dx),
    );
    expect(find.text('不应显示的专辑'), findsNothing);
    final sourceSelector = find.byKey(const ValueKey('选择来源歌单:source'));
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(sourceSelector)
          .decoration
          .labelText,
      isNull,
    );
    expect(find.text('选择来源歌单'), findsNothing);
    expect(find.text('选择目标歌单'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playlist-transfer-swap')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('选择来源歌单:target')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-transfer-swap')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('选择来源歌单:source')), findsOneWidget);

    await tester.tap(
      find.byKey(
        const ValueKey(
          'playlist-tool-track-https://music.example.com|demo:song-1',
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('playlist-transfer-move')),
          )
          .style
          ?.backgroundColor
          ?.resolve({}),
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('playlist-transfer-move')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlist-merge-confirmation')),
      findsOneWidget,
    );
    final keepInSource = find.byKey(
      const ValueKey('playlist-merge-keep-source'),
    );
    expect(tester.widget<CheckboxListTile>(keepInSource).value, isTrue);
    await tester.tap(keepInSource);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('playlist-merge-confirm')));
    await tester.pumpAndSettle();

    expect(updateRequests, hasLength(2));
    expect(updateRequests[0].queryParameters['playlistId'], target.id);
    expect(updateRequests[0].queryParametersAll['songIdToAdd'], ['song-1']);
    expect(updateRequests[1].queryParameters['playlistId'], source.id);
    expect(updateRequests[1].queryParametersAll['songIndexToRemove'], ['0']);
    expect(sourceSongIds, ['song-2']);

    await tester.tap(find.byTooltip('返回我的歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量添加歌曲'));
    await tester.pumpAndSettle();

    final batchLeft = find.byKey(const ValueKey('playlist-batch-library-pane'));
    final batchRight = find.byKey(const ValueKey('playlist-batch-target-pane'));
    expect(
      find.byKey(const ValueKey('playlist-batch-add-page')),
      findsOneWidget,
    );
    expect(
      tester.getCenter(batchLeft).dx,
      lessThan(tester.getCenter(batchRight).dx),
    );
    final librarySearchButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '搜索曲库',
    );
    expect(
      tester
          .widget<IconButton>(librarySearchButton)
          .style
          ?.backgroundColor
          ?.resolve({}),
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('batch-target:source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标列表').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('playlist-batch-search')),
      '新增',
    );
    await tester.tap(find.byTooltip('搜索曲库'));
    await tester.pumpAndSettle();
    expect(searchOffsets, [0]);
    expect(
      find.byKey(const ValueKey('playlist-search-pagination')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('playlist-search-next')));
    await tester.pumpAndSettle();
    expect(searchOffsets, [0, 60]);
    expect(find.text('第二页歌曲'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-search-previous')));
    await tester.pumpAndSettle();
    expect(searchOffsets, [0, 60, 0]);
    await tester.tap(
      find.byKey(
        const ValueKey(
          'playlist-tool-track-https://music.example.com|demo:song-3',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('playlist-transfer-move')));
    await tester.pumpAndSettle();

    expect(updateRequests, hasLength(3));
    expect(updateRequests.last.queryParameters['playlistId'], target.id);
    expect(updateRequests.last.queryParametersAll['songIdToAdd'], ['song-3']);
  });

  testWidgets('android phone playlist tools use sequential transfer steps', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com|demo',
      name: 'Zmusic',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    const playlists = [
      LibrarySectionItem(
        id: 'source',
        title: '来源列表',
        type: LibrarySectionType.playlists,
        owner: 'demo',
      ),
      LibrarySectionItem(
        id: 'target',
        title: '目标列表',
        type: LibrarySectionType.playlists,
        owner: 'demo',
      ),
    ];
    final client = MockClient((request) async {
      final method = request.url.pathSegments.last.replaceAll('.view', '');
      if (method == 'search3') {
        return _subsonicJsonResponse({
          'searchResult3': {
            'song': [
              {
                'id': 'search-song',
                'title': '曲库歌曲',
                'artist': '测试歌手',
                'suffix': 'flac',
              },
            ],
          },
        });
      }
      final playlistId = request.url.queryParameters['id'];
      return _subsonicJsonResponse({
        'playlist': {
          'id': playlistId,
          'name': '歌单',
          'entry': playlistId == 'source'
              ? [
                  {
                    'id': 'source-song',
                    'title': '来源歌曲',
                    'artist': '测试歌手',
                    'suffix': 'mp3',
                  },
                ]
              : <Object?>[],
        },
      });
    });
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..apiClientFactory = (config) =>
              SubsonicApiClient(server: config, httpClient: client);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistMergePage(
            controller: controller,
            playlists: playlists,
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final mergeSource = find.byKey(
      const ValueKey('playlist-merge-source-pane'),
    );
    final mergeTarget = find.byKey(
      const ValueKey('playlist-merge-target-pane'),
    );
    expect(mergeSource, findsOneWidget);
    expect(mergeTarget, findsNothing);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('playlist-transfer-continue')),
          )
          .onPressed,
      isNull,
    );
    expect(find.byIcon(Icons.swap_vert_rounded), findsNothing);
    expect(find.byKey(const ValueKey('playlist-transfer-swap')), findsNothing);

    await tester.tap(
      find.byKey(
        const ValueKey(
          'playlist-tool-track-https://music.example.com|demo:source-song',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('playlist-transfer-continue')));
    await tester.pump();

    expect(mergeSource, findsNothing);
    expect(mergeTarget, findsOneWidget);
    expect(
      find.byKey(const ValueKey('playlist-transfer-complete')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('playlist-transfer-back')));
    await tester.pump();
    expect(mergeSource, findsOneWidget);
    expect(mergeTarget, findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistBatchAddPage(
            controller: controller,
            playlists: playlists,
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final batchSource = find.byKey(
      const ValueKey('playlist-batch-library-pane'),
    );
    final batchTarget = find.byKey(
      const ValueKey('playlist-batch-target-pane'),
    );
    expect(batchSource, findsOneWidget);
    expect(batchTarget, findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('playlist-batch-search')),
      '曲库',
    );
    await tester.tap(find.byTooltip('搜索曲库'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey(
          'playlist-tool-track-https://music.example.com|demo:search-song',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('playlist-transfer-continue')));
    await tester.pump();

    expect(batchSource, findsNothing);
    expect(batchTarget, findsOneWidget);
    expect(
      find.byKey(const ValueKey('playlist-transfer-complete')),
      findsOneWidget,
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('radio shortcut opens stations and plays the selected stream', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final player = _RecordingPlayerController();
    final controller = AppController(store: LibraryStore(), player: player)
      ..servers = const [
        ServerConfig(
          id: 'https://music.example.com',
          name: 'cece',
          baseUrl: 'https://music.example.com',
          username: 'demo',
          password: 'secret',
        ),
      ]
      ..selectedServerId = 'https://music.example.com'
      ..libraryOverview = const LibraryOverview(
        radioStations: [
          LibrarySectionItem(
            id: 'radio-1',
            title: 'Jazz Radio',
            subtitle: 'https://radio.example.com/live.mp3',
            type: LibrarySectionType.radio,
          ),
          LibrarySectionItem(
            id: 'radio-2',
            title: 'News Radio',
            subtitle: 'https://radio.example.com/news.mp3',
            type: LibrarySectionType.radio,
          ),
          LibrarySectionItem(
            id: 'radio-3',
            title: 'Classic Radio',
            subtitle: 'https://radio.example.com/classic.mp3',
            type: LibrarySectionType.radio,
          ),
        ],
      );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('music-function-电台')),
        matching: find.text('电台'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('https://radio.example.com/live.mp3'), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-browse-title')))
          .data,
      '电台',
    );
    expect(find.text('电台'), findsWidgets);

    await tester.tap(find.text('Jazz Radio'));
    await tester.pumpAndSettle();

    expect(player.playedTrack?.title, 'Jazz Radio');
    expect(player.playedTrack?.artist, '电台');
    expect(player.playedTrack?.streamUrl, 'https://radio.example.com/live.mp3');
    expect(player.playedTrack?.sourceType, MusicSourceType.customStream);
    expect(player.playedTrack?.sourceItemId, 'radio:radio-1');
    expect(player.playedTracks.map((track) => track.title), [
      'Jazz Radio',
      'News Radio',
      'Classic Radio',
    ]);
    expect(player.playedIndex, 0);
  });

  testWidgets('radio playback disables song-only controls and lists channels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final player = PlayerController()..setPlaybackMode(PlaybackMode.shuffle);
    final controller = AppController(store: LibraryStore(), player: player)
      ..servers = const [
        ServerConfig(
          id: 'https://music.example.com',
          name: 'cece',
          baseUrl: 'https://music.example.com',
          username: 'demo',
          password: 'secret',
        ),
      ]
      ..selectedServerId = 'https://music.example.com'
      ..libraryOverview = const LibraryOverview(
        radioStations: [
          LibrarySectionItem(
            id: 'radio-1',
            title: 'Jazz Radio',
            subtitle: 'https://radio.example.com/jazz.mp3',
            type: LibrarySectionType.radio,
          ),
          LibrarySectionItem(
            id: 'radio-2',
            title: 'News Radio',
            subtitle: 'https://radio.example.com/news.mp3',
            type: LibrarySectionType.radio,
          ),
          LibrarySectionItem(
            id: 'radio-3',
            title: 'Classic Radio',
            subtitle: 'https://radio.example.com/classic.mp3',
            type: LibrarySectionType.radio,
          ),
        ],
      );

    await controller.playRadioStation(
      controller.libraryOverview.radioStations[1],
    );
    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(player.playbackMode, PlaybackMode.sequential);
    expect(player.queue.map((track) => track.title), [
      'Jazz Radio',
      'News Radio',
      'Classic Radio',
    ]);
    expect(player.currentTrack?.title, 'News Radio');

    final seekBar = find.byKey(const ValueKey('player-seek-bar'));
    expect(
      find.descendant(of: seekBar, matching: find.text('00:00')),
      findsNWidgets(2),
    );
    expect(
      tester
          .widget<Slider>(
            find.descendant(of: seekBar, matching: find.byType(Slider)),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '顺序播放',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '电台不支持收藏',
            ),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byTooltip('列表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final sidePanel = find.byKey(const ValueKey('queue-side-panel'));
    expect(sidePanel, findsOneWidget);
    expect(
      find.descendant(of: sidePanel, matching: find.text('电台频道')),
      findsOneWidget,
    );
    for (final title in ['Jazz Radio', 'News Radio', 'Classic Radio']) {
      expect(
        find.descendant(of: sidePanel, matching: find.text(title)),
        findsOneWidget,
      );
    }
  });

  testWidgets('library browse pagination is not wrapped in a glass surface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..libraryOverview = LibraryOverview(
            radioStations: [
              for (var index = 0; index < 19; index++)
                LibrarySectionItem(
                  id: 'radio-$index',
                  title: 'Radio $index',
                  subtitle: 'https://radio.example.com/$index.mp3',
                  type: LibrarySectionType.radio,
                ),
            ],
          );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('music-function-电台')),
        matching: find.text('电台'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();

    final pagination = find.byKey(const ValueKey('library-pagination-bar'));
    expect(pagination, findsOneWidget);
    expect(
      find.ancestor(
        of: pagination,
        matching: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_GlassSurface',
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('favorite shortcut opens the loaded favorite songs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..libraryOverview = const LibraryOverview(
            favoriteTracks: [
              Track(
                id: 'favorite-1',
                title: 'Favorite Song',
                artist: 'Singer',
                album: 'Album',
                streamUrl: 'https://music.example.com/rest/stream.view?id=1',
                sourceType: MusicSourceType.subsonic,
                sourceName: 'cece',
                sourceServerId: 'https://music.example.com',
                sourceItemId: '1',
              ),
            ],
          );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('music-function-我喜欢的')),
        matching: find.text('我喜欢的'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('返回音乐库'), findsOneWidget);
    expect(find.text('我喜欢的'), findsWidgets);
    expect(find.text('Favorite Song'), findsOneWidget);
    expect(find.text('Singer'), findsOneWidget);
    expect(find.text('Album'), findsNothing);
    expect(find.text('cece'), findsNothing);
  });

  testWidgets('favorite and daily shortcut play buttons replace the queue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const favorite = Track(
      id: 'favorite-play',
      title: 'Favorite Play',
      artist: 'Singer',
      album: 'Album',
      streamUrl: 'https://music.example.com/favorite-play',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'cece',
    );
    const recommendation = Track(
      id: 'daily-play',
      title: 'Daily Play',
      artist: 'Singer',
      album: 'Album',
      streamUrl: 'https://music.example.com/daily-play',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'cece',
    );
    final player = _RecordingPlayerController();
    final controller = AppController(store: LibraryStore(), player: player)
      ..libraryOverview = const LibraryOverview(favoriteTracks: [favorite])
      ..recommendedTracks = const [recommendation];

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    await tester.tap(find.byTooltip('播放我喜欢的'));
    await tester.pump();
    expect(player.playedTracks, [favorite]);

    await tester.tap(find.byTooltip('播放每日推荐'));
    await tester.pump();
    expect(player.playedTracks, [recommendation]);
  });

  testWidgets('mobile home tabs move to the app bar like desktop', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    )..statusMessage = '已加载 fnnav 的库信息，歌曲数：2494。';

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(find.text('已加载 fnnav 的库信息，歌曲数：2494。'), findsNothing);
    expect(find.text('Zmusic'), findsNothing);
    expect(find.byTooltip('设置'), findsNothing);
    expect(
      tester.getTopLeft(find.byIcon(Icons.settings_rounded).first).dy,
      lessThan(90),
    );

    await openSettingsTab(tester);

    expect(find.text('设置'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'mobile playlist shortcut opens playlist browse without duplicate section',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller =
          AppController(store: LibraryStore(), player: PlayerController())
            ..servers = const [
              ServerConfig(
                id: 'https://music.example.com',
                name: 'cece',
                baseUrl: 'https://music.example.com',
                username: 'demo',
                password: 'secret',
              ),
            ]
            ..selectedServerId = 'https://music.example.com'
            ..libraryOverview = const LibraryOverview(
              playlists: [
                LibrarySectionItem(
                  id: 'mine',
                  title: '国风',
                  subtitle: '24 首歌曲',
                  type: LibrarySectionType.playlists,
                  isPublic: false,
                  owner: 'demo',
                ),
              ],
            );

      await tester.pumpWidget(ZmusicApp(controller: controller));
      await tester.pump();

      expect(find.text('我的歌单'), findsWidgets);
      expect(find.byKey(const ValueKey('music-function-我的歌单')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('music-function-我的歌单')));
      await tester.pumpAndSettle();

      expect(find.byTooltip('返回音乐库'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('library-browse-title')))
            .data,
        '我的歌单',
      );
      expect(find.text('国风'), findsOneWidget);

      await tester.tap(find.text('国风').first);
      await tester.pumpAndSettle();

      final detailBack = find.byTooltip('返回音乐库');
      final detailHeader = find.byKey(const ValueKey('remote-playlist-header'));
      expect(detailHeader, findsOneWidget);
      expect(
        tester.getTopLeft(detailBack).dy,
        lessThan(tester.getTopLeft(detailHeader).dy),
      );
      expect(find.text('我的歌单'), findsOneWidget);
      expect(find.byTooltip('播放全部'), findsOneWidget);
      expect(find.byTooltip('添加歌曲'), findsOneWidget);
      expect(find.byTooltip('编辑歌单'), findsOneWidget);
      expect(find.byTooltip('删除歌单'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '播放全部'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '添加歌曲'), findsNothing);
      final actionCenters = [
        tester.getCenter(find.byTooltip('添加歌曲')),
        tester.getCenter(find.byTooltip('编辑歌单')),
        tester.getCenter(find.byTooltip('删除歌单')),
      ];
      final minY = actionCenters.map((offset) => offset.dy).reduce(math.min);
      final maxY = actionCenters.map((offset) => offset.dy).reduce(math.max);
      expect(maxY - minY, lessThan(1));

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('android edge swipe returns from in-app pages first', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..libraryOverview = const LibraryOverview(
            favoriteTracks: [
              Track(
                id: 'favorite-1',
                title: 'Favorite Song',
                artist: 'Singer',
                album: 'Album',
                streamUrl: 'https://music.example.com/rest/stream.view?id=1',
                sourceType: MusicSourceType.subsonic,
                sourceName: 'cece',
                sourceServerId: 'https://music.example.com',
                sourceItemId: '1',
              ),
            ],
          );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(
          const ValueKey('music-function-\u6211\u559c\u6b22\u7684'),
        ),
        matching: find.text('\u6211\u559c\u6b22\u7684'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Favorite Song'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('android-edge-back-swipe')),
      findsOneWidget,
    );

    await tester.dragFrom(const Offset(2, 320), const Offset(140, 0));
    await tester.pumpAndSettle();

    expect(find.text('Favorite Song'), findsNothing);
    expect(
      find.byKey(const ValueKey('music-function-\u6211\u559c\u6b22\u7684')),
      findsOneWidget,
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android root back sends the task to background', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const channel = MethodChannel('com.zmusic.app/task');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(calls, ['moveTaskToBack']);
    expect(
      find.byKey(const ValueKey('music-function-\u6211\u559c\u6b22\u7684')),
      findsOneWidget,
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'managed playlist supports expandable description and batch removal',
    (tester) async {
      tester.view.physicalSize = const Size(1264, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const server = ServerConfig(
        id: 'https://music.example.com|demo',
        name: 'Zmusic',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      const description =
          '123456789012345678901234567890123456789012345678901234567890';
      const playlist = LibrarySectionItem(
        id: 'managed-playlist',
        title: '测试歌单',
        description: description,
        type: LibrarySectionType.playlists,
        owner: 'demo',
      );
      final songIds = <String>['song-1', 'song-2', 'song-3'];
      final updateRequests = <Uri>[];
      final client = MockClient((request) async {
        final method = request.url.pathSegments.last.replaceAll('.view', '');
        if (method == 'getPlaylist') {
          return _subsonicJsonResponse({
            'playlist': {
              'id': playlist.id,
              'name': playlist.title,
              'entry': [
                for (final id in songIds)
                  {
                    'id': id,
                    'title': '歌曲 $id',
                    'artist': '测试歌手',
                    'suffix': 'mp3',
                  },
              ],
            },
          });
        }
        if (method == 'updatePlaylist') {
          updateRequests.add(request.url);
          final indexes =
              (request.url.queryParametersAll['songIndexToRemove'] ??
                      const <String>[])
                  .map(int.parse)
                  .toList();
          for (final index in indexes) {
            songIds.removeAt(index);
          }
          return _subsonicJsonResponse({});
        }
        return _subsonicJsonResponse({});
      });
      final controller =
          AppController(store: LibraryStore(), player: PlayerController())
            ..servers = const [server]
            ..selectedServerId = server.id
            ..libraryOverview = const LibraryOverview(playlists: [playlist])
            ..apiClientFactory = (config) =>
                SubsonicApiClient(server: config, httpClient: client);

      await tester.pumpWidget(ZmusicApp(controller: controller));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('music-function-我的歌单')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试歌单').first);
      await tester.pumpAndSettle();

      final artwork = find.byKey(const ValueKey('remote-playlist-artwork'));
      final trackCount = find.byKey(
        const ValueKey('remote-playlist-track-count'),
      );
      expect(
        tester.getTopLeft(trackCount).dy,
        greaterThan(tester.getBottomLeft(artwork).dy),
      );
      expect(find.text('${description.substring(0, 50)}...'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('remote-playlist-description')),
      );
      await tester.pump();
      expect(find.text(description), findsOneWidget);

      final batchRemove = find.byKey(
        const ValueKey('remote-playlist-batch-remove'),
      );
      await tester.tap(batchRemove);
      await tester.pump();
      expect(find.text('(0)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('remote-playlist-track-selection-0')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('remote-playlist-track-selection-0')),
      );
      await tester.tap(
        find.byKey(const ValueKey('remote-playlist-track-selection-2')),
      );
      await tester.pump();
      expect(find.text('(2)'), findsOneWidget);

      await tester.tap(batchRemove);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('remote-playlist-batch-remove-confirmation')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('remote-playlist-batch-remove-cancel')),
      );
      await tester.pumpAndSettle();
      expect(find.text('(2)'), findsOneWidget);

      await tester.tap(batchRemove);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('remote-playlist-batch-remove-confirm')),
      );
      await tester.pumpAndSettle();

      expect(updateRequests, hasLength(1));
      expect(updateRequests.single.queryParametersAll['songIndexToRemove'], [
        '2',
        '0',
      ]);
      expect(songIds, ['song-2']);
      expect(
        find.byKey(const ValueKey('remote-playlist-track-selection-0')),
        findsNothing,
      );

      await tester.tap(batchRemove);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('remote-playlist-track-selection-0')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('返回音乐库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试歌单').first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('remote-playlist-track-selection-0')),
        findsNothing,
      );

      await tester.tap(find.byTooltip('删除歌单'));
      await tester.pumpAndSettle();
      expect(find.text('确定删除“测试歌单”吗？'), findsOneWidget);
      expect(find.textContaining('Navidrome 服务'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('shared public playlist only exposes playback actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..libraryOverview = const LibraryOverview(
            playlists: [
              LibrarySectionItem(
                id: 'shared',
                title: '共享歌单',
                subtitle: '10 首歌曲',
                description: '公开歌单简介',
                type: LibrarySectionType.playlists,
                isPublic: true,
                owner: 'other',
              ),
            ],
          );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('music-function-公开歌单')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-browse-title')))
          .data,
      '公开歌单',
    );
    await tester.tap(find.text('共享歌单').first);
    await tester.pumpAndSettle();

    expect(find.byTooltip('播放全部'), findsOneWidget);
    expect(find.byTooltip('添加歌曲'), findsNothing);
    expect(find.byTooltip('批量移除歌曲'), findsNothing);
    expect(find.byTooltip('编辑歌单'), findsNothing);
    expect(find.byTooltip('删除歌单'), findsNothing);
    expect(find.text('公开歌单简介'), findsOneWidget);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('remote-playlist-track-count')))
          .dy,
      greaterThan(
        tester
            .getBottomLeft(
              find.byKey(const ValueKey('remote-playlist-artwork')),
            )
            .dy,
      ),
    );
    expect(find.text('歌曲'), findsNothing);
  });

  testWidgets('track long press menu can add subsonic songs without sharing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [
            ServerConfig(
              id: 'https://music.example.com',
              name: 'cece',
              baseUrl: 'https://music.example.com',
              username: 'demo',
              password: 'secret',
            ),
          ]
          ..selectedServerId = 'https://music.example.com'
          ..libraryOverview = const LibraryOverview(
            playlists: [
              LibrarySectionItem(
                id: 'mine',
                title: '我的列表',
                subtitle: '0 首歌曲',
                type: LibrarySectionType.playlists,
                isPublic: false,
                owner: 'demo',
              ),
            ],
            favoriteTracks: [
              Track(
                id: 'https://music.example.com:song-1',
                title: '测试歌曲',
                artist: '歌手',
                album: '专辑',
                streamUrl:
                    'https://music.example.com/rest/stream.view?id=song-1',
                sourceType: MusicSourceType.subsonic,
                sourceName: 'cece',
                sourceServerId: 'https://music.example.com',
                sourceItemId: 'song-1',
              ),
            ],
          );
    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('music-function-我喜欢的')),
        matching: find.text('我喜欢的'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey('track-row-https://music.example.com:song-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('下一首播放'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('分享'), findsNothing);
    expect(find.text('加入歌单'), findsOneWidget);
  });

  testWidgets('desktop app bar uses merged music and settings tabs', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [
            ServerConfig(
              id: 'https://music.example.com',
              name: 'cece',
              baseUrl: 'https://music.example.com',
              username: 'demo',
              password: 'secret',
            ),
          ]
          ..selectedServerId = 'https://music.example.com'
          ..libraryOverview = const LibraryOverview(songCount: 2176);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(find.text('Zmusic'), findsNothing);
    expect(find.text('音源：cece · 歌曲数：2176'), findsNothing);
    expect(find.byTooltip('设置'), findsNothing);
    expect(find.widgetWithText(FilledButton, '搜索'), findsNothing);
    expect(find.widgetWithText(FilledButton, '音乐'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '设置'), findsOneWidget);
    expect(
      tester.getTopLeft(find.widgetWithText(FilledButton, '音乐')).dy,
      lessThan(80),
    );

    expect(find.byKey(const ValueKey('music-function-歌曲')), findsNothing);
    expect(find.byKey(const ValueKey('music-function-专辑')), findsNothing);
    expect(find.byKey(const ValueKey('music-function-歌手')), findsNothing);
    expect(find.byKey(const ValueKey('music-function-我的歌单')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-function-公开歌单')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-function-我喜欢的')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-function-电台')), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('music tab includes discovery sections below search', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..libraryOverview = const LibraryOverview(
            latestAlbums: [
              LibrarySectionItem(
                id: 'latest-album',
                title: 'Latest Album',
                subtitle: 'Artist',
                type: LibrarySectionType.albums,
              ),
            ],
            recentAlbums: [
              LibrarySectionItem(
                id: 'recent-album',
                title: 'Recent Album',
                subtitle: 'Artist',
                type: LibrarySectionType.albums,
              ),
            ],
            frequentAlbums: [
              LibrarySectionItem(
                id: 'frequent-album',
                title: 'Frequent Album',
                subtitle: 'Artist',
                type: LibrarySectionType.albums,
              ),
            ],
            randomAlbums: [
              LibrarySectionItem(
                id: 'random-album',
                title: 'Random Album',
                subtitle: 'Artist',
                type: LibrarySectionType.albums,
              ),
            ],
          );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(find.text('最新专辑'), findsOneWidget);
    expect(find.text('最近播放'), findsOneWidget);
    expect(find.text('最多播放'), findsOneWidget);
    expect(find.text('随机专辑'), findsOneWidget);
    expect(find.text('Latest Album'), findsOneWidget);
    expect(find.text('Random Album'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('refresh-library')), findsNothing);
    for (final title in const ['最新专辑', '随机专辑', '最近播放', '最多播放']) {
      final section = find.byKey(ValueKey('discovery-section-$title'));
      expect(section, findsOneWidget);
      expect(
        find.descendant(of: section, matching: find.text('1')),
        findsNothing,
      );
    }
  });

  testWidgets('music home applies configured visibility and ordering', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const server = ServerConfig(
      id: 'https://music.example.com|demo',
      name: 'Zmusic',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    const publicPlaylist = LibrarySectionItem(
      id: 'public-playlist',
      title: '公共测试歌单',
      type: LibrarySectionType.playlists,
      isPublic: true,
      owner: 'other-user',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [server]
          ..selectedServerId = server.id
          ..settings = const AppSettings(
            homeShortcutOrder: [
              HomeShortcutSection.publicRadio,
              HomeShortcutSection.favorites,
              HomeShortcutSection.myPlaylists,
              HomeShortcutSection.publicPlaylists,
            ],
            hiddenHomeShortcuts: {HomeShortcutSection.publicPlaylists},
            homeDiscoveryOrder: [
              HomeDiscoverySection.frequentAlbums,
              HomeDiscoverySection.latestAlbums,
              HomeDiscoverySection.randomAlbums,
              HomeDiscoverySection.recentAlbums,
            ],
            hiddenHomeDiscoveries: {HomeDiscoverySection.randomAlbums},
            showMyPlaylistSection: false,
            showPublicPlaylistSection: true,
          )
          ..libraryOverview = const LibraryOverview(
            playlists: [publicPlaylist],
          );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final radio = find.byKey(const ValueKey('music-function-电台'));
    final favorites = find.byKey(const ValueKey('music-function-我喜欢的'));
    final myPlaylists = find.byKey(const ValueKey('music-function-我的歌单'));
    expect(radio, findsOneWidget);
    expect(favorites, findsOneWidget);
    expect(myPlaylists, findsOneWidget);
    expect(find.byKey(const ValueKey('music-function-公开歌单')), findsNothing);
    expect(
      tester.getTopLeft(radio).dx,
      lessThan(tester.getTopLeft(favorites).dx),
    );
    expect(
      tester.getTopLeft(favorites).dx,
      lessThan(tester.getTopLeft(myPlaylists).dx),
    );

    final frequent = find.byKey(const ValueKey('discovery-section-最多播放'));
    final latest = find.byKey(const ValueKey('discovery-section-最新专辑'));
    final recent = find.byKey(const ValueKey('discovery-section-最近播放'));
    expect(frequent, findsOneWidget);
    expect(latest, findsOneWidget);
    expect(recent, findsOneWidget);
    expect(find.byKey(const ValueKey('discovery-section-随机专辑')), findsNothing);
    expect(
      tester.getTopLeft(frequent).dx,
      lessThan(tester.getTopLeft(latest).dx),
    );
    expect(
      tester.getTopLeft(recent).dy,
      greaterThan(tester.getTopLeft(frequent).dy),
    );

    final publicSection = find.byKey(
      const ValueKey('home-public-playlists-section'),
    );
    await tester.dragUntilVisible(
      publicSection,
      find.byType(Scrollable).first,
      const Offset(0, -240),
    );
    expect(publicSection, findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-my-playlists-section')),
      findsNothing,
    );
  });

  testWidgets('settings tab keeps the bottom player visible', (tester) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);

    expect(find.text('主题'), findsOneWidget);
    expect(find.text('缓存'), findsOneWidget);
    expect(find.text('暂无播放内容'), findsOneWidget);

    final playerTop = tester.getTopLeft(find.text('暂无播放内容')).dy;
    expect(playerTop, greaterThan(0));
    expect(playerTop, lessThan(720));
  });

  testWidgets('uses Zmusic as the app title without home chrome text', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'Zmusic');
    expect(find.text('Zmusic'), findsNothing);
    expect(find.text('Zmusic'), findsNothing);
  });

  testWidgets('clears search text from search bar suffix action', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));

    final searchField = find.byType(TextField);
    expect(searchField, findsOneWidget);
    expect(find.byTooltip('清空搜索'), findsNothing);
    expect(
      find.byKey(const ValueKey('search-scope-hover-target')),
      findsOneWidget,
    );

    final field = tester.widget<TextField>(searchField);
    expect(field.textAlign, TextAlign.start);
    expect(field.textAlignVertical, TextAlignVertical.center);
    expect(field.decoration?.prefixIcon, isNull);
    expect(field.decoration?.hintText, '输入关键词');

    await tester.tap(searchField);
    await tester.pump();

    expect(tester.widget<TextField>(searchField).decoration?.hintText, isNull);

    await tester.enterText(searchField, '李志');
    await tester.pump();

    expect(find.byTooltip('清空搜索'), findsOneWidget);
    expect(tester.widget<TextField>(searchField).controller?.text, '李志');

    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();

    expect(tester.widget<TextField>(searchField).controller?.text, isEmpty);
    expect(find.byTooltip('清空搜索'), findsNothing);
    expect(find.byTooltip('搜索'), findsOneWidget);
  });

  testWidgets('desktop search scope opens on hover and closes on exit', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );
    await tester.pumpWidget(ZmusicApp(controller: controller));

    final hoverTarget = find.byKey(const ValueKey('search-scope-hover-target'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(1200, 700));
    await mouse.moveTo(tester.getCenter(hoverTarget));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('search-scope-option-songs')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-scope-option-all')), findsNothing);
    final songsOption = find.byKey(const ValueKey('search-scope-option-songs'));
    expect(
      tester
          .getTopLeft(
            find.descendant(of: songsOption, matching: find.text('歌曲')),
          )
          .dx,
      lessThan(
        tester
            .getTopLeft(
              find.descendant(
                of: songsOption,
                matching: find.byIcon(Icons.check_rounded),
              ),
            )
            .dx,
      ),
    );

    await mouse.moveTo(const Offset(1200, 700));
    await tester.pump(const Duration(milliseconds: 220));
    debugDefaultTargetPlatformOverride = null;

    expect(
      find.byKey(const ValueKey('search-scope-option-songs')),
      findsNothing,
    );
  });

  testWidgets(
    'search preference keeps focus and still requests every result type',
    (tester) async {
      tester.view.physicalSize = const Size(1264, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const source = ServerConfig(
        id: 'https://music.example.com',
        name: '远程音乐',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      final controller = _SuggestionSearchController()
        ..servers = const [source]
        ..selectedServerId = source.id;

      await tester.pumpWidget(ZmusicApp(controller: controller));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('search-scope-hover-target')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('search-scope-option-artists')),
      );
      await tester.pumpAndSettle();

      final searchField = find.byType(TextField);
      expect(tester.widget<TextField>(searchField).focusNode?.hasFocus, isTrue);

      await tester.enterText(searchField, '周杰伦');
      await tester.pump();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();

      expect(controller.requestedQuery, '周杰伦');
      expect(controller.requestedScope, LibrarySearchScope.all);
      expect(
        tester.widgetList<Tab>(find.byType(Tab)).map((tab) => tab.text),
        orderedEquals(const ['歌曲', '歌手', '专辑']),
      );
      expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index,
        1,
      );
    },
  );

  testWidgets(
    'remote suggestions align and open artist or album details directly',
    (tester) async {
      tester.view.physicalSize = const Size(1264, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const source = ServerConfig(
        id: 'https://music.example.com',
        name: '远程音乐',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      final controller = _SuggestionSearchController()
        ..servers = const [source]
        ..selectedServerId = source.id;

      await tester.pumpWidget(ZmusicApp(controller: controller));
      await tester.pump();

      final searchField = find.byType(TextField);
      await tester.tap(searchField);
      await tester.enterText(searchField, 'a1');
      await tester.pump(const Duration(milliseconds: 350));

      expect(controller.suggestionQueries, isEmpty);
      expect(
        find.byKey(const ValueKey('remote-search-suggestions')),
        findsNothing,
      );

      await tester.enterText(searchField, 'a12');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();

      expect(controller.suggestionQueries, ['a12']);
      final suggestions = find.byKey(
        const ValueKey('remote-search-suggestions'),
      );
      expect(suggestions, findsOneWidget);
      expect(
        find.byKey(const ValueKey('remote-search-suggestion-songs-song-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('remote-search-suggestion-songs-song-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('remote-search-suggestion-artists-artist-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('remote-search-suggestion-artists-artist-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('remote-search-suggestion-albums-album-1')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(suggestions).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(searchField).dy - 1),
      );
      expect(
        tester.getTopLeft(suggestions).dx,
        closeTo(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('search-scope-hover-target')),
              )
              .dx,
          1,
        ),
      );
      expect(
        tester.getTopRight(suggestions).dx,
        closeTo(tester.getTopRight(searchField).dx, 1),
      );

      await tester.enterText(searchField, '李');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();

      expect(controller.suggestionQueries, ['a12', '李']);
      await tester.tap(find.text('远程歌手一'));
      await tester.pumpAndSettle();

      expect(controller.requestedQuery, '远程歌手一');
      expect(controller.requestedScope, LibrarySearchScope.songs);
      expect(find.text('搜索结果'), findsNothing);
      expect(find.byKey(const ValueKey('artists:artist-1')), findsOneWidget);

      await tester.tap(find.byTooltip('返回音乐库'));
      await tester.pumpAndSettle();
      await tester.tap(searchField);
      await tester.enterText(searchField, '专');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();
      await tester.tap(find.text('远程专辑一'));
      await tester.pumpAndSettle();

      expect(controller.requestedQuery, '远程专辑一');
      expect(controller.requestedScope, LibrarySearchScope.songs);
      expect(find.text('搜索结果'), findsNothing);
      expect(find.byKey(const ValueKey('albums:album-1')), findsOneWidget);
    },
  );

  testWidgets('remote suggestions fit an Android phone search bar', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const source = ServerConfig(
      id: 'https://music.example.com',
      name: '远程音乐',
      baseUrl: 'https://music.example.com',
      username: 'demo',
      password: 'secret',
    );
    final controller = _SuggestionSearchController()
      ..servers = const [source]
      ..selectedServerId = source.id;

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final searchField = find.byType(TextField);
    await tester.tap(searchField);
    await tester.enterText(searchField, '周');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump();

    final suggestions = find.byKey(const ValueKey('remote-search-suggestions'));
    expect(suggestions, findsOneWidget);
    final bounds = tester.getRect(suggestions);
    debugDefaultTargetPlatformOverride = null;
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(390));
    expect(
      bounds.top,
      greaterThanOrEqualTo(tester.getBottomLeft(searchField).dy - 1),
    );
    expect(bounds.bottom, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('home-search-bar'))).dx,
      tester.getTopLeft(find.byKey(const ValueKey('music-function-我喜欢的'))).dx,
    );
  });

  testWidgets('clears search text when switching home tabs', (tester) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final searchField = find.byType(TextField);
    final searchTextController = tester
        .widget<TextField>(searchField)
        .controller!;
    await tester.enterText(searchField, '周杰伦');
    await tester.pump();

    expect(searchTextController.text, '周杰伦');

    await openSettingsTab(tester);

    expect(searchTextController.text, isEmpty);
    expect(find.byType(TextField), findsNothing);

    await openHomeTab(tester, label: '音乐', icon: Icons.music_note_rounded);

    expect(searchTextController.text, isEmpty);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('opens album songs and clears search when returning home', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );
    controller.servers = const [
      ServerConfig(
        id: 'local:D:\\Music',
        name: 'Local',
        baseUrl: '',
        username: '',
        password: '',
        sourceKind: MusicSourceKind.localFolder,
        localPath: r'D:\Music',
      ),
    ];
    controller.selectedServerId = 'local:D:\\Music';
    controller.localTracks = const [
      Track(
        id: 'local-song',
        title: 'Detail Song',
        artist: 'Detail Artist',
        album: 'Detail Album',
        streamUrl: 'file:///D:/Music/detail-song.mp3',
        sourceType: MusicSourceType.localFile,
        sourceName: 'Local',
        sourceItemId: r'D:\Music\detail-song.mp3',
      ),
    ];
    controller.libraryOverview = buildLocalLibraryOverview(
      controller.localTracks,
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.ensureVisible(find.text('Detail Album').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detail Album').first);
    await tester.pumpAndSettle();

    final detailBack = find.byTooltip('返回音乐库');
    final detailHeader = find.byKey(const ValueKey('library-item-header'));
    expect(detailHeader, findsOneWidget);
    expect(
      tester.getTopLeft(detailBack).dy,
      lessThan(tester.getTopLeft(detailHeader).dy),
    );
    expect(find.byKey(const ValueKey('artwork-play-all')), findsOneWidget);
    expect(find.text('最新专辑'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('track-artwork-local-song')),
      findsNothing,
    );
    expect(find.text('Detail Song'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('歌曲'), findsNothing);

    await tester.tap(find.byTooltip('返回音乐库'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('search-scope-hover-target')),
        matching: find.text('歌曲'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows audio format chip beside bottom player title', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: _BufferingPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(find.text('APE'), findsOneWidget);
    expect(tester.widget<Text>(find.text('APE')).style?.fontSize, 8);
  });

  testWidgets('initializes player volume to 55 percent', (tester) async {
    final player = _RecordingPlayerController();
    final controller = AppController(store: LibraryStore(), player: player);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(player.volume, 0.55);
  });

  testWidgets('shows playback queue button in bottom player bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(
      store: LibraryStore(),
      player: _BufferingPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final queueButton = find.byTooltip('列表');
    expect(queueButton, findsOneWidget);
    expect(find.byTooltip('收藏'), findsOneWidget);
    expect(
      find.descendant(of: queueButton, matching: find.text('列表')),
      findsNothing,
    );

    await tester.tap(queueButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final sidePanel = find.byKey(const ValueKey('queue-side-panel'));
    expect(find.byType(BottomSheet), findsNothing);
    expect(sidePanel, findsOneWidget);
    expect(find.text('播放队列'), findsOneWidget);
    expect(
      find.descendant(of: sidePanel, matching: find.text('APE')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sidePanel, matching: find.byTooltip('收藏')),
      findsOneWidget,
    );

    final panelRect = tester.getRect(sidePanel);
    expect(panelRect.right, closeTo(1264, 1));
    expect(panelRect.top, greaterThanOrEqualTo(56));
    expect(panelRect.bottom, greaterThan(640));
    expect(panelRect.bottom, lessThan(660));
  });

  testWidgets('home busy state does not show global progress bar', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    )..isBusy = true;

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('mobile bottom player is a compact floating entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(
      store: LibraryStore(),
      player: _BufferingPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    expect(find.byIcon(Icons.volume_up_outlined), findsNothing);
    expect(find.byTooltip('播放详情'), findsOneWidget);
    expect(find.byTooltip('收藏'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      find.byKey(const ValueKey('mobile-mini-artwork-rotation')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('播放详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('歌曲'), findsOneWidget);
    expect(find.byIcon(Icons.volume_up_outlined), findsNothing);
    expect(find.text('Buffering'), findsWidgets);
  });

  testWidgets('mobile now playing is fullscreen with song and lyrics tabs', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(
      store: LibraryStore(),
      player: _BufferingPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(find.byTooltip('播放详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('推荐'), findsNothing);
    expect(find.byIcon(Icons.search), findsNothing);
    expect(find.text('歌曲'), findsOneWidget);
    expect(find.text('歌词'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    final backCenter = tester.getCenter(find.byTooltip('返回'));
    final songTabCenter = tester.getCenter(find.text('歌曲'));
    final lyricsTabCenter = tester.getCenter(find.text('歌词'));
    expect((backCenter.dy - songTabCenter.dy).abs(), lessThanOrEqualTo(1));
    expect((songTabCenter.dy - lyricsTabCenter.dy).abs(), lessThanOrEqualTo(1));

    await tester.tap(find.text('歌词'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('暂无歌词'), findsOneWidget);
    expect(find.text('Buffering'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('now playing artist and album links open scoped search results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const source = ServerConfig(
      id: 'local:C:\\Music',
      name: '本地音乐',
      baseUrl: '',
      username: '',
      password: '',
      sourceKind: MusicSourceKind.localFolder,
      localPath: 'C:\\Music',
    );
    const track = Track(
      id: 'local:C:\\Music:song.mp3',
      title: '目标歌曲',
      artist: '目标歌手',
      album: '目标专辑',
      streamUrl: 'file:///C:/Music/song.mp3',
      sourceType: MusicSourceType.localFile,
      sourceName: '本地音乐',
      sourceServerId: 'local:C:\\Music',
      sourceItemId: 'C:\\Music\\song.mp3',
      audioFormat: 'MP3',
    );
    final player = _ScrobblePlayerController()..start(track);
    final controller = AppController(store: LibraryStore(), player: player)
      ..servers = const [source]
      ..selectedServerId = source.id
      ..localTracks = const [track];

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(find.byTooltip('播放详情'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('now-playing-artist-link')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('now-playing-album-link')),
      findsOneWidget,
    );
    expect(find.byTooltip('分享'), findsNothing);

    final albumLink = find.byKey(const ValueKey('now-playing-album-link'));
    final artistLink = find.byKey(const ValueKey('now-playing-artist-link'));
    expect(
      (tester.getCenter(albumLink).dy - tester.getCenter(artistLink).dy).abs(),
      lessThanOrEqualTo(1),
    );
    expect(find.text('来源：本地音乐'), findsNothing);
    final artistText = tester.widget<Text>(
      find.descendant(of: artistLink, matching: find.byType(Text)),
    );
    final colorScheme = Theme.of(tester.element(artistLink)).colorScheme;
    expect(artistText.style?.color, colorScheme.primary);

    await tester.tap(artistLink);
    await tester.pumpAndSettle();

    expect(controller.searchResults.artists.single.title, '目标歌手');
    expect(controller.searchResults.albums.single.title, '目标专辑');
    expect(
      DefaultTabController.of(tester.element(find.byType(TabBar))).index,
      1,
    );
    await tester.pump();

    await tester.tap(find.byTooltip('返回音乐库'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('now-playing-album-link')));
    await tester.pumpAndSettle();

    expect(controller.searchResults.albums.single.title, '目标专辑');
    expect(controller.visibleTracks.single.title, '目标歌曲');
    expect(
      DefaultTabController.of(tester.element(find.byType(TabBar))).index,
      2,
    );
  });

  testWidgets(
    'now playing metadata navigates before a remote search finishes',
    (tester) async {
      tester.view.physicalSize = const Size(1264, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const source = ServerConfig(
        id: 'https://music.example.com',
        name: '远端音乐',
        baseUrl: 'https://music.example.com',
        username: 'demo',
        password: 'secret',
      );
      const track = Track(
        id: 'https://music.example.com:song-1',
        title: '远端歌曲',
        artist: '响应慢的歌手',
        album: '响应慢的专辑',
        streamUrl: 'https://music.example.com/rest/stream.view?id=song-1',
        sourceType: MusicSourceType.subsonic,
        sourceName: '远端音乐',
        sourceServerId: 'https://music.example.com',
        sourceItemId: 'song-1',
      );
      final player = _ScrobblePlayerController()..start(track);
      final controller = _DeferredSearchController(player: player)
        ..servers = const [source]
        ..selectedServerId = source.id;

      await tester.pumpWidget(ZmusicApp(controller: controller));
      await tester.pump();
      await tester.tap(find.byTooltip('播放详情'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('歌手：响应慢的歌手'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('now-playing-artist-link')),
        findsNothing,
      );
      expect(find.text('搜索结果'), findsOneWidget);
      expect(find.text('最新专辑'), findsNothing);
      expect(controller.requestedQuery, '响应慢的歌手');
      expect(controller.requestedScope, LibrarySearchScope.all);

      controller.completeSearch();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('track rows show favorite action before play action', (
    tester,
  ) async {
    final requests = <String>[];
    final unstarResponse = Completer<http.Response>();
    const track = Track(
      id: 'song-1',
      title: 'Favorite Target',
      artist: 'Singer',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=song-1',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'cece',
      sourceServerId: 'https://music.example.com',
      sourceItemId: 'song-1',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [
            ServerConfig(
              id: 'https://music.example.com',
              name: 'cece',
              baseUrl: 'https://music.example.com',
              username: 'demo',
              password: 'secret',
            ),
          ]
          ..selectedServerId = 'https://music.example.com'
          ..libraryOverview = const LibraryOverview(favoriteTracks: [track]);
    controller.apiClientFactory = (server) => SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) {
        requests.add(request.url.pathSegments.last.replaceFirst('.view', ''));
        return unstarResponse.future;
      }),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('music-function-我喜欢的')),
        matching: find.text('我喜欢的'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final favoriteButton = find.byTooltip('取消收藏');
    final playButton = find.byTooltip('播放');
    expect(favoriteButton, findsOneWidget);
    expect(playButton, findsOneWidget);
    expect(
      tester.getTopLeft(favoriteButton).dx,
      lessThan(tester.getTopLeft(playButton).dx),
    );

    await tester.tap(favoriteButton);
    await tester.pump();

    expect(requests, ['unstar']);
    expect(find.byTooltip('正在取消收藏'), findsOneWidget);

    await tester.tap(find.byTooltip('正在取消收藏'));
    await tester.pump();

    expect(requests, ['unstar']);
    unstarResponse.complete(
      http.Response(
        jsonEncode({
          'subsonic-response': {'status': 'ok'},
        }),
        200,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byTooltip('收藏'), findsOneWidget);
  });

  testWidgets('favorite button fills while adding a favorite', (tester) async {
    final requests = <String>[];
    final starResponse = Completer<http.Response>();
    final controller =
        AppController(
            store: LibraryStore(),
            player: _BufferingPlayerController(),
          )
          ..servers = const [
            ServerConfig(
              id: 'https://music.example.com',
              name: 'cece',
              baseUrl: 'https://music.example.com',
              username: 'demo',
              password: 'secret',
            ),
          ]
          ..selectedServerId = 'https://music.example.com';
    controller.apiClientFactory = (server) => SubsonicApiClient(
      server: server,
      httpClient: MockClient((request) {
        requests.add(request.url.pathSegments.last.replaceFirst('.view', ''));
        return starResponse.future;
      }),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final track = controller.player.currentTrack!;
    expect(controller.isFavoriteTrack(track), isFalse);
    expect(controller.isFavoriteTrackToggling(track), isFalse);

    await tester.tap(find.byTooltip('收藏'));
    await tester.pump();

    expect(requests, ['star']);
    expect(controller.isFavoriteTrackToggling(track), isTrue);
    expect(controller.isBusy, isFalse);
    expect(find.byTooltip('正在收藏'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.tap(find.byTooltip('正在收藏'));
    await tester.pump();

    expect(requests, ['star']);
    starResponse.complete(
      http.Response(
        jsonEncode({
          'subsonic-response': {'status': 'ok'},
        }),
        200,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(controller.isFavoriteTrackToggling(track), isFalse);
    expect(controller.isFavoriteTrack(track), isTrue);
    expect(find.byTooltip('取消收藏'), findsOneWidget);
  });

  testWidgets('mobile track rows stay compact with fixed height', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const track = Track(
      id: 'compact-song',
      title: '一首很长很长但是不应该撑高列表行的歌曲名称',
      artist: 'Singer',
      album: 'Album',
      streamUrl: 'https://music.example.com/rest/stream.view?id=compact-song',
      sourceType: MusicSourceType.subsonic,
      sourceName: 'cece',
      sourceServerId: 'https://music.example.com',
      sourceItemId: 'compact-song',
      audioFormat: 'MP3',
    );
    final controller =
        AppController(store: LibraryStore(), player: PlayerController())
          ..servers = const [
            ServerConfig(
              id: 'https://music.example.com',
              name: 'cece',
              baseUrl: 'https://music.example.com',
              username: 'demo',
              password: 'secret',
            ),
          ]
          ..selectedServerId = 'https://music.example.com'
          ..libraryOverview = const LibraryOverview(favoriteTracks: [track]);

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('music-function-我喜欢的')),
        matching: find.text('我喜欢的'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final row = find.byKey(const ValueKey('track-row-compact-song'));
    expect(row, findsOneWidget);
    expect(tester.getSize(row).height, 52);
  });

  testWidgets('android settings hide desktop-only window and tray options', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);

    expect(find.text('应用 Logo'), findsOneWidget);
    expect(find.text('背景图'), findsOneWidget);
    expect(find.text('任务栏 / 托盘图标'), findsNothing);
    expect(find.text('窗口'), findsNothing);
    expect(find.text('关闭按钮最小化到托盘'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop settings omit taskbar and tray icon customization', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1264, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(
      store: LibraryStore(),
      player: PlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await openSettingsTab(tester);

    expect(find.text('应用 Logo'), findsOneWidget);
    expect(find.text('背景图'), findsOneWidget);
    expect(find.text('任务栏 / 托盘图标'), findsNothing);
    expect(find.text('窗口'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('uses stacked custom arrow icon for sequential playback mode', (
    tester,
  ) async {
    final controller = AppController(
      store: LibraryStore(),
      player: _BufferingPlayerController(),
    );

    await tester.pumpWidget(ZmusicApp(controller: controller));
    await tester.pump();

    final icon = find.byKey(const ValueKey('sequential-playback-icon'));
    expect(icon, findsOneWidget);
    expect(
      find.descendant(of: icon, matching: find.byIcon(Icons.arrow_forward)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: icon,
        matching: find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter != null,
        ),
      ),
      findsOneWidget,
    );
  });
}

Future<void> openSettingsTab(WidgetTester tester) async {
  await openHomeTab(tester, label: '设置', icon: Icons.settings_rounded);
}

Future<void> openHomeTab(
  WidgetTester tester, {
  required String label,
  required IconData icon,
}) async {
  final desktopTab = find.widgetWithText(FilledButton, label);
  if (desktopTab.evaluate().isNotEmpty) {
    await tester.tap(desktopTab.first);
  } else if (find.bySemanticsLabel(label).evaluate().isNotEmpty) {
    await tester.tap(find.bySemanticsLabel(label).first);
  } else {
    await tester.tap(find.byIcon(icon).first);
  }
  await tester.pumpAndSettle();
}

class _RecordingPlayerController extends PlayerController {
  Track? playedTrack;
  List<Track> playedTracks = const [];
  int? playedIndex;
  double? volume;
  bool stopped = false;

  @override
  Future<void> playTrack(Track track) async {
    playedTrack = track;
    playedTracks = [track];
    playedIndex = 0;
    notifyListeners();
  }

  @override
  Future<void> playTracks(List<Track> tracks, int index) async {
    playedTracks = List.of(tracks);
    playedIndex = index;
    playedTrack = tracks[index];
    notifyListeners();
  }

  @override
  Future<void> setVolume(double volume) async {
    this.volume = volume;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    playedTrack = null;
    playedTracks = const [];
    playedIndex = null;
    notifyListeners();
  }
}

class _CompletionPlaybackEngine implements PlaybackEngine {
  final StreamController<bool> _completedController =
      StreamController<bool>.broadcast(sync: true);
  final List<String> openedUrls = [];
  bool _playing = false;

  void completeCurrent() {
    _playing = false;
    _completedController.add(true);
  }

  @override
  bool get playing => _playing;

  @override
  bool get buffering => false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  Stream<bool> get completedStream => _completedController.stream;

  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  Stream<Duration> get bufferedPositionStream => const Stream<Duration>.empty();

  @override
  Stream<bool> get playingStream => const Stream<bool>.empty();

  @override
  Stream<bool> get bufferingStream => const Stream<bool>.empty();

  @override
  Future<void> open(String url) async {
    openedUrls.add(url);
  }

  @override
  Future<void> openAndPlay(String url) async {
    openedUrls.add(url);
    _playing = true;
  }

  @override
  Future<void> play() async {
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _playing = false;
  }

  @override
  Future<void> stop() async {
    _playing = false;
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() => _completedController.close();
}

class _PlaybackTickEngine implements PlaybackEngine {
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<Duration> _bufferController =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast(sync: true);

  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _buffering = false;

  void emitPosition(Duration value) {
    _position = value;
    _positionController.add(value);
  }

  void emitBufferedPosition(Duration value) {
    _bufferedPosition = value;
    _bufferController.add(value);
  }

  void emitBuffering(bool value) {
    _buffering = value;
    _bufferingController.add(value);
  }

  @override
  bool get playing => false;

  @override
  bool get buffering => _buffering;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Duration get bufferedPosition => _bufferedPosition;

  @override
  Stream<bool> get completedStream => const Stream<bool>.empty();

  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get bufferedPositionStream => _bufferController.stream;

  @override
  Stream<bool> get playingStream => const Stream<bool>.empty();

  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;

  @override
  Future<void> open(String url) async {}

  @override
  Future<void> openAndPlay(String url) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {
    _position = position;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _bufferController.close();
    await _bufferingController.close();
  }
}

class _SystemMediaPlayerController extends PlayerController {
  bool _playing = true;
  int playCalls = 0;
  int pauseCalls = 0;
  int toggleCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;

  void setPlaying(bool value) {
    _playing = value;
    notifyListeners();
  }

  @override
  Track? get currentTrack => const Track(
    id: 'system-song',
    title: 'System Song',
    artist: 'System Artist',
    album: 'System Album',
    streamUrl: 'https://music.example.com/system-song.mp3',
    sourceType: MusicSourceType.subsonic,
    sourceName: 'Navidrome',
    coverUrl: 'https://music.example.com/system-song.jpg',
    duration: Duration(minutes: 4),
  );

  @override
  bool get isPlaying => _playing;

  @override
  bool get canSkipPrevious => true;

  @override
  bool get canSkipNext => true;

  @override
  Duration get position => const Duration(seconds: 12);

  @override
  Duration? get duration => const Duration(minutes: 4);

  @override
  Future<void> play() async {
    playCalls += 1;
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
  }

  @override
  Future<void> togglePlay() async {
    toggleCalls += 1;
  }

  @override
  Future<void> playNext() async {
    nextCalls += 1;
  }

  @override
  Future<void> playPrevious() async {
    previousCalls += 1;
  }
}

class _StalledStartupPlaybackEngine implements PlaybackEngine {
  int openCount = 0;
  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;

  @override
  bool get playing => _playing;

  @override
  bool get buffering => _buffering;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  Stream<bool> get completedStream => const Stream<bool>.empty();

  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  Stream<Duration> get bufferedPositionStream => const Stream<Duration>.empty();

  @override
  Stream<bool> get playingStream => const Stream<bool>.empty();

  @override
  Stream<bool> get bufferingStream => const Stream<bool>.empty();

  @override
  Future<void> open(String url) async {}

  @override
  Future<void> openAndPlay(String url) async {
    openCount += 1;
    _playing = true;
    if (openCount == 1) {
      _buffering = true;
      _position = Duration.zero;
      return;
    }
    _buffering = false;
    _position = const Duration(seconds: 2);
  }

  @override
  Future<void> play() async {
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _playing = false;
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _buffering = false;
    _position = Duration.zero;
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {}
}

class _DeferredSearchController extends AppController {
  _DeferredSearchController({required super.player})
    : super(store: LibraryStore());

  final Completer<void> _searchCompleter = Completer<void>();
  String? requestedQuery;
  LibrarySearchScope? requestedScope;

  @override
  Future<void> searchSelectedServer(
    String query, {
    LibrarySearchScope scope = LibrarySearchScope.all,
  }) {
    requestedQuery = query;
    requestedScope = scope;
    return _searchCompleter.future;
  }

  void completeSearch() {
    if (!_searchCompleter.isCompleted) {
      _searchCompleter.complete();
    }
  }
}

class _SuggestionSearchController extends AppController {
  _SuggestionSearchController()
    : super(store: LibraryStore(), player: PlayerController());

  final List<String> suggestionQueries = [];
  String? requestedQuery;
  LibrarySearchScope? requestedScope;

  static const suggestions = LibrarySearchResults(
    songs: [
      Track(
        id: 'song-1',
        title: '远程歌曲一',
        artist: '远程歌手一',
        album: '远程专辑一',
        streamUrl: 'https://music.example.com/rest/stream.view?id=song-1',
        sourceType: MusicSourceType.subsonic,
        sourceName: '远程音乐',
      ),
      Track(
        id: 'song-2',
        title: '远程歌曲二',
        artist: '远程歌手二',
        album: '远程专辑二',
        streamUrl: 'https://music.example.com/rest/stream.view?id=song-2',
        sourceType: MusicSourceType.subsonic,
        sourceName: '远程音乐',
      ),
    ],
    artists: [
      LibrarySectionItem(
        id: 'artist-1',
        title: '远程歌手一',
        type: LibrarySectionType.artists,
      ),
      LibrarySectionItem(
        id: 'artist-2',
        title: '远程歌手二',
        type: LibrarySectionType.artists,
      ),
    ],
    albums: [
      LibrarySectionItem(
        id: 'album-1',
        title: '远程专辑一',
        subtitle: '远程歌手一',
        type: LibrarySectionType.albums,
      ),
    ],
  );

  @override
  Future<LibrarySearchResults> searchRemoteSuggestions(
    String query, {
    LibrarySearchScope scope = LibrarySearchScope.all,
  }) async {
    suggestionQueries.add(query);
    return suggestions;
  }

  @override
  Future<void> searchSelectedServer(
    String query, {
    LibrarySearchScope scope = LibrarySearchScope.all,
  }) async {
    requestedQuery = query;
    requestedScope = scope;
    searchResults = switch (scope) {
      LibrarySearchScope.artists => const LibrarySearchResults(
        artists: [
          LibrarySectionItem(
            id: 'artist-1',
            title: '远程歌手一',
            type: LibrarySectionType.artists,
          ),
        ],
      ),
      LibrarySearchScope.albums => const LibrarySearchResults(
        albums: [
          LibrarySectionItem(
            id: 'album-1',
            title: '远程专辑一',
            type: LibrarySectionType.albums,
          ),
        ],
      ),
      LibrarySearchScope.songs => const LibrarySearchResults(
        songs: [
          Track(
            id: 'song-1',
            title: '远程歌曲一',
            artist: '远程歌手一',
            album: '远程专辑一',
            streamUrl: 'https://music.example.com/rest/stream.view?id=song-1',
            sourceType: MusicSourceType.subsonic,
            sourceName: '远程音乐',
          ),
        ],
      ),
      LibrarySearchScope.all => suggestions,
    };
    notifyListeners();
  }
}

class _ScrobblePlayerController extends PlayerController {
  final StreamController<Duration> _positions =
      StreamController<Duration>.broadcast();

  Track? _track;
  bool _playing = false;
  int _sessionId = 0;
  Duration _position = Duration.zero;

  @override
  Track? get currentTrack => _track;

  @override
  bool get isPlaying => _playing;

  @override
  int get playSessionId => _sessionId;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _track?.duration;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  void start(Track track) {
    _track = track;
    _position = Duration.zero;
    _playing = true;
    _sessionId += 1;
    notifyListeners();
  }

  void emitPosition(Duration position) {
    _position = position;
    _positions.add(position);
  }

  @override
  void dispose() {
    _positions.close();
    super.dispose();
  }
}

class _BufferingPlayerController extends PlayerController {
  static const _track = Track(
    id: 'buffering-track',
    title: 'Buffering',
    artist: 'Artist',
    album: 'Album',
    streamUrl: 'https://music.example.com/rest/stream.view?id=buffering-track',
    sourceType: MusicSourceType.subsonic,
    sourceName: 'Navidrome',
    sourceItemId: 'buffering-track',
    audioFormat: 'APE',
    duration: Duration(minutes: 4),
  );

  @override
  List<Track> get queue => const [_track];

  @override
  Track? get currentTrack => _track;

  @override
  bool get isPlaying => false;

  @override
  bool get isBuffering => true;

  @override
  bool get canSkipPrevious => false;

  @override
  bool get canSkipNext => false;

  @override
  PlaybackMode get playbackMode => PlaybackMode.sequential;

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => _track.duration;

  @override
  Duration get bufferedPosition => const Duration(seconds: 30);

  @override
  Stream<Duration> get positionStream => Stream.value(Duration.zero);

  @override
  Stream<Duration> get bufferedPositionStream => Stream.value(bufferedPosition);
}

class _CountingAudioCacheManager extends AudioCacheManager {
  int cacheSizeCalls = 0;
  final List<Completer<int>> _cacheSizeCompleters = [];

  @override
  Future<int> cacheSize(AppSettings settings) {
    cacheSizeCalls += 1;
    final completer = Completer<int>();
    _cacheSizeCompleters.add(completer);
    return completer.future;
  }

  void completeNext(int value) {
    _cacheSizeCompleters.removeAt(0).complete(value);
  }
}

class _BufferedAheadPlayerController extends _BufferingPlayerController {
  @override
  bool get isBuffering => false;

  @override
  Duration get position => const Duration(seconds: 2);

  @override
  Duration get bufferedPosition => const Duration(minutes: 4);

  @override
  Stream<Duration> get positionStream => Stream.value(position);

  @override
  Stream<Duration> get bufferedPositionStream => Stream.value(bufferedPosition);
}
