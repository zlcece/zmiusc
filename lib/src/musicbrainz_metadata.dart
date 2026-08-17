import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

enum OnlineMetadataSource { musicBrainz, kugou, kuwo, qqMusic, netease }

extension OnlineMetadataSourceLabel on OnlineMetadataSource {
  String get label => switch (this) {
    OnlineMetadataSource.musicBrainz => 'MusicBrainz',
    OnlineMetadataSource.kugou => '酷狗音乐',
    OnlineMetadataSource.kuwo => '酷我音乐',
    OnlineMetadataSource.qqMusic => 'QQ音乐',
    OnlineMetadataSource.netease => '网易云音乐',
  };
}

enum OnlineMetadataField { title, artist, album, genres, year, trackNumber }

class OnlineMetadataCandidate {
  const OnlineMetadataCandidate({
    required this.source,
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.genres,
    required this.year,
    required this.trackNumber,
    required this.artworkUrl,
    this.score = 0,
  });

  final OnlineMetadataSource source;
  final String id;
  final String title;
  final String artist;
  final String album;
  final String genres;
  final String year;
  final String trackNumber;
  final String artworkUrl;
  final int score;

  String valueFor(OnlineMetadataField field) {
    return switch (field) {
      OnlineMetadataField.title => title,
      OnlineMetadataField.artist => artist,
      OnlineMetadataField.album => album,
      OnlineMetadataField.genres => genres,
      OnlineMetadataField.year => year,
      OnlineMetadataField.trackNumber => trackNumber,
    };
  }
}

