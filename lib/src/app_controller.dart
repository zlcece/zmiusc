import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'audio_cache.dart';
import 'artwork_cache.dart';
import 'app_update.dart';
import 'app_logger.dart';
import 'library_store.dart';
import 'local_library.dart';
import 'models.dart';
import 'player_controller.dart';
import 'playback_source.dart';
import 'playlist_sync.dart';
import 'settings_models.dart';
import 'source_config_codec.dart';
import 'subsonic_api.dart';

const String defaultMusicServerUrl = 'https://fnnav.zuitimes.com';
const int searchSongPageSize = 60;
const Duration playlistTrackCacheDuration = Duration(minutes: 5);
const Duration playlistTrackLoadTimeout = Duration(seconds: 45);

List<Track> _sortAlbumTracks(List<Track> tracks) {
  if (!tracks.any((track) => track.trackNumber != null)) {
    return tracks;
  }
  final indexedTracks = tracks.indexed.toList();
  indexedTracks.sort((left, right) {
    final leftNumber = left.$2.trackNumber;
    final rightNumber = right.$2.trackNumber;
    if (leftNumber == null) {
      return rightNumber == null ? left.$1.compareTo(right.$1) : 1;
    }
    if (rightNumber == null) {
      return -1;
    }
    final numberComparison = leftNumber.compareTo(rightNumber);
    return numberComparison != 0
        ? numberComparison
        : left.$1.compareTo(right.$1);
  });
  return indexedTracks.map((entry) => entry.$2).toList();
}

