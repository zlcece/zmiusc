import 'dart:io';
import 'dart:math';

import 'models.dart';

LibraryOverview buildLocalLibraryOverview(List<Track> tracks) {
  final artistCounts = <String, int>{};
  final albumCounts = <String, int>{};
  final albumArtists = <String, String>{};
  final artistCovers = <String, String>{};
  final albumCovers = <String, String>{};

  for (final track in tracks) {
    final artist = _displayArtist(track.artist);
    artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
    final coverUrl = track.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      artistCovers.putIfAbsent(artist, () => coverUrl);
    }

    final album = track.album.trim();
    if (album.isNotEmpty) {
      albumCounts[album] = (albumCounts[album] ?? 0) + 1;
      albumArtists.putIfAbsent(album, () => artist);
      if (coverUrl != null && coverUrl.isNotEmpty) {
        albumCovers.putIfAbsent(album, () => coverUrl);
      }
    }
  }

  final artists = artistCounts.entries
      .map(
        (entry) => LibrarySectionItem(
          id: 'local-artist:${entry.key}',
          title: entry.key,
          subtitle: '${entry.value} 首',
          coverUrl: artistCovers[entry.key],
          type: LibrarySectionType.artists,
        ),
      )
      .toList();

  final albums = albumCounts.entries
      .map(
        (entry) => LibrarySectionItem(
          id: 'local-album:${entry.key}',
          title: entry.key,
          subtitle: '${albumArtists[entry.key] ?? '未知歌手'} · ${entry.value} 首',
          coverUrl: albumCovers[entry.key],
          type: LibrarySectionType.albums,
        ),
      )
      .toList();

  final randomAlbums = [...albums]..shuffle(Random(0));

  return LibraryOverview(
    artists: artists,
    albums: albums,
    latestAlbums: albums.take(12).toList(),
    recentAlbums: albums.reversed.take(12).toList(),
    frequentAlbums: albums.take(12).toList(),
    randomAlbums: randomAlbums.take(12).toList(),
    songCount: tracks.length,
  );
}

LibrarySearchResults searchLocalLibrary(
  List<Track> tracks,
  String query, {
  LibrarySearchScope scope = LibrarySearchScope.all,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) {
    return const LibrarySearchResults();
  }

  final songs =
      scope == LibrarySearchScope.artists || scope == LibrarySearchScope.albums
      ? const <Track>[]
      : tracks
            .where(
              (track) =>
                  _contains(track.title, normalizedQuery) ||
                  _contains(track.artist, normalizedQuery) ||
                  _contains(track.album, normalizedQuery),
            )
            .toList();

  final overview = buildLocalLibraryOverview(tracks);
  final artists =
      scope == LibrarySearchScope.songs || scope == LibrarySearchScope.albums
      ? const <LibrarySectionItem>[]
      : overview.artists
            .where((item) => _contains(item.title, normalizedQuery))
            .toList();
  final albums =
      scope == LibrarySearchScope.songs || scope == LibrarySearchScope.artists
      ? const <LibrarySectionItem>[]
      : overview.albums
            .where(
              (item) =>
                  _contains(item.title, normalizedQuery) ||
                  _contains(item.subtitle, normalizedQuery),
            )
            .toList();

  return LibrarySearchResults(songs: songs, artists: artists, albums: albums);
}

Future<List<Track>> scanLocalAudioFolder({
  required ServerConfig source,
  Future<LocalAudioMetadata> Function(String path)? metadataReader,
}) async {
  if (!source.isLocalFolder) {
    return const [];
  }

  final root = Directory(source.localPath);
  if (!root.existsSync()) {
    throw Exception('本地音乐文件夹不存在。');
  }

  final readMetadata = metadataReader ?? _readBasicMetadata;
  final tracks = <Track>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File || !isSupportedAudioPath(entity.path)) {
      continue;
    }
    try {
      final metadata = await readMetadata(entity.path);
      tracks.add(localMetadataToTrack(metadata, source));
    } catch (_) {
      continue;
    }
  }
  tracks.sort((left, right) {
    final artist = left.artist.compareTo(right.artist);
    if (artist != 0) {
      return artist;
    }
    final album = left.album.compareTo(right.album);
    if (album != 0) {
      return album;
    }
    return left.title.compareTo(right.title);
  });
  return tracks;
}

Track localMetadataToTrack(LocalAudioMetadata metadata, ServerConfig source) {
  final title = metadata.title.trim().isEmpty
      ? fileNameWithoutExtension(metadata.path)
      : metadata.title.trim();
  final artist = _displayArtist(metadata.artist);
  return Track(
    id: 'local:${metadata.path}',
    title: title,
    artist: artist,
    album: metadata.album.trim(),
    streamUrl: Uri.file(metadata.path).toString(),
    sourceType: MusicSourceType.localFile,
    sourceName: source.name,
    sourceServerId: source.id,
    sourceItemId: metadata.path,
    duration: metadata.duration,
    lyrics: metadata.lyrics,
    coverUrl: metadata.coverUrl,
    audioFormat: readAudioFormatFromPath(metadata.path),
    trackNumber: _trackNumber(metadata.trackNumber),
  );
}

int? _trackNumber(String value) {
  final result = int.tryParse(value.trim().split('/').first);
  return result != null && result > 0 ? result : null;
}

String _displayArtist(String value) {
  final artist = value.trim();
  return artist.isEmpty ? '未知歌手' : artist;
}

bool _contains(String value, String normalizedQuery) {
  return value.toLowerCase().contains(normalizedQuery);
}

Future<LocalAudioMetadata> _readBasicMetadata(String path) async {
  return LocalAudioMetadata(
    path: path,
    title: fileNameWithoutExtension(path),
    artist: '',
    album: '',
    genres: '',
    year: '',
    trackNumber: '',
    lyrics: '',
  );
}