class OnlineMetadataArtwork {
  const OnlineMetadataArtwork({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

class OnlineMetadataService {
  OnlineMetadataService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  final http.Client _httpClient;
  final bool _ownsClient;
  DateTime? _lastMusicBrainzRequestAt;

  Future<List<OnlineMetadataCandidate>> search({
    required OnlineMetadataSource source,
    required String title,
    required String artist,
    required String album,
    int limit = 8,
  }) async {
    final query = _searchQuery(title: title, artist: artist, album: album);
    if (query.isEmpty) {
      throw Exception('请先填写标题、歌手或专辑。');
    }
    final boundedLimit = limit.clamp(1, 20);
    return switch (source) {
      OnlineMetadataSource.musicBrainz => _searchMusicBrainz(
        title: title,
        artist: artist,
        album: album,
        limit: boundedLimit,
      ),
      OnlineMetadataSource.kugou => _searchKugou(query, boundedLimit),
      OnlineMetadataSource.kuwo => _searchKuwo(query, boundedLimit),
      OnlineMetadataSource.qqMusic => _searchQqMusic(query, boundedLimit),
      OnlineMetadataSource.netease => _searchNetease(query, boundedLimit),
    };
  }

  Future<OnlineMetadataArtwork?> downloadArtwork(String artworkUrl) async {
    final uri = Uri.tryParse(artworkUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final response = await _httpClient
        .get(uri)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('专辑封面下载失败：HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.isEmpty) {
      throw Exception('专辑封面下载失败：图片内容为空。');
    }
    const maximumArtworkBytes = 10 * 1024 * 1024;
    if (response.bodyBytes.length > maximumArtworkBytes) {
      throw Exception('专辑封面超过 10 MB，无法写入。');
    }
    final mimeType = _imageMimeType(
      response.headers['content-type'],
      response.bodyBytes,
    );
    if (mimeType == null) {
      throw Exception('专辑封面格式无法识别。');
    }
    return OnlineMetadataArtwork(
      bytes: Uint8List.fromList(response.bodyBytes),
      mimeType: mimeType,
    );
  }

  Future<List<OnlineMetadataCandidate>> _searchMusicBrainz({
    required String title,
    required String artist,
    required String album,
    required int limit,
  }) async {
    final queryParts = <String>[
      if (title.trim().isNotEmpty) 'recording:"${_escapeLucene(title.trim())}"',
      if (artist.trim().isNotEmpty)
        'artistname:"${_escapeLucene(artist.trim())}"',
      if (album.trim().isNotEmpty) 'release:"${_escapeLucene(album.trim())}"',
    ];
    final lastRequestAt = _lastMusicBrainzRequestAt;
    if (lastRequestAt != null) {
      final elapsed = DateTime.now().difference(lastRequestAt);
      const minimumInterval = Duration(milliseconds: 1100);
      if (elapsed < minimumInterval) {
        await Future<void>.delayed(minimumInterval - elapsed);
      }
    }
    _lastMusicBrainzRequestAt = DateTime.now();

    final response = await _httpClient
        .get(
          Uri.https('musicbrainz.org', '/ws/2/recording/', {
            'query': queryParts.join(' AND '),
            'fmt': 'json',
            'limit': limit.toString(),
          }),
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'Zmusic/1.0.17 (https://file.zuitimes.com/zmusic/)',
          },
        )
        .timeout(const Duration(seconds: 15));
    final payload = _decodeResponse(response, 'MusicBrainz');
    return _mapList(payload['recordings'])
        .map((value) {
          final releases = _mapList(value['releases']);
          final release = releases.firstOrNull;
          final firstReleaseDate = _string(value['first-release-date']);
          final releaseDate = _string(release?['date']);
          return OnlineMetadataCandidate(
            source: OnlineMetadataSource.musicBrainz,
            id: _string(value['id']),
            title: _string(value['title']),
            artist: _artistCredit(value['artist-credit']),
            album: _string(release?['title']),
            genres: _genres(value['genres']),
            year: _year(
              firstReleaseDate.isEmpty ? releaseDate : firstReleaseDate,
            ),
            trackNumber: '',
            artworkUrl: _musicBrainzArtworkUrl(release),
            score: _readInt(value['score']) ?? 0,
          );
        })
        .where((candidate) => candidate.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<OnlineMetadataCandidate>> _searchKugou(
    String query,
    int limit,
  ) async {
    final response = await _httpClient
        .get(
          Uri.https('songsearch.kugou.com', '/song_search_v2', {
            'keyword': query,
            'page': '1',
            'pagesize': limit.toString(),
            'platform': 'WebFilter',
          }),
        )
        .timeout(const Duration(seconds: 15));
    final payload = _decodeResponse(response, '酷狗音乐');
    if (_readInt(payload['status']) != 1) {
      throw Exception('酷狗音乐搜索失败：${_string(payload['error_msg'])}');
    }
    final data = _asMap(payload['data']);
    return _mapList(data?['lists'])
        .map(
          (value) => OnlineMetadataCandidate(
            source: OnlineMetadataSource.kugou,
            id: _string(value['FileHash']).isNotEmpty
                ? _string(value['FileHash'])
                : _string(value['ID']),
            title: _string(value['SongName']),
            artist: _string(value['SingerName']),
            album: _string(value['AlbumName']),
            genres: '',
            year: _year(_string(value['PublishDate'])),
            trackNumber: '',
            artworkUrl: _kugouArtworkUrl(value),
          ),
        )
        .where((candidate) => candidate.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<OnlineMetadataCandidate>> _searchKuwo(
    String query,
    int limit,
  ) async {
    final response = await _httpClient
        .get(
          Uri.https('search.kuwo.cn', '/r.s', {
            'client': 'kt',
            'all': query,
            'pn': '0',
            'rn': limit.toString(),
            'ft': 'music',
            'encoding': 'utf8',
            'rformat': 'json',
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('酷我音乐搜索失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(
      _pythonLiteralToJson(utf8.decode(response.bodyBytes)),
    );
    final payload = _asMap(decoded);
    if (payload == null) {
      throw Exception('酷我音乐返回了无法识别的数据。');
    }
    return _mapList(payload['abslist'])
        .map(
          (value) => OnlineMetadataCandidate(
            source: OnlineMetadataSource.kuwo,
            id: _string(value['MUSICRID']).replaceFirst('MUSIC_', ''),
            title: _decodeBasicHtml(
              _string(value['SONGNAME']).isNotEmpty
                  ? _string(value['SONGNAME'])
                  : _string(value['NAME']),
            ),
            artist: _decodeBasicHtml(_string(value['ARTIST'])),
            album: _decodeBasicHtml(_string(value['ALBUM'])),
            genres: '',
            year: '',
            trackNumber: '',
            artworkUrl: _kuwoArtworkUrl(value),
            score: _readInt(value['SCORE100']) ?? 0,
          ),
        )
        .where((candidate) => candidate.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<OnlineMetadataCandidate>> _searchQqMusic(
    String query,
    int limit,
  ) async {
    final response = await _httpClient
        .get(
          Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp', {
            'p': '1',
            'n': limit.toString(),
            'w': query,
            'format': 'json',
          }),
          headers: const {'Referer': 'https://y.qq.com/'},
        )
        .timeout(const Duration(seconds: 15));
    final payload = _decodeResponse(response, 'QQ音乐');
    if (_readInt(payload['code']) != 0) {
      throw Exception('QQ音乐搜索失败。');
    }
    final data = _asMap(payload['data']);
    final songs = _asMap(data?['song']);
    return _mapList(songs?['list'])
        .map(
          (value) => OnlineMetadataCandidate(
            source: OnlineMetadataSource.qqMusic,
            id: _string(value['songmid']),
            title: _string(value['songname']),
            artist: _artistNames(value['singer']),
            album: _string(value['albumname']),
            genres: '',
            year: _yearFromUnixSeconds(value['pubtime']),
            trackNumber: _positiveNumber(value['cdIdx']),
            artworkUrl: _qqArtworkUrl(value),
          ),
        )
        .where((candidate) => candidate.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<OnlineMetadataCandidate>> _searchNetease(
    String query,
    int limit,
  ) async {
    final response = await _httpClient
        .post(
          Uri.parse('https://music.163.com/api/cloudsearch/pc'),
          headers: const {
            'Referer': 'https://music.163.com/',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {
            's': query,
            'type': '1',
            'offset': '0',
            'limit': limit.toString(),
            'total': 'true',
          },
        )
        .timeout(const Duration(seconds: 15));
    final payload = _decodeResponse(response, '网易云音乐');
    if (_readInt(payload['code']) != 200) {
      throw Exception('网易云音乐搜索失败：${_string(payload['message'])}');
    }
    final result = _asMap(payload['result']);
    return _mapList(result?['songs'])
        .map((value) {
          final album = _asMap(value['al']) ?? _asMap(value['album']);
          return OnlineMetadataCandidate(
            source: OnlineMetadataSource.netease,
            id: _string(value['id']),
            title: _string(value['name']),
            artist: _artistNames(value['ar'] ?? value['artists']),
            album: _string(album?['name']),
            genres: '',
            year: _yearFromUnixMilliseconds(value['publishTime']),
            trackNumber: _positiveNumber(value['no']),
            artworkUrl: _secureImageUrl(_string(album?['picUrl'])),
          );
        })
        .where((candidate) => candidate.id.isNotEmpty)
        .toList(growable: false);
  }

  void dispose() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}

Map<String, Object?> _decodeResponse(http.Response response, String service) {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('$service 搜索失败：HTTP ${response.statusCode}');
  }
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  final payload = _asMap(decoded);
  if (payload == null) {
    throw Exception('$service 返回了无法识别的数据。');
  }
  return payload;
}

Map<String, Object?>? _asMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return value.map((key, value) => MapEntry(key.toString(), value as Object?));
}

List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value.map(_asMap).whereType<Map<String, Object?>>().toList();
}

String _searchQuery({
  required String title,
  required String artist,
  required String album,
}) {
  final values = <String>[];
  for (final value in [title, artist, album]) {
    final normalized = value.trim();
    if (normalized.isNotEmpty && !values.contains(normalized)) {
      values.add(normalized);
    }
  }
  return values.join(' ');
}

String _artistCredit(Object? value) {
  final buffer = StringBuffer();
  for (final credit in _mapList(value)) {
    final artist = _asMap(credit['artist']);
    final name = _string(credit['name']).isNotEmpty
        ? _string(credit['name'])
        : _string(artist?['name']);
    buffer
      ..write(name)
      ..write(_string(credit['joinphrase']));
  }
  return buffer.toString().trim();
}

String _artistNames(Object? value) {
  if (value is! List) {
    return _string(value);
  }
  return value
      .map(_asMap)
      .whereType<Map<String, Object?>>()
      .map((artist) => _string(artist['name']))
      .where((name) => name.isNotEmpty)
      .join('/');
}

String _musicBrainzArtworkUrl(Map<String, Object?>? release) {
  final releaseId = _string(release?['id']);
  return releaseId.isEmpty
      ? ''
      : 'https://coverartarchive.org/release/$releaseId/front-500';
}

String _kugouArtworkUrl(Map<String, Object?> value) {
  final direct = _string(value['Image']);
  final transParam = _asMap(value['trans_param']);
  final template = direct.isNotEmpty
      ? direct
      : _string(transParam?['union_cover']);
  return _secureImageUrl(template.replaceAll('{size}', '400'));
}

String _kuwoArtworkUrl(Map<String, Object?> value) {
  final path = _string(value['web_albumpic_short']);
  if (path.isEmpty) {
    return '';
  }
  final normalized = path.replaceFirst(RegExp(r'^\d+/'), '');
  return 'https://img1.kuwo.cn/star/albumcover/500/$normalized';
}

String _qqArtworkUrl(Map<String, Object?> value) {
  final albumMid = _string(value['albummid']);
  return albumMid.isEmpty
      ? ''
      : 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumMid.jpg';
}

String _secureImageUrl(String value) {
  return value.trim().replaceFirst(RegExp(r'^http://'), 'https://');
}

String _genres(Object? value) {
  return _mapList(value)
      .map((genre) => _string(genre['name']))
      .where((name) => name.isNotEmpty)
      .join(', ');
}

String _year(String value) {
  final match = RegExp(r'^\d{4}').firstMatch(value.trim());
  return match?.group(0) ?? '';
}

String _yearFromUnixSeconds(Object? value) {
  final seconds = _readInt(value);
  if (seconds == null || seconds <= 0) {
    return '';
  }
  return DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).year.toString();
}

String _yearFromUnixMilliseconds(Object? value) {
  final milliseconds = _readInt(value);
  if (milliseconds == null || milliseconds <= 0) {
    return '';
  }
  return DateTime.fromMillisecondsSinceEpoch(
    milliseconds,
    isUtc: true,
  ).year.toString();
}

String _positiveNumber(Object? value) {
  final number = _readInt(value);
  return number == null || number <= 0 ? '' : number.toString();
}

int? _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(_string(value));
}

String? _imageMimeType(String? contentType, List<int> bytes) {
  final normalized = contentType?.split(';').first.trim().toLowerCase();
  if (normalized != null && normalized.startsWith('image/')) {
    return normalized;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}

String _string(Object? value) => value?.toString().trim() ?? '';

String _escapeLucene(String value) {
  const specialCharacters = r'+-&|!(){}[]^"~*?:\/';
  final escaped = StringBuffer();
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    if (specialCharacters.contains(character)) {
      escaped.write(r'\');
    }
    escaped.write(character);
  }
  return escaped.toString();
}

String _decodeBasicHtml(String value) {
  return value
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();
}

String _pythonLiteralToJson(String value) {
  final output = StringBuffer();
  var inString = false;
  var escaped = false;
  for (var index = 0; index < value.length; index += 1) {
    final character = value[index];
    if (inString) {
      if (escaped) {
        if (character == "'") {
          output.write("'");
        } else {
          output
            ..write(r'\')
            ..write(character);
        }
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == "'") {
        output.write('"');
        inString = false;
      } else if (character == '"') {
        output.write(r'\"');
      } else {
        output.write(character);
      }
      continue;
    }
    if (character == "'") {
      output.write('"');
      inString = true;
      continue;
    }
    output.write(character);
  }
  if (escaped || inString) {
    throw const FormatException('酷我音乐返回的数据格式不完整。');
  }
  return output
      .toString()
      .replaceAll(RegExp(r'\bNone\b'), 'null')
      .replaceAll(RegExp(r'\bTrue\b'), 'true')
      .replaceAll(RegExp(r'\bFalse\b'), 'false');
}