class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.player,
    AudioCacheManager? cacheManager,
    ArtworkCacheManager? artworkCacheManager,
    AppUpdateService? updateService,
    PlaylistSyncService? playlistSyncService,
  }) : cacheManager = cacheManager ?? AudioCacheManager(),
       artworkCacheManager =
           artworkCacheManager ?? ArtworkCacheManager.instance,
       updateService = updateService ?? AppUpdateService(),
       playlistSyncService = playlistSyncService ?? PlaylistSyncService() {
    player.addListener(_handlePlayerChanged);
    _positionSubscription = player.positionStream.listen(_handlePlayerPosition);
    player.trackResolver = _resolveTrackForPlayback;
    player.sequentialQueueCompletionProvider =
        _loadRandomQueueAfterSequentialCompletion;
    player.onPlaybackSessionChanged = _handlePlaybackSessionChanged;
    player.setSkipUnplayableTracks(settings.skipUnplayableTracks);
  }

  final LibraryStore store;
  final PlayerController player;
  final AudioCacheManager cacheManager;
  final ArtworkCacheManager artworkCacheManager;
  final AppUpdateService updateService;
  final PlaylistSyncService playlistSyncService;
  SubsonicApiClient Function(ServerConfig server) apiClientFactory = (server) =>
      SubsonicApiClient(server: server);

  List<ServerConfig> servers = [];
  List<Track> customTracks = [];
  List<Track> localTracks = [];
  List<Track> recommendedTracks = [];
  LibrarySearchResults searchResults = const LibrarySearchResults();
  int searchSongPageIndex = 0;
  bool hasNextSearchSongPage = false;
  LibraryOverview libraryOverview = const LibraryOverview();
  AppSettings settings = const AppSettings();
  double? desktopPlayerVolume;
  String? selectedServerId;
  String? statusMessage;
  String loginServerUrl = defaultMusicServerUrl;
  String loginUsername = '';
  String loginPassword = '';
  ThemeMode themeMode = ThemeMode.system;
  bool isInitialized = false;
  bool isBusy = false;
  bool isRefreshingLibrary = false;
  bool isLoadingRecommendations = false;
  bool _logsUnlocked = false;
  final Set<String> _favoriteTrackToggleKeys = <String>{};
  final Map<String, ({DateTime loadedAt, List<Track> tracks})>
  _playlistTrackCache = {};
  final Map<String, Future<List<Track>>> _playlistTrackLoads = {};
  String? _lastLyricTrackId;
  String? _activeScrobbleSessionKey;
  String? _nowPlayingScrobbleSessionKey;
  String? _submittedScrobbleSessionKey;
  Future<int>? _cacheSizeFuture;
  Future<void> _playbackSessionWrite = Future<void>.value();
  bool _suppressPlaybackSessionPersistence = false;
  bool _isRestoringPlaybackSession = false;
  int _recommendationRequestId = 0;
  String? _recommendedDateKey;
  List<DailyRecommendationHistoryEntry> _recommendationHistory = [];
  late final StreamSubscription<Duration> _positionSubscription;

  ServerConfig? get selectedServer {
    for (final server in servers) {
      if (server.id == selectedServerId) {
        return server;
      }
    }
    return servers.isEmpty ? null : servers.first;
  }

  String get selectedUsername => selectedServer?.username.trim() ?? '';

  bool get logsUnlocked => _logsUnlocked;

  bool unlockLogsForSession(String password) {
    if (password != 'rizhi') {
      return false;
    }
    if (!_logsUnlocked) {
      _logsUnlocked = true;
      notifyListeners();
    }
    return true;
  }

  bool get isAuthenticated {
    final server = selectedServer;
    return server != null && !server.isLocalFolder;
  }

  List<LibrarySectionItem> get myPlaylists {
    return libraryOverview.playlists
        .where((playlist) => isUserOwnedPlaylist(playlist, selectedUsername))
        .toList();
  }

  List<LibrarySectionItem> get publicPlaylists {
    return libraryOverview.playlists
        .where(
          (playlist) =>
              playlist.isPublic == true &&
              !isUserOwnedPlaylist(playlist, selectedUsername),
        )
        .toList();
  }

  bool get canCreateRemotePlaylist {
    final server = selectedServer;
    return server != null && !server.isLocalFolder;
  }

  List<LibrarySectionItem> get visiblePlaylists {
    return libraryOverview.playlistsForUser(selectedUsername);
  }

  List<LibrarySectionItem> get manageablePlaylists {
    return visiblePlaylists
        .where((playlist) => canManageRemotePlaylist(playlist))
        .toList();
  }

  bool canManageRemotePlaylist(LibrarySectionItem playlist) {
    return canCreateRemotePlaylist &&
        isUserOwnedPlaylist(playlist, selectedUsername);
  }

  bool canAddTrackToRemotePlaylist(Track track) {
    final server = selectedServer;
    return server != null &&
        !server.isLocalFolder &&
        track.sourceType == MusicSourceType.subsonic &&
        (track.sourceServerId == null ||
            track.sourceServerId!.isEmpty ||
            track.sourceServerId == server.id) &&
        track.sourceItemId != null &&
        track.sourceItemId!.isNotEmpty &&
        manageablePlaylists.isNotEmpty;
  }

  List<Track> get visibleTracks => [...customTracks, ...searchResults.songs];

  Future<void> load({bool loadLibrary = true}) async {
    _clearPlaylistTrackCache();
    final restoredServers = await store.loadServers();
    customTracks = await store.loadCustomTracks();
    settings = (await store.loadSettings()).normalized;
    if (Platform.isWindows || Platform.isMacOS) {
      desktopPlayerVolume = await store.loadDesktopPlayerVolume();
    }
    AppLogger.instance.setLevel(settings.logLevel);
    player.setSkipUnplayableTracks(settings.skipUnplayableTracks);
    if (settings.cacheDirectory.isEmpty) {
      settings = settings.copyWith(
        cacheDirectory: await cacheManager.defaultCacheDirectory(),
      );
      await store.saveSettings(settings);
    }
    themeMode = _themeModeFromString(await store.loadThemeMode());

    final storedServerId = await store.loadSelectedServerId();
    ServerConfig? restoredServer;
    for (final server in restoredServers.where(
      (value) => !value.isLocalFolder,
    )) {
      if (server.id == storedServerId) {
        restoredServer = server;
        break;
      }
      restoredServer ??= server;
    }
    servers = restoredServer == null ? [] : [restoredServer];
    selectedServerId = restoredServer?.id;
    loginServerUrl =
        await store.loadLoginServerUrl() ??
        restoredServer?.normalizedBaseUrl ??
        defaultMusicServerUrl;
    loginUsername =
        await store.loadLoginUsername() ?? restoredServer?.username ?? '';
    loginPassword =
        await store.loadLoginPassword() ?? restoredServer?.password ?? '';
    if (restoredServers.length != servers.length) {
      for (final server in restoredServers) {
        if (server.id != restoredServer?.id) {
          await store.deleteServerPassword(server.id);
        }
      }
      await store.saveServers(servers);
      await store.saveSelectedServerId(selectedServerId);
    }
    if (restoredServer == null) {
      await store.clearPlaybackSession();
      await store.clearDailyRecommendation();
    } else {
      final playbackSession = await store.loadPlaybackSession();
      if (playbackSession != null) {
        _isRestoringPlaybackSession = true;
        try {
          player.restorePlaybackSession(
            queue: playbackSession.queue,
            currentIndex: playbackSession.currentIndex,
            playbackMode: playbackSession.playbackMode,
          );
        } finally {
          _isRestoringPlaybackSession = false;
        }
      }
      if (settings.showDailyRecommendation) {
        final recommendation = await store.loadDailyRecommendation();
        if (recommendation != null) {
          _recommendationHistory = _recentRecommendationHistory(
            recommendation.history,
            DateTime.now(),
          );
        }
        if (recommendation != null &&
            recommendation.dateKey == _recommendationDateKey(DateTime.now()) &&
            recommendation.tracks.isNotEmpty) {
          final queueKeys = player.queue.map(_recommendationTrackKey).toSet();
          if (recommendation.tracks.every(
            (track) => !queueKeys.contains(_recommendationTrackKey(track)),
          )) {
            recommendedTracks = recommendation.tracks;
            _recommendedDateKey = recommendation.dateKey;
          }
        }
      } else {
        await store.clearDailyRecommendation();
      }
    }
    isInitialized = true;
    AppLogger.instance.info('app', '应用状态加载完成');

    notifyListeners();
    if (loadLibrary && selectedServer != null) {
      await loadLibraryOverview();
    } else {
      libraryOverview = const LibraryOverview();
    }
  }

  Future<void> login({
    required String username,
    required String password,
    String baseUrl = defaultMusicServerUrl,
  }) async {
    final normalizedUrl = normalizeServerUrl(baseUrl);
    final account = username.trim();
    final uri = Uri.tryParse(normalizedUrl);
    if (normalizedUrl.isEmpty ||
        uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('请输入有效的音源 URL。');
    }
    if (account.isEmpty || password.isEmpty) {
      throw const FormatException('请输入账号和密码。');
    }

    final server = ServerConfig(
      id: remoteSourceId(normalizedUrl, account),
      name: 'Zmusic',
      baseUrl: normalizedUrl,
      username: account,
      password: password,
    );
    isBusy = true;
    statusMessage = null;
    notifyListeners();
    try {
      await apiClientFactory(server).ping();
      await store.saveServers([server]);
      await store.saveSelectedServerId(server.id);
      await store.saveLoginServerUrl(normalizedUrl);
      await store.saveLoginCredentials(account, password);
      await _clearPlaybackSession();
      await _clearDailyRecommendation();
      _clearPlaylistTrackCache();
      for (final existing in servers) {
        if (existing.id != server.id) {
          await store.deleteServerPassword(existing.id);
        }
      }
      servers = [server];
      selectedServerId = server.id;
      loginServerUrl = normalizedUrl;
      loginUsername = account;
      loginPassword = password;
      isInitialized = true;
      searchResults = const LibrarySearchResults();
      libraryOverview = const LibraryOverview();
      localTracks = [];
      statusMessage = '登录成功。';
      AppLogger.instance.info('account', '远程账号登录成功');
    } catch (error, stackTrace) {
      statusMessage =
          '登录失败：${error.toString().replaceFirst('Exception: ', '')}';
      AppLogger.instance.error(
        'account',
        '远程账号登录失败',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
    unawaited(loadLibraryOverview(autoPlayDailyRecommendationOnStartup: true));
  }

  Future<void> logout() async {
    AppLogger.instance.info('account', '退出当前账号');
    await _clearPlaybackSession();
    await _clearDailyRecommendation();
    _clearPlaylistTrackCache();
    for (final server in servers) {
      await store.deleteServerPassword(server.id);
    }
    servers = [];
    selectedServerId = null;
    searchResults = const LibrarySearchResults();
    libraryOverview = const LibraryOverview();
    localTracks = [];
    statusMessage = null;
    await store.saveServers(const []);
    await store.saveSelectedServerId(null);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    await store.saveThemeMode(_themeModeToString(mode));
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings value) async {
    final previousSettings = settings;
    settings = value.normalized;
    AppLogger.instance.setLevel(settings.logLevel);
    player.setSkipUnplayableTracks(settings.skipUnplayableTracks);
    final shouldReloadHomeOverview = _shouldReloadHomeOverviewForSettings(
      previousSettings,
      settings,
    );
    _cacheSizeFuture = null;
    await store.saveSettings(settings);
    if (previousSettings.cacheDirectory != settings.cacheDirectory ||
        previousSettings.cacheSizeBytes != settings.cacheSizeBytes) {
      await cacheManager.trimCache(settings);
    }
    if (previousSettings.showDailyRecommendation !=
        settings.showDailyRecommendation) {
      if (settings.showDailyRecommendation) {
        unawaited(ensureDailyRecommendation());
      } else {
        await _clearDailyRecommendation();
      }
    }
    statusMessage = '设置已保存。';
    notifyListeners();
    if (shouldReloadHomeOverview && selectedServer != null) {
      unawaited(loadLibraryOverview());
    }
  }

  Future<void> saveDesktopPlayerVolume(double volume) async {
    final normalized = volume.clamp(0, 1).toDouble();
    desktopPlayerVolume = normalized;
    await store.saveDesktopPlayerVolume(normalized);
  }

  bool _shouldReloadHomeOverviewForSettings(
    AppSettings previous,
    AppSettings current,
  ) {
    if (!previous.shouldLoadHomePlaylists && current.shouldLoadHomePlaylists) {
      return true;
    }
    for (final section in HomeShortcutSection.values) {
      if (!previous.isHomeShortcutVisible(section) &&
          current.isHomeShortcutVisible(section)) {
        return true;
      }
    }
    for (final section in HomeDiscoverySection.values) {
      if (!previous.isHomeDiscoveryVisible(section) &&
          current.isHomeDiscoveryVisible(section)) {
        return true;
      }
    }
    return false;
  }

  Future<int> cacheSize() {
    final inFlight = _cacheSizeFuture;
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<int> future;
    future = cacheManager.cacheSize(settings).whenComplete(() {
      if (identical(_cacheSizeFuture, future)) {
        _cacheSizeFuture = null;
      }
    });
    _cacheSizeFuture = future;
    return future;
  }

  Future<void> clearAudioCache() async {
    await _runBusy(() async {
      final remainingBytes = await cacheManager.clearCache(
        settings,
        protectedPaths: player.activeStreamingCachePaths,
      );
      _cacheSizeFuture = null;
      statusMessage = remainingBytes == 0 ? '缓存已清除。' : '缓存已清理，正在使用的缓存已保留。';
    });
  }

  Future<void> clearArtworkCache() async {
    await _runBusy(() async {
      await artworkCacheManager.clearCache();
      statusMessage = '系统缓存已清除。';
    });
  }

  Future<void> saveServer(ServerConfig server, {String? previousId}) async {
    final normalized = _normalizeServer(server);
    if (previousId != null && previousId != normalized.id) {
      servers.removeWhere((value) => value.id == previousId);
      await store.deleteServerPassword(previousId);
      if (selectedServerId == previousId) {
        selectedServerId = normalized.id;
      }
    }

    final index = servers.indexWhere((value) => value.id == normalized.id);
    if (index >= 0) {
      servers[index] = normalized;
    } else {
      servers.add(normalized);
      final hasSelectedServer =
          selectedServerId != null &&
          servers.any((value) => value.id == selectedServerId);
      if (!hasSelectedServer) {
        selectedServerId = normalized.id;
      }
    }

    await store.saveServers(servers);
    await store.saveSelectedServerId(selectedServerId);
    statusMessage = '音源已保存。';
    notifyListeners();
    if (selectedServerId == normalized.id) {
      await loadLibraryOverview();
    }
  }

  Future<void> removeServer(String id) async {
    servers.removeWhere((value) => value.id == id);
    if (selectedServerId == id) {
      selectedServerId = servers.isEmpty ? null : servers.first.id;
      libraryOverview = const LibraryOverview();
      searchResults = const LibrarySearchResults();
      localTracks = [];
    }
    await store.deleteServerPassword(id);
    await store.saveServers(servers);
    await store.saveSelectedServerId(selectedServerId);
    statusMessage = '音源已删除。';
    notifyListeners();
    if (selectedServer != null) {
      await loadLibraryOverview();
    }
  }

  Future<void> selectServer(String? id) async {
    if (id == null || id == selectedServerId) {
      return;
    }
    selectedServerId = id;
    searchResults = const LibrarySearchResults();
    libraryOverview = const LibraryOverview();
    localTracks = [];
    await store.saveSelectedServerId(id);
    notifyListeners();
    await loadLibraryOverview();
  }

  Future<void> testSelectedServer() async {
    final server = selectedServer;
    if (server == null) {
      statusMessage = '请先添加音源。';
      notifyListeners();
      return;
    }
    await testServer(server);
  }

  Future<void> testServer(ServerConfig server) async {
    if (server.isLocalFolder) {
      await _runBusy(() async {
        if (!Directory(server.localPath).existsSync()) {
          throw Exception('本地音乐文件夹不存在。');
        }
        statusMessage = '本地音源路径可用。';
      });
      return;
    }

    await _runBusy(() async {
      await apiClientFactory(server).ping();
      statusMessage = '已连接到 ${server.name}。';
    });
  }

  Future<void> loadLibraryOverview({
    bool autoPlayDailyRecommendationOnStartup = false,
  }) async {
    final server = selectedServer;
    if (server == null) {
      libraryOverview = const LibraryOverview();
      localTracks = [];
      notifyListeners();
      return;
    }

    _clearPlaylistTrackCache();
    AppLogger.instance.info('library', '开始重新加载曲库');
    isRefreshingLibrary = true;
    isBusy = true;
    statusMessage = null;
    notifyListeners();
    try {
      if (server.isLocalFolder) {
        await _loadLocalLibrary(server);
        return;
      }

      localTracks = [];
      libraryOverview = const LibraryOverview();
      notifyListeners();
      await _loadRemoteLibraryOverviewIncrementally(server);
      AppLogger.instance.info('library', '曲库加载完成');
    } finally {
      isBusy = false;
      isRefreshingLibrary = false;
      notifyListeners();
    }
    if (autoPlayDailyRecommendationOnStartup) {
      await _autoPlayDailyRecommendationAfterStartup();
    }
  }

  Future<void> _autoPlayDailyRecommendationAfterStartup() async {
    if (!settings.autoPlayDailyRecommendationOnStartup ||
        !settings.showDailyRecommendation ||
        recommendedTracks.isEmpty ||
        player.isPlaying ||
        player.isBuffering) {
      return;
    }
    AppLogger.instance.info('recommendation', '启动加载完成，自动播放每日推荐');
    await playTrackList(List<Track>.of(recommendedTracks), 0);
  }

  Future<void> _loadRemoteLibraryOverviewIncrementally(
    ServerConfig server,
  ) async {
    final client = apiClientFactory(server);
    final errors = <Object>[];

    Future<void> loadPart<T>(
      Future<T> future,
      void Function(T value) apply,
    ) async {
      try {
        final value = await future;
        if (!_isCurrentServer(server)) {
          return;
        }
        apply(value);
        notifyListeners();
      } catch (error, stackTrace) {
        errors.add(error);
        AppLogger.instance.error(
          'library',
          '加载曲库分项数据失败',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    final tasks = <Future<void>>[];
    final deferredTasks = <Future<void>>[];
    final shouldGenerateRecommendations =
        settings.showDailyRecommendation && recommendedTracks.isEmpty;
    final recentAlbumsFuture =
        settings.isHomeDiscoveryVisible(HomeDiscoverySection.recentAlbums) ||
            shouldGenerateRecommendations
        ? client.albumList('recent', size: 12)
        : null;
    final frequentAlbumsFuture =
        settings.isHomeDiscoveryVisible(HomeDiscoverySection.frequentAlbums) ||
            shouldGenerateRecommendations
        ? client.albumList('frequent', size: 12)
        : null;
    final favoriteTracksFuture =
        settings.isHomeShortcutVisible(HomeShortcutSection.favorites) ||
            shouldGenerateRecommendations
        ? client.favoriteTracks()
        : null;
    if (settings.isHomeDiscoveryVisible(HomeDiscoverySection.latestAlbums)) {
      var artists = const <LibrarySectionItem>[];
      var albums = const <LibrarySectionItem>[];
      final artistsTask = loadPart<List<LibrarySectionItem>>(client.artists(), (
        value,
      ) {
        artists = value;
        libraryOverview = libraryOverview.copyWith(artists: artists);
      });
      final albumsTask = loadPart<List<LibrarySectionItem>>(client.albums(), (
        value,
      ) {
        albums = value;
        libraryOverview = libraryOverview.copyWith(
          albums: albums,
          latestAlbums: albums.take(12).toList(),
        );
      });
      tasks.addAll([
        artistsTask,
        albumsTask,
        Future.wait([artistsTask, albumsTask]).then((_) {
          if (!_isCurrentServer(server) || artists.isEmpty || albums.isEmpty) {
            return;
          }
          libraryOverview = libraryOverview.copyWith(
            artists: client.artistsWithArtworkFallbacks(artists, albums),
          );
          notifyListeners();
        }),
      ]);
    }
    if (settings.shouldLoadHomePlaylists) {
      tasks.add(
        loadPart<List<LibrarySectionItem>>(client.playlists(), (value) {
          libraryOverview = libraryOverview.copyWith(playlists: value);
        }),
      );
    }
    // Exact song counts require paging through every album. Keep that work
    // outside the visible-content refresh indicator.
    deferredTasks.add(
      loadPart<int?>(client.songCount(), (value) {
        libraryOverview = libraryOverview.copyWith(songCount: value);
      }),
    );
    if (settings.isHomeDiscoveryVisible(HomeDiscoverySection.recentAlbums)) {
      tasks.add(
        loadPart<List<LibrarySectionItem>>(recentAlbumsFuture!, (value) {
          libraryOverview = libraryOverview.copyWith(recentAlbums: value);
        }),
      );
    }
    if (settings.isHomeDiscoveryVisible(HomeDiscoverySection.frequentAlbums)) {
      tasks.add(
        loadPart<List<LibrarySectionItem>>(frequentAlbumsFuture!, (value) {
          libraryOverview = libraryOverview.copyWith(frequentAlbums: value);
        }),
      );
    }
    if (settings.isHomeDiscoveryVisible(HomeDiscoverySection.randomAlbums)) {
      tasks.add(
        loadPart<List<LibrarySectionItem>>(
          client.albumList('random', size: 12),
          (value) {
            libraryOverview = libraryOverview.copyWith(randomAlbums: value);
          },
        ),
      );
    }
    if (settings.isHomeShortcutVisible(HomeShortcutSection.favorites)) {
      tasks.add(
        loadPart<List<Track>>(favoriteTracksFuture!, (value) {
          libraryOverview = libraryOverview.copyWith(favoriteTracks: value);
        }),
      );
    }
    if (settings.isHomeShortcutVisible(HomeShortcutSection.publicRadio)) {
      tasks.add(
        loadPart<List<LibrarySectionItem>>(client.radioStations(), (value) {
          libraryOverview = libraryOverview.copyWith(radioStations: value);
        }),
      );
    }
    if (shouldGenerateRecommendations) {
      deferredTasks.add(
        _loadDailyRecommendationForServer(
          server,
          client,
          seed: _dailyRecommendationSeed(DateTime.now()),
          favoriteTracksFuture: favoriteTracksFuture!,
          recentAlbumsFuture: recentAlbumsFuture!,
          frequentAlbumsFuture: frequentAlbumsFuture!,
          showStatus: false,
        ),
      );
    }

    await Future.wait(tasks);

    if (!_isCurrentServer(server)) {
      return;
    }
    statusMessage = libraryOverview.isEmpty && errors.isNotEmpty
        ? errors.first.toString().replaceFirst('Exception: ', '')
        : null;
    isRefreshingLibrary = false;
    notifyListeners();
    await Future.wait(deferredTasks);
  }

  bool _isCurrentServer(ServerConfig server) {
    return selectedServerId == server.id;
  }

  Future<void> searchSelectedServer(
    String query, {
    LibrarySearchScope scope = LibrarySearchScope.all,
  }) async {
    await searchSelectedServerPage(query, scope: scope, pageIndex: 0);
  }

  Future<void> searchSelectedServerPage(
    String query, {
    LibrarySearchScope scope = LibrarySearchScope.all,
    required int pageIndex,
  }) async {
    final server = selectedServer;
    if (server == null) {
      statusMessage = '请先添加音源。';
      notifyListeners();
      return;
    }
    if (query.trim().isEmpty) {
      statusMessage = '请输入搜索关键词。';
      notifyListeners();
      return;
    }

    final normalizedPageIndex = pageIndex < 0 ? 0 : pageIndex;
    await _runBusy(() async {
      if (server.isLocalFolder) {
        if (localTracks.isEmpty) {
          await _loadLocalLibrary(server);
        }
        final results = searchLocalLibrary(
          localTracks,
          query.trim(),
          scope: scope,
        );
        final pageStart = normalizedPageIndex * searchSongPageSize;
        final pageEnd = (pageStart + searchSongPageSize).clamp(
          0,
          results.songs.length,
        );
        final songs = pageStart >= results.songs.length
            ? const <Track>[]
            : results.songs.sublist(pageStart, pageEnd);
        searchResults = LibrarySearchResults(
          songs: songs,
          artists: results.artists,
          albums: results.albums,
        );
        searchSongPageIndex = normalizedPageIndex;
        hasNextSearchSongPage = pageEnd < results.songs.length;
        statusMessage = _searchStatusMessage(scope, searchResults);
        return;
      }

      final results = await apiClientFactory(server).search(
        query.trim(),
        scope: scope,
        songCount: searchSongPageSize + 1,
        songOffset: normalizedPageIndex * searchSongPageSize,
      );
      hasNextSearchSongPage = results.songs.length > searchSongPageSize;
      searchSongPageIndex = normalizedPageIndex;
      searchResults = LibrarySearchResults(
        songs: results.songs.take(searchSongPageSize).toList(),
        artists: results.artists,
        albums: results.albums,
      );
      statusMessage = _searchStatusMessage(scope, searchResults);
    });
  }

  Future<LibrarySearchResults> searchRemoteSuggestions(
    String query, {
    LibrarySearchScope scope = LibrarySearchScope.all,
  }) async {
    final server = selectedServer;
    final keyword = query.trim();
    if (server == null || server.isLocalFolder || keyword.isEmpty) {
      return const LibrarySearchResults();
    }

    var songCount = 0;
    var artistCount = 0;
    var albumCount = 0;
    switch (scope) {
      case LibrarySearchScope.all:
        songCount = 2;
        artistCount = 2;
        albumCount = 1;
      case LibrarySearchScope.songs:
        songCount = 5;
      case LibrarySearchScope.artists:
        artistCount = 5;
      case LibrarySearchScope.albums:
        albumCount = 5;
    }

    return apiClientFactory(server).search(
      keyword,
      scope: scope,
      songCount: songCount,
      artistCount: artistCount,
      albumCount: albumCount,
    );
  }

  Future<void> searchLibraryItem(LibrarySectionItem item) async {
    await searchSelectedServer(item.title, scope: LibrarySearchScope.songs);
    if (item.type != LibrarySectionType.albums) {
      return;
    }
    searchResults = LibrarySearchResults(
      songs: _sortAlbumTracks(searchResults.songs),
      artists: searchResults.artists,
      albums: searchResults.albums,
    );
    notifyListeners();
  }

  Future<void> refreshFavoriteTracks() async {
    await _runIndependentRefresh(() async {
      final server = _selectedRemoteServer();
      final tracks = await apiClientFactory(server).favoriteTracks();
      libraryOverview = libraryOverview.copyWith(favoriteTracks: tracks);
      statusMessage = '已刷新我喜欢的：${tracks.length} 首。';
    });
  }

  Future<void> refreshRemotePlaylists() async {
    await _runIndependentRefresh(() async {
      final server = _selectedRemoteServer();
      final playlists = await apiClientFactory(server).playlists();
      libraryOverview = libraryOverview.copyWith(playlists: playlists);
      statusMessage = '已刷新歌单：${playlists.length} 个。';
    });
  }

  Future<void> refreshRadioStations() async {
    await _runIndependentRefresh(() async {
      final server = _selectedRemoteServer();
      final stations = await apiClientFactory(server).radioStations();
      libraryOverview = libraryOverview.copyWith(radioStations: stations);
      statusMessage = '已刷新电台：${stations.length} 个。';
    });
  }

  Future<void> ensureDailyRecommendation() async {
    final server = selectedServer;
    if (!settings.showDailyRecommendation ||
        server == null ||
        server.isLocalFolder ||
        isLoadingRecommendations) {
      return;
    }
    final now = DateTime.now();
    final dateKey = _recommendationDateKey(now);
    if (recommendedTracks.isNotEmpty && _recommendedDateKey == dateKey) {
      return;
    }
    final client = apiClientFactory(server);
    await _loadDailyRecommendationForServer(
      server,
      client,
      seed: _dailyRecommendationSeed(now),
      favoriteTracksFuture: client.favoriteTracks(),
      recentAlbumsFuture: client.albumList('recent', size: 12),
      frequentAlbumsFuture: client.albumList('frequent', size: 12),
      showStatus: false,
    );
  }

  Future<void> refreshDailyRecommendation() async {
    final server = selectedServer;
    if (!settings.showDailyRecommendation ||
        server == null ||
        server.isLocalFolder ||
        isLoadingRecommendations) {
      return;
    }
    final client = apiClientFactory(server);
    await _loadDailyRecommendationForServer(
      server,
      client,
      seed: DateTime.now().microsecondsSinceEpoch,
      favoriteTracksFuture: client.favoriteTracks(),
      recentAlbumsFuture: client.albumList('recent', size: 12),
      frequentAlbumsFuture: client.albumList('frequent', size: 12),
      showStatus: true,
    );
  }

  Future<void> _loadDailyRecommendationForServer(
    ServerConfig server,
    SubsonicApiClient client, {
    required int seed,
    required Future<List<Track>> favoriteTracksFuture,
    required Future<List<LibrarySectionItem>> recentAlbumsFuture,
    required Future<List<LibrarySectionItem>> frequentAlbumsFuture,
    required bool showStatus,
  }) async {
    if (isLoadingRecommendations) {
      return;
    }

    final requestId = ++_recommendationRequestId;
    isLoadingRecommendations = true;
    notifyListeners();
    try {
      final randomTracksFuture = _safeRecommendationList(
        client.randomSongs(size: 100),
      );
      final favoriteTracks = await _safeRecommendationList(
        favoriteTracksFuture,
      );
      final recentAlbums = await _safeRecommendationList(recentAlbumsFuture);
      final frequentAlbums = await _safeRecommendationList(
        frequentAlbumsFuture,
      );

      final favoriteArtists =
          favoriteTracks
              .map((track) => track.artist.trim())
              .where((artist) => artist.isNotEmpty)
              .toSet()
              .toList()
            ..shuffle(Random(seed ^ 0x4f1bbcdc));
      final relatedSearches = favoriteArtists
          .take(2)
          .map((artist) => _safeRecommendationSearch(client, artist));

      final habitAlbums = _interleaveRecommendationAlbums(
        recentAlbums,
        frequentAlbums,
      );
      final habitSearches = habitAlbums
          .take(4)
          .map(
            (album) => _safeRecommendationList(client.albumTracks(album.id)),
          );

      final relatedTracks = (await Future.wait(
        relatedSearches,
      )).expand((tracks) => tracks).toList();
      final habitualTracks = (await Future.wait(
        habitSearches,
      )).expand((tracks) => tracks).toList();
      final randomTracks = await randomTracksFuture;
      final generatedAt = DateTime.now();
      final tracks = buildDailyRecommendationTracks(
        favorites: favoriteTracks,
        related: relatedTracks,
        habitual: habitualTracks,
        randomTracks: randomTracks,
        excludedTracks: player.queue,
        seed: seed,
        history: _recommendationHistory,
        generatedAt: generatedAt,
      );

      if (requestId != _recommendationRequestId ||
          !_isCurrentServer(server) ||
          !settings.showDailyRecommendation) {
        return;
      }
      final dateKey = _recommendationDateKey(generatedAt);
      final favoriteKeys = favoriteTracks.map(_recommendationTrackKey).toSet();
      final selectedFavorites = tracks
          .where(
            (track) => favoriteKeys.contains(_recommendationTrackKey(track)),
          )
          .toList();
      _recommendationHistory = _mergeRecommendationHistory(
        _recommendationHistory,
        DailyRecommendationHistoryEntry(
          dateKey: dateKey,
          tracks: tracks,
          favoriteTracks: selectedFavorites,
        ),
        generatedAt,
      );
      recommendedTracks = tracks;
      _recommendedDateKey = dateKey;
      await store.saveDailyRecommendation(
        DailyRecommendationCache(
          dateKey: dateKey,
          tracks: tracks,
          history: _recommendationHistory,
        ),
      );
      if (showStatus) {
        statusMessage = tracks.isEmpty
            ? '暂时没有可推荐的歌曲。'
            : '已换一批：${tracks.length} 首。';
      }
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        'recommendation',
        '生成每日推荐失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (showStatus && requestId == _recommendationRequestId) {
        statusMessage = '生成每日推荐失败，请稍后重试。';
      }
    } finally {
      if (requestId == _recommendationRequestId) {
        isLoadingRecommendations = false;
        notifyListeners();
      }
    }
  }

  Future<List<T>> _safeRecommendationList<T>(Future<List<T>> future) async {
    try {
      return await future;
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'recommendation',
        '加载推荐数据源失败',
        error: error,
        stackTrace: stackTrace,
      );
      return <T>[];
    }
  }

  Future<List<Track>> _safeRecommendationSearch(
    SubsonicApiClient client,
    String artist,
  ) async {
    try {
      final results = await client.search(
        artist,
        scope: LibrarySearchScope.songs,
        songCount: 20,
        albumCount: 0,
        artistCount: 0,
      );
      final normalizedArtist = _normalizeRecommendationText(artist);
      return results.songs
          .where(
            (track) =>
                _normalizeRecommendationText(track.artist) == normalizedArtist,
          )
          .toList();
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'recommendation',
        '搜索收藏歌手相关歌曲失败',
        error: error,
        stackTrace: stackTrace,
      );
      return [];
    }
  }

  Future<void> _clearDailyRecommendation() async {
    _recommendationRequestId++;
    recommendedTracks = [];
    _recommendedDateKey = null;
    _recommendationHistory = [];
    isLoadingRecommendations = false;
    await store.clearDailyRecommendation();
    notifyListeners();
  }

  Future<List<Track>> playlistTracks(
    LibrarySectionItem item, {
    bool forceRefresh = false,
  }) {
    final server = selectedServer;
    if (server == null || server.isLocalFolder) {
      return Future.value(const <Track>[]);
    }
    final key = _playlistTrackCacheKey(server, item.id);
    if (forceRefresh) {
      _playlistTrackCache.remove(key);
      _playlistTrackLoads.remove(key);
    } else {
      final cached = _playlistTrackCache[key];
      if (cached != null &&
          DateTime.now().difference(cached.loadedAt) <
              playlistTrackCacheDuration) {
        return Future.value(cached.tracks);
      }
      final inFlight = _playlistTrackLoads[key];
      if (inFlight != null) {
        return inFlight;
      }
    }

    late final Future<List<Track>> request;
    request = apiClientFactory(server)
        .playlistTracks(item.id)
        .timeout(
          playlistTrackLoadTimeout,
          onTimeout: () => throw Exception('歌单加载超时，请返回后重试。'),
        )
        .then((tracks) {
          final cachedTracks = List<Track>.unmodifiable(tracks);
          if (identical(_playlistTrackLoads[key], request)) {
            _playlistTrackCache[key] = (
              loadedAt: DateTime.now(),
              tracks: cachedTracks,
            );
          }
          return cachedTracks;
        })
        .whenComplete(() {
          if (identical(_playlistTrackLoads[key], request)) {
            _playlistTrackLoads.remove(key);
          }
        });
    _playlistTrackLoads[key] = request;
    return request;
  }

  String _playlistTrackCacheKey(ServerConfig server, String playlistId) {
    return '${server.id}\u0000${playlistId.trim()}';
  }

  void _clearPlaylistTrackCache() {
    _playlistTrackCache.clear();
    _playlistTrackLoads.clear();
  }

  void _invalidatePlaylistTracks(ServerConfig server, String playlistId) {
    final key = _playlistTrackCacheKey(server, playlistId);
    _playlistTrackCache.remove(key);
    _playlistTrackLoads.remove(key);
  }

  Future<LibrarySectionItem?> createRemotePlaylist({
    required String name,
    String comment = '',
    bool isPublic = false,
    List<Track> tracks = const [],
  }) async {
    final server = _selectedRemoteServer();
    LibrarySectionItem? created;
    await _runBusy(() async {
      final client = apiClientFactory(server);
      created = await client.createPlaylist(
        name: name,
        songIds: _subsonicSongIdsForServer(server, tracks),
      );
      final playlist = created;
      if (playlist != null &&
          (comment.trim().isNotEmpty || playlist.isPublic != isPublic)) {
        await client.updatePlaylist(
          playlistId: playlist.id,
          comment: comment,
          isPublic: isPublic,
        );
      }
      statusMessage = '歌单已创建。';
    });
    await loadLibraryOverview();
    return created;
  }

  Future<void> updateRemotePlaylist(
    LibrarySectionItem playlist, {
    required String name,
    required String comment,
    required bool isPublic,
  }) async {
    final server = _selectedRemoteServer();
    _ensureCanManageRemotePlaylist(playlist);
    await _runBusy(() async {
      await apiClientFactory(server).updatePlaylist(
        playlistId: playlist.id,
        name: name,
        comment: comment,
        isPublic: isPublic,
      );
      libraryOverview = _replaceRemotePlaylist(
        playlist.id,
        LibrarySectionItem(
          id: playlist.id,
          title: name.trim().isEmpty ? playlist.title : name.trim(),
          subtitle: playlist.subtitle,
          coverUrl: playlist.coverUrl,
          description: comment.trim(),
          isPublic: isPublic,
          owner: playlist.owner,
          type: LibrarySectionType.playlists,
        ),
      );
      statusMessage = '歌单已保存。';
    });
  }

  Future<void> deleteRemotePlaylist(LibrarySectionItem playlist) async {
    final server = _selectedRemoteServer();
    _ensureCanManageRemotePlaylist(playlist);
    await _runBusy(() async {
      await apiClientFactory(server).deletePlaylist(playlist.id);
      _invalidatePlaylistTracks(server, playlist.id);
      libraryOverview = libraryOverview.copyWith(
        playlists: [
          for (final item in libraryOverview.playlists)
            if (item.id != playlist.id) item,
        ],
      );
      statusMessage = '歌单已删除。';
    });
  }

  Future<int> addTracksToRemotePlaylist(
    LibrarySectionItem playlist,
    List<Track> tracks,
  ) async {
    if (tracks.isEmpty) {
      return 0;
    }
    final server = _selectedRemoteServer();
    _ensureCanManageRemotePlaylist(playlist);
    var addedCount = 0;
    await _runBusy(() async {
      final client = apiClientFactory(server);
      final requestedSongIds = _subsonicSongIdsForServer(server, tracks);
      final existingSongIds = _subsonicSongIdsForServer(
        server,
        await client.playlistTracks(playlist.id),
      ).toSet();
      final songIdsToAdd = <String>[];
      for (final songId in requestedSongIds) {
        if (existingSongIds.add(songId)) {
          songIdsToAdd.add(songId);
        }
      }
      if (songIdsToAdd.isEmpty) {
        statusMessage = '歌曲已在歌单中。';
        return;
      }
      for (var start = 0; start < songIdsToAdd.length; start += 100) {
        final end = (start + 100).clamp(0, songIdsToAdd.length);
        await client.updatePlaylist(
          playlistId: playlist.id,
          songIdsToAdd: songIdsToAdd.sublist(start, end),
        );
      }
      addedCount = songIdsToAdd.length;
      _invalidatePlaylistTracks(server, playlist.id);
      statusMessage = '已加入 $addedCount 首歌曲。';
    });
    return addedCount;
  }

  Future<PlaylistMergeResult> mergeRemotePlaylists({
    required LibrarySectionItem target,
    required List<LibrarySectionItem> sources,
  }) async {
    if (sources.isEmpty) {
      throw const FormatException('请至少选择一个要合并的歌单。');
    }
    final server = _selectedRemoteServer();
    _ensureCanManageRemotePlaylist(target);
    for (final source in sources) {
      _ensureCanManageRemotePlaylist(source);
      if (source.id == target.id) {
        throw const FormatException('目标歌单不能同时作为来源歌单。');
      }
    }

    isBusy = true;
    statusMessage = null;
    notifyListeners();
    try {
      final client = apiClientFactory(server);
      final targetIds = _subsonicSongIdsForServer(
        server,
        await client.playlistTracks(target.id),
      ).toSet();
      final sourceTracks = <Track>[];
      for (final source in sources) {
        sourceTracks.addAll(await client.playlistTracks(source.id));
      }
      final sourceIds = _subsonicSongIdsForServer(server, sourceTracks);
      final idsToAdd = <String>[];
      final seen = <String>{};
      for (final id in sourceIds) {
        if (seen.add(id) && targetIds.add(id)) {
          idsToAdd.add(id);
        }
      }
      await _addSongIdsInBatches(client, target.id, idsToAdd);
      if (idsToAdd.isNotEmpty) {
        _invalidatePlaylistTracks(server, target.id);
      }
      final result = PlaylistMergeResult(
        sourceTrackCount: sourceIds.length,
        addedCount: idsToAdd.length,
        skippedCount: sourceIds.length - idsToAdd.length,
      );
      statusMessage = idsToAdd.isEmpty
          ? '所选歌曲都已在目标歌单中。'
          : '歌单合并完成，新增 ${idsToAdd.length} 首。';
      return result;
    } catch (error) {
      statusMessage = error.toString().replaceFirst('Exception: ', '');
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<PlaylistSyncResult> syncExternalPlaylist(
    String urlOrId, {
    String? targetPlaylistName,
    bool allowDifferentArtistSameTitle = false,
    bool preferHighQuality = false,
    void Function(PlaylistSyncProgress progress)? onProgress,
  }) async {
    final server = _selectedRemoteServer();
    isBusy = true;
    statusMessage = null;
    notifyListeners();
    try {
      onProgress?.call(
        const PlaylistSyncProgress(completed: 0, total: 0, message: '正在读取外部歌单'),
      );
      final external = await playlistSyncService.fetchPlaylist(urlOrId);
      if (external.tracks.isEmpty) {
        throw Exception('外部歌单没有可同步的歌曲。');
      }
      final client = apiClientFactory(server);
      final match = await playlistSyncService.matchPlaylist(
        external,
        client,
        allowDifferentArtistSameTitle: allowDifferentArtistSameTitle,
        preferHighQuality: preferHighQuality,
        onProgress: onProgress,
      );
      final targetName = targetPlaylistName?.trim().isNotEmpty == true
          ? targetPlaylistName!.trim()
          : external.name;

      LibrarySectionItem? target;
      for (final playlist in myPlaylists) {
        if (playlist.title.trim().toLowerCase() == targetName.toLowerCase()) {
          target = playlist;
          break;
        }
      }
      var createdPlaylist = false;
      if (target == null) {
        target = await client.createPlaylist(name: targetName);
        if (target == null) {
          throw Exception('Navidrome 未返回新建歌单信息。');
        }
        createdPlaylist = true;
      }

      final existingIds = _subsonicSongIdsForServer(
        server,
        await client.playlistTracks(target.id),
      ).toSet();
      final matchedIds = _subsonicSongIdsForServer(server, match.matchedTracks);
      final idsToAdd = <String>[];
      for (final id in matchedIds) {
        if (existingIds.add(id)) {
          idsToAdd.add(id);
        }
      }
      onProgress?.call(
        PlaylistSyncProgress(
          completed: match.playlist.tracks.length,
          total: match.playlist.tracks.length,
          message: '正在写入 ${idsToAdd.length} 首歌曲',
        ),
      );
      await _addSongIdsInBatches(client, target.id, idsToAdd);
      if (idsToAdd.isNotEmpty) {
        _invalidatePlaylistTracks(server, target.id);
      }
      libraryOverview = libraryOverview.copyWith(
        playlists: await client.playlists(),
      );
      final result = PlaylistSyncResult(
        playlistName: targetName,
        sourceCount: external.tracks.length,
        matchedCount: match.matchedTracks.length,
        addedCount: idsToAdd.length,
        alreadyPresentCount: matchedIds.length - idsToAdd.length,
        missingTracks: match.missingTracks,
        duplicateMatchCount: match.duplicateMatchCount,
        createdPlaylist: createdPlaylist,
      );
      statusMessage =
          '歌单同步完成，新增 ${idsToAdd.length} 首，未匹配 ${match.missingTracks.length} 首。';
      onProgress?.call(
        PlaylistSyncProgress(
          completed: external.tracks.length,
          total: external.tracks.length,
          message: '同步完成',
        ),
      );
      return result;
    } catch (error) {
      statusMessage = error.toString().replaceFirst('Exception: ', '');
      rethrow;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<void> _addSongIdsInBatches(
    SubsonicApiClient client,
    String playlistId,
    List<String> songIds,
  ) async {
    for (var start = 0; start < songIds.length; start += 100) {
      final end = (start + 100).clamp(0, songIds.length);
      await client.updatePlaylist(
        playlistId: playlistId,
        songIdsToAdd: songIds.sublist(start, end),
      );
    }
  }

  Future<void> removeRemotePlaylistTrack(
    LibrarySectionItem playlist,
    int trackIndex,
  ) async {
    final server = _selectedRemoteServer();
    _ensureCanManageRemotePlaylist(playlist);
    await _runBusy(() async {
      await apiClientFactory(server).updatePlaylist(
        playlistId: playlist.id,
        songIndexesToRemove: [trackIndex],
      );
      _invalidatePlaylistTracks(server, playlist.id);
      statusMessage = '已从歌单移除。';
    });
  }

  Future<int> removeRemotePlaylistTracks(
    LibrarySectionItem playlist,
    Iterable<int> trackIndexes,
  ) async {
    final server = _selectedRemoteServer();
    _ensureCanManageRemotePlaylist(playlist);
    final indexes = trackIndexes.where((index) => index >= 0).toSet().toList()
      ..sort((left, right) => right.compareTo(left));
    if (indexes.isEmpty) {
      return 0;
    }
    await _runBusy(() async {
      await apiClientFactory(
        server,
      ).updatePlaylist(playlistId: playlist.id, songIndexesToRemove: indexes);
      _invalidatePlaylistTracks(server, playlist.id);
      statusMessage = '已从来源歌单移除 ${indexes.length} 首歌曲。';
    });
    return indexes.length;
  }

  bool canFavoriteTrack(Track track) {
    return track.sourceType == MusicSourceType.subsonic &&
        (track.sourceItemId?.isNotEmpty ?? false) &&
        _serverForTrack(track) != null;
  }

  bool isFavoriteTrack(Track track) {
    final sourceItemId = track.sourceItemId;
    if (sourceItemId == null || sourceItemId.isEmpty) {
      return false;
    }
    return libraryOverview.favoriteTracks.any(
      (value) =>
          value.sourceItemId == sourceItemId &&
          (track.sourceServerId == null ||
              track.sourceServerId!.isEmpty ||
              value.sourceServerId == track.sourceServerId),
    );
  }

  bool isFavoriteTrackToggling(Track track) {
    final favoriteKey = _favoriteTrackKey(track);
    return favoriteKey != null &&
        _favoriteTrackToggleKeys.contains(favoriteKey);
  }

  Future<void> toggleFavoriteTrack(Track track) async {
    final sourceItemId = track.sourceItemId;
    final server = _serverForTrack(track);
    final favoriteKey = _favoriteTrackKey(track);
    if (track.sourceType != MusicSourceType.subsonic ||
        sourceItemId == null ||
        sourceItemId.isEmpty ||
        server == null ||
        favoriteKey == null) {
      statusMessage = '当前歌曲不支持收藏。';
      notifyListeners();
      return;
    }
    if (_favoriteTrackToggleKeys.contains(favoriteKey)) {
      return;
    }

    final wasFavorite = isFavoriteTrack(track);
    _favoriteTrackToggleKeys.add(favoriteKey);
    statusMessage = null;
    notifyListeners();
    try {
      final client = apiClientFactory(server);
      if (wasFavorite) {
        await client.unstarTrack(sourceItemId);
        libraryOverview = libraryOverview.copyWith(
          favoriteTracks: [
            for (final value in libraryOverview.favoriteTracks)
              if (value.sourceItemId != sourceItemId ||
                  value.sourceServerId != track.sourceServerId)
                value,
          ],
        );
        statusMessage = '已取消收藏。';
      } else {
        await client.starTrack(sourceItemId);
        libraryOverview = libraryOverview.copyWith(
          favoriteTracks: [track, ...libraryOverview.favoriteTracks],
        );
        statusMessage = '已收藏。';
      }
    } catch (error) {
      statusMessage = error.toString().replaceFirst('Exception: ', '');
    } finally {
      _favoriteTrackToggleKeys.remove(favoriteKey);
      notifyListeners();
    }
  }

  Future<List<Track>> searchTracksForSource(
    ServerConfig server,
    String query, {
    int offset = 0,
    int limit = 60,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      return [];
    }
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit <= 0 ? 60 : limit;

    if (server.isLocalFolder) {
      final tracks = server.id == selectedServer?.id && localTracks.isNotEmpty
          ? localTracks
          : await scanLocalAudioFolder(
              source: server,
              metadataReader: readLocalAudioMetadata,
            );
      final matches = searchLocalLibrary(
        tracks,
        keyword,
        scope: LibrarySearchScope.songs,
      ).songs;
      return matches.skip(safeOffset).take(safeLimit).toList();
    }

    final results = await apiClientFactory(server).search(
      keyword,
      scope: LibrarySearchScope.songs,
      songCount: safeLimit,
      songOffset: safeOffset,
      artistCount: 0,
      albumCount: 0,
    );
    return results.songs;
  }

  String exportServerConfigText() {
    if (servers.isEmpty) {
      throw Exception('还没有可导出的音源。');
    }
    return encodeSourceConfig(
      servers: servers,
      selectedServerId: selectedServerId,
    );
  }

  String exportSingleServerConfigText(ServerConfig server) {
    return encodeSourceConfig(servers: [server], selectedServerId: server.id);
  }

  Future<int> importServerConfigText(String value) async {
    final bundle = decodeSourceConfig(value);
    var changedCount = 0;
    for (final server in bundle.servers) {
      final normalized = _normalizeServer(server);
      final index = servers.indexWhere((value) => value.id == normalized.id);
      if (index >= 0) {
        servers[index] = normalized;
      } else {
        servers.add(normalized);
      }
      changedCount++;
    }

    final selectedUrl = bundle.selectedServerUrl;
    final importedSelectedId = _resolveServerId(selectedUrl);
    if (importedSelectedId != null) {
      selectedServerId = importedSelectedId;
    } else if (selectedServerId == null ||
        !servers.any((server) => server.id == selectedServerId)) {
      selectedServerId = servers.isEmpty ? null : servers.first.id;
    }

    await store.saveServers(servers);
    await store.saveSelectedServerId(selectedServerId);
    statusMessage = '已导入 $changedCount 个音源。';
    notifyListeners();
    if (selectedServer != null) {
      await loadLibraryOverview();
    }
    return changedCount;
  }

  Future<void> addCustomTrack(Track track) async {
    customTracks.removeWhere((value) => value.id == track.id);
    customTracks.insert(0, track);
    await store.saveCustomTracks(customTracks);
    statusMessage = '播放条目已保存。';
    notifyListeners();
  }

  Future<void> removeCustomTrack(String id) async {
    customTracks.removeWhere((value) => value.id == id);
    await store.saveCustomTracks(customTracks);
    statusMessage = '播放条目已删除。';
    notifyListeners();
  }

  Future<void> playTrack(Track track) async {
    final tracks = visibleTracks;
    final index = tracks.indexWhere((value) => value.id == track.id);
    if (index >= 0) {
      await playTrackList(tracks, index);
    } else {
      await _play(() => player.playTrack(track));
    }
  }

  Future<void> playTrackList(List<Track> tracks, int index) async {
    await _play(() => player.playTracks(tracks, index));
  }

  Future<List<Track>> _loadRandomQueueAfterSequentialCompletion() async {
    final server = selectedServer;
    final currentTrack = player.currentTrack;
    if (!settings.playRandomAfterSequentialQueue ||
        server == null ||
        server.isLocalFolder ||
        currentTrack == null ||
        isRadioTrack(currentTrack)) {
      return const [];
    }

    try {
      final tracks = await apiClientFactory(
        server,
      ).randomSongs(size: _sequentialCompletionRandomQueueSize);
      if (!settings.playRandomAfterSequentialQueue ||
          selectedServer?.id != server.id) {
        return const [];
      }
      return tracks;
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        'player',
        '队列结束后加载随机歌曲失败',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  Future<void> playTrackNext(Track track) async {
    await player.playTrackNext(track);
    statusMessage = '已设为下一首播放：${track.title}。';
    notifyListeners();
  }

  Future<void> playRadioStation(LibrarySectionItem station) async {
    final streamUrl = station.subtitle.trim();
    if (streamUrl.isEmpty) {
      statusMessage = '电台没有可播放地址。';
      notifyListeners();
      return;
    }

    final server = selectedServer;
    final stations = libraryOverview.radioStations
        .where((value) => value.subtitle.trim().isNotEmpty)
        .toList();
    final index = stations.indexWhere((value) => value.id == station.id);
    if (index < 0) {
      statusMessage = '电台频道列表中找不到当前频道。';
      notifyListeners();
      return;
    }

    final tracks = [for (final value in stations) _radioTrack(value, server)];
    player.setPlaybackMode(PlaybackMode.sequential);
    await _play(() => player.playTracks(tracks, index));
  }

  Track _radioTrack(LibrarySectionItem station, ServerConfig? server) {
    return Track(
      id: 'radio:${server?.id ?? 'source'}:${station.id}',
      title: station.title,
      artist: '电台',
      album: station.description.trim().isEmpty ? '电台' : station.description,
      streamUrl: station.subtitle.trim(),
      sourceType: MusicSourceType.customStream,
      sourceName: server?.name ?? '电台',
      coverUrl: station.coverUrl,
      sourceServerId: server?.id,
      sourceItemId: 'radio:${station.id}',
    );
  }

  Future<void> loadLyricsForCurrentTrack([Track? track]) async {
    final target = track ?? player.currentTrack;
    if (target == null ||
        target.sourceType != MusicSourceType.subsonic ||
        target.lyrics.trim().isNotEmpty) {
      return;
    }

    final server = _serverForTrack(target);
    if (server == null) {
      return;
    }

    final lyrics = await SubsonicApiClient(
      server: server,
    ).lyricsForTrack(target);
    final trimmed = lyrics.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final current = player.currentTrack;
    if (current == null || current.id != target.id) {
      return;
    }
    player.updateTrack(current.copyWith(lyrics: trimmed));
  }

  Future<LocalAudioMetadata> readLocalAudioMetadata(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw Exception('文件不存在。');
    }
    if (!isSupportedAudioPath(path)) {
      throw Exception('不支持的音频格式。');
    }

    return _readMetadataFile(path);
  }

  Future<LocalAudioMetadata> _readMetadataFile(String path) async {
    final file = File(path);
    final metadata = readMetadata(file, getImage: true);
    String? coverUrl;
    if (metadata.pictures.isNotEmpty) {
      final picture = metadata.pictures.firstWhere(
        (item) => item.pictureType == PictureType.coverFront,
        orElse: () => metadata.pictures.first,
      );
      try {
        coverUrl = await artworkCacheManager.cacheEmbeddedArtwork(
          path,
          picture.bytes,
        );
      } catch (_) {
        coverUrl = null;
      }
    }
    return LocalAudioMetadata(
      path: path,
      title: metadata.title ?? fileNameWithoutExtension(path),
      artist: metadata.artist ?? '',
      album: metadata.album ?? '',
      genres: metadata.genres.join(', '),
      year: metadata.year?.year.toString() ?? '',
      trackNumber: metadata.trackNumber?.toString() ?? '',
      lyrics: metadata.lyrics ?? '',
      duration: metadata.duration,
      coverUrl: coverUrl,
    );
  }

  Future<LocalAudioMetadata> saveAudioMetadata(
    LocalAudioMetadata value, {
    Uint8List? artworkBytes,
    String? artworkMimeType,
  }) async {
    return saveLocalAudioMetadata(
      value,
      artworkBytes: artworkBytes,
      artworkMimeType: artworkMimeType,
    );
  }

  Future<LocalAudioMetadata> saveLocalAudioMetadata(
    LocalAudioMetadata value, {
    Uint8List? artworkBytes,
    String? artworkMimeType,
  }) async {
    if (!canWriteAudioMetadataPath(value.path)) {
      throw Exception('当前格式只支持读取，不能写入元数据。');
    }

    final file = File(value.path);
    _updateMetadata(
      file,
      value,
      artworkBytes: artworkBytes,
      artworkMimeType: artworkMimeType,
    );

    final updated = await readLocalAudioMetadata(value.path);
    _replaceLocalTrack(updated);
    statusMessage = '本地音频元数据已保存。';
    notifyListeners();
    return updated;
  }

  Future<void> addLocalAudioTrack(LocalAudioMetadata metadata) async {
    final track = localMetadataToTrack(
      metadata,
      const ServerConfig(
        id: 'local:custom',
        name: '本地文件',
        baseUrl: '',
        username: '',
        password: '',
        sourceKind: MusicSourceKind.localFolder,
      ),
    ).copyWith(sourceServerId: '', sourceItemId: '');
    await addCustomTrack(track);
    statusMessage = '本地音频已加入播放列表。';
    notifyListeners();
  }

  Future<int> playDroppedLocalAudioFiles(Iterable<String> paths) async {
    if (!isAuthenticated) {
      statusMessage = '请先登录后再打开本地音频。';
      notifyListeners();
      return 0;
    }

    const source = ServerConfig(
      id: 'local:file-drop',
      name: '本地文件',
      baseUrl: '',
      username: '',
      password: '',
      sourceKind: MusicSourceKind.localFolder,
    );
    final tracks = <Track>[];
    final seenPaths = <String>{};
    for (final rawPath in paths) {
      final path = rawPath.trim();
      final file = File(path);
      if (path.isEmpty ||
          !seenPaths.add(file.absolute.path.toLowerCase()) ||
          !file.existsSync() ||
          !isSupportedAudioPath(path)) {
        continue;
      }

      LocalAudioMetadata metadata;
      try {
        metadata = await _readMetadataFile(path);
      } catch (_) {
        metadata = LocalAudioMetadata(
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
      tracks.add(localMetadataToTrack(metadata, source));
    }

    if (tracks.isEmpty) {
      statusMessage = '拖入的文件中没有可播放的音频。';
      notifyListeners();
      return 0;
    }

    try {
      await player.playTracks(tracks, 0);
      statusMessage = '已打开 ${tracks.length} 首本地歌曲。';
    } catch (error) {
      statusMessage =
          '播放失败：${error.toString().replaceFirst('Exception: ', '')}';
    }
    notifyListeners();
    return tracks.length;
  }

  Future<void> _runBusy(Future<void> Function() operation) async {
    isBusy = true;
    statusMessage = null;
    notifyListeners();

    try {
      await operation();
    } catch (error) {
      statusMessage = error.toString().replaceFirst('Exception: ', '');
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<void> _runIndependentRefresh(Future<void> Function() operation) async {
    statusMessage = null;
    notifyListeners();
    try {
      await operation();
    } catch (error) {
      statusMessage = error.toString().replaceFirst('Exception: ', '');
    } finally {
      notifyListeners();
    }
  }

  Future<void> _play(Future<void> Function() operation) async {
    statusMessage = null;
    notifyListeners();
    try {
      await operation();
    } catch (error, stackTrace) {
      statusMessage =
          '播放失败：${error.toString().replaceFirst('Exception: ', '')}';
      AppLogger.instance.error(
        'player',
        '播放操作失败',
        error: error,
        stackTrace: stackTrace,
      );
      notifyListeners();
    }
  }

  Future<PlaybackTrack> _resolveTrackForPlayback(Track track) async {
    var playableTrack = _ensurePlayableRemoteTrack(track);
    if (isRadioTrack(playableTrack)) {
      playableTrack = playableTrack.copyWith(
        streamUrl: await _resolveRadioStreamUrl(playableTrack.streamUrl),
      );
    }
    return cacheManager.resolveForPlayback(playableTrack, settings);
  }

  Track _ensurePlayableRemoteTrack(Track track) {
    if (track.sourceType != MusicSourceType.subsonic) {
      return track;
    }
    final songId = track.sourceItemId?.trim();
    if (songId == null || songId.isEmpty) {
      return track;
    }

    ServerConfig? server;
    final sourceServerId = track.sourceServerId?.trim();
    for (final candidate in servers) {
      if (sourceServerId != null &&
          sourceServerId.isNotEmpty &&
          candidate.id == sourceServerId) {
        server = candidate;
        break;
      }
    }
    server ??= selectedServer;
    if (server == null || server.isLocalFolder) {
      return track;
    }

    final streamUrl = SubsonicApiClient(
      server: server,
    ).streamUri(songId, audioFormat: track.audioFormat).toString();
    return track.copyWith(streamUrl: streamUrl);
  }

  Future<String> _resolveRadioStreamUrl(String streamUrl) async {
    final uri = Uri.tryParse(streamUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        !_isRadioPlaylistUri(uri)) {
      return streamUrl;
    }

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return streamUrl;
      }
      return radioPlaylistStreamUrl(response.body, uri) ?? streamUrl;
    } catch (_) {
      return streamUrl;
    }
  }

  void _updateMetadata(
    File file,
    LocalAudioMetadata value, {
    Uint8List? artworkBytes,
    String? artworkMimeType,
  }) {
    updateMetadata(file, (metadata) {
      metadata
        ..setTitle(_emptyToNull(value.title))
        ..setArtist(_emptyToNull(value.artist))
        ..setAlbum(_emptyToNull(value.album))
        ..setYear(_yearFromString(value.year))
        ..setTrackNumber(_intFromString(value.trackNumber))
        ..setGenres(_genresFromString(value.genres))
        ..setLyrics(_emptyToNull(value.lyrics));
      if (artworkBytes != null && artworkBytes.isNotEmpty) {
        metadata.setPictures([
          Picture(
            artworkBytes,
            artworkMimeType ?? 'image/jpeg',
            PictureType.coverFront,
          ),
        ]);
      }
    });
  }

  void _handlePlayerChanged() {
    notifyListeners();
    if (_isRestoringPlaybackSession) {
      return;
    }
    final track = player.currentTrack;
    if (track == null) {
      _lastLyricTrackId = null;
      _resetPlaybackScrobbleSession();
      return;
    }
    _syncPlaybackScrobbleSession(track);
    if (track.id != _lastLyricTrackId) {
      _lastLyricTrackId = track.id;
      unawaited(loadLyricsForCurrentTrack(track));
    }
  }

  void _handlePlaybackSessionChanged() {
    if (_suppressPlaybackSessionPersistence || !isAuthenticated) {
      return;
    }
    final session = PlaybackSession(
      queue: player.queue,
      currentIndex: player.currentQueueIndex,
      playbackMode: player.playbackMode,
    );
    _playbackSessionWrite = _playbackSessionWrite
        .then((_) => store.savePlaybackSession(session))
        .catchError((Object error, StackTrace stackTrace) {
          AppLogger.instance.error(
            'player',
            '保存播放队列会话失败',
            error: error,
            stackTrace: stackTrace,
          );
        });
  }

  Future<void> _clearPlaybackSession() async {
    _suppressPlaybackSessionPersistence = true;
    try {
      await player.stop();
      player.setPlaybackMode(PlaybackMode.sequential);
      await _playbackSessionWrite;
      await store.clearPlaybackSession();
    } finally {
      _suppressPlaybackSessionPersistence = false;
    }
  }

  Future<void> flushPersistentState() async {
    await _playbackSessionWrite;
  }

  void _handlePlayerPosition(Duration position) {
    if (!player.isPlaying) {
      return;
    }
    final track = player.currentTrack;
    if (track == null) {
      return;
    }
    if (position <= Duration.zero) {
      return;
    }
    _maybeScrobbleNowPlaying(track);
    final sessionKey = _syncPlaybackScrobbleSession(track);
    if (sessionKey == null || _submittedScrobbleSessionKey == sessionKey) {
      return;
    }
    if (!shouldSubmitPlaybackScrobble(
      position: position,
      duration: player.duration ?? track.duration,
    )) {
      return;
    }
    _submittedScrobbleSessionKey = sessionKey;
    unawaited(_sendPlaybackScrobble(track, submission: true));
  }

  String? _syncPlaybackScrobbleSession(Track track) {
    final sessionKey = _playbackScrobbleSessionKey(track);
    if (sessionKey == _activeScrobbleSessionKey) {
      return sessionKey;
    }
    _activeScrobbleSessionKey = sessionKey;
    _nowPlayingScrobbleSessionKey = null;
    _submittedScrobbleSessionKey = null;
    return sessionKey;
  }

  void _resetPlaybackScrobbleSession() {
    _activeScrobbleSessionKey = null;
    _nowPlayingScrobbleSessionKey = null;
    _submittedScrobbleSessionKey = null;
  }

  void _maybeScrobbleNowPlaying(Track track) {
    if (!player.isPlaying) {
      return;
    }
    final sessionKey = _syncPlaybackScrobbleSession(track);
    if (sessionKey == null || _nowPlayingScrobbleSessionKey == sessionKey) {
      return;
    }
    _nowPlayingScrobbleSessionKey = sessionKey;
    unawaited(_sendPlaybackScrobble(track, submission: false));
  }

  String? _playbackScrobbleSessionKey(Track track) {
    final trackKey = _playbackScrobbleTrackKey(track);
    if (trackKey == null) {
      return null;
    }
    return '$trackKey#${player.playSessionId}';
  }

  String? _playbackScrobbleTrackKey(Track track) {
    if (track.sourceType != MusicSourceType.subsonic) {
      return null;
    }
    final sourceItemId = track.sourceItemId?.trim();
    if (sourceItemId == null || sourceItemId.isEmpty) {
      return null;
    }
    final sourceServerId = track.sourceServerId?.trim();
    return '${sourceServerId ?? ''}:$sourceItemId';
  }

  Future<void> _sendPlaybackScrobble(
    Track track, {
    required bool submission,
  }) async {
    final sourceItemId = track.sourceItemId?.trim();
    if (track.sourceType != MusicSourceType.subsonic ||
        sourceItemId == null ||
        sourceItemId.isEmpty) {
      return;
    }
    final server = _serverForTrack(track);
    if (server == null || server.isLocalFolder) {
      return;
    }
    final sourceServerId = track.sourceServerId?.trim();
    if (sourceServerId != null &&
        sourceServerId.isNotEmpty &&
        sourceServerId != server.id) {
      return;
    }

    try {
      await apiClientFactory(server).scrobbleTrack(
        sourceItemId,
        submission: submission,
        time: DateTime.now(),
      );
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'player',
        '提交播放记录失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  ServerConfig _normalizeServer(ServerConfig server) {
    if (server.isLocalFolder) {
      final localPath = server.localPath.trim();
      return server.copyWith(
        id: localSourceId(localPath),
        baseUrl: '',
        username: '',
        password: '',
        localPath: localPath,
      );
    }

    final normalizedUrl = normalizeServerUrl(server.baseUrl);
    final username = server.username.trim();
    return server.copyWith(
      id: remoteSourceId(normalizedUrl, username),
      baseUrl: normalizedUrl,
      username: username,
    );
  }

  String? _resolveServerId(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    for (final server in servers) {
      if (server.id == value) {
        return server.id;
      }
    }
    final normalizedUrl = normalizeServerUrl(value);
    for (final server in servers) {
      if (!server.isLocalFolder && server.normalizedBaseUrl == normalizedUrl) {
        return server.id;
      }
    }
    return null;
  }

  Future<void> _loadLocalLibrary(ServerConfig server) async {
    localTracks = await scanLocalAudioFolder(
      source: server,
      metadataReader: readLocalAudioMetadata,
    );
    libraryOverview = buildLocalLibraryOverview(localTracks);
    final songCount = libraryOverview.songCount ?? 0;
    statusMessage = songCount == 0
        ? '本地音源没有扫描到音乐文件。'
        : '已加载 ${server.name}，歌曲数：$songCount。';
  }

  void _replaceLocalTrack(LocalAudioMetadata metadata) {
    final source = _sourceForLocalPath(metadata.path);
    if (source == null) {
      return;
    }
    final track = localMetadataToTrack(metadata, source);
    localTracks = [
      for (final value in localTracks)
        value.sourceItemId == metadata.path || value.id == track.id
            ? track
            : value,
    ];
    searchResults = LibrarySearchResults(
      songs: [
        for (final value in searchResults.songs)
          value.sourceItemId == metadata.path || value.id == track.id
              ? track
              : value,
      ],
      artists: searchResults.artists,
      albums: searchResults.albums,
    );
    libraryOverview = buildLocalLibraryOverview(localTracks);
  }

  ServerConfig _selectedRemoteServer() {
    final server = selectedServer;
    if (server == null || server.isLocalFolder) {
      throw Exception('请先选择 Navidrome/Subsonic 音源。');
    }
    return server;
  }

  void _ensureCanManageRemotePlaylist(LibrarySectionItem playlist) {
    if (!canManageRemotePlaylist(playlist)) {
      throw Exception('公开歌单只能播放。');
    }
  }

  List<String> _subsonicSongIdsForServer(
    ServerConfig server,
    List<Track> tracks,
  ) {
    final ids = <String>[];
    for (final track in tracks) {
      if (track.sourceType != MusicSourceType.subsonic) {
        throw Exception('只能把当前音源的歌曲加入歌单。');
      }
      final sourceServerId = track.sourceServerId;
      if (sourceServerId != null &&
          sourceServerId.isNotEmpty &&
          sourceServerId != server.id) {
        throw Exception('歌曲与歌单不属于同一个音源。');
      }
      final sourceItemId = track.sourceItemId;
      if (sourceItemId == null || sourceItemId.isEmpty) {
        throw Exception('歌曲缺少云端 ID。');
      }
      ids.add(sourceItemId);
    }
    return ids;
  }

  LibraryOverview _replaceRemotePlaylist(
    String id,
    LibrarySectionItem replacement,
  ) {
    return libraryOverview.copyWith(
      playlists: [
        for (final item in libraryOverview.playlists)
          item.id == id ? replacement : item,
      ],
    );
  }

  ServerConfig? _sourceForLocalPath(String path) {
    for (final server in servers.where((value) => value.isLocalFolder)) {
      if (path.startsWith(server.localPath)) {
        return server;
      }
    }
    final server = selectedServer;
    return server != null && server.isLocalFolder ? server : null;
  }

  ServerConfig? _serverForTrack(Track track) {
    final sourceServerId = track.sourceServerId;
    if (sourceServerId != null && sourceServerId.isNotEmpty) {
      for (final server in servers) {
        if (server.id == sourceServerId) {
          return server;
        }
      }
    }

    for (final server in servers) {
      if (track.id.startsWith('${server.id}:') ||
          track.streamUrl.startsWith('${server.normalizedBaseUrl}/')) {
        return server;
      }
    }
    return selectedServer;
  }

  String? _favoriteTrackKey(Track track) {
    final sourceItemId = track.sourceItemId;
    if (sourceItemId == null || sourceItemId.isEmpty) {
      return null;
    }
    final sourceServerId = track.sourceServerId;
    if (sourceServerId != null && sourceServerId.isNotEmpty) {
      return '$sourceServerId:$sourceItemId';
    }
    final server = _serverForTrack(track);
    return server == null ? null : '${server.id}:$sourceItemId';
  }

  @override
  void dispose() {
    player.sequentialQueueCompletionProvider = null;
    player.onPlaybackSessionChanged = null;
    player.removeListener(_handlePlayerChanged);
    _positionSubscription.cancel();
    player.dispose();
    super.dispose();
  }
}

const int _dailyRecommendationCount = 30;
const int _recommendationHistoryDays = 7;
const int _recommendationGeneralCooldownDays = 3;
const int _recommendationFavoriteCooldownDays = 5;
const int _sequentialCompletionRandomQueueSize = 30;

String _recommendationDateKey(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

int _dailyRecommendationSeed(DateTime date) {
  return date.year * 10000 + date.month * 100 + date.day;
}

int? _recommendationHistoryAge(String dateKey, DateTime now) {
  final date = DateTime.tryParse(dateKey);
  if (date == null) {
    return null;
  }
  final today = DateTime(now.year, now.month, now.day);
  final historyDate = DateTime(date.year, date.month, date.day);
  return today.difference(historyDate).inDays;
}

List<DailyRecommendationHistoryEntry> _recentRecommendationHistory(
  Iterable<DailyRecommendationHistoryEntry> history,
  DateTime now,
) {
  return history.where((entry) {
    final age = _recommendationHistoryAge(entry.dateKey, now);
    return age != null && age >= 0 && age < _recommendationHistoryDays;
  }).toList();
}

List<DailyRecommendationHistoryEntry> _mergeRecommendationHistory(
  Iterable<DailyRecommendationHistoryEntry> history,
  DailyRecommendationHistoryEntry current,
  DateTime now,
) {
  final recent = _recentRecommendationHistory(history, now);
  final currentIndex = recent.indexWhere(
    (entry) => entry.dateKey == current.dateKey,
  );
  if (currentIndex < 0) {
    recent.add(current);
    return recent;
  }

  final existing = recent[currentIndex];
  recent[currentIndex] = DailyRecommendationHistoryEntry(
    dateKey: current.dateKey,
    tracks: _bestRecommendationTracksByKey([
      ...existing.tracks,
      ...current.tracks,
    ]).values.toList(),
    favoriteTracks: _bestRecommendationTracksByKey([
      ...existing.favoriteTracks,
      ...current.favoriteTracks,
    ]).values.toList(),
  );
  return recent;
}

int _directFavoriteRecommendationCount(int favoriteCount) {
  if (favoriteCount <= 0) {
    return 0;
  }
  if (favoriteCount < 10) {
    return 1;
  }
  if (favoriteCount < 30) {
    return 2;
  }
  return 4;
}

List<LibrarySectionItem> _interleaveRecommendationAlbums(
  List<LibrarySectionItem> recent,
  List<LibrarySectionItem> frequent,
) {
  final result = <LibrarySectionItem>[];
  final seenIds = <String>{};
  final length = max(recent.length, frequent.length);
  for (var index = 0; index < length; index++) {
    if (index < recent.length && seenIds.add(recent[index].id)) {
      result.add(recent[index]);
    }
    if (index < frequent.length && seenIds.add(frequent[index].id)) {
      result.add(frequent[index]);
    }
  }
  return result;
}

List<Track> buildDailyRecommendationTracks({
  required List<Track> favorites,
  required List<Track> related,
  required List<Track> habitual,
  required List<Track> randomTracks,
  required Iterable<Track> excludedTracks,
  required int seed,
  Iterable<DailyRecommendationHistoryEntry> history = const [],
  DateTime? generatedAt,
}) {
  final bestByKey = _bestRecommendationTracksByKey([
    ...favorites,
    ...related,
    ...habitual,
    ...randomTracks,
  ]);
  List<Track> normalizeSource(List<Track> source) {
    final seen = <String>{};
    return [
      for (final track in source)
        if (seen.add(_recommendationTrackKey(track)))
          bestByKey[_recommendationTrackKey(track)]!,
    ];
  }

  final normalizedFavorites = normalizeSource(favorites);
  final favoriteKeys = normalizedFavorites.map(_recommendationTrackKey).toSet();
  List<Track> withoutDirectFavorites(List<Track> source) {
    return source
        .where(
          (track) => !favoriteKeys.contains(_recommendationTrackKey(track)),
        )
        .toList();
  }

  final normalizedRelated = withoutDirectFavorites(normalizeSource(related));
  final normalizedHabitual = withoutDirectFavorites(normalizeSource(habitual));
  final normalizedRandom = withoutDirectFavorites(
    normalizeSource(randomTracks),
  );
  final usedKeys = excludedTracks.map(_recommendationTrackKey).toSet();
  final cooldownLayers = <int, Set<String>>{};
  final now = generatedAt ?? DateTime.now();
  for (final entry in _recentRecommendationHistory(history, now)) {
    final age = _recommendationHistoryAge(entry.dateKey, now)!;
    final keys = cooldownLayers.putIfAbsent(age, () => <String>{});
    if (age < _recommendationGeneralCooldownDays) {
      keys.addAll(entry.tracks.map(_recommendationTrackKey));
    }
    if (age < _recommendationFavoriteCooldownDays) {
      keys.addAll(entry.favoriteTracks.map(_recommendationTrackKey));
    }
  }
  final blockedKeyCounts = <String, int>{};
  for (final keys in cooldownLayers.values) {
    for (final key in keys) {
      blockedKeyCounts.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  final random = Random(seed);
  final selected = <Track>[];

  void addFrom(List<Track> source, int count) {
    if (count <= 0) {
      return;
    }
    final candidates = source.where((track) {
      final key = _recommendationTrackKey(track);
      return !usedKeys.contains(key) && !blockedKeyCounts.containsKey(key);
    }).toList()..shuffle(random);
    var added = 0;
    for (final track in candidates) {
      if (!usedKeys.add(_recommendationTrackKey(track))) {
        continue;
      }
      selected.add(track);
      added++;
      if (added >= count) {
        break;
      }
    }
  }

  final directFavoriteCount = _directFavoriteRecommendationCount(
    normalizedFavorites.length,
  );
  final randomCount = _dailyRecommendationCount - directFavoriteCount - 8 - 9;
  addFrom(normalizedFavorites, directFavoriteCount);
  addFrom(normalizedRelated, 8);
  addFrom(normalizedHabitual, 9);
  addFrom(normalizedRandom, randomCount);

  void fillFromAvailableSources() {
    addFrom(normalizedRandom, _dailyRecommendationCount - selected.length);
    addFrom(normalizedRelated, _dailyRecommendationCount - selected.length);
    addFrom(normalizedHabitual, _dailyRecommendationCount - selected.length);
    addFrom(normalizedFavorites, _dailyRecommendationCount - selected.length);
  }

  fillFromAvailableSources();
  final cooldownAges = cooldownLayers.keys.toList()
    ..sort((left, right) => right.compareTo(left));
  for (final age in cooldownAges) {
    if (selected.length >= _dailyRecommendationCount) {
      break;
    }
    for (final key in cooldownLayers[age]!) {
      final count = blockedKeyCounts[key];
      if (count == null || count <= 1) {
        blockedKeyCounts.remove(key);
      } else {
        blockedKeyCounts[key] = count - 1;
      }
    }
    fillFromAvailableSources();
  }

  return _avoidAdjacentRecommendationArtists(
    selected.take(_dailyRecommendationCount).toList(),
  );
}

Map<String, Track> _bestRecommendationTracksByKey(Iterable<Track> tracks) {
  final result = <String, Track>{};
  for (final track in tracks) {
    final key = _recommendationTrackKey(track);
    final current = result[key];
    if (current == null ||
        _recommendationQualityRank(track) >
            _recommendationQualityRank(current)) {
      result[key] = track;
    }
  }
  return result;
}

int _recommendationQualityRank(Track track) {
  return switch ((track.audioFormat ?? '').trim().toUpperCase()) {
    'FLAC' => 3,
    'APE' => 2,
    'MP3' => 1,
    _ => 0,
  };
}

String _recommendationTrackKey(Track track) {
  final title = _normalizeRecommendationText(track.title);
  if (title.isEmpty) {
    return track.id;
  }
  return '${_normalizeRecommendationText(track.artist)}\u0000$title';
}

String _normalizeRecommendationText(String value) {
  return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

List<Track> _avoidAdjacentRecommendationArtists(List<Track> tracks) {
  final remaining = List<Track>.of(tracks);
  final result = <Track>[];
  while (remaining.isNotEmpty) {
    final previousArtist = result.isEmpty
        ? null
        : _normalizeRecommendationText(result.last.artist);
    var nextIndex = 0;
    if (previousArtist != null && previousArtist.isNotEmpty) {
      final differentArtistIndex = remaining.indexWhere(
        (track) => _normalizeRecommendationText(track.artist) != previousArtist,
      );
      if (differentArtistIndex >= 0) {
        nextIndex = differentArtistIndex;
      }
    }
    result.add(remaining.removeAt(nextIndex));
  }
  return result;
}

const Duration _scrobbleSubmitAfter = Duration(seconds: 30);

bool shouldSubmitPlaybackScrobble({
  required Duration position,
  required Duration? duration,
}) {
  if (position <= Duration.zero) {
    return false;
  }
  if (duration == null || duration <= Duration.zero) {
    return position >= _scrobbleSubmitAfter;
  }
  final halfDuration = Duration(milliseconds: duration.inMilliseconds ~/ 2);
  final threshold = halfDuration < _scrobbleSubmitAfter
      ? halfDuration
      : _scrobbleSubmitAfter;
  return position >= threshold;
}

ThemeMode _themeModeFromString(String value) {
  return switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

String _themeModeToString(ThemeMode mode) {
  return switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
}

String? radioPlaylistStreamUrl(String body, Uri playlistUri) {
  for (final line in const LineSplitter().convert(body)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }

    final equalsIndex = trimmed.indexOf('=');
    if (equalsIndex > 0 &&
        !trimmed
            .substring(0, equalsIndex)
            .trim()
            .toLowerCase()
            .startsWith('file')) {
      continue;
    }
    final value = equalsIndex > 0
        ? trimmed.substring(equalsIndex + 1).trim()
        : trimmed;
    if (value.isEmpty || value.startsWith('[')) {
      continue;
    }

    final candidateUri = Uri.tryParse(value);
    if (candidateUri == null) {
      continue;
    }
    final resolved = candidateUri.hasScheme
        ? candidateUri
        : playlistUri.resolveUri(candidateUri);
    if (resolved.scheme == 'http' || resolved.scheme == 'https') {
      return resolved.toString();
    }
  }
  return null;
}

bool _isRadioPlaylistUri(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.endsWith('.m3u') || path.endsWith('.pls');
}

String _searchStatusMessage(
  LibrarySearchScope scope,
  LibrarySearchResults results,
) {
  if (results.isEmpty) {
    return '没有找到相关结果。';
  }

  return switch (scope) {
    LibrarySearchScope.all =>
      '找到 歌曲 ${results.songs.length} 首，歌手 ${results.artists.length} 位，专辑 ${results.albums.length} 张。',
    LibrarySearchScope.songs => '找到 ${results.songs.length} 首歌曲。',
    LibrarySearchScope.artists => '找到 ${results.artists.length} 位歌手。',
    LibrarySearchScope.albums => '找到 ${results.albums.length} 张专辑。',
  };
}

String? _emptyToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _yearFromString(String value) {
  final year = int.tryParse(value.trim());
  if (year == null || year <= 0) {
    return null;
  }
  return DateTime(year);
}

int? _intFromString(String value) {
  return int.tryParse(value.trim());
}

List<String> _genresFromString(String value) {
  return value
      .split(RegExp(r'[,;/]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}
