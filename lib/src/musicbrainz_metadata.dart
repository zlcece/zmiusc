import 'dart:convert';

import 'package:http/http.dart' as http;

enum MusicBrainzMetadataField { title, artist, album, genres, year }

class MusicBrainzMetadataCandidate {
  const MusicBrainzMetadataCandidate({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.genres,
    required this.year,
    required this.score,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String genres;
  final String year;
  final int score;

  String valueFor(MusicBrainzMetadataField field) {
    return switch (field) {
      MusicBrainzMetadataField.title => title,
      MusicBrainzMetadataField.artist => artist,
      MusicBrainzMetadataField.album => album,
      MusicBrainzMetadataField.genres => genres,
      MusicBrainzMetadataField.year => year,
    };
  }

  factory MusicBrainzMetadataCandidate.fromJson(Map<String, Object?> json) {
    final releases = _mapList(json['releases']);
    final firstRelease = releases.isEmpty ? null : releases.first;
    final firstReleaseDate = _string(json['first-release-date']);
    final releaseDate = _string(firstRelease?['date']);
    return MusicBrainzMetadataCandidate(
      id: _string(json['id']),
      title: _string(json['title']),
      artist: _artistCredit(json['artist-credit']),
      album: _string(firstRelease?['title']),
      genres: _genres(json['genres']),
      year: _year(firstReleaseDate.isEmpty ? releaseDate : firstReleaseDate),
      score: int.tryParse(_string(json['score'])) ?? 0,
    );
  }
}

class MusicBrainzMetadataService {
  MusicBrainzMetadataService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  final http.Client _httpClient;
  final bool _ownsClient;
  DateTime? _lastRequestAt;

  Future<List<MusicBrainzMetadataCandidate>> search({
    required String title,
    required String artist,
    required String album,
    int limit = 8,
  }) async {
    final queryParts = <String>[
      if (title.trim().isNotEmpty) 'recording:"${_escapeLucene(title.trim())}"',
      if (artist.trim().isNotEmpty)
        'artistname:"${_escapeLucene(artist.trim())}"',
      if (album.trim().isNotEmpty) 'release:"${_escapeLucene(album.trim())}"',
    ];
    if (queryParts.isEmpty) {
      throw Exception('请先填写标题、歌手或专辑。');
    }

    final lastRequestAt = _lastRequestAt;
    if (lastRequestAt != null) {
      final elapsed = DateTime.now().difference(lastRequestAt);
      const minimumInterval = Duration(milliseconds: 1100);
      if (elapsed < minimumInterval) {
        await Future<void>.delayed(minimumInterval - elapsed);
      }
    }
    _lastRequestAt = DateTime.now();

    final uri = Uri.https('musicbrainz.org', '/ws/2/recording/', {
      'query': queryParts.join(' AND '),
      'fmt': 'json',
      'limit': limit.clamp(1, 20).toString(),
    });
    final response = await _httpClient
        .get(
          uri,
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'Zmusic/1.0.14 (https://file.zuitimes.com/zmusic/)',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 503) {
        throw Exception('MusicBrainz 请求过于频繁，请稍后重试。');
      }
      throw Exception('MusicBrainz 查询失败：HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) {
      throw Exception('MusicBrainz 返回了无法识别的数据。');
    }
    final recordings = _mapList(decoded['recordings']);
    return recordings
        .map(MusicBrainzMetadataCandidate.fromJson)
        .where((candidate) => candidate.id.isNotEmpty)
        .toList(growable: false);
  }

  void dispose() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}

List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value
      .whereType<Map>()
      .map(
        (item) => item.map(
          (key, value) => MapEntry(key.toString(), value as Object?),
        ),
      )
      .toList(growable: false);
}

String _artistCredit(Object? value) {
  final credits = _mapList(value);
  final buffer = StringBuffer();
  for (final credit in credits) {
    final artist = credit['artist'];
    final artistMap = artist is Map
        ? artist.map((key, value) => MapEntry(key.toString(), value as Object?))
        : const <String, Object?>{};
    final name = _string(credit['name']).isNotEmpty
        ? _string(credit['name'])
        : _string(artistMap['name']);
    buffer
      ..write(name)
      ..write(_string(credit['joinphrase']));
  }
  return buffer.toString().trim();
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
