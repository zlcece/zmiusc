import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'subsonic_api.dart';

class ExternalPlaylistTrack {
  const ExternalPlaylistTrack({
    required this.title,
    required this.artists,
    this.album = '',
  });

  final String title;
  final String artists;
  final String album;
}

class ExternalPlaylist {
  const ExternalPlaylist({
    required this.name,
    required this.platformName,
    required this.tracks,
  });

  final String name;
  final String platformName;
  final List<ExternalPlaylistTrack> tracks;
}

class PlaylistMatchResult {
  const PlaylistMatchResult({
    required this.playlist,
    required this.matchedTracks,
    required this.missingTracks,
    required this.duplicateMatchCount,
  });

  final ExternalPlaylist playlist;
  final List<Track> matchedTracks;
  final List<ExternalPlaylistTrack> missingTracks;
  final int duplicateMatchCount;
}

class PlaylistSyncProgress {
  const PlaylistSyncProgress({
    required this.completed,
    required this.total,
    required this.message,
  });

  final int completed;
  final int total;
  final String message;

  double get fraction => total <= 0 ? 0 : completed / total;
}

class PlaylistSyncResult {
  const PlaylistSyncResult({
    required this.playlistName,
    required this.sourceCount,
    required this.matchedCount,
    required this.addedCount,
    required this.alreadyPresentCount,
    required this.missingTracks,
    required this.duplicateMatchCount,
    required this.createdPlaylist,
  });

  final String playlistName;
  final int sourceCount;
  final int matchedCount;
  final int addedCount;
  final int alreadyPresentCount;
  final List<ExternalPlaylistTrack> missingTracks;
  final int duplicateMatchCount;
  final bool createdPlaylist;

  int get missingCount => missingTracks.length;
}

class PlaylistMergeResult {
  const PlaylistMergeResult({
    required this.sourceTrackCount,
    required this.addedCount,
    required this.skippedCount,
  });

  final int sourceTrackCount;
  final int addedCount;
  final int skippedCount;
}

class PlaylistSyncService {
  PlaylistSyncService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  static const _matchConcurrency = 4;
  final http.Client _httpClient;

  Future<ExternalPlaylist> fetchPlaylist(String urlOrId) {
    final value = urlOrId.trim();
    if (value.isEmpty) {
      throw const FormatException('请输入网易云音乐或 QQ 音乐歌单地址。');
    }
    return _isQqPlaylist(value)
        ? _fetchQqPlaylist(value)
        : _fetchNeteasePlaylist(value);
  }

  Future<PlaylistMatchResult> matchPlaylist(
    ExternalPlaylist playlist,
    SubsonicApiClient client, {
    bool allowDifferentArtistSameTitle = false,
    bool preferHighQuality = false,
    void Function(PlaylistSyncProgress progress)? onProgress,
  }) async {
    final matched = <Track>[];
    final missing = <ExternalPlaylistTrack>[];
    final usedIds = <String>{};
    var duplicateCount = 0;

    onProgress?.call(
      PlaylistSyncProgress(
        completed: 0,
        total: playlist.tracks.length,
        message: '正在匹配 ${playlist.platformName} 歌曲',
      ),
    );

    for (
      var start = 0;
      start < playlist.tracks.length;
      start += _matchConcurrency
    ) {
      final end = (start + _matchConcurrency).clamp(0, playlist.tracks.length);
      final chunk = playlist.tracks.sublist(start, end);
      final results = await Future.wait([
        for (final sourceTrack in chunk)
          _matchTrack(
            sourceTrack,
            client,
            allowDifferentArtistSameTitle: allowDifferentArtistSameTitle,
            preferHighQuality: preferHighQuality,
          ),
      ]);
      for (var index = 0; index < chunk.length; index += 1) {
        final track = results[index];
        if (track == null) {
          missing.add(chunk[index]);
          continue;
        }
        final id = track.sourceItemId ?? track.id;
        if (!usedIds.add(id)) {
          duplicateCount += 1;
          continue;
        }
        matched.add(track);
      }
      onProgress?.call(
        PlaylistSyncProgress(
          completed: end,
          total: playlist.tracks.length,
          message: '已匹配 $end / ${playlist.tracks.length}',
        ),
      );
    }

    return PlaylistMatchResult(
      playlist: playlist,
      matchedTracks: matched,
      missingTracks: missing,
      duplicateMatchCount: duplicateCount,
    );
  }

