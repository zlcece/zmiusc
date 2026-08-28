import 'dart:io';

enum MusicSourceType { customStream, subsonic, localFile }

enum MusicSourceKind { subsonic, localFolder }

enum PlaybackMode { sequential, shuffle, repeatOne, repeatAll }

enum LibrarySectionType { artists, albums, playlists, radio }

enum LibrarySearchScope { all, songs, artists, albums }

const String localEmbeddedArtworkScheme = 'zmusic-local-artwork';

String localEmbeddedArtworkUrl(String sourcePath) {
  return Uri(
    scheme: localEmbeddedArtworkScheme,
    host: 'cover',
    queryParameters: {'path': File(sourcePath).absolute.path},
  ).toString();
}

class LibrarySectionItem {
  const LibrarySectionItem({
    required this.id,
    required this.title,
    required this.type,
    this.subtitle = '',
    this.coverUrl,
    this.description = '',
    this.isLocal = false,
    this.isPublic,
    this.owner = '',
  });

  final String id;
  final String title;
  final String subtitle;
  final String? coverUrl;
  final String description;
  final bool isLocal;
  final bool? isPublic;
  final String owner;
  final LibrarySectionType type;
}

class LibrarySearchResults {
  const LibrarySearchResults({
    this.songs = const [],
    this.artists = const [],
    this.albums = const [],
  });

  final List<Track> songs;
  final List<LibrarySectionItem> artists;
  final List<LibrarySectionItem> albums;

  bool get isEmpty => songs.isEmpty && artists.isEmpty && albums.isEmpty;

  bool get isNotEmpty => !isEmpty;
}

class LibraryOverview {
  const LibraryOverview({
    this.artists = const [],
    this.albums = const [],
    this.playlists = const [],
    this.latestAlbums = const [],
    this.recentAlbums = const [],
    this.frequentAlbums = const [],
    this.randomAlbums = const [],
    this.favoriteTracks = const [],
    this.radioStations = const [],
    this.songCount,
  });

  final List<LibrarySectionItem> artists;
  final List<LibrarySectionItem> albums;
  final List<LibrarySectionItem> playlists;
  final List<LibrarySectionItem> latestAlbums;
  final List<LibrarySectionItem> recentAlbums;
  final List<LibrarySectionItem> frequentAlbums;
  final List<LibrarySectionItem> randomAlbums;
  final List<Track> favoriteTracks;
  final List<LibrarySectionItem> radioStations;
  final int? songCount;

  List<LibrarySectionItem> get myPlaylists =>
      playlists.where((playlist) => playlist.isPublic != true).toList();

  List<LibrarySectionItem> get publicPlaylists => playlists
      .where((playlist) => !playlist.isLocal && playlist.isPublic == true)
      .toList();

  List<LibrarySectionItem> playlistsForUser(String username) {
    return orderPlaylistsForUser(playlists, username);
  }

  LibraryOverview copyWith({
    List<LibrarySectionItem>? artists,
    List<LibrarySectionItem>? albums,
    List<LibrarySectionItem>? playlists,
    List<LibrarySectionItem>? latestAlbums,
    List<LibrarySectionItem>? recentAlbums,
    List<LibrarySectionItem>? frequentAlbums,
    List<LibrarySectionItem>? randomAlbums,
    List<Track>? favoriteTracks,
    List<LibrarySectionItem>? radioStations,
    int? songCount,
  }) {
    return LibraryOverview(
      artists: artists ?? this.artists,
      albums: albums ?? this.albums,
      playlists: playlists ?? this.playlists,
      latestAlbums: latestAlbums ?? this.latestAlbums,
      recentAlbums: recentAlbums ?? this.recentAlbums,
      frequentAlbums: frequentAlbums ?? this.frequentAlbums,
      randomAlbums: randomAlbums ?? this.randomAlbums,
      favoriteTracks: favoriteTracks ?? this.favoriteTracks,
      radioStations: radioStations ?? this.radioStations,
      songCount: songCount ?? this.songCount,
    );
  }

