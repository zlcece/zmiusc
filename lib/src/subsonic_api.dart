import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'app_logger.dart';
import 'models.dart';

class SubsonicApiException implements Exception {
  const SubsonicApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SubsonicApiClient {
  SubsonicApiClient({required this.server, http.Client? httpClient})
    : _httpClient = httpClient ?? _sharedHttpClient;

  static const _apiVersion = '1.16.1';
  static const _clientName = 'zmusic';
  static const _albumCountPageSize = 500;
  static const _readRetryDelays = <Duration>[
    Duration(milliseconds: 400),
    Duration(milliseconds: 1000),
  ];
  static final http.Client _sharedHttpClient = _createSharedHttpClient();

  final ServerConfig server;
  final http.Client _httpClient;
  final Random _random = Random.secure();

  static http.Client _createSharedHttpClient() {
    final client = HttpClient()..maxConnectionsPerHost = 4;
    return IOClient(client);
  }

  Future<void> ping() async {
    await _request('ping');
  }

  String _searchCount(
    LibrarySearchScope scope, {
    required Set<LibrarySearchScope> includedScopes,
    required int count,
  }) {
    return includedScopes.contains(scope) ? '$count' : '0';
  }

  Future<LibrarySearchResults> search(
    String query, {
    LibrarySearchScope scope = LibrarySearchScope.all,
    int songCount = 60,
    int songOffset = 0,
    int albumCount = 30,
    int artistCount = 30,
  }) async {
    final payload = await _request('search3', {
      'query': query,
      'songCount': _searchCount(
        scope,
        includedScopes: const {
          LibrarySearchScope.all,
          LibrarySearchScope.songs,
        },
        count: songCount,
      ),
      'songOffset': '${songOffset < 0 ? 0 : songOffset}',
      'albumCount': _searchCount(
        scope,
        includedScopes: const {
          LibrarySearchScope.all,
          LibrarySearchScope.albums,
        },
        count: albumCount,
      ),
      'artistCount': _searchCount(
        scope,
        includedScopes: const {
          LibrarySearchScope.all,
          LibrarySearchScope.artists,
        },
        count: artistCount,
      ),
    });
    final result = payload['searchResult3'];
    if (result is! Map) {
      return const LibrarySearchResults();
    }

    return LibrarySearchResults(
      songs: _asList(result['song'])
          .whereType<Map>()
          .map((value) => _songToTrack(Map<String, Object?>.from(value)))
          .toList(),
      artists: _asList(result['artist'])
          .whereType<Map>()
          .map(
            (value) => _artistToLibraryItem(Map<String, Object?>.from(value)),
          )
          .whereType<LibrarySectionItem>()
          .toList(),
      albums: _asList(result['album'])
          .whereType<Map>()
          .map((value) => _albumToLibraryItem(Map<String, Object?>.from(value)))
          .toList(),
    );
  }

  Future<LibraryOverview> libraryOverview() async {
    final artists = await _artists();
    final albums = await _albums();
    final playlists = await _playlists();
    final songCount = await _songCount();
    final recentAlbums = await _optionalList(
      () => _albumsByListType('recent', size: 12),
    );
    final frequentAlbums = await _optionalList(
      () => _albumsByListType('frequent', size: 12),
    );
    final randomAlbums = await _optionalList(
      () => _albumsByListType('random', size: 12),
    );
    final favoriteTracks = await _optionalList(_favoriteTracks);
    final radioStations = await _optionalList(_radioStations);
    return LibraryOverview(
      artists: _withArtistArtworkFallbacks(artists, albums),
      albums: albums,
      playlists: playlists,
      latestAlbums: albums.take(12).toList(),
      recentAlbums: recentAlbums,
      frequentAlbums: frequentAlbums,
      randomAlbums: randomAlbums,
      favoriteTracks: favoriteTracks,
      radioStations: radioStations,
      songCount: songCount,
    );
  }

  Future<List<LibrarySectionItem>> artists() {
    return _artists();
  }

  Future<List<LibrarySectionItem>> albums() {
    return _albums();
  }

  Future<List<LibrarySectionItem>> albumList(String type, {int size = 30}) {
    return _albumsByListType(type, size: size);
  }

  Future<List<Track>> favoriteTracks() {
    return _favoriteTracks();
  }

  Future<List<Track>> randomSongs({int size = 100}) async {
    final payload = await _request('getRandomSongs', {
      'size': size.clamp(1, 500).toString(),
    });
    final randomSongs = payload['randomSongs'];
    if (randomSongs is! Map) {
      return [];
    }
    return _asList(randomSongs['song'])
        .whereType<Map>()
        .map((value) => _songToTrack(Map<String, Object?>.from(value)))
        .toList();
  }

  Future<List<Track>> albumTracks(String albumId) async {
    final id = albumId.trim();
    if (id.isEmpty) {
      return [];
    }
    final payload = await _request('getAlbum', {'id': id});
    final album = payload['album'];
    if (album is! Map) {
      return [];
    }
    return _asList(album['song'])
        .whereType<Map>()
        .map((value) => _songToTrack(Map<String, Object?>.from(value)))
        .toList();
  }

  Future<List<LibrarySectionItem>> playlists() {
    return _playlists();
  }

  Future<List<LibrarySectionItem>> radioStations() {
    return _radioStations();
  }

  Future<int?> songCount() {
    return _songCount();
  }

  List<LibrarySectionItem> artistsWithArtworkFallbacks(
    List<LibrarySectionItem> artists,
    List<LibrarySectionItem> albums,
  ) {
    return _withArtistArtworkFallbacks(artists, albums);
  }

  List<LibrarySectionItem> _withArtistArtworkFallbacks(
    List<LibrarySectionItem> artists,
    List<LibrarySectionItem> albums,
  ) {
    final albumCoverByArtist = <String, String>{};
    for (final album in albums) {
      final artist = album.subtitle.trim().toLowerCase();
      final coverUrl = album.coverUrl;
      if (artist.isNotEmpty && coverUrl != null && coverUrl.isNotEmpty) {
        albumCoverByArtist.putIfAbsent(artist, () => coverUrl);
      }
    }
    if (albumCoverByArtist.isEmpty) {
      return artists;
    }

    return [
      for (final artist in artists)
        if (artist.coverUrl != null && artist.coverUrl!.isNotEmpty)
          artist
        else
          LibrarySectionItem(
            id: artist.id,
            title: artist.title,
            subtitle: artist.subtitle,
            coverUrl: albumCoverByArtist[artist.title.trim().toLowerCase()],
            description: artist.description,
            isLocal: artist.isLocal,
            isPublic: artist.isPublic,
            owner: artist.owner,
            type: artist.type,
          ),
    ];
  }

  Future<List<Track>> playlistTracks(String playlistId) async {
    final id = playlistId.trim();
    if (id.isEmpty) {
      return [];
    }

    final payload = await _request('getPlaylist', {'id': id});
    final playlist = payload['playlist'];
    if (playlist is! Map) {
      return [];
    }

    return _asList(playlist['entry'])
        .whereType<Map>()
        .map((value) => _songToTrack(Map<String, Object?>.from(value)))
        .toList();
  }

  Future<LibrarySectionItem?> createPlaylist({
    required String name,
    List<String> songIds = const [],
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const SubsonicApiException('歌单名称不能为空。');
    }

    final payload = await _requestAll('createPlaylist', {
      'name': [trimmedName],
      if (songIds.isNotEmpty) 'songId': songIds,
    });
    final playlist = payload['playlist'];
    if (playlist is Map) {
      return _playlistToLibraryItem(Map<String, Object?>.from(playlist));
    }
    return null;
  }

  Future<void> updatePlaylist({
    required String playlistId,
    String? name,
    String? comment,
    bool? isPublic,
    List<String> songIdsToAdd = const [],
    List<int> songIndexesToRemove = const [],
  }) async {
    final id = playlistId.trim();
    if (id.isEmpty) {
      throw const SubsonicApiException('歌单 ID 不能为空。');
    }

    await _requestAll('updatePlaylist', {
      'playlistId': [id],
      if (name != null) 'name': [name.trim()],
      if (comment != null) 'comment': [comment.trim()],
      if (isPublic != null) 'public': [isPublic ? 'true' : 'false'],
      if (songIdsToAdd.isNotEmpty) 'songIdToAdd': songIdsToAdd,
      if (songIndexesToRemove.isNotEmpty)
        'songIndexToRemove': [
          for (final index in songIndexesToRemove) index.toString(),
        ],
    });
  }

  Future<void> deletePlaylist(String playlistId) async {
    final id = playlistId.trim();
    if (id.isEmpty) {
      throw const SubsonicApiException('歌单 ID 不能为空。');
    }
    await _request('deletePlaylist', {'id': id});
  }

  Future<void> starTrack(String songId) async {
    final id = songId.trim();
    if (id.isEmpty) {
      throw const SubsonicApiException('歌曲 ID 不能为空。');
    }
    await _request('star', {'id': id});
  }

  Future<void> unstarTrack(String songId) async {
    final id = songId.trim();
    if (id.isEmpty) {
      throw const SubsonicApiException('歌曲 ID 不能为空。');
    }
    await _request('unstar', {'id': id});
  }

  Future<void> scrobbleTrack(
    String songId, {
    required bool submission,
    DateTime? time,
  }) async {
    final id = songId.trim();
    if (id.isEmpty) {
      throw const SubsonicApiException('歌曲 ID 不能为空。');
    }
    await _request('scrobble', {
      'id': id,
      'submission': submission ? 'true' : 'false',
      if (time != null) 'time': time.millisecondsSinceEpoch.toString(),
    });
  }

  Uri streamUri(String id, {String? audioFormat}) {
    return _methodUri('stream', {
      'id': id,
      if (shouldRequestSubsonicMp3Transcode(audioFormat)) ...{
        'format': 'mp3',
        'maxBitRate': '320',
      },
    }, includeResponseFormat: false);
  }

  Uri? coverUri(String? id) {
    if (id == null || id.isEmpty) {
      return null;
    }
    return _methodUri('getCoverArt', {'id': id, 'size': '600'});
  }

  Future<String> lyricsForTrack(Track track) async {
    final songId = track.sourceItemId;
    if (songId != null && songId.isNotEmpty) {
      final lyrics = await _tryLyricsBySongId(songId);
      if (lyrics.isNotEmpty) {
        return lyrics;
      }
    }

    return _tryLyricsByArtistTitle(track.artist, track.title);
  }

  Future<String> _tryLyricsBySongId(String id) async {
    try {
      final payload = await _request('getLyricsBySongId', {'id': id});
      return _extractLyrics(payload).trim();
    } on Object {
      return '';
    }
  }

  Future<String> _tryLyricsByArtistTitle(String artist, String title) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      return '';
    }