  Future<Track?> _matchTrack(
    ExternalPlaylistTrack source,
    SubsonicApiClient client, {
    required bool allowDifferentArtistSameTitle,
    required bool preferHighQuality,
  }) async {
    if (source.title.trim().isEmpty) {
      return null;
    }
    final results = await client.search(
      source.title,
      scope: LibrarySearchScope.songs,
      songCount: 12,
      artistCount: 0,
      albumCount: 0,
    );
    final sourceTitles = _titleVariants(source.title);
    final titleMatches = results.songs.where((track) {
      return _titleVariants(track.title).any(sourceTitles.contains);
    }).toList();
    if (titleMatches.isEmpty) {
      return null;
    }

    final artistMatches = titleMatches
        .where((track) => _artistsMatch(source.artists, track.artist))
        .toList();
    if (source.artists.trim().isNotEmpty &&
        artistMatches.isEmpty &&
        !allowDifferentArtistSameTitle) {
      return null;
    }
    final candidates = artistMatches.isEmpty ? titleMatches : artistMatches;
    candidates.sort((left, right) {
      final rank =
          _formatRank(
            left.audioFormat,
            preferHighQuality: preferHighQuality,
          ).compareTo(
            _formatRank(
              right.audioFormat,
              preferHighQuality: preferHighQuality,
            ),
          );
      return rank != 0 ? rank : left.title.compareTo(right.title);
    });
    return candidates.first;
  }