  bool get isEmpty =>
      artists.isEmpty &&
      albums.isEmpty &&
      playlists.isEmpty &&
      latestAlbums.isEmpty &&
      recentAlbums.isEmpty &&
      frequentAlbums.isEmpty &&
      randomAlbums.isEmpty &&
      favoriteTracks.isEmpty &&
      radioStations.isEmpty &&
      (songCount == null || songCount == 0);
}

bool isUserOwnedPlaylist(LibrarySectionItem playlist, String username) {
  if (playlist.isLocal || playlist.isPublic != true) {
    return true;
  }
  final owner = playlist.owner.trim();
  final currentUser = username.trim();
  return owner.isNotEmpty &&
      currentUser.isNotEmpty &&
      owner.toLowerCase() == currentUser.toLowerCase();
}

List<LibrarySectionItem> orderPlaylistsForUser(
  Iterable<LibrarySectionItem> playlists,
  String username,
) {
  final own = <LibrarySectionItem>[];
  final shared = <LibrarySectionItem>[];
  for (final playlist in playlists) {
    if (isUserOwnedPlaylist(playlist, username)) {
      own.add(playlist);
    } else {
      shared.add(playlist);
    }
  }
  return [...own, ...shared];
}

int libraryPageCount(int itemCount, int pageSize) {
  if (itemCount <= 0 || pageSize <= 0) {
    return 0;
  }
  return (itemCount / pageSize).ceil();
}

List<T> libraryPageItems<T>(List<T> items, int pageIndex, int pageSize) {
  final pageCount = libraryPageCount(items.length, pageSize);
  if (pageCount == 0) {
    return const [];
  }

  final boundedPageIndex = pageIndex.clamp(0, pageCount - 1);
  final start = boundedPageIndex * pageSize;
  final end = (start + pageSize).clamp(0, items.length);
  return items.sublist(start, end);
}

const int libraryBrowsePageSize = 18;

int libraryBrowsePageCount(int itemCount) {
  return libraryPageCount(itemCount, libraryBrowsePageSize);
}

List<T> libraryBrowsePageItems<T>(List<T> items, int pageIndex) {
  return libraryPageItems(items, pageIndex, libraryBrowsePageSize);
}

class LocalAudioMetadata {
  const LocalAudioMetadata({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.genres,
    required this.year,
    required this.trackNumber,
    required this.lyrics,
    this.duration,
    this.coverUrl,
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final String genres;
  final String year;
  final String trackNumber;
  final String lyrics;
  final Duration? duration;
  final String? coverUrl;

  LocalAudioMetadata copyWith({
    String? title,
    String? artist,
    String? album,
    String? genres,
    String? year,
    String? trackNumber,
    String? lyrics,
    Duration? duration,
    String? coverUrl,
  }) {
    return LocalAudioMetadata(
      path: path,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      genres: genres ?? this.genres,
      year: year ?? this.year,
      trackNumber: trackNumber ?? this.trackNumber,
      lyrics: lyrics ?? this.lyrics,
      duration: duration ?? this.duration,
      coverUrl: coverUrl ?? this.coverUrl,
    );
  }
}

class ServerConfig {
  const ServerConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
    this.sourceKind = MusicSourceKind.subsonic,
    this.localPath = '',
  });

  final String id;
  final String name;
  final String baseUrl;
  final String username;
  final String password;
  final MusicSourceKind sourceKind;
  final String localPath;

  bool get isLocalFolder => sourceKind == MusicSourceKind.localFolder;

  String get normalizedBaseUrl {
    if (isLocalFolder) {
      return '';
    }
    return normalizeServerUrl(baseUrl);
  }

  ServerConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? username,
    String? password,
    MusicSourceKind? sourceKind,
    String? localPath,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      sourceKind: sourceKind ?? this.sourceKind,
      localPath: localPath ?? this.localPath,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'baseUrl': baseUrl,
      'username': username,
      'password': password,
      'sourceKind': sourceKind.name,
      'localPath': localPath,
    };
  }

  factory ServerConfig.fromJson(Map<String, Object?> json) {
    final sourceKind = MusicSourceKind.values.firstWhere(
      (value) => value.name == readString(json, 'sourceKind'),
      orElse: () {
        final type = readString(json, 'type');
        final localPath = readString(json, 'localPath');
        final id = readString(json, 'id');
        return type == 'localFolder' ||
                localPath.isNotEmpty ||
                id.startsWith('local:')
            ? MusicSourceKind.localFolder
            : MusicSourceKind.subsonic;
      },
    );
    if (sourceKind == MusicSourceKind.localFolder) {
      final localPath = readString(json, 'localPath');
      final id = readString(json, 'id');
      final path = localPath.isNotEmpty
          ? localPath
          : (id.startsWith('local:') ? id.substring('local:'.length) : '');
      return ServerConfig(
        id: localSourceId(path.isEmpty ? id : path),
        name: readString(json, 'name'),
        baseUrl: '',
        username: '',
        password: '',
        sourceKind: MusicSourceKind.localFolder,
        localPath: path,
      );
    }

    final baseUrl = readString(json, 'baseUrl');
    final username = readString(json, 'username');
    final normalizedUrl = normalizeServerUrl(baseUrl);
    return ServerConfig(
      id: normalizedUrl.isEmpty
          ? readString(json, 'id')
          : remoteSourceId(normalizedUrl, username),
      name: readString(json, 'name'),
      baseUrl: normalizedUrl.isEmpty ? baseUrl : normalizedUrl,
      username: username,
      password: readString(json, 'password'),
    );
  }
}

String localSourceId(String path) {
  return path.startsWith('local:') ? path : 'local:$path';
}

String remoteSourceId(String baseUrl, String username) {
  final normalizedUrl = normalizeServerUrl(baseUrl);
  final account = username.trim();
  if (account.isEmpty) {
    return normalizedUrl;
  }
  return '$normalizedUrl|$account';
}

String normalizeServerUrl(String value) {
  var normalized = value.trim();
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.streamUrl,
    required this.sourceType,
    required this.sourceName,
    this.coverUrl,
    this.duration,
    this.lyrics = '',
    this.sourceServerId,
    this.sourceItemId,
    this.audioFormat,
    this.trackNumber,
    this.playCount = 0,
    this.lastPlayedAt,
    this.genre = '',
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String streamUrl;
  final MusicSourceType sourceType;
  final String sourceName;
  final String? coverUrl;
  final Duration? duration;
  final String lyrics;
  final String? sourceServerId;
  final String? sourceItemId;
  final String? audioFormat;
  final int? trackNumber;
  final int playCount;
  final DateTime? lastPlayedAt;
  final String genre;

  Track copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? streamUrl,
    MusicSourceType? sourceType,
    String? sourceName,
    String? coverUrl,
    Duration? duration,
    String? lyrics,
    String? sourceServerId,
    String? sourceItemId,
    String? audioFormat,
    int? trackNumber,
    int? playCount,
    DateTime? lastPlayedAt,
    String? genre,
  }) {
    return Track(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      streamUrl: streamUrl ?? this.streamUrl,
      sourceType: sourceType ?? this.sourceType,
      sourceName: sourceName ?? this.sourceName,
      coverUrl: coverUrl ?? this.coverUrl,
      duration: duration ?? this.duration,
      lyrics: lyrics ?? this.lyrics,
      sourceServerId: sourceServerId ?? this.sourceServerId,
      sourceItemId: sourceItemId ?? this.sourceItemId,
      audioFormat: audioFormat ?? this.audioFormat,
      trackNumber: trackNumber ?? this.trackNumber,
      playCount: playCount ?? this.playCount,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      genre: genre ?? this.genre,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'streamUrl': streamUrl,
      'sourceType': sourceType.name,
      'sourceName': sourceName,
      'coverUrl': coverUrl,
      'durationSeconds': duration?.inSeconds,
      'lyrics': lyrics,
      'sourceServerId': sourceServerId,
      'sourceItemId': sourceItemId,
      'audioFormat': audioFormat,
      'trackNumber': trackNumber,
      'playCount': playCount,
      'lastPlayedAt': lastPlayedAt?.toIso8601String(),
      'genre': genre,
    };
  }

  factory Track.fromJson(Map<String, Object?> json) {
    final sourceType = MusicSourceType.values.firstWhere(
      (value) => value.name == readString(json, 'sourceType'),
      orElse: () => MusicSourceType.customStream,
    );
    final seconds = readInt(json, 'durationSeconds');
    final streamUrl = readString(json, 'streamUrl');
    final localPath = sourceType == MusicSourceType.localFile
        ? localFilePathFromStreamUrl(streamUrl)
        : null;
    final storedCoverUrl = readNullableString(json, 'coverUrl');

    return Track(
      id: readString(json, 'id'),
      title: readString(json, 'title', '未命名'),
      artist: readString(json, 'artist', '未知歌手'),
      album: readString(json, 'album'),
      streamUrl: streamUrl,
      sourceType: sourceType,
      sourceName: readString(json, 'sourceName', '自定义'),
      coverUrl:
          storedCoverUrl ??
          (localPath == null ? null : localEmbeddedArtworkUrl(localPath)),
      duration: seconds == null ? null : Duration(seconds: seconds),
      lyrics: readString(json, 'lyrics'),
      sourceServerId: readNullableString(json, 'sourceServerId'),
      sourceItemId: readNullableString(json, 'sourceItemId'),
      audioFormat: localPath == null
          ? readAudioFormat(readNullableString(json, 'audioFormat'))
          : readAudioFormatFromPath(localPath),
      trackNumber: readInt(json, 'trackNumber'),
      playCount: readInt(json, 'playCount') ?? 0,
      lastPlayedAt: DateTime.tryParse(
        readNullableString(json, 'lastPlayedAt') ?? '',
      ),
      genre: readString(json, 'genre'),
    );
  }
}