    final parameters = <String, String>{'title': trimmedTitle};
    final trimmedArtist = artist.trim();
    if (trimmedArtist.isNotEmpty) {
      parameters['artist'] = trimmedArtist;
    }

    try {
      final payload = await _request('getLyrics', parameters);
      return _extractLyrics(payload).trim();
    } on Object {
      return '';
    }
  }

  Future<Map<String, Object?>> _request(
    String method, [
    Map<String, String> parameters = const {},
  ]) {
    return _requestAll(method, {
      for (final entry in parameters.entries) entry.key: [entry.value],
    });
  }

  Future<Map<String, Object?>> _requestAll(
    String method, [
    Map<String, List<String>> parameters = const {},
  ]) async {
    try {
      final response = await _getWithRetry(
        method,
        _methodUriAll(method, parameters),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SubsonicApiException(
          'HTTP ${response.statusCode}: ${response.reasonPhrase ?? '请求失败'}',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const SubsonicApiException('Subsonic 响应格式无效。');
      }

      final root = decoded['subsonic-response'];
      if (root is! Map) {
        throw const SubsonicApiException('缺少 Subsonic 响应根节点。');
      }

      final status = root['status']?.toString();
      if (status == 'failed') {
        final error = root['error'];
        if (error is Map) {
          final code = error['code']?.toString() ?? 'unknown';
          final message = error['message']?.toString() ?? '请求失败';
          throw SubsonicApiException('Subsonic $code: $message');
        }
        throw const SubsonicApiException('Subsonic 请求失败。');
      }

      final successLabel = method == 'scrobble'
          ? parameters['submission']?.firstOrNull == 'true'
                ? 'Subsonic scrobble（播放计次）请求成功'
                : 'Subsonic scrobble（正在播放）请求成功'
          : 'Subsonic $method 请求成功';
      AppLogger.instance.debug('network', successLabel);
      return Map<String, Object?>.from(root);
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        'network',
        'Subsonic $method 请求失败',
        error: error,
        stackTrace: stackTrace,
      );
      final userFacingError = _userFacingNetworkError(error);
      if (!identical(userFacingError, error)) {
        Error.throwWithStackTrace(userFacingError, stackTrace);
      }
      rethrow;
    }
  }

  Future<http.Response> _getWithRetry(String method, Uri uri) async {
    final canRetry = _isReadOnlyMethod(method);
    for (var attempt = 0; ; attempt += 1) {
      try {
        final response = await _httpClient.get(uri);
        if (canRetry &&
            attempt < _readRetryDelays.length &&
            _isRetryableStatusCode(response.statusCode)) {
          AppLogger.instance.warning(
            'network',
            'Subsonic $method 返回 HTTP ${response.statusCode}，正在重试',
          );
          await _waitBeforeRetry(attempt);
          continue;
        }
        return response;
      } catch (error, stackTrace) {
        if (!canRetry ||
            attempt >= _readRetryDelays.length ||
            !_isRetryableNetworkError(error)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        AppLogger.instance.warning(
          'network',
          'Subsonic $method 连接中断，正在进行第 ${attempt + 1} 次重试',
          error: error,
          stackTrace: stackTrace,
        );
        await _waitBeforeRetry(attempt);
      }
    }
  }

  Future<void> _waitBeforeRetry(int attempt) {
    final baseDelay = _readRetryDelays[attempt].inMilliseconds;
    final jitter = _random.nextInt(250);
    return Future<void>.delayed(Duration(milliseconds: baseDelay + jitter));
  }

  static bool _isReadOnlyMethod(String method) {
    return method == 'ping' || method == 'search3' || method.startsWith('get');
  }

  static bool _isRetryableStatusCode(int statusCode) {
    return statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.tooManyRequests ||
        statusCode >= HttpStatus.internalServerError;
  }

  static bool _isRetryableNetworkError(Object error) {
    if (error is HandshakeException) {
      return !_isCertificateError(error.message);
    }
    return error is SocketException || error is http.ClientException;
  }

  static Object _userFacingNetworkError(Object error) {
    if (error is HandshakeException) {
      if (_isCertificateError(error.message)) {
        return const SubsonicApiException('服务器安全证书验证失败，请检查音源地址或证书。');
      }
      return const SubsonicApiException('与音乐服务器建立安全连接失败，请检查网络后重试。');
    }
    if (error is SocketException || error is http.ClientException) {
      return const SubsonicApiException('无法连接音乐服务器，请检查网络或稍后重试。');
    }
    return error;
  }

  static bool _isCertificateError(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('certificate') ||
        normalized.contains('cert_verify_failed');
  }

  Uri _methodUri(
    String method,
    Map<String, String> parameters, {
    bool includeResponseFormat = true,
  }) {
    return _methodUriAll(method, {
      for (final entry in parameters.entries) entry.key: [entry.value],
    }, includeResponseFormat: includeResponseFormat);
  }

  Uri _methodUriAll(
    String method,
    Map<String, List<String>> parameters, {
    bool includeResponseFormat = true,
  }) {
    final base = Uri.parse(server.normalizedBaseUrl);
    final pathPrefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final path = '$pathPrefix/rest/$method.view';
    final salt = _salt();
    final token = md5.convert(utf8.encode('${server.password}$salt'));

    final queryParameters = <String, Object>{
      'u': server.username,
      't': token.toString(),
      's': salt,
      'v': _apiVersion,
      'c': _clientName,
      if (includeResponseFormat) 'f': 'json',
      for (final entry in parameters.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
      for (final entry in parameters.entries)
        if (entry.value.length != 1) entry.key: entry.value,
    };

    return base.replace(path: path, queryParameters: queryParameters);
  }

  Track _songToTrack(Map<String, Object?> value) {
    final id = readString(value, 'id');
    final durationSeconds = readInt(value, 'duration');
    final coverId = readNullableString(value, 'coverArt');
    final suffix = readNullableString(value, 'suffix');
    final contentType = readNullableString(value, 'contentType');

    final audioFormat = readAudioFormat(suffix) ?? readAudioFormat(contentType);

    return Track(
      id: '${server.id}:$id',
      title: readString(value, 'title', '未命名'),
      artist: readString(value, 'artist', '未知歌手'),
      album: readString(value, 'album'),
      streamUrl: streamUri(id, audioFormat: audioFormat).toString(),
      sourceType: MusicSourceType.subsonic,
      sourceName: server.name,
      coverUrl: coverUri(coverId)?.toString(),
      duration: durationSeconds == null
          ? null
          : Duration(seconds: durationSeconds),
      sourceServerId: server.id,
      sourceItemId: id,
      audioFormat: audioFormat,
      trackNumber: _positiveInt(value, 'track'),
    );
  }

  int? _positiveInt(Map<String, Object?> value, String key) {
    final result = readInt(value, key);
    return result != null && result > 0 ? result : null;
  }

  LibrarySectionItem? _artistToLibraryItem(Map<String, Object?> value) {
    final name = readString(value, 'name');
    if (name.isEmpty) {
      return null;
    }
    final imageUrl = readNullableString(value, 'artistImageUrl');
    final coverId = readNullableString(value, 'coverArt');
    return LibrarySectionItem(
      id: readString(value, 'id', name),
      title: name,
      subtitle: '歌手',
      coverUrl: imageUrl ?? coverUri(coverId)?.toString(),
      type: LibrarySectionType.artists,
    );
  }

  LibrarySectionItem _albumToLibraryItem(Map<String, Object?> value) {
    final coverId = readNullableString(value, 'coverArt');
    return LibrarySectionItem(
      id: readString(value, 'id', readString(value, 'name')),
      title: readString(value, 'name', '未命名专辑'),
      subtitle: readString(value, 'artist'),
      coverUrl: coverUri(coverId)?.toString(),
      type: LibrarySectionType.albums,
    );
  }

  Future<List<LibrarySectionItem>> _artists() async {
    final payload = await _request('getArtists');
    final artistsRoot = payload['artists'];
    if (artistsRoot is! Map) {
      return [];
    }

    final items = <LibrarySectionItem>[];
    for (final index in _asList(artistsRoot['index']).whereType<Map>()) {
      for (final artist in _asList(index['artist']).whereType<Map>()) {
        final value = Map<String, Object?>.from(artist);
        final item = _artistToLibraryItem(value);
        if (item != null) {
          items.add(item);
        }
      }
    }
    return items;
  }

  Future<List<LibrarySectionItem>> _albums() {
    return _albumsByListType('newest', size: 30);
  }

  Future<List<LibrarySectionItem>> _albumsByListType(
    String type, {
    int size = 30,
  }) async {
    final payload = await _request('getAlbumList2', {
      'type': type,
      'size': size.toString(),
    });
    final albumList = payload['albumList2'];
    if (albumList is! Map) {
      return [];
    }

    return _asList(albumList['album'])
        .whereType<Map>()
        .map((album) => _albumToLibraryItem(Map<String, Object?>.from(album)))
        .toList();
  }

  Future<List<Track>> _favoriteTracks() async {
    final payload = await _request('getStarred2');
    final starred = payload['starred2'];
    if (starred is! Map) {
      return [];
    }
    return _asList(starred['song'])
        .whereType<Map>()
        .map((value) => _songToTrack(Map<String, Object?>.from(value)))
        .toList();
  }

  Future<List<LibrarySectionItem>> _radioStations() async {
    final payload = await _request('getInternetRadioStations');
    final stations = payload['internetRadioStations'];
    if (stations is! Map) {
      return [];
    }
    return _asList(stations['internetRadioStation']).whereType<Map>().map((
      station,
    ) {
      final value = Map<String, Object?>.from(station);
      final streamUrl = readString(value, 'streamUrl');
      final name = readString(value, 'name', '未命名电台');
      return LibrarySectionItem(
        id: readString(value, 'id', streamUrl.isEmpty ? name : streamUrl),
        title: name,
        subtitle: streamUrl.isEmpty ? '电台' : streamUrl,
        description: readString(value, 'homePageUrl'),
        type: LibrarySectionType.radio,
      );
    }).toList();
  }

  Future<List<LibrarySectionItem>> _playlists() async {
    final payload = await _request('getPlaylists');
    final playlists = payload['playlists'];
    if (playlists is! Map) {
      return [];
    }

    return _asList(playlists['playlist'])
        .whereType<Map>()
        .map(
          (playlist) =>
              _playlistToLibraryItem(Map<String, Object?>.from(playlist)),
        )
        .toList();
  }

  LibrarySectionItem _playlistToLibraryItem(Map<String, Object?> value) {
    final songCount = readInt(value, 'songCount');
    final coverId = readNullableString(value, 'coverArt');
    final publicValue = value['public'];
    return LibrarySectionItem(
      id: readString(value, 'id', readString(value, 'name')),
      title: readString(value, 'name', '未命名歌单'),
      subtitle: songCount == null ? '歌单' : '$songCount 首歌曲',
      coverUrl: coverUri(coverId)?.toString(),
      description: readString(value, 'comment'),
      isPublic: publicValue is bool ? publicValue : null,
      owner: readString(value, 'owner'),
      type: LibrarySectionType.playlists,
    );
  }

  Future<int?> _songCount() async {
    var offset = 0;
    var total = 0;
    var foundSongCount = false;

    try {
      while (true) {
        final payload = await _request('getAlbumList2', {
          'type': 'alphabeticalByName',
          'size': _albumCountPageSize.toString(),
          'offset': offset.toString(),
        });
        final albumList = payload['albumList2'];
        if (albumList is! Map) {
          return foundSongCount ? total : null;
        }

        final albums = _asList(albumList['album']).whereType<Map>().toList();
        if (albums.isEmpty) {
          return foundSongCount ? total : null;
        }

        for (final album in albums) {
          final songCount = readInt(
            Map<String, Object?>.from(album),
            'songCount',
          );
          if (songCount == null) {
            continue;
          }
          foundSongCount = true;
          total += songCount;
        }

        if (albums.length < _albumCountPageSize) {
          return foundSongCount ? total : null;
        }
        offset += albums.length;
      }
    } on Object {
      return null;
    }
  }

  Future<List<T>> _optionalList<T>(Future<List<T>> Function() loader) async {
    try {
      return await loader();
    } on Object {
      return [];
    }
  }

  String _salt() {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  List<Object?> _asList(Object? value) {
    if (value == null) {
      return [];
    }
    if (value is List) {
      return value.cast<Object?>();
    }
    return [value];
  }

  String _extractLyrics(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value.trim();
    }
    if (value is Iterable) {
      return value
          .map(_extractLyrics)
          .where((text) => text.isNotEmpty)
          .join('\n');
    }
    if (value is Map) {
      final line = _extractLyricLines(value['line']);
      if (line.isNotEmpty) {
        return line;
      }

      final structured = _extractStructuredLyrics(value['structuredLyrics']);
      if (structured.isNotEmpty) {
        return structured;
      }

      for (final key in const [
        'lyricsList',
        'lyrics',
        'value',
        'text',
        'unsyncedLyrics',
        'syncedLyrics',
      ]) {
        final lyrics = _extractLyrics(value[key]);
        if (lyrics.isNotEmpty) {
          return lyrics;
        }
      }
    }
    return '';
  }

  String _extractStructuredLyrics(Object? value) {
    final entries = _asList(value).whereType<Map>().toList();
    if (entries.isEmpty) {
      return '';
    }

    final ordered = [
      ...entries.where((entry) => entry['synced'] == true),
      ...entries.where((entry) => entry['synced'] != true),
    ];
    for (final entry in ordered) {
      final lyrics = _extractLyricLines(entry['line']);
      if (lyrics.isNotEmpty) {
        return lyrics;
      }
    }
    return '';
  }

  String _extractLyricLines(Object? value) {
    return _asList(value)
        .map((line) {
          if (line is Map) {
            return _extractLyricLine(Map<String, Object?>.from(line));
          }
          return _extractLyrics(line);
        })
        .where((text) => text.isNotEmpty)
        .join('\n');
  }

  String _extractLyricLine(Map<String, Object?> line) {
    final text = _extractLyrics(line['value'] ?? line['text']);
    if (text.isEmpty) {
      return '';
    }

    final timestamp = _lyricTimestamp(line['start'] ?? line['time']);
    return timestamp == null ? text : '$timestamp$text';
  }

  String? _lyricTimestamp(Object? value) {
    final duration = _lyricDuration(value);
    if (duration == null) {
      return null;
    }

    final totalMinutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    final centiseconds = (duration.inMilliseconds.remainder(1000) / 10).floor();
    return '[${totalMinutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${centiseconds.toString().padLeft(2, '0')}]';
  }

  Duration? _lyricDuration(Object? value) {
    if (value is int) {
      return Duration(milliseconds: value);
    }
    if (value is num) {
      return Duration(milliseconds: value.round());
    }

    final text = value?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    final milliseconds = int.tryParse(text);
    if (milliseconds != null) {
      return Duration(milliseconds: milliseconds);
    }

    final seconds = double.tryParse(text);
    if (seconds != null) {
      return Duration(milliseconds: (seconds * 1000).round());
    }
    return null;
  }
}

bool shouldRequestSubsonicMp3Transcode(String? audioFormat) {
  return false;
}