  Future<ExternalPlaylist> _fetchNeteasePlaylist(String value) async {
    final resolvedValue = await _resolveNeteasePlaylistValue(value);
    final playlistId = _playlistId(resolvedValue, qq: false);
    final endpoints = [
      'https://music.163.com/api/v6/playlist/detail?id=$playlistId&n=10000&s=0',
      'https://music.163.com/api/playlist/detail?id=$playlistId&n=10000&s=0',
      'https://interface.music.163.com/api/v6/playlist/detail?id=$playlistId&n=10000&s=0',
    ];
    Map<String, Object?>? playlist;
    Object? lastError;
    for (final endpoint in endpoints) {
      try {
        final payload = await _getJson(
          Uri.parse(endpoint),
          headers: const {'Referer': 'https://music.163.com/'},
        );
        playlist = _asMap(payload['playlist']);
        if (playlist != null) {
          break;
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (playlist == null) {
      throw Exception('获取网易云歌单失败：${lastError ?? '响应无歌单信息'}');
    }

    final orderedIds = [
      for (final value in _asList(playlist['trackIds']))
        if (_asMap(value)?['id'] != null) _asMap(value)!['id'].toString(),
    ];
    final tracksById = <String, ExternalPlaylistTrack>{};
    for (final rawTrack in _asList(playlist['tracks'])) {
      final track = _asMap(rawTrack);
      if (track == null) {
        continue;
      }
      final id = track['id']?.toString() ?? '';
      if (id.isNotEmpty) {
        tracksById[id] = _neteaseTrack(track);
      }
    }

    final missingIds = orderedIds
        .where((id) => !tracksById.containsKey(id))
        .toList();
    for (var start = 0; start < missingIds.length; start += 200) {
      final end = (start + 200).clamp(0, missingIds.length);
      final ids = missingIds.sublist(start, end).map(int.parse).toList();
      final uri = Uri.https('music.163.com', '/api/song/detail', {
        'ids': jsonEncode(ids),
      });
      final payload = await _getJson(
        uri,
        headers: const {'Referer': 'https://music.163.com/'},
      );
      for (final rawTrack in _asList(payload['songs'])) {
        final track = _asMap(rawTrack);
        if (track == null) {
          continue;
        }
        final id = track['id']?.toString() ?? '';
        if (id.isNotEmpty) {
          tracksById[id] = _neteaseTrack(track);
        }
      }
    }

    final tracks = orderedIds.isEmpty
        ? tracksById.values.toList()
        : [for (final id in orderedIds) ?tracksById[id]];
    return ExternalPlaylist(
      name: playlist['name']?.toString().trim().isNotEmpty == true
          ? playlist['name'].toString().trim()
          : '网易云歌单-$playlistId',
      platformName: '网易云音乐',
      tracks: tracks,
    );
  }

  Future<String> _resolveNeteasePlaylistValue(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !_isNeteaseShortLink(uri)) {
      return value;
    }

    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await _httpClient.send(request);
    await response.stream.drain<void>();
    final location = response.headers['location'];
    if (response.statusCode < 300 ||
        response.statusCode >= 400 ||
        location == null ||
        location.trim().isEmpty) {
      throw const FormatException('无法解析网易云短链接。');
    }
    return uri.resolve(location.trim()).toString();
  }

  Future<ExternalPlaylist> _fetchQqPlaylist(String value) async {
    final playlistId = _playlistId(value, qq: true);
    const pageSize = 500;
    var offset = 0;
    var expectedCount = pageSize;
    String name = '';
    final tracks = <ExternalPlaylistTrack>[];
    while (offset < expectedCount) {
      final body = await _fetchQqPlaylistPage(playlistId, offset, pageSize);
      final info = _asMap(body['dirinfo']) ?? const <String, Object?>{};
      name = name.isEmpty ? info['title']?.toString().trim() ?? '' : name;
      expectedCount = _readInt(info['songnum']) ?? tracks.length;
      final page = _asList(body['songlist']);
      if (page.isEmpty) {
        break;
      }
      for (final rawTrack in page) {
        final track = _asMap(rawTrack);
        if (track != null) {
          tracks.add(_qqTrack(track));
        }
      }
      offset = tracks.length;
    }
    return ExternalPlaylist(
      name: name.isEmpty ? 'QQ音乐歌单-$playlistId' : name,
      platformName: 'QQ音乐',
      tracks: tracks,
    );
  }

  Future<Map<String, Object?>> _fetchQqPlaylistPage(
    String playlistId,
    int offset,
    int pageSize,
  ) async {
    final response = await _httpClient.post(
      Uri.parse('https://u.y.qq.com/cgi-bin/musicu.fcg'),
      headers: const {
        'Content-Type': 'application/json',
        'Referer': 'https://y.qq.com/',
        'Origin': 'https://y.qq.com',
      },
      body: jsonEncode({
        'comm': {'ct': 24, 'cv': 0},
        'req_0': {
          'module': 'music.srfDissInfo.aiDissInfo',
          'method': 'uniform_get_Dissinfo',
          'param': {
            'disstid': int.parse(playlistId),
            'userinfo': 1,
            'tag': 1,
            'song_begin': offset,
            'song_num': pageSize,
          },
        },
      }),
    );
    final payload = _decodeResponse(response);
    final request = _asMap(payload['req_0']);
    final body = _asMap(request?['data']);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        payload['code'] != 0 ||
        request?['code'] != 0 ||
        body == null) {
      throw Exception('获取 QQ 音乐歌单失败。');
    }
    return body;
  }

  Future<Map<String, Object?>> _getJson(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final response = await _httpClient.get(uri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return _decodeResponse(response);
  }
}

Map<String, Object?> _decodeResponse(http.Response response) {
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  if (decoded is! Map) {
    throw const FormatException('歌单服务响应格式无效。');
  }
  return Map<String, Object?>.from(decoded);
}

ExternalPlaylistTrack _neteaseTrack(Map<String, Object?> value) {
  final album = _asMap(value['al']) ?? _asMap(value['album']);
  return ExternalPlaylistTrack(
    title: value['name']?.toString() ?? '',
    artists: _artistNames(value['ar'] ?? value['artists']),
    album: album?['name']?.toString() ?? '',
  );
}

ExternalPlaylistTrack _qqTrack(Map<String, Object?> value) {
  final album = _asMap(value['album']);
  return ExternalPlaylistTrack(
    title: value['title']?.toString() ?? value['name']?.toString() ?? '',
    artists: _artistNames(value['singer'] ?? value['singers']),
    album: album?['title']?.toString() ?? album?['name']?.toString() ?? '',
  );
}

String _artistNames(Object? value) {
  if (value is! List) {
    return value?.toString() ?? '';
  }
  return value
      .map((item) => _asMap(item)?['name']?.toString() ?? item.toString())
      .where((name) => name.trim().isNotEmpty)
      .join('/');
}

String _playlistId(String value, {required bool qq}) {
  final trimmed = value.trim();
  final raw = qq && trimmed.toLowerCase().startsWith('qq:')
      ? trimmed.substring(3).trim()
      : trimmed;
  if (RegExp(r'^\d+$').hasMatch(raw)) {
    return raw;
  }
  final uri = Uri.tryParse(raw);
  if (uri != null) {
    for (final key in qq ? const ['id', 'disstid'] : const ['id']) {
      final id = uri.queryParameters[key];
      if (id != null && RegExp(r'^\d+$').hasMatch(id)) {
        return id;
      }
    }
  }
  final pattern = qq
      ? RegExp(r'(?:playlist/|[?&](?:id|disstid)=)(\d+)', caseSensitive: false)
      : RegExp(r'(?:playlist\?id=|[?&]id=)(\d+)', caseSensitive: false);
  final match = pattern.firstMatch(raw);
  if (match != null) {
    return match.group(1)!;
  }
  throw FormatException(qq ? '无法识别 QQ 音乐歌单地址。' : '无法识别网易云歌单地址。');
}

bool _isQqPlaylist(String value) {
  final lower = value.trim().toLowerCase();
  return lower.startsWith('qq:') || lower.contains('qq.com');
}

bool _isNeteaseShortLink(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == '163cn.tv' || host.endsWith('.163cn.tv');
}

Set<String> _titleVariants(String value) {
  final raw = value.trim().replaceFirst(
    RegExp(r'\.(mp3|flac|ape|m4a|wav|aac|ogg)$', caseSensitive: false),
    '',
  );
  if (raw.isEmpty) {
    return const {};
  }
  final pieces = <String>{raw};
  for (final separator in const [' - ', '-', '–', '—', '_']) {
    final index = raw.indexOf(separator);
    if (index >= 0 && index + separator.length < raw.length) {
      pieces.add(raw.substring(index + separator.length).trim());
    }
  }
  for (final piece in pieces.toList()) {
    final stripped = piece
        .replaceAll(RegExp(r'[\(\[（【].*?[\)\]）】]'), '')
        .trim();
    if (stripped.isNotEmpty) {
      pieces.add(stripped);
    }
  }
  return pieces.map(_normalizeText).where((value) => value.isNotEmpty).toSet();
}

bool _artistsMatch(String source, String candidate) {
  final sourceParts = _artistParts(source);
  if (sourceParts.isEmpty) {
    return true;
  }
  final candidateParts = _artistParts(candidate);
  return sourceParts.any(
    (left) => candidateParts.any(
      (right) =>
          left == right ||
          (left.length >= 2 && right.contains(left)) ||
          (right.length >= 2 && left.contains(right)),
    ),
  );
}

Set<String> _artistParts(String value) {
  return value
      .replaceAll('、', '/')
      .replaceAll('，', '/')
      .split(
        RegExp(
          r'/|,|&|\+|\band\b|\bfeat\.?\b|\bft\.?\b|;|；',
          caseSensitive: false,
        ),
      )
      .map(_normalizeText)
      .where((part) => part.isNotEmpty)
      .toSet();
}

String _normalizeText(String value) {
  return value
      .toLowerCase()
      .replaceAll('＆', '&')
      .replaceAll('＋', '+')
      .replaceAll('·', '')
      .replaceAll(
        RegExp(r'''[\s\-_.,，。!！?？:：;；'"“”‘’/\\|&+~《》<>\[\]{}()（）]+'''),
        '',
      );
}

int _formatRank(String? value, {required bool preferHighQuality}) {
  final format = (value ?? '').trim().toLowerCase().replaceFirst('.', '');
  if (preferHighQuality) {
    return switch (format) {
      'ape' => 0,
      'flac' => 1,
      'mp3' => 2,
      _ => 9,
    };
  }
  return switch (format) {
    'mp3' => 0,
    'flac' => 1,
    'ape' => 2,
    _ => 9,
  };
}

Map<String, Object?>? _asMap(Object? value) {
  return value is Map ? Map<String, Object?>.from(value) : null;
}

List<Object?> _asList(Object? value) {
  if (value is List) {
    return value;
  }
  return value == null ? const [] : [value];
}

int? _readInt(Object? value) {
  return value is int ? value : int.tryParse(value?.toString() ?? '');
}