bool isRadioTrack(Track track) {
  return track.sourceItemId?.startsWith('radio:') ?? false;
}

bool isSupportedAudioPath(String path) {
  return switch (_extension(path)) {
    '.mp3' ||
    '.flac' ||
    '.mp4' ||
    '.m4a' ||
    '.wav' ||
    '.ogg' ||
    '.opus' ||
    '.aiff' ||
    '.ape' => true,
    _ => false,
  };
}

bool canWriteAudioMetadataPath(String path) {
  return switch (_extension(path)) {
    '.mp3' || '.flac' || '.mp4' || '.m4a' || '.wav' => true,
    _ => false,
  };
}

String fileNameWithoutExtension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final index = name.lastIndexOf('.');
  return index < 0 ? name : name.substring(0, index);
}

String? readAudioFormat(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  final withoutParameters = normalized.split(';').first.trim();
  final format = switch (withoutParameters) {
    'audio/mpeg' || 'audio/mp3' || 'mpeg' => 'mp3',
    'audio/x-ape' || 'audio/ape' || 'monkeysaudio' => 'ape',
    'audio/flac' || 'audio/x-flac' => 'flac',
    'audio/x-wav' || 'audio/wav' => 'wav',
    'audio/aac' || 'audio/x-aac' => 'aac',
    'audio/ogg' || 'application/ogg' => 'ogg',
    _ =>
      withoutParameters.startsWith('.')
          ? withoutParameters.substring(1)
          : withoutParameters.contains('/')
          ? null
          : withoutParameters,
  };
  if (format == null || format.isEmpty) {
    return null;
  }
  return format.toUpperCase();
}

String? readAudioFormatFromPath(String path) {
  final extension = _extension(path);
  return extension.isEmpty ? null : readAudioFormat(extension);
}

String? localFilePathFromStreamUrl(String streamUrl) {
  final uri = Uri.tryParse(streamUrl);
  if (uri == null || uri.scheme != 'file') {
    return null;
  }
  try {
    return uri.toFilePath();
  } on UnsupportedError {
    return null;
  }
}

String _extension(String path) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final index = name.lastIndexOf('.');
  return index < 0 ? '' : name.substring(index).toLowerCase();
}

String readString(
  Map<String, Object?> json,
  String key, [
  String fallback = '',
]) {
  final value = json[key];
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

String? readNullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value.toString().trim().isEmpty) {
    return null;
  }
  return value.toString();
}

int? readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}
