import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ai_recommendation.dart';
import 'app_controller.dart';
import 'app_logger.dart';
import 'app_update.dart';
import 'artwork_cache.dart';
import 'compact_switch.dart';
import 'lyrics_timeline.dart';
import 'metadata_admin.dart';
import 'models.dart';
import 'playlist_tools_page.dart';
import 'settings_models.dart';

const String _appName = 'Zmusic';
const double _defaultPlayerVolume = 0.55;
const double _mobilePlayerVolume = 1;
const MethodChannel _androidTaskChannel = MethodChannel('com.zmusic.app/task');
final Expando<bool> _appUpdateDialogVisibility = Expando<bool>();

class ZmusicApp extends StatefulWidget {
  const ZmusicApp({
    required this.controller,
    this.isDiLinkCompatibilityBuild = false,
    super.key,
  });

  final AppController controller;
  final bool isDiLinkCompatibilityBuild;

  @override
  State<ZmusicApp> createState() => _ZmusicAppState();
}

class _ZmusicAppState extends State<ZmusicApp> {
  @override
  void initState() {
    super.initState();
    unawaited(_cleanupInstalledUpdate());
  }

  Future<void> _cleanupInstalledUpdate() async {
    if (defaultTargetPlatform != TargetPlatform.windows &&
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      await widget.controller.updateService.cleanupInstalledUpdate(
        installedVersionCode: int.tryParse(packageInfo.buildNumber) ?? 0,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'update',
        '清理已安装更新包失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return MaterialApp(
          title: _appName,
          debugShowCheckedModeBanner: false,
          themeMode: widget.controller.themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: HomePage(
            controller: widget.controller,
            isDiLinkCompatibilityBuild: widget.isDiLinkCompatibilityBuild,
          ),
        );
      },
    );
  }
}

ThemeData _theme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff2f8f70),
    brightness: brightness,
  );
  final iconColor = isDark ? Colors.white : colorScheme.onSurface;
  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: iconColor,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: IconThemeData(color: iconColor),
      actionsIconTheme: IconThemeData(color: iconColor),
    ),
    iconTheme: IconThemeData(color: iconColor),
    dividerColor: colorScheme.outlineVariant.withValues(
      alpha: isDark ? 0.34 : 0.42,
    ),
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
  );
}

class HomePage extends StatefulWidget {
  const HomePage({
    required this.controller,
    this.isDiLinkCompatibilityBuild = false,
    super.key,
  });

  final AppController controller;
  final bool isDiLinkCompatibilityBuild;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.controller, required this.onLoggedIn});

  final AppController controller;
  final VoidCallback onLoggedIn;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  late final TextEditingController _serverUrlController;
  DateTime? _lastTitleTap;
  int _titleTapCount = 0;
  bool _showServerUrl = false;
  bool _showPassword = false;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _usernameController.text = widget.controller.loginUsername;
    _passwordController.text = widget.controller.loginPassword;
    _serverUrlController = TextEditingController(
      text: widget.controller.loginServerUrl,
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 520;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _BackgroundWatermark(
              logoPath: widget.controller.settings.logoPath,
              backgroundPath: widget.controller.settings.backgroundPath,
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 22 : 32,
                  vertical: 28,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 410),
                  child: AutofillGroup(
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: GestureDetector(
                              key: const ValueKey('login-title'),
                              onTap: _handleTitleTap,
                              child: Text(
                                _appName,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      fontSize:
                                          (Theme.of(context)
                                                  .textTheme
                                                  .headlineSmall
                                                  ?.fontSize ??
                                              24) +
                                          2,
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 28),
                          TextFormField(
                            key: const ValueKey('login-username'),
                            controller: _usernameController,
                            autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              hintText: '账号',
                              prefixIcon: Icon(Icons.person_outline_rounded),
                              border: OutlineInputBorder(),
                            ),
                            validator: _required,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            key: const ValueKey('login-password'),
                            controller: _passwordController,
                            autofillHints: const [AutofillHints.password],
                            obscureText: !_showPassword,
                            textInputAction: _showServerUrl
                                ? TextInputAction.next
                                : TextInputAction.done,
                            onFieldSubmitted: (_) {
                              if (!_showServerUrl) {
                                unawaited(_submit());
                              }
                            },
                            decoration: InputDecoration(
                              hintText: '密码',
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                              ),
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                tooltip: _showPassword ? '隐藏密码' : '显示密码',
                                onPressed: () => setState(
                                  () => _showPassword = !_showPassword,
                                ),
                                icon: Icon(
                                  _showPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                            ),
                            validator: _required,
                          ),
                          if (_showServerUrl) ...[
                            const SizedBox(height: 12),
                            TextFormField(
                              key: const ValueKey('login-server-url'),
                              controller: _serverUrlController,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.done,
                              onFieldSubmitted: (_) => unawaited(_submit()),
                              decoration: InputDecoration(
                                hintText: '音源 URL',
                                prefixIcon: const Icon(Icons.dns_outlined),
                                border: const OutlineInputBorder(),
                                suffixIcon: IconButton(
                                  key: const ValueKey('login-hide-server-url'),
                                  tooltip: '隐藏音源 URL',
                                  onPressed: _hideServerUrl,
                                  icon: const Icon(
                                    Icons.visibility_off_outlined,
                                  ),
                                ),
                              ),
                              validator: _url,
                            ),
                          ],
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              _errorMessage!,
                              key: const ValueKey('login-error'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            key: const ValueKey('login-submit'),
                            onPressed: _submitting ? null : _submit,
                            icon: _submitting
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.login_rounded),
                            label: Text(_submitting ? '登录中' : '登录'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleTitleTap() {
    final now = DateTime.now();
    if (_lastTitleTap == null ||
        now.difference(_lastTitleTap!) > const Duration(seconds: 3)) {
      _titleTapCount = 0;
    }
    _lastTitleTap = now;
    _titleTapCount += 1;
    if (_titleTapCount < 5 || _showServerUrl) {
      return;
    }
    setState(() {
      _showServerUrl = true;
      _titleTapCount = 0;
    });
  }

  void _hideServerUrl() {
    setState(() {
      _showServerUrl = false;
      _titleTapCount = 0;
      _lastTitleTap = null;
    });
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await widget.controller.login(
        username: _usernameController.text,
        password: _passwordController.text,
        baseUrl: _serverUrlController.text,
      );
      if (mounted) {
        TextInput.finishAutofillContext();
        widget.onLoggedIn();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage = _formatError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }
}

enum _HomeTab { music, settings }

enum _PlaylistCollection { mine, public }

enum _PlaylistTool { sync, merge, batchAdd }

class _HomePageState extends State<HomePage> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _desktopVolumePersistTimer;
  bool _wasRefreshingLibrary = false;
  LibrarySearchScope _searchScope = LibrarySearchScope.songs;
  _SearchResultTab _selectedSearchTab = _SearchResultTab.songs;
  double _volume = _defaultPlayerVolume;
  double _lastNonZeroVolume = _defaultPlayerVolume;
  bool _showNowPlaying = false;
  bool _showSearchResults = false;
  _HomeTab _selectedHomeTab = _HomeTab.music;
  LibrarySectionType? _activeLibrarySection;
  LibrarySectionItem? _activeLibraryItem;
  String? _activeLibraryItemPageTitle;
  bool _activeLibraryItemHideTrackArtwork = false;
  LibrarySectionItem? _activeRemotePlaylist;
  _PlaylistCollection? _activePlaylistCollection;
  _PlaylistTool? _activePlaylistTool;
  bool _showMetadataManager = false;
  bool _showLogViewer = false;
  String? _activeTrackCollectionTitle;
  List<Track> _activeTrackCollectionTracks = const [];
  bool _didRunStartupUpdateCheck = false;

  @override
  void initState() {
    super.initState();
    _wasRefreshingLibrary = widget.controller.isRefreshingLibrary;
    widget.controller.addListener(_handleControllerChanged);
    unawaited(_initializePlayerVolume());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showLibraryStatus(widget.controller.statusMessage);
      unawaited(_checkForUpdateOnStartup());
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _desktopVolumePersistTimer?.cancel();
    if (_usesDesktopVolumePersistence) {
      unawaited(widget.controller.saveDesktopPlayerVolume(_volume));
    }
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        if (widget.controller.isInitialized &&
            !widget.controller.isAuthenticated) {
          return _LoginPage(
            controller: widget.controller,
            onLoggedIn: () {
              if (!mounted) {
                return;
              }
              setState(() {
                _selectedHomeTab = _HomeTab.music;
                _resetContentNavigation();
              });
            },
          );
        }
        final compactTabs = !_usesDesktopHomeTabs(context);
        final currentTrack = widget.controller.player.currentTrack;
        final mobileNowPlaying =
            MediaQuery.sizeOf(context).width < _mobilePlayerWidthBreakpoint &&
            _showNowPlaying &&
            currentTrack != null;
        return PopScope<void>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              unawaited(_handleBackNavigation());
            }
          },
          child: Scaffold(
            appBar: mobileNowPlaying
                ? null
                : AppBar(
                    toolbarHeight: compactTabs ? 48 : null,
                    centerTitle: true,
                    title: _HomeTabStrip(
                      selectedTab: _selectedHomeTab,
                      compact: compactTabs,
                      onChanged: _selectHomeTab,
                    ),
                    flexibleSpace: const _GlassAppBarBackground(),
                  ),
            body: Stack(
              children: [
                Positioned.fill(
                  child: _BackgroundWatermark(
                    logoPath: widget.controller.settings.logoPath,
                    backgroundPath: widget.controller.settings.backgroundPath,
                  ),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final content = _buildActiveContent(
                      widget.controller,
                      currentTrack,
                    );
                    final isPhone =
                        constraints.maxWidth < _mobilePlayerWidthBreakpoint;
                    final hideBottomPlayer =
                        isPhone && _showNowPlaying && currentTrack != null;
                    final activeContent =
                        _usesAndroidPhoneBackGesture(constraints.maxWidth)
                        ? _MobileBackSwipeRegion(
                            onBack: _handleBackNavigation,
                            child: content,
                          )
                        : content;

                    return Column(
                      children: [
                        Expanded(child: activeContent),
                        if (!hideBottomPlayer)
                          _PlayerBar(
                            controller: widget.controller,
                            reduceArtworkMotion:
                                widget.isDiLinkCompatibilityBuild,
                            onArtworkTap: currentTrack == null
                                ? null
                                : () => setState(() => _showNowPlaying = true),
                            volume: _volume,
                            onVolumeChanged: _setVolume,
                            onMuteToggle: _toggleMute,
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActiveContent(AppController controller, Track? currentTrack) {
    if (_showNowPlaying && currentTrack != null) {
      return _NowPlayingView(
        controller: controller,
        onClose: () => setState(() => _showNowPlaying = false),
        onArtistTap: (artist) =>
            _openScopedSearch(artist, LibrarySearchScope.artists),
        onAlbumTap: (album) =>
            _openScopedSearch(album, LibrarySearchScope.albums),
      );
    }

    if (_showMetadataManager) {
      return MetadataManagerPage(
        key: const ValueKey('metadata-manager-page'),
        controller: controller,
        onBack: _closeMetadataManager,
      );
    }

    if (_showLogViewer) {
      return _AppLogViewerPage(
        key: const ValueKey('app-log-viewer-page'),
        controller: controller,
        onBack: _closeLogViewer,
      );
    }

    final playlistTool = _activePlaylistTool;
    if (playlistTool != null) {
      return switch (playlistTool) {
        _PlaylistTool.sync => PlaylistSyncPage(
          key: const ValueKey('playlist-sync-page'),
          controller: controller,
          onBack: _closePlaylistTool,
        ),
        _PlaylistTool.merge => PlaylistMergePage(
          key: const ValueKey('playlist-merge-page'),
          controller: controller,
          playlists: controller.manageablePlaylists,
          onBack: _closePlaylistTool,
        ),
        _PlaylistTool.batchAdd => PlaylistBatchAddPage(
          key: const ValueKey('playlist-batch-add-page'),
          controller: controller,
          playlists: controller.manageablePlaylists,
          initialPlaylistId: _activeRemotePlaylist?.id,
          onBack: _closePlaylistTool,
        ),
      };
    }

    final remotePlaylist = _activeRemotePlaylist;
    if (remotePlaylist != null) {
      return _RemotePlaylistDetailPage(
        key: ValueKey(remotePlaylist.id),
        controller: controller,
        playlist: remotePlaylist,
        pageTitle: controller.canManageRemotePlaylist(remotePlaylist)
            ? '我的歌单'
            : '公开歌单',
        onBack: _closeActiveDetailPage,
        onBatchAdd: _openBatchAddForPlaylist,
      );
    }

    final libraryItem = _activeLibraryItem;
    if (libraryItem != null) {
      return _LibraryItemSongsPage(
        key: ValueKey('${libraryItem.type.name}:${libraryItem.id}'),
        controller: controller,
        item: libraryItem,
        pageTitle:
            _activeLibraryItemPageTitle ??
            _librarySectionTitle(libraryItem.type),
        hideTrackArtwork: _activeLibraryItemHideTrackArtwork,
        onBack: _closeActiveDetailPage,
      );
    }

    final trackCollectionTitle = _activeTrackCollectionTitle;
    if (trackCollectionTitle != null) {
      final isDailyRecommendation = trackCollectionTitle == '每日推荐';
      final isCasualListening = trackCollectionTitle == '随便听听';
      final tracks = isDailyRecommendation
          ? controller.recommendedTracks
          : isCasualListening
          ? controller.casualListeningTracks
          : _activeTrackCollectionTracks;
      return _TrackCollectionPage(
        title: trackCollectionTitle,
        tracks: tracks,
        controller: controller,
        onBack: _closeActiveDetailPage,
        onRefresh: isDailyRecommendation
            ? _refreshDailyRecommendation
            : isCasualListening
            ? _refreshCasualListening
            : trackCollectionTitle == '我喜欢的'
            ? _refreshFavorites
            : null,
        onPlayAll:
            (isDailyRecommendation || isCasualListening) && tracks.isNotEmpty
            ? () => controller.playTrackList(tracks, 0)
            : null,
        onSave: isDailyRecommendation && tracks.isNotEmpty
            ? _saveDailyRecommendation
            : null,
        isLoading:
            (isDailyRecommendation && controller.isLoadingRecommendations) ||
            (isCasualListening && controller.isLoadingCasualListening),
      );
    }

    final playlistCollection = _activePlaylistCollection;
    if (playlistCollection != null) {
      final mine = playlistCollection == _PlaylistCollection.mine;
      final compactTools = MediaQuery.sizeOf(context).width < 600;
      return _LibraryBrowsePage(
        type: LibrarySectionType.playlists,
        titleOverride: mine ? '我的歌单' : '公开歌单',
        emptyTextOverride: mine ? '暂无我的歌单' : '暂无公开歌单',
        items: mine ? controller.myPlaylists : controller.publicPlaylists,
        onBack: _showLibraryHomePage,
        onRefresh: _refreshPlaylists,
        onCreatePlaylist: mine && controller.canCreateRemotePlaylist
            ? _createPlaylist
            : null,
        actions: mine && compactTools
            ? [
                PopupMenuButton<String>(
                  tooltip: '我的歌单工具',
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (value) {
                    switch (value) {
                      case 'sync':
                        _openPlaylistTool(_PlaylistTool.sync);
                        break;
                      case 'merge':
                        _openPlaylistTool(_PlaylistTool.merge);
                        break;
                      case 'batch':
                        _openPlaylistTool(_PlaylistTool.batchAdd);
                        break;
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'sync',
                      child: ListTile(
                        leading: Icon(Icons.sync_rounded),
                        title: Text('同步外部歌单'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'merge',
                      child: ListTile(
                        leading: Icon(Icons.merge_type_rounded),
                        title: Text('合并歌单'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'batch',
                      child: ListTile(
                        leading: Icon(Icons.playlist_add_rounded),
                        title: Text('批量添加歌曲'),
                      ),
                    ),
                  ],
                ),
              ]
            : mine
            ? [
                IconButton(
                  tooltip: '同步外部歌单',
                  onPressed: () => _openPlaylistTool(_PlaylistTool.sync),
                  icon: const Icon(Icons.sync_rounded),
                ),
                IconButton(
                  tooltip: '合并歌单',
                  onPressed: () => _openPlaylistTool(_PlaylistTool.merge),
                  icon: const Icon(Icons.merge_type_rounded),
                ),
                IconButton(
                  tooltip: '批量添加歌曲',
                  onPressed: () => _openPlaylistTool(_PlaylistTool.batchAdd),
                  icon: const Icon(Icons.playlist_add_rounded),
                ),
              ]
            : const [],
        onTap: _openPlaylistDetail,
      );
    }

    final sectionType = _activeLibrarySection;
    if (sectionType != null) {
      final overview = controller.libraryOverview;
      final items = switch (sectionType) {
        LibrarySectionType.artists => overview.artists,
        LibrarySectionType.albums => overview.albums,
        LibrarySectionType.playlists => controller.visiblePlaylists,
        LibrarySectionType.radio => overview.radioStations,
      };
      return _LibraryBrowsePage(
        type: sectionType,
        titleOverride: sectionType == LibrarySectionType.radio ? '电台' : null,
        items: items,
        onBack: _showLibraryHomePage,
        onRefresh: sectionType == LibrarySectionType.playlists
            ? _refreshPlaylists
            : sectionType == LibrarySectionType.radio
            ? _refreshRadioStations
            : null,
        onCreatePlaylist:
            sectionType == LibrarySectionType.playlists &&
                controller.canCreateRemotePlaylist
            ? _createPlaylist
            : null,
        onTap: sectionType == LibrarySectionType.playlists
            ? _openPlaylistDetail
            : sectionType == LibrarySectionType.radio
            ? _playRadioStation
            : _searchLibraryItem,
      );
    }

    if (_showSearchResults) {
      return _buildSearchResultsPage(controller);
    }

    return _buildLibraryHome(controller);
  }

  Widget _buildLibraryHome(AppController controller) {
    return _LibraryHome(
      controller: controller,
      searchController: _searchController,
      searchScope: _searchScope,
      selectedHomeTab: _selectedHomeTab,
      onSearch: _search,
      onSearchScopeChanged: (scope) => setState(() => _searchScope = scope),
      onSuggestionSelected: _openSearchSuggestion,
      onHomeTabChanged: _selectHomeTab,
      onOpenDiscoveryAlbum: _openDiscoveryAlbum,
      onPlayDiscoverySection: _playDiscoverySection,
      onOpenPlaylist: _openPlaylistDetail,
      onPlayPlaylist: _playHomePlaylist,
      onOpenTrackCollection: _openTrackCollection,
      onShowLibrarySection: _openLibrarySectionPage,
      onCreatePlaylist: _createPlaylist,
      onRefreshFavorites: _refreshFavorites,
      onRefreshPlaylists: _refreshPlaylists,
      onRefreshRadioStations: _refreshRadioStations,
      onOpenDailyRecommendation: _openDailyRecommendation,
      onRefreshDailyRecommendation: _refreshDailyRecommendation,
      onOpenCasualListening: _openCasualListening,
      onRefreshCasualListening: _refreshCasualListening,
      onStartLibraryShuffle: _startLibraryShuffle,
      onRefreshLibrary: _refreshLibrary,
      onOpenPlaylistCollection: _openPlaylistCollection,
      onOpenMetadataManager: _openMetadataManager,
      onOpenLogViewer: _openLogViewer,
    );
  }

  Widget _buildSearchResultsPage(AppController controller) {
    return _SearchResultsPage(
      controller: controller,
      searchController: _searchController,
      searchScope: _searchScope,
      selectedSearchTab: _selectedSearchTab,
      onSearch: _search,
      onSearchScopeChanged: (scope) => setState(() => _searchScope = scope),
      onSuggestionSelected: _openSearchSuggestion,
      onSearchTabChanged: (tab) => setState(() => _selectedSearchTab = tab),
      onSearchLibraryItem: _searchLibraryItem,
      onPreviousSongPage: controller.searchSongPageIndex <= 0
          ? null
          : () => _searchSongPage(controller.searchSongPageIndex - 1),
      onNextSongPage: controller.hasNextSearchSongPage
          ? () => _searchSongPage(controller.searchSongPageIndex + 1)
          : null,
      onBack: _showLibraryHomePage,
    );
  }

  Future<void> _search() async {
    final shouldOpenResults =
        widget.controller.selectedServer != null &&
        _searchController.text.trim().isNotEmpty;
    await widget.controller.searchSelectedServer(
      _searchController.text,
      scope: LibrarySearchScope.all,
    );
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
    setState(() {
      _selectedSearchTab = _defaultSearchResultTab(
        _searchScope,
        widget.controller.visibleTracks,
        widget.controller.searchResults,
      );
      if (shouldOpenResults) {
        _showSearchResults = true;
        _showNowPlaying = false;
        _activeLibrarySection = null;
        _activeLibraryItem = null;
        _activeRemotePlaylist = null;
        _activePlaylistCollection = null;
        _activePlaylistTool = null;
        _activeTrackCollectionTitle = null;
        _activeTrackCollectionTracks = const [];
      }
    });
  }

  Future<void> _searchSongPage(int pageIndex) async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return;
    }
    await widget.controller.searchSelectedServerPage(
      query,
      scope: LibrarySearchScope.all,
      pageIndex: pageIndex,
    );
    if (!mounted || _searchController.text.trim() != query) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
    setState(() => _selectedSearchTab = _SearchResultTab.songs);
  }

  void _openSearchSuggestion(_RemoteSearchSuggestion suggestion) {
    final libraryItem = suggestion.libraryItem;
    if (libraryItem != null) {
      unawaited(_openLibraryItem(libraryItem));
      return;
    }
    _openScopedSearch(suggestion.title, suggestion.scope);
  }

  void _openScopedSearch(String keyword, LibrarySearchScope scope) {
    final query = keyword.trim();
    if (query.isEmpty) {
      return;
    }

    _searchController.text = query;
    setState(() {
      _selectedHomeTab = _HomeTab.music;
      _searchScope = scope;
      _selectedSearchTab = _defaultSearchResultTab(
        scope,
        const [],
        const LibrarySearchResults(),
      );
      _showNowPlaying = false;
      _showSearchResults = true;
      _activeLibrarySection = null;
      _activeLibraryItem = null;
      _activeLibraryItemPageTitle = null;
      _activeLibraryItemHideTrackArtwork = false;
      _activeRemotePlaylist = null;
      _activePlaylistCollection = null;
      _activePlaylistTool = null;
      _activeTrackCollectionTitle = null;
      _activeTrackCollectionTracks = const [];
    });

    unawaited(_loadSearchFromNowPlaying(query, scope));
  }

  Future<void> _loadSearchFromNowPlaying(
    String query,
    LibrarySearchScope scope,
  ) async {
    await widget.controller.searchSelectedServer(
      query,
      scope: LibrarySearchScope.all,
    );
    if (!mounted ||
        _searchController.text.trim() != query ||
        _searchScope != scope ||
        _selectedHomeTab != _HomeTab.music) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
    setState(() {
      _selectedSearchTab = _defaultSearchResultTab(
        scope,
        widget.controller.visibleTracks,
        widget.controller.searchResults,
      );
      _showSearchResults = true;
    });
  }

  Future<void> _searchLibraryItem(LibrarySectionItem item) async {
    await _openLibraryItem(item);
  }

  Future<void> _openDiscoveryAlbum(
    HomeDiscoverySection section,
    LibrarySectionItem item,
  ) async {
    await _openLibraryItem(
      item,
      pageTitle: _homeDiscoveryLabel(section),
      hideTrackArtwork: true,
    );
  }

  Future<void> _playDiscoverySection(
    HomeDiscoverySection section,
    List<LibrarySectionItem> albums,
  ) async {
    final title = _homeDiscoveryLabel(section);
    try {
      final result = await widget.controller.homeDiscoveryTracks(albums);
      if (!mounted) {
        return;
      }
      if (result.tracks.isEmpty) {
        _showLibraryStatus(
          result.failedAlbumCount > 0 ? '$title加载失败。' : '$title暂无可播放歌曲。',
        );
        return;
      }
      await widget.controller.playTrackList(result.tracks, 0);
      if (!mounted) {
        return;
      }
      final skipped = result.failedAlbumCount > 0
          ? '，已跳过 ${result.failedAlbumCount} 张加载失败的专辑'
          : '';
      _showLibraryStatus('正在播放$title：${result.tracks.length} 首$skipped。');
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'library',
        '播放$title失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showLibraryStatus('播放失败：${_formatError(error)}');
      }
    }
  }

  Future<void> _playHomePlaylist(LibrarySectionItem playlist) async {
    try {
      final tracks = await widget.controller.playlistTracks(playlist);
      if (!mounted) {
        return;
      }
      if (tracks.isEmpty) {
        _showLibraryStatus('歌单暂无可播放歌曲。');
        return;
      }
      await widget.controller.playTrackList(tracks, 0);
      if (mounted) {
        _showLibraryStatus('正在播放歌单：${playlist.title}。');
      }
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'playlist',
        '播放歌单“${playlist.title}”失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _showLibraryStatus('播放失败：${_formatError(error)}');
      }
    }
  }

  Future<void> _openLibraryItem(
    LibrarySectionItem item, {
    String? pageTitle,
    bool hideTrackArtwork = false,
  }) async {
    _searchController.text = item.title;
    await widget.controller.searchLibraryItem(item);
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
    setState(() {
      _searchScope = LibrarySearchScope.songs;
      _selectedSearchTab = _SearchResultTab.songs;
      _showSearchResults = false;
      _showNowPlaying = false;
      _activeLibrarySection = null;
      _activeLibraryItem = item;
      _activeLibraryItemPageTitle = pageTitle;
      _activeLibraryItemHideTrackArtwork = hideTrackArtwork;
      _activeRemotePlaylist = null;
      _activePlaylistCollection = null;
      _activePlaylistTool = null;
      _activeTrackCollectionTitle = null;
      _activeTrackCollectionTracks = const [];
    });
  }

  void _openTrackCollection(String title, List<Track> tracks) {
    setState(() {
      _showNowPlaying = false;
      _showSearchResults = false;
      _activeLibrarySection = null;
      _activeLibraryItem = null;
      _activeRemotePlaylist = null;
      _activePlaylistCollection = null;
      _activePlaylistTool = null;
      _activeTrackCollectionTitle = title;
      _activeTrackCollectionTracks = tracks;
    });
  }

  void _openDailyRecommendation() {
    _openTrackCollection('每日推荐', widget.controller.recommendedTracks);
    unawaited(widget.controller.ensureDailyRecommendation());
  }

  void _openCasualListening() {
    _openTrackCollection('随便听听', widget.controller.casualListeningTracks);
    unawaited(widget.controller.ensureCasualListening());
  }

  Future<void> _playRadioStation(LibrarySectionItem station) async {
    await widget.controller.playRadioStation(station);
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
  }

  Future<void> _refreshFavorites() async {
    await widget.controller.refreshFavoriteTracks();
    if (!mounted) {
      return;
    }
    setState(() {
      if (_activeTrackCollectionTitle == '我喜欢的') {
        _activeTrackCollectionTracks =
            widget.controller.libraryOverview.favoriteTracks;
      }
    });
    _showLibraryStatus(widget.controller.statusMessage);
  }

  Future<void> _refreshPlaylists() async {
    await widget.controller.refreshRemotePlaylists();
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
  }

  Future<void> _refreshRadioStations() async {
    await widget.controller.refreshRadioStations();
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
  }

  Future<void> _refreshDailyRecommendation() async {
    await widget.controller.refreshDailyRecommendation();
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
  }

  Future<void> _refreshCasualListening() async {
    await widget.controller.refreshCasualListening();
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
  }

  Future<void> _startLibraryShuffle() async {
    await widget.controller.startLibraryShuffle();
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
  }

  Future<void> _saveDailyRecommendation() async {
    final tracks = widget.controller.recommendedTracks;
    if (tracks.isEmpty || !widget.controller.canCreateRemotePlaylist) {
      _showLibraryStatus('暂无可保存的推荐歌曲。');
      return;
    }
    if (widget.controller.manageablePlaylists.isEmpty) {
      await widget.controller.refreshRemotePlaylists();
      if (!mounted) {
        return;
      }
    }
    final choice = await showDialog<Object>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('保存每日推荐'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('create'),
            child: const ListTile(
              leading: Icon(Icons.add_rounded),
              title: Text('新建歌单'),
            ),
          ),
          for (final playlist in widget.controller.manageablePlaylists)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(playlist),
              child: ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: Text(
                  playlist.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || choice == null) {
      return;
    }
    if (choice is LibrarySectionItem) {
      await widget.controller.addTracksToRemotePlaylist(choice, tracks);
    } else {
      final now = DateTime.now();
      final date = [
        now.year.toString(),
        now.month.toString().padLeft(2, '0'),
        now.day.toString().padLeft(2, '0'),
      ].join('-');
      final result = await showDialog<_RemotePlaylistEditResult>(
        context: context,
        builder: (context) => _RemotePlaylistDialog(initialName: '每日推荐 $date'),
      );
      if (result == null) {
        return;
      }
      await widget.controller.createRemotePlaylist(
        name: result.name,
        comment: result.comment,
        isPublic: result.isPublic,
        tracks: tracks,
      );
    }
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
  }

  Future<void> _refreshLibrary() async {
    await widget.controller.loadLibraryOverview(refreshHomePlayback: true);
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
  }

  void _handleControllerChanged() {
    final playerVolume = widget.controller.player.volume;
    if (mounted && (_volume - playerVolume).abs() > 0.0001) {
      setState(() {
        _volume = playerVolume;
        if (playerVolume > 0) {
          _lastNonZeroVolume = playerVolume;
        }
      });
      _scheduleDesktopVolumePersistence(playerVolume);
    }
    final isRefreshing = widget.controller.isRefreshingLibrary;
    if (!_wasRefreshingLibrary && isRefreshing) {
      ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
    }
    if (_wasRefreshingLibrary && !isRefreshing) {
      _showLibraryStatus(widget.controller.statusMessage);
    }
    _wasRefreshingLibrary = isRefreshing;
  }

  void _showLibraryStatus(String? message) {
    if (message == null || message.isEmpty || !mounted) {
      return;
    }
    _showSourceMessage(context, message);
  }

  Future<void> _checkForUpdateOnStartup() async {
    if (_didRunStartupUpdateCheck ||
        !mounted ||
        !widget.controller.isInitialized ||
        !widget.controller.settings.checkUpdatesOnStartup) {
      return;
    }
    _didRunStartupUpdateCheck = true;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final platformKey = await resolveAppUpdatePlatformKey();
      final update = await widget.controller.updateService.fetchForPlatform(
        platformKey,
      );
      if (!mounted ||
          !isNewerAppVersion(update.latestVersion, packageInfo.version)) {
        return;
      }
      await _showAppUpdateDialog(
        context: context,
        controller: widget.controller,
        currentVersion: packageInfo.version,
        update: update,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        'update',
        '启动时检查更新失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _openLibrarySectionPage(LibrarySectionType type) {
    setState(() {
      _showNowPlaying = false;
      _showSearchResults = false;
      _activeRemotePlaylist = null;
      _activeLibraryItem = null;
      _activeLibrarySection = type;
      _activePlaylistCollection = null;
      _activePlaylistTool = null;
      _activeTrackCollectionTitle = null;
      _activeTrackCollectionTracks = const [];
    });
  }

  void _openPlaylistCollection(_PlaylistCollection collection) {
    setState(() {
      _showNowPlaying = false;
      _showSearchResults = false;
      _activeLibrarySection = null;
      _activeLibraryItem = null;
      _activeRemotePlaylist = null;
      _activePlaylistCollection = collection;
      _activePlaylistTool = null;
      _activeTrackCollectionTitle = null;
      _activeTrackCollectionTracks = const [];
    });
  }

  Future<void> _openPlaylistDetail(LibrarySectionItem item) async {
    setState(() {
      _showNowPlaying = false;
      _showSearchResults = false;
      _activeLibrarySection = null;
      _activeLibraryItem = null;
      _activeRemotePlaylist = item;
      _activePlaylistCollection = null;
      _activePlaylistTool = null;
      _activeTrackCollectionTitle = null;
      _activeTrackCollectionTracks = const [];
    });
  }

  Future<void> _createPlaylist() async {
    if (!widget.controller.canCreateRemotePlaylist) {
      _showLibraryStatus('请先登录。');
      return;
    }
    final result = await showDialog<_RemotePlaylistEditResult>(
      context: context,
      builder: (context) => const _RemotePlaylistDialog(),
    );
    if (result == null) {
      return;
    }
    await widget.controller.createRemotePlaylist(
      name: result.name,
      comment: result.comment,
      isPublic: result.isPublic,
    );
    if (!mounted) {
      return;
    }
    _showLibraryStatus(widget.controller.statusMessage);
    setState(() {});
  }

  void _openPlaylistTool(_PlaylistTool tool) {
    final playlists = widget.controller.manageablePlaylists;
    if (tool == _PlaylistTool.merge && playlists.length < 2) {
      _showLibraryStatus('至少需要两个我的歌单。');
      return;
    }
    if (tool == _PlaylistTool.batchAdd && playlists.isEmpty) {
      _showLibraryStatus('暂无可编辑的我的歌单。');
      return;
    }
    setState(() {
      _showNowPlaying = false;
      _showSearchResults = false;
      _activeLibrarySection = null;
      _activeLibraryItem = null;
      _activeRemotePlaylist = null;
      _activePlaylistCollection = _PlaylistCollection.mine;
      _activePlaylistTool = tool;
      _activeTrackCollectionTitle = null;
      _activeTrackCollectionTracks = const [];
    });
  }

  void _closePlaylistTool() {
    setState(() => _activePlaylistTool = null);
    _showLibraryStatus(widget.controller.statusMessage);
  }

  void _openMetadataManager() {
    setState(() {
      _clearSearchText();
      _resetContentNavigation();
      _showMetadataManager = true;
    });
  }

  void _closeMetadataManager() {
    setState(() => _showMetadataManager = false);
  }

  void _openLogViewer() {
    setState(() {
      _clearSearchText();
      _resetContentNavigation();
      _showLogViewer = true;
    });
  }

  void _closeLogViewer() {
    setState(() => _showLogViewer = false);
  }

  void _openBatchAddForPlaylist(LibrarySectionItem playlist) {
    if (!widget.controller.canManageRemotePlaylist(playlist)) {
      _showLibraryStatus('公开歌单只能播放。');
      return;
    }
    setState(() {
      _showNowPlaying = false;
      _showSearchResults = false;
      _activePlaylistTool = _PlaylistTool.batchAdd;
    });
  }

  void _selectHomeTab(_HomeTab tab) {
    setState(() {
      _clearSearchText();
      _selectedHomeTab = tab;
      _resetContentNavigation();
    });
  }

  void _showLibraryHomePage() {
    setState(() {
      _clearSearchText();
      _resetContentNavigation();
    });
  }

  void _closeActiveDetailPage() {
    setState(() {
      _clearSearchText();
      _showNowPlaying = false;
      _activeLibrarySection = null;
      _activeLibraryItem = null;
      _activeLibraryItemPageTitle = null;
      _activeLibraryItemHideTrackArtwork = false;
      _activeRemotePlaylist = null;
      _activePlaylistCollection = null;
      _activePlaylistTool = null;
      _showMetadataManager = false;
      _activeTrackCollectionTitle = null;
      _activeTrackCollectionTracks = const [];
    });
  }

  void _clearSearchText() {
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    }
    _searchScope = LibrarySearchScope.songs;
    _selectedSearchTab = _SearchResultTab.songs;
  }

  void _resetContentNavigation() {
    _showNowPlaying = false;
    _showSearchResults = false;
    _activeLibrarySection = null;
    _activeLibraryItem = null;
    _activeLibraryItemPageTitle = null;
    _activeLibraryItemHideTrackArtwork = false;
    _activeRemotePlaylist = null;
    _activePlaylistCollection = null;
    _activePlaylistTool = null;
    _showMetadataManager = false;
    _showLogViewer = false;
    _activeTrackCollectionTitle = null;
    _activeTrackCollectionTracks = const [];
  }

  Future<void> _handleBackNavigation() async {
    if (_closeTopInAppPage()) {
      return;
    }
    await _moveAndroidTaskToBack();
  }

  bool _closeTopInAppPage() {
    if (_showNowPlaying) {
      setState(() => _showNowPlaying = false);
      return true;
    }
    if (_showMetadataManager) {
      _closeMetadataManager();
      return true;
    }
    if (_showLogViewer) {
      _closeLogViewer();
      return true;
    }
    if (_activePlaylistTool != null) {
      _closePlaylistTool();
      return true;
    }
    if (_activeLibrarySection != null ||
        _activeLibraryItem != null ||
        _activeRemotePlaylist != null ||
        _activePlaylistCollection != null ||
        _activeTrackCollectionTitle != null) {
      _closeActiveDetailPage();
      return true;
    }
    if (_showSearchResults) {
      _showLibraryHomePage();
      return true;
    }
    return false;
  }

  Future<void> _moveAndroidTaskToBack() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _androidTaskChannel.invokeMethod<void>('moveTaskToBack');
        return;
      } on MissingPluginException {
        // Widget tests and old builds may not have the Android channel.
      } on PlatformException {
        // Fall through to the framework fallback if the host rejects it.
      }
    }
    await SystemNavigator.pop();
  }

  void _setVolume(double value) {
    final nextVolume = value.clamp(0.0, 1.0);
    if (nextVolume > 0) {
      _lastNonZeroVolume = nextVolume;
    }
    setState(() => _volume = nextVolume);
    widget.controller.player.setVolume(nextVolume);
    _scheduleDesktopVolumePersistence(nextVolume);
  }

  Future<void> _initializePlayerVolume() async {
    final initialVolume = switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => _mobilePlayerVolume,
      TargetPlatform.windows || TargetPlatform.macOS =>
        widget.controller.desktopPlayerVolume ?? _defaultPlayerVolume,
      _ => _defaultPlayerVolume,
    };
    if (!mounted) {
      return;
    }
    _volume = initialVolume;
    _lastNonZeroVolume = initialVolume;
    await widget.controller.player.setVolume(initialVolume);
  }

  bool get _usesDesktopVolumePersistence =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;

  void _scheduleDesktopVolumePersistence(double volume) {
    if (!_usesDesktopVolumePersistence) {
      return;
    }
    _desktopVolumePersistTimer?.cancel();
    _desktopVolumePersistTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(widget.controller.saveDesktopPlayerVolume(volume)),
    );
  }

  void _toggleMute() {
    if (_volume > 0) {
      _setVolume(0);
      return;
    }
    _setVolume(_lastNonZeroVolume <= 0 ? 1 : _lastNonZeroVolume);
  }
}

class _MobileBackSwipeRegion extends StatefulWidget {
  const _MobileBackSwipeRegion({required this.child, required this.onBack});

  final Widget child;
  final Future<void> Function() onBack;

  @override
  State<_MobileBackSwipeRegion> createState() => _MobileBackSwipeRegionState();
}

class _MobileBackSwipeRegionState extends State<_MobileBackSwipeRegion> {
  double _dragDistance = 0;

  void _handleDragStart(DragStartDetails details) {
    _dragDistance = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _dragDistance = math.max(0, _dragDistance + details.delta.dx);
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldGoBack = _dragDistance >= 72 || velocity >= 520;
    _dragDistance = 0;
    if (shouldGoBack) {
      unawaited(widget.onBack());
    }
  }

  void _handleDragCancel() {
    _dragDistance = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 28,
          child: GestureDetector(
            key: const ValueKey('android-edge-back-swipe'),
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _handleDragStart,
            onHorizontalDragUpdate: _handleDragUpdate,
            onHorizontalDragEnd: _handleDragEnd,
            onHorizontalDragCancel: _handleDragCancel,
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class _BackgroundWatermark extends StatelessWidget {
  const _BackgroundWatermark({
    required this.logoPath,
    required this.backgroundPath,
  });

  final String logoPath;
  final String backgroundPath;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? const [Color(0xFF07100D), Color(0xFF10231C)]
                  : const [Color(0xFFF7FBF8), Color(0xFFEAF4EF)],
            ),
          ),
        ),
        if (backgroundPath.trim().isNotEmpty)
          Opacity(
            opacity: isDark ? 0.08 : 0.07,
            child: _BrandBackgroundImage(imagePath: backgroundPath),
          ),
        if (logoPath.trim().isNotEmpty && logoPath != backgroundPath)
          Opacity(
            opacity: isDark ? 0.09 : 0.08,
            child: Center(
              child: FractionallySizedBox(
                widthFactor: 0.44,
                heightFactor: 0.44,
                child: _BrandLogoImage(logoPath: logoPath),
              ),
            ),
          ),
      ],
    );
  }
}

class _BrandBackgroundImage extends StatelessWidget {
  const _BrandBackgroundImage({required this.imagePath});

  final String imagePath;

  @override
  Widget build(BuildContext context) {
    final file = imagePath.trim().isEmpty ? null : File(imagePath);
    if (file != null && file.existsSync()) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      );
    }
    return const SizedBox.shrink();
  }
}

class _BrandLogoImage extends StatelessWidget {
  const _BrandLogoImage({required this.logoPath});

  final String logoPath;

  @override
  Widget build(BuildContext context) {
    final file = File(logoPath);
    if (!file.existsSync()) {
      return const SizedBox.shrink();
    }
    return Image.file(
      file,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
    );
  }
}

class _GlassAppBarBackground extends StatelessWidget {
  const _GlassAppBarBackground();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _glassFillColor(context, lightAlpha: 0.62, darkAlpha: 0.34),
        border: Border(bottom: BorderSide(color: _glassBorderColor(context))),
      ),
    );
  }
}

class _PageBackButton extends StatelessWidget {
  const _PageBackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '返回音乐库',
      style: IconButton.styleFrom(
        fixedSize: const Size.square(40),
        minimumSize: const Size.square(40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
      icon: const Icon(Icons.arrow_back),
    );
  }
}

class _DetailPageHeading extends StatelessWidget {
  const _DetailPageHeading({
    required this.title,
    required this.onBack,
    this.actions = const [],
    this.titleKey,
  });

  final String title;
  final VoidCallback onBack;
  final List<Widget> actions;
  final Key? titleKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('detail-page-heading'),
      children: [
        _PageBackButton(onPressed: onBack),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            key: titleKey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        ...actions,
      ],
    );
  }
}

class _PlayableArtwork extends StatelessWidget {
  const _PlayableArtwork({required this.artwork, required this.onPlay});

  final Widget artwork;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        artwork,
        IconButton(
          key: const ValueKey('artwork-play-all'),
          tooltip: '播放全部',
          onPressed: onPlay,
          iconSize: 30,
          icon: Icon(
            Icons.play_arrow_rounded,
            color: Colors.white,
            shadows: const [
              Shadow(color: Colors.black87, blurRadius: 8),
              Shadow(color: Colors.black54, blurRadius: 2),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlassSurface extends StatelessWidget {
  const _GlassSurface({
    required this.child,
    this.padding,
    this.darkAlpha = 0.18,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double darkAlpha;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(8);
    return ClipRRect(
      borderRadius: borderRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _glassFillColor(
            context,
            lightAlpha: 0.54,
            darkAlpha: darkAlpha,
          ),
          borderRadius: borderRadius,
          border: Border.all(color: _glassBorderColor(context)),
          boxShadow: _glassShadow(context),
        ),
        child: Material(
          color: Colors.transparent,
          child: padding == null
              ? child
              : Padding(padding: padding!, child: child),
        ),
      ),
    );
  }
}

Color _glassFillColor(
  BuildContext context, {
  required double lightAlpha,
  required double darkAlpha,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return (isDark ? Colors.black : Colors.white).withValues(
    alpha: isDark ? darkAlpha : lightAlpha,
  );
}

Color _glassBorderColor(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return (isDark ? Colors.white : Colors.black).withValues(
    alpha: isDark ? 0.14 : 0.08,
  );
}

List<BoxShadow> _glassShadow(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.08),
      blurRadius: isDark ? 18 : 22,
      offset: const Offset(0, 10),
    ),
  ];
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({
    required this.controller,
    required this.onBack,
    required this.onRefreshLibrary,
    required this.onOpenMetadataManager,
    required this.onOpenLogViewer,
    this.showBack = true,
  });

  final AppController controller;
  final VoidCallback onBack;
  final Future<void> Function() onRefreshLibrary;
  final VoidCallback onOpenMetadataManager;
  final VoidCallback onOpenLogViewer;
  final bool showBack;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  late AppSettings _settings;
  late Future<int> _cacheSizeFuture;
  late Future<String> _appVersionFuture;
  bool _checkingForUpdate = false;
  final Set<String> _testingAiServices = <String>{};
  int _usernameTapCount = 0;
  Timer? _usernameTapResetTimer;

  @override
  void initState() {
    super.initState();
    _settings = widget.controller.settings;
    _cacheSizeFuture = widget.controller.cacheSize();
    _appVersionFuture = PackageInfo.fromPlatform().then(
      (packageInfo) => packageInfo.version,
    );
  }

  @override
  void dispose() {
    _usernameTapResetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    final pagePadding = EdgeInsets.fromLTRB(
      compact ? 10 : 16,
      compact ? 8 : 16,
      compact ? 10 : 16,
      24,
    );
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        _settings = widget.controller.settings;
        final showPlaylistSectionItems =
            _settings.showMyPlaylistSection ||
            _settings.showPublicPlaylistSection;
        return ListView(
          padding: pagePadding,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Row(
                  children: [
                    if (widget.showBack) ...[
                      _PageBackButton(onPressed: widget.onBack),
                      const SizedBox(width: 12),
                    ],
                    Text(
                      '设置',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: compact ? 10 : 18),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SettingsSection(
                      title: '账号',
                      children: [
                        _SettingsActionTile(
                          leading: const Icon(Icons.account_circle_outlined),
                          title: widget.controller.selectedUsername.isEmpty
                              ? '未登录'
                              : widget.controller.selectedUsername,
                          titleKey: const ValueKey(
                            'settings-log-unlock-target',
                          ),
                          onTitleTap: _handleUsernameTap,
                          subtitle: Text(
                            widget.controller.libraryOverview.songCount == null
                                ? '歌曲数：--'
                                : '歌曲数：${widget.controller.libraryOverview.songCount}',
                          ),
                          action: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildRefreshLibraryButton(context),
                              const SizedBox(width: 4),
                              TextButton.icon(
                                key: const ValueKey('logout-button'),
                                onPressed: _logout,
                                icon: const Icon(Icons.logout_rounded),
                                label: const Text('登出'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    _SettingsSection(
                      title: '首页布局',
                      children: [
                        _HomeLayoutOrderEditor<HomePlaybackSection>(
                          title: '推荐播放',
                          itemKeyPrefix: 'home-playback',
                          items: _settings.homePlaybackOrder,
                          hiddenItems: _settings.hiddenHomePlaybacks,
                          labelFor: _homePlaybackLabel,
                          onMove: _moveHomePlayback,
                          onAllVisibilityChanged:
                              _setAllHomePlaybacksVisibility,
                          onVisibilityChanged: _setHomePlaybackVisibility,
                        ),
                        const Divider(height: 1),
                        _HomeLayoutOrderEditor<HomeShortcutSection>(
                          title: '快捷入口',
                          itemKeyPrefix: 'home-shortcut',
                          items: _settings.homeShortcutOrder,
                          hiddenItems: _settings.hiddenHomeShortcuts,
                          labelFor: _homeShortcutLabel,
                          onMove: _moveHomeShortcut,
                          onAllVisibilityChanged:
                              _setAllHomeShortcutsVisibility,
                          onVisibilityChanged: _setHomeShortcutVisibility,
                        ),
                        const Divider(height: 1),
                        _HomeLayoutOrderEditor<HomeDiscoverySection>(
                          title: '专辑与播放',
                          itemKeyPrefix: 'home-discovery',
                          items: _settings.homeDiscoveryOrder,
                          hiddenItems: _settings.hiddenHomeDiscoveries,
                          labelFor: _homeDiscoveryLabel,
                          onMove: _moveHomeDiscovery,
                          onAllVisibilityChanged:
                              _setAllHomeDiscoveriesVisibility,
                          onVisibilityChanged: _setHomeDiscoveryVisibility,
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '歌单',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  ),
                                  CompactSwitch(
                                    key: const ValueKey(
                                      'home-playlist-sections-all-visible',
                                    ),
                                    value: showPlaylistSectionItems,
                                    onChanged:
                                        _setAllPlaylistSectionsVisibility,
                                  ),
                                ],
                              ),
                              if (showPlaylistSectionItems) ...[
                                CompactSwitchListTile(
                                  key: const ValueKey(
                                    'home-my-playlists-section-visible',
                                  ),
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('我的歌单'),
                                  value: _settings.showMyPlaylistSection,
                                  onChanged: (value) => unawaited(
                                    _saveSettings(
                                      _settings.copyWith(
                                        showMyPlaylistSection: value,
                                      ),
                                    ),
                                  ),
                                ),
                                CompactSwitchListTile(
                                  key: const ValueKey(
                                    'home-public-playlists-section-visible',
                                  ),
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('公开歌单'),
                                  value: _settings.showPublicPlaylistSection,
                                  onChanged: (value) => unawaited(
                                    _saveSettings(
                                      _settings.copyWith(
                                        showPublicPlaylistSection: value,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    _SettingsSection(
                      title: '播放',
                      children: [
                        CompactSwitchListTile(
                          key: const ValueKey(
                            'play-random-after-sequential-queue',
                          ),
                          title: const Text('随机播放'),
                          subtitle: const Text('顺序播放的队列结束后，自动获取随机歌曲并继续播放'),
                          value: _settings.playRandomAfterSequentialQueue,
                          onChanged: (value) => unawaited(
                            _saveSettings(
                              _settings.copyWith(
                                playRandomAfterSequentialQueue: value,
                              ),
                            ),
                          ),
                        ),
                        CompactSwitchListTile(
                          key: const ValueKey(
                            'auto-play-daily-recommendation-on-startup',
                          ),
                          title: const Text('启动后自动播放'),
                          subtitle: const Text('登录并加载完成后，自动播放选中的首页推荐入口'),
                          value: _settings.autoPlayDailyRecommendationOnStartup,
                          onChanged: _settings.visibleHomePlaybackOrder.isEmpty
                              ? null
                              : (value) => unawaited(
                                  _saveSettings(
                                    _settings.copyWith(
                                      autoPlayDailyRecommendationOnStartup:
                                          value,
                                    ),
                                  ),
                                ),
                        ),
                        if (_settings.autoPlayDailyRecommendationOnStartup &&
                            _settings.visibleHomePlaybackOrder.isNotEmpty)
                          RadioGroup<HomePlaybackSection>(
                            groupValue: _settings.startupPlaybackSection,
                            onChanged: (value) {
                              if (value != null) {
                                unawaited(
                                  _saveSettings(
                                    _settings.copyWith(
                                      startupPlaybackSection: value,
                                    ),
                                  ),
                                );
                              }
                            },
                            child: Column(
                              children: [
                                for (final section
                                    in _settings.visibleHomePlaybackOrder)
                                  RadioListTile<HomePlaybackSection>(
                                    dense: true,
                                    value: section,
                                    title: Text(_homePlaybackLabel(section)),
                                  ),
                              ],
                            ),
                          ),
                        CompactSwitchListTile(
                          key: const ValueKey('skip-unplayable-tracks'),
                          title: const Text('播放失败自动切歌'),
                          subtitle: const Text('原始音频流多次启动失败后，自动播放下一首'),
                          value: _settings.skipUnplayableTracks,
                          onChanged: (value) => unawaited(
                            _saveSettings(
                              _settings.copyWith(skipUnplayableTracks: value),
                            ),
                          ),
                        ),
                      ],
                    ),
                    _SettingsSection(
                      title: 'AI 智能推荐',
                      action: TextButton.icon(
                        key: const ValueKey('settings-ai-service-add'),
                        onPressed: () => _editAiService(null),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('添加'),
                      ),
                      children: [
                        CompactSwitchListTile(
                          key: const ValueKey('ai-recommendation-enabled'),
                          title: const Text('启用 AI 智能推荐'),
                          subtitle: const Text('按列表顺序尝试已启用服务，全部失败时使用本地推荐'),
                          value: _settings.aiRecommendationEnabled,
                          onChanged: (value) =>
                              unawaited(_setAiRecommendationEnabled(value)),
                        ),
                        if (_settings.aiServices.isNotEmpty) ...[
                          const Divider(height: 1),
                          for (
                            var index = 0;
                            index < _settings.aiServices.length;
                            index++
                          ) ...[
                            _AiServiceTile(
                              service: _settings.aiServices[index],
                              isTesting: _testingAiServices.contains(
                                _settings.aiServices[index].id,
                              ),
                              onTest: () => _testSavedAiService(
                                _settings.aiServices[index],
                              ),
                              onEdit: () =>
                                  _editAiService(_settings.aiServices[index]),
                              onDelete: () =>
                                  _deleteAiService(_settings.aiServices[index]),
                            ),
                            if (index < _settings.aiServices.length - 1)
                              const Divider(height: 1),
                          ],
                        ],
                      ],
                    ),
                    _SettingsSection(
                      title: '外观',
                      children: [
                        _ThemeSettingTile(controller: widget.controller),
                        _SettingsActionTile(
                          leading: const Icon(
                            Icons.branding_watermark_outlined,
                          ),
                          title: '应用 Logo',
                          subtitle: Text(
                            _settings.logoPath.isEmpty
                                ? '使用默认图片'
                                : _settings.logoPath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          action: TextButton.icon(
                            key: const ValueKey('settings-logo-upload'),
                            onPressed: _pickLogo,
                            icon: const Icon(Icons.upload_file_outlined),
                            label: const Text('上传'),
                          ),
                        ),
                        _SettingsActionTile(
                          leading: const Icon(Icons.wallpaper_outlined),
                          title: '背景图',
                          subtitle: Text(
                            _settings.backgroundPath.isEmpty
                                ? '未设置背景图'
                                : _settings.backgroundPath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          action: TextButton.icon(
                            key: const ValueKey('settings-background-upload'),
                            onPressed: _pickBackground,
                            icon: const Icon(Icons.upload_file_outlined),
                            label: const Text('上传'),
                          ),
                        ),
                      ],
                    ),
                    _SettingsSection(
                      title: '缓存',
                      children: [
                        _SettingsActionTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: '缓存目录',
                          subtitle: Text(
                            _settings.cacheDirectory,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          action: TextButton.icon(
                            key: const ValueKey(
                              'settings-cache-directory-select',
                            ),
                            onPressed: _pickCacheDirectory,
                            icon: const Icon(Icons.folder_open_outlined),
                            label: const Text('选择'),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '缓存大小上限：${_formatGb(_settings.cacheSizeBytes)}',
                              ),
                              Slider(
                                value: _settings.cacheSizeBytes / gb,
                                min: 0.5,
                                max: 10,
                                divisions: 19,
                                label: _formatGb(_settings.cacheSizeBytes),
                                onChanged: (value) => _saveSettings(
                                  _settings.copyWith(
                                    cacheSizeBytes: (value * gb).round(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        FutureBuilder<int>(
                          future: _cacheSizeFuture,
                          builder: (context, snapshot) {
                            return _SettingsActionTile(
                              leading: const Icon(
                                Icons.cleaning_services_outlined,
                              ),
                              title: '清除缓存',
                              subtitle: Text(
                                '当前缓存：${_formatBytes(snapshot.data ?? 0)}',
                              ),
                              action: TextButton.icon(
                                onPressed: widget.controller.isBusy
                                    ? null
                                    : _clearCache,
                                icon: const Icon(Icons.delete_sweep),
                                label: const Text('清除'),
                              ),
                            );
                          },
                        ),
                        _SettingsActionTile(
                          leading: const Icon(
                            Icons.image_not_supported_outlined,
                          ),
                          title: '清除系统缓存',
                          subtitle: const Text('清除本地封面图片缓存'),
                          action: TextButton.icon(
                            key: const ValueKey('settings-artwork-cache-clear'),
                            onPressed: widget.controller.isBusy
                                ? null
                                : _clearSystemCache,
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: const Text('清除'),
                          ),
                        ),
                      ],
                    ),
                    if (defaultTargetPlatform == TargetPlatform.windows ||
                        defaultTargetPlatform == TargetPlatform.macOS)
                      _SettingsSection(
                        title: '工具',
                        children: [
                          _SettingsActionTile(
                            leading: const Icon(Icons.sell_outlined),
                            title: '标签管理',
                            subtitle: const Text('查看和修改本地音频文件元数据'),
                            action: IconButton(
                              key: const ValueKey(
                                'settings-open-metadata-manager',
                              ),
                              tooltip: '打开标签管理',
                              onPressed: widget.onOpenMetadataManager,
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ),
                        ],
                      ),
                    if (_supportsDesktopSettings(defaultTargetPlatform))
                      _SettingsSection(
                        title: '窗口',
                        children: [
                          if (defaultTargetPlatform == TargetPlatform.windows)
                            CompactSwitchListTile(
                              key: const ValueKey('launch-at-startup'),
                              title: const Text('开机启动'),
                              subtitle: const Text('登录 Windows 后自动启动 Zmusic'),
                              value: _settings.launchAtStartup,
                              onChanged: (value) => unawaited(
                                _saveSettings(
                                  _settings.copyWith(launchAtStartup: value),
                                ),
                              ),
                            ),
                          if (defaultTargetPlatform == TargetPlatform.windows)
                            const Divider(height: 1),
                          RadioGroup<CloseButtonBehavior>(
                            groupValue: _settings.closeButtonBehavior,
                            onChanged: (value) {
                              if (value != null) {
                                _saveSettings(
                                  _settings.copyWith(
                                    closeButtonBehavior: value,
                                  ),
                                );
                              }
                            },
                            child: Column(
                              children: const [
                                RadioListTile<CloseButtonBehavior>(
                                  value: CloseButtonBehavior.exit,
                                  title: Text('关闭按钮直接退出'),
                                ),
                                RadioListTile<CloseButtonBehavior>(
                                  value: CloseButtonBehavior.minimizeToTray,
                                  title: Text('关闭按钮最小化到托盘'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    if (widget.controller.logsUnlocked)
                      _SettingsSection(
                        key: const ValueKey('settings-log-section'),
                        title: '日志',
                        children: [
                          _SettingsActionTile(
                            leading: const Icon(Icons.tune_rounded),
                            title: '日志级别',
                            subtitle: Text(
                              _logLevelDescription(_settings.logLevel),
                            ),
                            action: DropdownButton<AppLogLevel>(
                              key: const ValueKey('settings-log-level'),
                              value: _settings.logLevel,
                              underline: const SizedBox.shrink(),
                              items: [
                                for (final level in AppLogLevel.values)
                                  DropdownMenuItem(
                                    value: level,
                                    child: Text(_logLevelLabel(level)),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  unawaited(
                                    _saveSettings(
                                      _settings.copyWith(logLevel: value),
                                    ),
                                  );
                                }
                              },
                            ),
                          ),
                          const Divider(height: 1),
                          _SettingsActionTile(
                            leading: const Icon(Icons.article_outlined),
                            title: '当前日志',
                            subtitle: const Text('滚动查看当前会话的日志记录'),
                            action: IconButton(
                              key: const ValueKey('settings-open-log-viewer'),
                              tooltip: '查看日志',
                              onPressed: widget.onOpenLogViewer,
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ),
                        ],
                      ),
                    _SettingsSection(
                      title: '关于',
                      children: [
                        CompactSwitchListTile(
                          key: const ValueKey('check-updates-on-startup'),
                          title: const Text('启动时检查更新'),
                          value: _settings.checkUpdatesOnStartup,
                          onChanged: (value) => unawaited(
                            _saveSettings(
                              _settings.copyWith(checkUpdatesOnStartup: value),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        FutureBuilder<String>(
                          future: _appVersionFuture,
                          builder: (context, snapshot) => _SettingsActionTile(
                            leading: const Icon(Icons.system_update_outlined),
                            title: '检查更新',
                            subtitle: Text('版本：${snapshot.data ?? '--'}'),
                            action: TextButton.icon(
                              key: const ValueKey('check-for-updates'),
                              onPressed: _checkingForUpdate
                                  ? null
                                  : _checkForUpdate,
                              icon: _checkingForUpdate
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.refresh),
                              label: Text(_checkingForUpdate ? '检查中' : '检查'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickCacheDirectory() async {
    final path = await getDirectoryPath(
      initialDirectory: _settings.cacheDirectory.trim().isEmpty
          ? null
          : _settings.cacheDirectory.trim(),
    );
    if (path != null) {
      await _saveSettings(_settings.copyWith(cacheDirectory: path));
      if (mounted) {
        _refreshCacheSize();
      }
    }
  }

  Widget _buildRefreshLibraryButton(BuildContext context) {
    final refreshing = widget.controller.isRefreshingLibrary;
    final icon = refreshing
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.refresh_rounded);
    final onPressed = widget.controller.isBusy
        ? null
        : () => unawaited(widget.onRefreshLibrary());
    if (defaultTargetPlatform == TargetPlatform.android &&
        _isPhoneWidth(context)) {
      return IconButton(
        key: const ValueKey('refresh-library'),
        tooltip: '重新加载曲库',
        onPressed: onPressed,
        icon: icon,
      );
    }
    return TextButton.icon(
      key: const ValueKey('refresh-library'),
      onPressed: onPressed,
      icon: icon,
      label: const Text('重新加载曲库'),
    );
  }

  Future<void> _pickLogo() async {
    final file = await openFile(acceptedTypeGroups: [_imageTypeGroup]);
    if (file != null) {
      await _saveSettings(_settings.copyWith(logoPath: file.path));
    }
  }

  Future<void> _pickBackground() async {
    final file = await openFile(acceptedTypeGroups: [_imageTypeGroup]);
    if (file != null) {
      await _saveSettings(_settings.copyWith(backgroundPath: file.path));
    }
  }

  Future<void> _saveSettings(AppSettings settings) async {
    await widget.controller.updateSettings(settings);
    if (mounted) {
      setState(() => _settings = widget.controller.settings);
    }
  }

  Future<void> _setAiRecommendationEnabled(bool enabled) async {
    try {
      await widget.controller.setAiRecommendationEnabled(enabled);
    } catch (error) {
      if (mounted) {
        _showSourceMessage(context, _formatError(error));
      }
    }
  }

  Future<void> _editAiService(AiServiceConfig? service) async {
    final result = await showDialog<_AiServiceEditorResult>(
      context: context,
      builder: (context) => _AiServiceEditorDialog(
        controller: widget.controller,
        service: service,
      ),
    );
    if (result == null) {
      return;
    }
    try {
      await widget.controller.saveAiService(result.service, result.apiKey);
      if (mounted) {
        _showSourceMessage(
          context,
          service == null ? 'AI 服务已添加。' : 'AI 服务已保存。',
        );
      }
    } catch (error) {
      if (mounted) {
        _showSourceMessage(context, _formatError(error));
      }
    }
  }

  Future<void> _testSavedAiService(AiServiceConfig service) async {
    if (!_testingAiServices.add(service.id)) {
      return;
    }
    setState(() {});
    try {
      final apiKey = await widget.controller.loadAiServiceApiKey(service.id);
      await widget.controller.testAiService(service, apiKey);
      if (mounted) {
        _showSourceMessage(context, '${service.name} 连接成功。');
      }
    } catch (error) {
      if (mounted) {
        _showSourceMessage(context, '测试失败：${_formatError(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _testingAiServices.remove(service.id));
      }
    }
  }

  Future<void> _deleteAiService(AiServiceConfig service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 AI 服务'),
        content: Text('确定删除“${service.name}”及其 API Key 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.controller.deleteAiService(service.id);
      if (mounted) {
        _showSourceMessage(context, 'AI 服务已删除。');
      }
    } catch (error) {
      if (mounted) {
        _showSourceMessage(context, '删除失败：${_formatError(error)}');
      }
    }
  }

  void _moveHomePlayback(HomePlaybackSection section, int offset) {
    final order = _moveOrderedItem(
      _settings.homePlaybackOrder,
      section,
      offset,
    );
    unawaited(_saveSettings(_settings.copyWith(homePlaybackOrder: order)));
  }

  void _moveHomeShortcut(HomeShortcutSection section, int offset) {
    final order = _moveOrderedItem(
      _settings.homeShortcutOrder,
      section,
      offset,
    );
    unawaited(_saveSettings(_settings.copyWith(homeShortcutOrder: order)));
  }

  void _moveHomeDiscovery(HomeDiscoverySection section, int offset) {
    final order = _moveOrderedItem(
      _settings.homeDiscoveryOrder,
      section,
      offset,
    );
    unawaited(_saveSettings(_settings.copyWith(homeDiscoveryOrder: order)));
  }

  void _setHomeShortcutVisibility(HomeShortcutSection section, bool visible) {
    final hidden = Set<HomeShortcutSection>.from(_settings.hiddenHomeShortcuts);
    visible ? hidden.remove(section) : hidden.add(section);
    unawaited(_saveSettings(_settings.copyWith(hiddenHomeShortcuts: hidden)));
  }

  void _setHomePlaybackVisibility(HomePlaybackSection section, bool visible) {
    final updated = switch (section) {
      HomePlaybackSection.dailyRecommendation => _settings.copyWith(
        showDailyRecommendation: visible,
      ),
      HomePlaybackSection.casualListening => _settings.copyWith(
        showCasualListening: visible,
      ),
      HomePlaybackSection.libraryShuffle => _settings.copyWith(
        showLibraryShuffle: visible,
      ),
    };
    unawaited(_saveSettings(updated));
  }

  void _setAllHomePlaybacksVisibility(bool visible) {
    unawaited(
      _saveSettings(
        _settings.copyWith(
          showDailyRecommendation: visible,
          showCasualListening: visible,
          showLibraryShuffle: visible,
        ),
      ),
    );
  }

  void _setAllHomeShortcutsVisibility(bool visible) {
    unawaited(
      _saveSettings(
        _settings.copyWith(
          hiddenHomeShortcuts: visible
              ? <HomeShortcutSection>{}
              : HomeShortcutSection.values.toSet(),
        ),
      ),
    );
  }

  void _setHomeDiscoveryVisibility(HomeDiscoverySection section, bool visible) {
    final hidden = Set<HomeDiscoverySection>.from(
      _settings.hiddenHomeDiscoveries,
    );
    visible ? hidden.remove(section) : hidden.add(section);
    unawaited(_saveSettings(_settings.copyWith(hiddenHomeDiscoveries: hidden)));
  }

  void _setAllHomeDiscoveriesVisibility(bool visible) {
    unawaited(
      _saveSettings(
        _settings.copyWith(
          hiddenHomeDiscoveries: visible
              ? <HomeDiscoverySection>{}
              : HomeDiscoverySection.values.toSet(),
        ),
      ),
    );
  }

  void _setAllPlaylistSectionsVisibility(bool visible) {
    unawaited(
      _saveSettings(
        _settings.copyWith(
          showMyPlaylistSection: visible,
          showPublicPlaylistSection: visible,
        ),
      ),
    );
  }

  Future<void> _clearCache() async {
    await widget.controller.clearAudioCache();
    if (!mounted) {
      return;
    }
    _refreshCacheSize();
    _showSourceMessage(context, widget.controller.statusMessage ?? '缓存已清除。');
  }

  Future<void> _clearSystemCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除系统缓存'),
        content: const Text('清除后会删除本地封面图片缓存，之后需要时会重新加载封面。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.controller.clearArtworkCache();
    if (!mounted) {
      return;
    }
    _showSourceMessage(context, widget.controller.statusMessage ?? '系统缓存已清除。');
  }

  void _handleUsernameTap() {
    if (widget.controller.logsUnlocked) {
      return;
    }
    _usernameTapResetTimer?.cancel();
    _usernameTapCount += 1;
    if (_usernameTapCount < 5) {
      _usernameTapResetTimer = Timer(const Duration(seconds: 2), () {
        _usernameTapCount = 0;
      });
      return;
    }
    _usernameTapCount = 0;
    unawaited(_requestLogUnlock());
  }

  Future<void> _requestLogUnlock() async {
    final passwordController = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('查看日志'),
        content: TextField(
          key: const ValueKey('settings-log-unlock-password'),
          controller: passwordController,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: '请输入密码'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('settings-log-unlock-confirm'),
            onPressed: () => Navigator.of(context).pop(passwordController.text),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    passwordController.dispose();
    if (!mounted || password == null) {
      return;
    }
    if (!widget.controller.unlockLogsForSession(password)) {
      _showSourceMessage(context, '密码错误。');
      return;
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('登出账号'),
        content: const Text('登出后需要重新输入账号和密码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('登出'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.logout();
    }
  }

  void _refreshCacheSize() {
    if (!mounted) {
      return;
    }
    setState(() {
      _cacheSizeFuture = widget.controller.cacheSize();
    });
  }

  Future<void> _checkForUpdate() async {
    if (_checkingForUpdate) {
      return;
    }
    setState(() => _checkingForUpdate = true);
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final platformKey = await resolveAppUpdatePlatformKey();
      final update = await widget.controller.updateService.fetchForPlatform(
        platformKey,
      );
      if (!mounted) {
        return;
      }
      if (!isNewerAppVersion(update.latestVersion, packageInfo.version)) {
        _showSourceMessage(context, '当前已是最新版本。');
        return;
      }
      setState(() => _checkingForUpdate = false);
      await _showAppUpdateDialog(
        context: context,
        controller: widget.controller,
        currentVersion: packageInfo.version,
        update: update,
      );
    } catch (error) {
      if (mounted) {
        _showSourceMessage(context, '检查更新失败：${_formatError(error)}');
      }
    } finally {
      if (mounted && _checkingForUpdate) {
        setState(() => _checkingForUpdate = false);
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kib = bytes / 1024;
    if (kib < 1024) {
      return '${kib.toStringAsFixed(1)} KB';
    }
    final mib = kib / 1024;
    return '${mib.toStringAsFixed(1)} MB';
  }
}

enum _AiServiceAction { test, edit, delete }

class _AiServiceTile extends StatelessWidget {
  const _AiServiceTile({
    required this.service,
    required this.isTesting,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
  });

  final AiServiceConfig service;
  final bool isTesting;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(service.endpoint);
    final host = uri?.host ?? service.endpoint;
    final statusLabel = service.enabled ? '已启用' : '未启用';
    return ListTile(
      key: ValueKey('ai-service-${service.id}'),
      leading: Icon(
        service.enabled
            ? Icons.check_circle_outline_rounded
            : Icons.pause_circle_outline_rounded,
        color: service.enabled
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(service.name),
      subtitle: Text(
        '$statusLabel · ${service.model} · $host',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: isTesting
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : PopupMenuButton<_AiServiceAction>(
              tooltip: 'AI 服务操作',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (action) {
                switch (action) {
                  case _AiServiceAction.test:
                    onTest();
                    break;
                  case _AiServiceAction.edit:
                    onEdit();
                    break;
                  case _AiServiceAction.delete:
                    onDelete();
                    break;
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _AiServiceAction.test,
                  child: ListTile(
                    leading: Icon(Icons.cable_rounded),
                    title: Text('测试连接'),
                  ),
                ),
                PopupMenuItem(
                  value: _AiServiceAction.edit,
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('编辑'),
                  ),
                ),
                PopupMenuItem(
                  value: _AiServiceAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline_rounded),
                    title: Text('删除'),
                  ),
                ),
              ],
            ),
    );
  }
}

class _AiServiceEditorResult {
  const _AiServiceEditorResult({required this.service, required this.apiKey});

  final AiServiceConfig service;
  final String apiKey;
}

class _AiServiceEditorDialog extends StatefulWidget {
  const _AiServiceEditorDialog({
    required this.controller,
    required this.service,
  });

  final AppController controller;
  final AiServiceConfig? service;

  @override
  State<_AiServiceEditorDialog> createState() => _AiServiceEditorDialogState();
}

class _AiServiceEditorDialogState extends State<_AiServiceEditorDialog> {
  static const _quickPresets = <AiServicePreset>[
    AiServicePreset.chatGpt,
    AiServicePreset.deepSeek,
    AiServicePreset.tencent,
    AiServicePreset.bailian,
  ];

  final _formKey = GlobalKey<FormState>();
  late final String _serviceId;
  late final TextEditingController _nameController;
  late final TextEditingController _endpointController;
  late final TextEditingController _modelController;
  final TextEditingController _apiKeyController = TextEditingController();
  late AiServicePreset _preset;
  late bool _enabled;
  bool _loadingApiKey = false;
  bool _showApiKey = false;
  bool _testing = false;
  bool _fetchingModels = false;
  String? _testMessage;
  bool _testSucceeded = false;

  bool get _networkBusy => _testing || _fetchingModels;

  @override
  void initState() {
    super.initState();
    final service = widget.service;
    _serviceId = service?.id ?? widget.controller.createAiServiceId();
    _preset = _presetForEndpoint(service?.endpoint ?? '');
    if (service == null) {
      _preset = AiServicePreset.chatGpt;
    }
    _enabled = service?.enabled ?? true;
    _nameController = TextEditingController(
      text: service?.name ?? _preset.label,
    );
    _endpointController = TextEditingController(
      text: service?.endpoint ?? _preset.endpoint,
    );
    _modelController = TextEditingController(text: service?.model ?? '');
    if (service != null) {
      _loadingApiKey = true;
      unawaited(_loadApiKey(service.id));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _endpointController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadApiKey(String serviceId) async {
    try {
      final apiKey = await widget.controller.loadAiServiceApiKey(serviceId);
      if (mounted) {
        _apiKeyController.text = apiKey;
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _testSucceeded = false;
          _testMessage = '读取 API Key 失败：${_formatError(error)}';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loadingApiKey = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    return Dialog(
      insetPadding: _responsiveDialogInsetPadding(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 580,
          maxHeight:
              MediaQuery.sizeOf(context).height * (compact ? 0.94 : 0.86),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.service == null ? '添加 AI 服务' : '编辑 AI 服务',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 20,
                  16,
                  compact ? 14 : 20,
                  12,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '服务类型',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final columnCount = constraints.maxWidth < 420
                              ? 2
                              : 4;
                          final buttonWidth =
                              (constraints.maxWidth - (columnCount - 1) * 8) /
                              columnCount;
                          return Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final preset in _quickPresets)
                                SizedBox(
                                  width: buttonWidth,
                                  height: 40,
                                  child: preset == _preset
                                      ? FilledButton(
                                          onPressed: _networkBusy
                                              ? null
                                              : () => _applyPreset(preset),
                                          child: Text(preset.label),
                                        )
                                      : OutlinedButton(
                                          onPressed: _networkBusy
                                              ? null
                                              : () => _applyPreset(preset),
                                          child: Text(preset.label),
                                        ),
                                ),
                            ],
                          );
                        },
                      ),
                      CompactSwitchListTile(
                        key: const ValueKey('ai-service-enabled'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('启用此服务'),
                        subtitle: const Text('推荐失败时按列表顺序继续尝试下一项'),
                        value: _enabled,
                        onChanged: _networkBusy
                            ? null
                            : (value) => setState(() => _enabled = value),
                      ),
                      TextFormField(
                        controller: _nameController,
                        enabled: !_networkBusy,
                        textInputAction: TextInputAction.next,
                        onChanged: (_) => _clearTestResult(),
                        decoration: const InputDecoration(
                          labelText: '服务名称',
                          border: OutlineInputBorder(),
                        ),
                        validator: _requiredValue,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _endpointController,
                        enabled: !_networkBusy,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                        onChanged: _handleEndpointChanged,
                        decoration: const InputDecoration(
                          labelText: '服务地址',
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateEndpoint,
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final apiKeyField = TextFormField(
                            controller: _apiKeyController,
                            enabled: !_networkBusy && !_loadingApiKey,
                            obscureText: !_showApiKey,
                            enableSuggestions: false,
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            onChanged: (_) => _clearTestResult(),
                            decoration: InputDecoration(
                              labelText: 'API Key',
                              border: const OutlineInputBorder(),
                              suffixIcon: _loadingApiKey
                                  ? const Padding(
                                      padding: EdgeInsets.all(14),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : IconButton(
                                      tooltip: _showApiKey
                                          ? '隐藏 API Key'
                                          : '显示 API Key',
                                      onPressed: () => setState(
                                        () => _showApiKey = !_showApiKey,
                                      ),
                                      icon: Icon(
                                        _showApiKey
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                    ),
                            ),
                            validator: _requiredValue,
                          );
                          final fetchButton = SizedBox(
                            height: 56,
                            child: OutlinedButton.icon(
                              key: const ValueKey('ai-service-fetch-models'),
                              onPressed: _networkBusy || _loadingApiKey
                                  ? null
                                  : _fetchModels,
                              icon: _fetchingModels
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.download_rounded),
                              label: Text(_fetchingModels ? '获取中' : '获取模型'),
                            ),
                          );
                          if (constraints.maxWidth >= 460) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: apiKeyField),
                                const SizedBox(width: 8),
                                fetchButton,
                              ],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              apiKeyField,
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: fetchButton,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _modelController,
                        enabled: !_networkBusy,
                        textInputAction: TextInputAction.done,
                        onChanged: (_) => _clearTestResult(),
                        decoration: const InputDecoration(
                          labelText: '模型名称',
                          helperText: '可从模型列表选择，也可自定义输入',
                          border: OutlineInputBorder(),
                        ),
                        validator: _requiredValue,
                        onFieldSubmitted: (_) {
                          if (!_networkBusy && !_loadingApiKey) {
                            _save();
                          }
                        },
                      ),
                      if (_testMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _testMessage!,
                          style: TextStyle(
                            color: _testSucceeded
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('ai-service-test'),
                    onPressed: _networkBusy || _loadingApiKey ? null : _test,
                    icon: _testing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cable_rounded),
                    label: Text(_testing ? '测试中' : '测试'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('ai-service-save'),
                    onPressed: _networkBusy || _loadingApiKey ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _applyPreset(AiServicePreset preset) {
    setState(() {
      _preset = preset;
      _nameController.text = preset.label;
      _endpointController.text = preset.endpoint;
      _testMessage = null;
    });
  }

  void _handleEndpointChanged(String endpoint) {
    final preset = _presetForEndpoint(endpoint);
    if (_preset != preset || _testMessage != null) {
      setState(() {
        _preset = preset;
        _testMessage = null;
      });
    }
  }

  void _clearTestResult() {
    if (_testMessage != null && !_networkBusy) {
      setState(() => _testMessage = null);
    }
  }

  Future<void> _fetchModels() async {
    final endpointError = _validateEndpoint(_endpointController.text);
    if (endpointError != null) {
      setState(() {
        _testSucceeded = false;
        _testMessage = endpointError;
      });
      return;
    }
    if (_apiKeyController.text.trim().isEmpty) {
      setState(() {
        _testSucceeded = false;
        _testMessage = '请先填写 API Key。';
      });
      return;
    }

    List<String>? models;
    setState(() {
      _fetchingModels = true;
      _testMessage = null;
    });
    try {
      models = await widget.controller.fetchAiServiceModels(
        endpoint: _endpointController.text,
        apiKey: _apiKeyController.text,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _testSucceeded = false;
          _testMessage = '获取模型失败：${_formatError(error)}';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _fetchingModels = false);
      }
    }
    if (!mounted || models == null) {
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _AiModelPickerDialog(
        models: models!,
        selectedModel: _modelController.text.trim(),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _modelController.text = selected;
        _testSucceeded = true;
        _testMessage = '已选择模型：$selected';
      });
    }
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      await widget.controller.testAiService(
        _currentService(),
        _apiKeyController.text,
      );
      if (mounted) {
        setState(() {
          _testSucceeded = true;
          _testMessage = '连接成功。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _testSucceeded = false;
          _testMessage = '测试失败：${_formatError(error)}';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.of(context).pop(
      _AiServiceEditorResult(
        service: _currentService(),
        apiKey: _apiKeyController.text.trim(),
      ),
    );
  }

  AiServiceConfig _currentService() {
    return AiServiceConfig(
      id: _serviceId,
      name: _nameController.text.trim(),
      endpoint: _endpointController.text.trim(),
      model: _modelController.text.trim(),
      enabled: _enabled,
    );
  }

  String? _requiredValue(String? value) {
    return value == null || value.trim().isEmpty ? '不能为空' : null;
  }

  String? _validateEndpoint(String? value) {
    final requiredError = _requiredValue(value);
    if (requiredError != null) {
      return requiredError;
    }
    final uri = Uri.tryParse(value!.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return '请输入有效的 HTTP 或 HTTPS 地址';
    }
    return null;
  }
}

class _AiModelPickerDialog extends StatefulWidget {
  const _AiModelPickerDialog({
    required this.models,
    required this.selectedModel,
  });

  final List<String> models;
  final String selectedModel;

  @override
  State<_AiModelPickerDialog> createState() => _AiModelPickerDialogState();
}

class _AiModelPickerDialogState extends State<_AiModelPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final models = query.isEmpty
        ? widget.models
        : widget.models
              .where((model) => model.toLowerCase().contains(query))
              .toList();
    return AlertDialog(
      title: const Text('选择模型'),
      content: SizedBox(
        width: 460,
        height: math.min(430.0, MediaQuery.sizeOf(context).height * 0.62),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: '搜索模型',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: models.isEmpty
                  ? const Center(child: Text('没有匹配的模型'))
                  : ListView.builder(
                      itemCount: models.length,
                      itemBuilder: (context, index) {
                        final model = models[index];
                        final selected = model == widget.selectedModel;
                        return ListTile(
                          dense: true,
                          title: Text(
                            model,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: selected
                              ? Icon(
                                  Icons.check_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                          onTap: () => Navigator.of(context).pop(model),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

AiServicePreset _presetForEndpoint(String endpoint) {
  final normalized = endpoint.trim();
  for (final preset in AiServicePreset.values) {
    if (preset != AiServicePreset.custom && preset.endpoint == normalized) {
      return preset;
    }
  }
  return AiServicePreset.custom;
}

String _logLevelLabel(AppLogLevel level) {
  return switch (level) {
    AppLogLevel.error => '错误',
    AppLogLevel.warning => '警告',
    AppLogLevel.info => '信息',
    AppLogLevel.debug => '调试',
  };
}

String _logLevelDescription(AppLogLevel level) {
  return switch (level) {
    AppLogLevel.error => '仅记录错误和崩溃信息',
    AppLogLevel.warning => '记录错误、警告和重试信息',
    AppLogLevel.info => '记录错误、警告和关键操作',
    AppLogLevel.debug => '记录所有调试信息',
  };
}

class _AppLogViewerPage extends StatefulWidget {
  const _AppLogViewerPage({
    required this.controller,
    required this.onBack,
    super.key,
  });

  final AppController controller;
  final VoidCallback onBack;

  @override
  State<_AppLogViewerPage> createState() => _AppLogViewerPageState();
}

class _AppLogViewerPageState extends State<_AppLogViewerPage> {
  final ScrollController _scrollController = ScrollController();
  final AppLogger _logger = AppLogger.instance;
  bool _followLatest = true;

  @override
  void initState() {
    super.initState();
    _logger.addListener(_handleLogChanged);
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _logger.removeListener(_handleLogChanged);
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _logger.entries;
    return Stack(
      children: [
        Positioned.fill(
          child: _BackgroundWatermark(
            logoPath: widget.controller.settings.logoPath,
            backgroundPath: widget.controller.settings.backgroundPath,
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            _isPhoneWidth(context) ? 10 : 16,
            _isPhoneWidth(context) ? 8 : 16,
            _isPhoneWidth(context) ? 10 : 16,
            16,
          ),
          child: Column(
            children: [
              _DetailPageHeading(
                title: '当前日志',
                onBack: widget.onBack,
                actions: [
                  IconButton(
                    key: const ValueKey('copy-current-logs'),
                    tooltip: '复制日志',
                    onPressed: entries.isEmpty ? null : _copyLogs,
                    icon: const Icon(Icons.copy_all_outlined),
                  ),
                  if (defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.linux)
                    IconButton(
                      key: const ValueKey('export-current-logs'),
                      tooltip: '导出日志',
                      onPressed: entries.isEmpty ? null : _exportLogs,
                      icon: const Icon(Icons.save_alt_rounded),
                    ),
                  IconButton(
                    key: const ValueKey('clear-current-logs'),
                    tooltip: '清除日志',
                    onPressed: entries.isEmpty ? null : _clearLogs,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: _GlassSurface(
                      padding: EdgeInsets.zero,
                      darkAlpha: 0.18,
                      child: entries.isEmpty
                          ? const Center(child: Text('当前暂无日志'))
                          : ListView.separated(
                              key: const ValueKey('current-log-list'),
                              controller: _scrollController,
                              padding: const EdgeInsets.all(14),
                              itemCount: entries.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 16),
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                return SelectionArea(
                                  child: Text(
                                    entry.formatted,
                                    style: TextStyle(
                                      fontFamily: Platform.isWindows
                                          ? 'Consolas'
                                          : 'monospace',
                                      fontSize: 12,
                                      height: 1.45,
                                      color: _logLevelColor(
                                        context,
                                        entry.level,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _handleScroll() {
    if (_scrollController.hasClients) {
      _followLatest = _scrollController.position.extentAfter < 48;
    }
  }

  void _handleLogChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    if (_followLatest) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _scrollToBottom() {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  Future<void> _copyLogs() async {
    final content = await _logger.exportText();
    if (!mounted || content.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    if (mounted) {
      _showSourceMessage(context, '日志已复制。');
    }
  }

  Future<void> _exportLogs() async {
    try {
      final content = await _logger.exportText();
      if (content.isEmpty) {
        return;
      }
      final now = DateTime.now();
      final location = await getSaveLocation(
        suggestedName:
            'zmusic-log-${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}-${_twoDigits(now.hour)}${_twoDigits(now.minute)}.txt',
      );
      if (location == null) {
        return;
      }
      await File(location.path).writeAsString(content, flush: true);
      if (mounted) {
        _showSourceMessage(context, '日志已导出。');
      }
    } catch (error, stackTrace) {
      _logger.error('logger', '导出日志失败', error: error, stackTrace: stackTrace);
      if (mounted) {
        _showSourceMessage(context, '导出日志失败：${_formatError(error)}');
      }
    }
  }

  Future<void> _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除日志'),
        content: const Text('确定清除当前日志和本地历史日志文件吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _logger.clear();
    }
  }
}

Color _logLevelColor(BuildContext context, AppLogLevel level) {
  final colors = Theme.of(context).colorScheme;
  return switch (level) {
    AppLogLevel.error => colors.error,
    AppLogLevel.warning => const Color(0xFFD99A24),
    AppLogLevel.info => colors.onSurface,
    AppLogLevel.debug => colors.onSurfaceVariant,
  };
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

Future<void> _showAppUpdateDialog({
  required BuildContext context,
  required AppController controller,
  required String currentVersion,
  required AppUpdateInfo update,
}) async {
  if ((_appUpdateDialogVisibility[controller] ?? false) || !context.mounted) {
    return;
  }
  _appUpdateDialogVisibility[controller] = true;
  var downloading = false;
  AppUpdateDownloadChannel? activeDownloadChannel;
  AppUpdateDownloadProgress? progress;
  String? downloadError;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            void startDownload(AppUpdateDownloadChannel channel) {
              setDialogState(() => activeDownloadChannel = channel);
              unawaited(
                _openAppUpdateDownload(
                  pageContext: context,
                  dialogContext: dialogContext,
                  controller: controller,
                  update: update,
                  downloadChannel: channel,
                  setDialogState: setDialogState,
                  onProgress: (value) => progress = value,
                  setDownloading: (value) => downloading = value,
                  setError: (value) => downloadError = value,
                ),
              );
            }

            return AlertDialog(
              key: const ValueKey('app-update-dialog'),
              insetPadding: _responsiveDialogInsetPadding(dialogContext),
              constraints: _responsiveDialogConstraints(
                dialogContext,
                maxWidth: 480,
                maxHeightFactor: 0.82,
              ),
              scrollable: true,
              title: Text('发现新版本 ${update.latestVersion}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前版本：$currentVersion'),
                  if (update.releaseTime.isNotEmpty)
                    Text('发布时间：${update.releaseTime}'),
                  if (update.updateContent.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      '更新内容',
                      style: Theme.of(dialogContext).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    for (final item in update.updateContent)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $item'),
                      ),
                  ],
                  if (downloading) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: progress?.fraction),
                    const SizedBox(height: 8),
                    Text(_formatUpdateDownloadProgress(progress)),
                  ],
                  if (downloadError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      downloadError!,
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: downloading
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('稍后更新'),
                ),
                FilledButton.icon(
                  onPressed: downloading
                      ? null
                      : () => startDownload(
                          AppUpdateDownloadChannel.defaultChannel,
                        ),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(
                    downloading &&
                            activeDownloadChannel ==
                                AppUpdateDownloadChannel.defaultChannel
                        ? '下载中'
                        : '服务器更新',
                  ),
                ),
                if (update.githubDownloadUri != null)
                  OutlinedButton.icon(
                    onPressed: downloading
                        ? null
                        : () => startDownload(AppUpdateDownloadChannel.github),
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: Text(
                      downloading &&
                              activeDownloadChannel ==
                                  AppUpdateDownloadChannel.github
                          ? '下载中'
                          : 'GitHub更新',
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  } finally {
    _appUpdateDialogVisibility[controller] = false;
  }
}

Future<void> _openAppUpdateDownload({
  required BuildContext pageContext,
  required BuildContext dialogContext,
  required AppController controller,
  required AppUpdateInfo update,
  required AppUpdateDownloadChannel downloadChannel,
  required StateSetter setDialogState,
  required ValueChanged<AppUpdateDownloadProgress> onProgress,
  required ValueChanged<bool> setDownloading,
  required ValueChanged<String?> setError,
}) async {
  if (defaultTargetPlatform != TargetPlatform.windows &&
      defaultTargetPlatform != TargetPlatform.android) {
    await _openAppUpdateDownloadInBrowser(
      pageContext,
      dialogContext,
      update.downloadUriFor(downloadChannel),
    );
    return;
  }

  setDialogState(() {
    setDownloading(true);
    onProgress(
      const AppUpdateDownloadProgress(receivedBytes: 0, totalBytes: null),
    );
    setError(null);
  });
  try {
    final installer = await controller.updateService.downloadUpdate(
      update,
      channel: downloadChannel,
      onProgress: (value) {
        if (dialogContext.mounted) {
          setDialogState(() => onProgress(value));
        }
      },
    );
    if (defaultTargetPlatform == TargetPlatform.android) {
      await openAndroidUpdateInstaller(installer);
      if (dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
      if (pageContext.mounted) {
        _showSourceMessage(pageContext, '更新包已下载，已打开系统安装程序。');
      }
      return;
    }
    await Process.start(
      installer.path,
      const [],
      mode: ProcessStartMode.detached,
    );
    if (dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
    if (pageContext.mounted) {
      _showSourceMessage(pageContext, '更新安装器已下载并启动。');
    }
  } catch (error) {
    if (dialogContext.mounted) {
      setDialogState(() {
        setDownloading(false);
        setError('下载更新失败：${_formatError(error)}');
      });
    } else if (pageContext.mounted) {
      _showSourceMessage(pageContext, '下载更新失败：${_formatError(error)}');
    }
  }
}

Future<void> _openAppUpdateDownloadInBrowser(
  BuildContext pageContext,
  BuildContext dialogContext,
  Uri downloadUri,
) async {
  try {
    final opened = await launchUrl(
      downloadUri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      throw Exception('系统无法打开下载地址。');
    }
    if (dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
  } catch (error) {
    if (pageContext.mounted) {
      _showSourceMessage(pageContext, '打开下载地址失败：${_formatError(error)}');
    }
  }
}

String _formatUpdateDownloadProgress(AppUpdateDownloadProgress? progress) {
  if (progress == null) {
    return '正在下载更新...';
  }
  final total = progress.totalBytes;
  if (total == null || total <= 0) {
    return '正在下载更新：${_formatDownloadBytes(progress.receivedBytes)}';
  }
  final percent = (progress.fraction! * 100).clamp(0, 100).round();
  return '正在下载更新：${_formatDownloadBytes(progress.receivedBytes)} / ${_formatDownloadBytes(total)} ($percent%)';
}

String _formatDownloadBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final kib = bytes / 1024;
  if (kib < 1024) {
    return '${kib.toStringAsFixed(1)} KB';
  }
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(1)} MB';
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
    this.action,
    super.key,
  });

  final String? title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 10 : 16),
      child: _GlassSurface(
        padding: EdgeInsets.symmetric(vertical: compact ? 4 : 8),
        darkAlpha: 0.18,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null || action != null)
              Padding(
                padding: EdgeInsets.fromLTRB(16, compact ? 6 : 8, 16, 4),
                child: Row(
                  children: [
                    if (title != null)
                      Expanded(
                        child: Text(
                          title!,
                          style: compact
                              ? Theme.of(context).textTheme.titleSmall
                              : Theme.of(context).textTheme.titleMedium,
                        ),
                      )
                    else
                      const Spacer(),
                    ?action,
                  ],
                ),
              ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _HomeLayoutOrderEditor<T extends Enum> extends StatelessWidget {
  const _HomeLayoutOrderEditor({
    required this.title,
    required this.itemKeyPrefix,
    required this.items,
    required this.hiddenItems,
    required this.labelFor,
    required this.onMove,
    required this.onAllVisibilityChanged,
    required this.onVisibilityChanged,
  });

  final String title;
  final String itemKeyPrefix;
  final List<T> items;
  final Set<T> hiddenItems;
  final String Function(T item) labelFor;
  final void Function(T item, int offset) onMove;
  final ValueChanged<bool> onAllVisibilityChanged;
  final void Function(T item, bool visible) onVisibilityChanged;

  @override
  Widget build(BuildContext context) {
    final showItems = hiddenItems.length < items.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              CompactSwitch(
                key: ValueKey('$itemKeyPrefix-all-visible'),
                value: showItems,
                onChanged: onAllVisibilityChanged,
              ),
            ],
          ),
          if (showItems)
            for (var index = 0; index < items.length; index++)
              _HomeLayoutOrderRow<T>(
                key: ValueKey('$itemKeyPrefix-${items[index].name}'),
                itemKeyPrefix: itemKeyPrefix,
                item: items[index],
                position: index + 1,
                label: labelFor(items[index]),
                visible: !hiddenItems.contains(items[index]),
                canMoveUp: index > 0,
                canMoveDown: index < items.length - 1,
                onMove: onMove,
                onVisibilityChanged: onVisibilityChanged,
              ),
        ],
      ),
    );
  }
}

class _HomeLayoutOrderRow<T extends Enum> extends StatelessWidget {
  const _HomeLayoutOrderRow({
    required this.itemKeyPrefix,
    required this.item,
    required this.position,
    required this.label,
    required this.visible,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onMove,
    required this.onVisibilityChanged,
    super.key,
  });

  final String itemKeyPrefix;
  final T item;
  final int position;
  final String label;
  final bool visible;
  final bool canMoveUp;
  final bool canMoveDown;
  final void Function(T item, int offset) onMove;
  final void Function(T item, bool visible) onVisibilityChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$position',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            key: ValueKey('$itemKeyPrefix-${item.name}-up'),
            tooltip: '上移',
            visualDensity: VisualDensity.compact,
            onPressed: canMoveUp ? () => onMove(item, -1) : null,
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
          ),
          IconButton(
            key: ValueKey('$itemKeyPrefix-${item.name}-down'),
            tooltip: '下移',
            visualDensity: VisualDensity.compact,
            onPressed: canMoveDown ? () => onMove(item, 1) : null,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
          CompactSwitch(
            key: ValueKey('$itemKeyPrefix-${item.name}-visible'),
            value: visible,
            onChanged: (value) => onVisibilityChanged(item, value),
          ),
        ],
      ),
    );
  }
}

List<T> _moveOrderedItem<T>(List<T> order, T item, int offset) {
  final currentIndex = order.indexOf(item);
  final targetIndex = currentIndex + offset;
  if (currentIndex < 0 || targetIndex < 0 || targetIndex >= order.length) {
    return order;
  }
  final result = List<T>.from(order);
  result.removeAt(currentIndex);
  result.insert(targetIndex, item);
  return result;
}

String _homePlaybackLabel(HomePlaybackSection section) {
  return switch (section) {
    HomePlaybackSection.dailyRecommendation => '每日推荐',
    HomePlaybackSection.casualListening => '随便听听',
    HomePlaybackSection.libraryShuffle => '曲库随机',
  };
}

String _homeShortcutLabel(HomeShortcutSection section) {
  return switch (section) {
    HomeShortcutSection.favorites => '我喜欢的',
    HomeShortcutSection.myPlaylists => '我的歌单',
    HomeShortcutSection.publicPlaylists => '公开歌单',
    HomeShortcutSection.publicRadio => '电台',
  };
}

String _homeDiscoveryLabel(HomeDiscoverySection section) {
  return switch (section) {
    HomeDiscoverySection.latestAlbums => '最新专辑',
    HomeDiscoverySection.randomAlbums => '随机专辑',
    HomeDiscoverySection.recentAlbums => '最近播放',
    HomeDiscoverySection.frequentAlbums => '最多播放',
  };
}

class _SettingsActionTile extends StatelessWidget {
  const _SettingsActionTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.action,
    this.titleKey,
    this.onTitleTap,
  });

  final Widget leading;
  final String title;
  final Widget subtitle;
  final Widget action;
  final Key? titleKey;
  final VoidCallback? onTitleTap;

  Widget _buildTitle(BuildContext context, {TextStyle? style}) {
    return GestureDetector(
      key: titleKey,
      behavior: HitTestBehavior.opaque,
      onTap: onTitleTap,
      child: Text(title, style: style),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 560) {
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: leading,
            title: _buildTitle(context),
            subtitle: subtitle,
            trailing: action,
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 16, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildTitle(
                      context,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    DefaultTextStyle.merge(
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      child: subtitle,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              action,
            ],
          ),
        );
      },
    );
  }
}

class _ThemeSettingTile extends StatelessWidget {
  const _ThemeSettingTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    final selector = SegmentedButton<ThemeMode>(
      showSelectedIcon: !compact,
      style: compact
          ? const ButtonStyle(visualDensity: VisualDensity.compact)
          : null,
      segments: const [
        ButtonSegment(
          value: ThemeMode.system,
          icon: Icon(Icons.brightness_auto_outlined),
          label: Text('系统'),
        ),
        ButtonSegment(
          value: ThemeMode.light,
          icon: Icon(Icons.light_mode_outlined),
          label: Text('浅色'),
        ),
        ButtonSegment(
          value: ThemeMode.dark,
          icon: Icon(Icons.dark_mode_outlined),
          label: Text('深色'),
        ),
      ],
      selected: {controller.themeMode},
      onSelectionChanged: (values) => controller.setThemeMode(values.single),
    );
    if (!compact) {
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: const Icon(Icons.contrast_outlined),
        title: const Text('主题'),
        subtitle: selector,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 16, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.contrast_outlined),
              const SizedBox(width: 16),
              Text('主题', style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
          const SizedBox(height: 7),
          selector,
        ],
      ),
    );
  }
}

class _RemotePlaylistDetailPage extends StatefulWidget {
  const _RemotePlaylistDetailPage({
    required this.controller,
    required this.playlist,
    this.pageTitle = '歌单',
    required this.onBack,
    required this.onBatchAdd,
    super.key,
  });

  final AppController controller;
  final LibrarySectionItem playlist;
  final String pageTitle;
  final VoidCallback onBack;
  final ValueChanged<LibrarySectionItem> onBatchAdd;

  @override
  State<_RemotePlaylistDetailPage> createState() =>
      _RemotePlaylistDetailPageState();
}

class _RemotePlaylistDetailPageState extends State<_RemotePlaylistDetailPage> {
  static const _pageSizeOptions = <int>[25, 50, 100, 200];

  late LibrarySectionItem _playlist;
  late Future<List<Track>> _tracksFuture;
  final Set<int> _selectedRemovalIndexes = <int>{};
  bool _batchRemoving = false;
  int _pageIndex = 0;
  int _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _playlist = widget.playlist;
    _tracksFuture = widget.controller.playlistTracks(_playlist);
  }

  @override
  void didUpdateWidget(covariant _RemotePlaylistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.id != widget.playlist.id) {
      _playlist = widget.playlist;
      _tracksFuture = widget.controller.playlistTracks(_playlist);
      _selectedRemovalIndexes.clear();
      _batchRemoving = false;
      _pageIndex = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManage = widget.controller.canManageRemotePlaylist(_playlist);
    return Stack(
      children: [
        Positioned.fill(
          child: _BackgroundWatermark(
            logoPath: widget.controller.settings.logoPath,
            backgroundPath: widget.controller.settings.backgroundPath,
          ),
        ),
        FutureBuilder<List<Track>>(
          future: _tracksFuture,
          builder: (context, snapshot) {
            final tracks = snapshot.data ?? const <Track>[];
            final pageCount = libraryPageCount(tracks.length, _pageSize);
            final pageIndex = pageCount == 0
                ? 0
                : _pageIndex.clamp(0, pageCount - 1);
            final pageTracks = libraryPageItems(tracks, pageIndex, _pageSize);
            final pageStartIndex = pageIndex * _pageSize;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
              children: [
                _DetailPageHeading(
                  title: widget.pageTitle,
                  onBack: _handleBack,
                ),
                const SizedBox(height: 14),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        KeyedSubtree(
                          key: const ValueKey('remote-playlist-header'),
                          child: _RemotePlaylistHeader(
                            playlist: _playlist,
                            tracks: tracks,
                            isLoading:
                                snapshot.connectionState ==
                                ConnectionState.waiting,
                            canManage: canManage,
                            onPlayAll: tracks.isEmpty
                                ? null
                                : () => widget.controller.playTrackList(
                                    tracks,
                                    0,
                                  ),
                            onAddTracks: () => widget.onBatchAdd(_playlist),
                            batchRemoving: _batchRemoving,
                            batchRemoveCount: _selectedRemovalIndexes.length,
                            onBatchRemove: _toggleBatchRemoval,
                            onEdit: _editPlaylist,
                            onDelete: _deletePlaylist,
                          ),
                        ),
                        const Divider(height: 24),
                        if (snapshot.hasError)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: Text(_formatError(snapshot.error!)),
                            ),
                          )
                        else if (snapshot.connectionState ==
                            ConnectionState.waiting)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (tracks.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: Text('暂无歌曲')),
                          )
                        else
                          _TrackList(
                            controller: widget.controller,
                            tracks: pageTracks,
                            playbackTracks: tracks,
                            indexOffset: pageStartIndex,
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            allowTrackActions: canManage,
                            selectedIndexes: _batchRemoving
                                ? _selectedRemovalIndexes
                                : null,
                            onSelectionChanged: _batchRemoving
                                ? _setTrackSelected
                                : null,
                            onRemoveFromRemotePlaylist: canManage
                                ? (index, track) => _removeTrack(index)
                                : null,
                          ),
                        if (tracks.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _PlaylistTrackPagination(
                            pageIndex: pageIndex,
                            pageCount: pageCount,
                            pageSize: _pageSize,
                            pageSizeOptions: _pageSizeOptions,
                            onPageChanged: (value) {
                              setState(() => _pageIndex = value);
                            },
                            onPageSizeChanged: (value) {
                              setState(() {
                                _pageSize = value;
                                _pageIndex = 0;
                              });
                            },
                            onCustomPageSize: _setCustomPageSize,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _editPlaylist() async {
    if (!widget.controller.canManageRemotePlaylist(_playlist)) {
      _showSourceMessage(context, '公开歌单只能播放。');
      return;
    }
    final result = await showDialog<_RemotePlaylistEditResult>(
      context: context,
      builder: (context) => _RemotePlaylistDialog(playlist: _playlist),
    );
    if (result == null) {
      return;
    }
    await widget.controller.updateRemotePlaylist(
      _playlist,
      name: result.name,
      comment: result.comment,
      isPublic: result.isPublic,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _playlist = LibrarySectionItem(
        id: _playlist.id,
        title: result.name,
        subtitle: _playlist.subtitle,
        coverUrl: _playlist.coverUrl,
        description: result.comment,
        isPublic: result.isPublic,
        owner: _playlist.owner,
        type: LibrarySectionType.playlists,
      );
    });
    _showSourceMessage(context, widget.controller.statusMessage ?? '歌单已保存。');
  }

  Future<void> _deletePlaylist() async {
    if (!widget.controller.canManageRemotePlaylist(_playlist)) {
      _showSourceMessage(context, '公开歌单只能播放。');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定删除“${_playlist.title}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.controller.deleteRemotePlaylist(_playlist);
    if (!mounted) {
      return;
    }
    _showSourceMessage(context, widget.controller.statusMessage ?? '歌单已删除。');
    widget.onBack();
  }

  Future<void> _removeTrack(int index) async {
    if (!widget.controller.canManageRemotePlaylist(_playlist)) {
      _showSourceMessage(context, '公开歌单只能播放。');
      return;
    }
    await widget.controller.removeRemotePlaylistTrack(_playlist, index);
    if (!mounted) {
      return;
    }
    _showSourceMessage(context, widget.controller.statusMessage ?? '已从歌单移除。');
    _refreshTracks();
  }

  void _setTrackSelected(int index, bool selected) {
    setState(() {
      if (selected) {
        _selectedRemovalIndexes.add(index);
      } else {
        _selectedRemovalIndexes.remove(index);
      }
    });
  }

  Future<void> _toggleBatchRemoval() async {
    if (!widget.controller.canManageRemotePlaylist(_playlist)) {
      return;
    }
    if (!_batchRemoving) {
      setState(() {
        _batchRemoving = true;
        _selectedRemovalIndexes.clear();
      });
      return;
    }
    if (_selectedRemovalIndexes.isEmpty) {
      _showSourceMessage(context, '请先选择要移除的歌曲。');
      return;
    }
    final selectedCount = _selectedRemovalIndexes.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('remote-playlist-batch-remove-confirmation'),
        title: const Text('批量移除歌曲'),
        content: Text('确定将选中的 $selectedCount 首歌曲移出“${_playlist.title}”吗？'),
        actions: [
          TextButton(
            key: const ValueKey('remote-playlist-batch-remove-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            key: const ValueKey('remote-playlist-batch-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.controller.removeRemotePlaylistTracks(
      _playlist,
      _selectedRemovalIndexes,
    );
    if (!mounted) {
      return;
    }
    _showSourceMessage(context, '已从歌单移除 $selectedCount 首歌曲。');
    setState(() {
      _batchRemoving = false;
      _selectedRemovalIndexes.clear();
      _tracksFuture = widget.controller.playlistTracks(_playlist);
    });
  }

  void _handleBack() {
    _selectedRemovalIndexes.clear();
    _batchRemoving = false;
    widget.onBack();
  }

  void _refreshTracks() {
    if (!mounted) {
      return;
    }
    setState(() {
      _tracksFuture = widget.controller.playlistTracks(
        _playlist,
        forceRefresh: true,
      );
    });
  }

  Future<void> _setCustomPageSize() async {
    final controller = TextEditingController(text: '$_pageSize');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义每页数量'),
        content: TextField(
          key: const ValueKey('playlist-custom-page-size-input'),
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(hintText: '输入每页歌曲数量'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    final pageSize = int.tryParse(value ?? '');
    if (!mounted || pageSize == null || pageSize <= 0) {
      return;
    }
    setState(() {
      _pageSize = pageSize;
      _pageIndex = 0;
    });
  }
}

class _PlaylistTrackPagination extends StatelessWidget {
  const _PlaylistTrackPagination({
    required this.pageIndex,
    required this.pageCount,
    required this.pageSize,
    required this.pageSizeOptions,
    required this.onPageChanged,
    required this.onPageSizeChanged,
    required this.onCustomPageSize,
  });

  final int pageIndex;
  final int pageCount;
  final int pageSize;
  final List<int> pageSizeOptions;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onPageSizeChanged;
  final VoidCallback onCustomPageSize;

  @override
  Widget build(BuildContext context) {
    final firstPage = pageCount <= 3
        ? 0
        : pageIndex <= 1
        ? 0
        : pageIndex >= pageCount - 2
        ? pageCount - 3
        : pageIndex - 1;
    final visiblePageCount = math.min(3, pageCount);

    return Wrap(
      key: const ValueKey('playlist-track-pagination'),
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('每页'),
            const SizedBox(width: 6),
            PopupMenuButton<int>(
              tooltip: '设置每页数量',
              onSelected: (value) {
                if (value == 0) {
                  onCustomPageSize();
                } else {
                  onPageSizeChanged(value);
                }
              },
              itemBuilder: (context) => [
                for (final value in pageSizeOptions)
                  PopupMenuItem(value: value, child: Text('$value 首')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 0, child: Text('自定义…')),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$pageSize 首'),
                    const Icon(Icons.arrow_drop_down, size: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '上一页',
              onPressed: pageIndex <= 0
                  ? null
                  : () => onPageChanged(pageIndex - 1),
              icon: const Icon(Icons.chevron_left),
            ),
            for (var offset = 0; offset < visiblePageCount; offset += 1)
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(36, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: firstPage + offset == pageIndex
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  textStyle: TextStyle(
                    fontWeight: firstPage + offset == pageIndex
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
                onPressed: () => onPageChanged(firstPage + offset),
                child: Text('${firstPage + offset + 1}'),
              ),
            IconButton(
              tooltip: '下一页',
              onPressed: pageIndex >= pageCount - 1
                  ? null
                  : () => onPageChanged(pageIndex + 1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
    );
  }
}

class _RemotePlaylistHeader extends StatefulWidget {
  const _RemotePlaylistHeader({
    required this.playlist,
    required this.tracks,
    required this.isLoading,
    required this.canManage,
    required this.onPlayAll,
    required this.onAddTracks,
    required this.batchRemoving,
    required this.batchRemoveCount,
    required this.onBatchRemove,
    required this.onEdit,
    required this.onDelete,
  });

  final LibrarySectionItem playlist;
  final List<Track> tracks;
  final bool isLoading;
  final bool canManage;
  final Future<void> Function()? onPlayAll;
  final VoidCallback onAddTracks;
  final bool batchRemoving;
  final int batchRemoveCount;
  final VoidCallback onBatchRemove;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_RemotePlaylistHeader> createState() => _RemotePlaylistHeaderState();
}

class _RemotePlaylistHeaderState extends State<_RemotePlaylistHeader> {
  bool _descriptionExpanded = false;

  @override
  void didUpdateWidget(covariant _RemotePlaylistHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.id != widget.playlist.id ||
        oldWidget.playlist.description != widget.playlist.description) {
      _descriptionExpanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    final artworkSize = compact ? 84.0 : 88.0;
    final titleStyle = Theme.of(context).textTheme.titleLarge;
    final description = widget.playlist.description.trim();
    final descriptionRunes = description.runes.toList(growable: false);
    final canExpandDescription = descriptionRunes.length > 50;
    final visibleDescription = description.isEmpty
        ? '暂无简介'
        : canExpandDescription && !_descriptionExpanded
        ? '${String.fromCharCodes(descriptionRunes.take(50))}...'
        : description;
    Widget actionButton({
      Key? key,
      required String tooltip,
      required IconData icon,
      required VoidCallback? onPressed,
    }) {
      final size = compact ? 28.0 : 32.0;
      final style = IconButton.styleFrom(
        fixedSize: Size.square(size),
        minimumSize: Size.square(size),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
      return IconButton(
        key: key,
        tooltip: tooltip,
        style: style,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        padding: EdgeInsets.zero,
        iconSize: compact ? 17 : 19,
        onPressed: onPressed,
        icon: Icon(icon),
      );
    }

    final actionButtons = <Widget>[
      if (widget.canManage) ...[
        actionButton(
          tooltip: '添加歌曲',
          icon: Icons.playlist_add,
          onPressed: widget.onAddTracks,
        ),
        if (widget.batchRemoving)
          Tooltip(
            message: '批量移除歌曲',
            child: TextButton.icon(
              key: const ValueKey('remote-playlist-batch-remove'),
              style: TextButton.styleFrom(
                minimumSize: Size(compact ? 42 : 48, compact ? 28 : 32),
                padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: widget.onBatchRemove,
              icon: Icon(
                Icons.playlist_remove_rounded,
                size: compact ? 17 : 19,
              ),
              label: Text('(${widget.batchRemoveCount})'),
            ),
          )
        else
          actionButton(
            key: const ValueKey('remote-playlist-batch-remove'),
            tooltip: '批量移除歌曲',
            icon: Icons.playlist_remove_rounded,
            onPressed: widget.onBatchRemove,
          ),
        actionButton(
          tooltip: '编辑歌单',
          icon: Icons.edit_outlined,
          onPressed: widget.onEdit,
        ),
        actionButton(
          tooltip: '删除歌单',
          icon: Icons.delete_outline,
          onPressed: widget.onDelete,
        ),
      ],
    ];
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < actionButtons.length; i++) ...[
          actionButtons[i],
          if (i != actionButtons.length - 1) SizedBox(width: compact ? 3 : 8),
        ],
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            KeyedSubtree(
              key: const ValueKey('remote-playlist-artwork'),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _RemotePlaylistCover(
                    playlist: widget.playlist,
                    size: artworkSize,
                  ),
                  _AsyncPlayButton(
                    key: const ValueKey('artwork-play-all'),
                    tooltip: '播放全部',
                    onPressed: widget.onPlayAll,
                    artworkOverlay: true,
                    size: compact ? 24 : 30,
                    iconSize: compact ? 17 : 21,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: artworkSize,
              child: Text(
                widget.isLoading ? '正在加载' : '歌单 · ${widget.tracks.length} 首',
                key: const ValueKey('remote-playlist-track-count'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        SizedBox(width: compact ? 12 : 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.playlist.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle?.copyWith(
                  fontSize: (titleStyle.fontSize ?? 22) + 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              InkWell(
                key: const ValueKey('remote-playlist-description'),
                borderRadius: BorderRadius.circular(4),
                onTap: canExpandDescription
                    ? () => setState(
                        () => _descriptionExpanded = !_descriptionExpanded,
                      )
                    : null,
                child: Text(
                  visibleDescription,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (widget.canManage) ...[const SizedBox(height: 4), actions],
            ],
          ),
        ),
      ],
    );
  }
}

class _RemotePlaylistEditResult {
  const _RemotePlaylistEditResult({
    required this.name,
    required this.comment,
    required this.isPublic,
  });

  final String name;
  final String comment;
  final bool isPublic;
}

class _RemotePlaylistDialog extends StatefulWidget {
  const _RemotePlaylistDialog({this.playlist, this.initialName = ''});

  final LibrarySectionItem? playlist;
  final String initialName;

  @override
  State<_RemotePlaylistDialog> createState() => _RemotePlaylistDialogState();
}

class _RemotePlaylistDialogState extends State<_RemotePlaylistDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _commentController;
  late bool _isPublic;

  @override
  void initState() {
    super.initState();
    final playlist = widget.playlist;
    _nameController = TextEditingController(
      text: playlist?.title ?? widget.initialName,
    );
    _commentController = TextEditingController(
      text: playlist?.description ?? '',
    );
    _isPublic = playlist?.isPublic ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: _responsiveDialogInsetPadding(context),
      title: Text(widget.playlist == null ? '新建歌单' : '编辑歌单'),
      content: ConstrainedBox(
        constraints: _responsiveDialogConstraints(context, maxWidth: 520),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '歌单名称'),
                  validator: _required,
                ),
                TextField(
                  controller: _commentController,
                  decoration: const InputDecoration(labelText: '简介'),
                  minLines: 2,
                  maxLines: 4,
                ),
                CompactSwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _isPublic,
                  onChanged: (value) => setState(() => _isPublic = value),
                  title: const Text('公开歌单'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.of(context).pop(
      _RemotePlaylistEditResult(
        name: _nameController.text.trim(),
        comment: _commentController.text.trim(),
        isPublic: _isPublic,
      ),
    );
  }
}

class _RemotePlaylistCover extends StatelessWidget {
  const _RemotePlaylistCover({required this.playlist, this.size = 72});

  final LibrarySectionItem playlist;
  final double size;

  @override
  Widget build(BuildContext context) {
    final coverUrl = playlist.coverUrl;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.primaryContainer,
      ),
      child: Icon(
        Icons.queue_music_outlined,
        color: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
    );
    if (coverUrl == null || coverUrl.isEmpty) {
      return placeholder;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: _CachedArtworkImage(
        imageUrl: coverUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: placeholder,
      ),
    );
  }
}

class _CachedArtworkImage extends StatefulWidget {
  const _CachedArtworkImage({
    required this.imageUrl,
    required this.placeholder,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
  });

  final String imageUrl;
  final Widget placeholder;
  final double width;
  final double height;
  final BoxFit fit;

  @override
  State<_CachedArtworkImage> createState() => _CachedArtworkImageState();
}

class _CachedArtworkImageState extends State<_CachedArtworkImage> {
  File? _file;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CachedArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      setState(() {
        _file = null;
      });
      _load();
    }
  }

  void _load() {
    final requestId = ++_requestId;
    ArtworkCacheManager.instance
        .cacheArtwork(widget.imageUrl)
        .then((file) {
          if (!mounted || requestId != _requestId) {
            return;
          }
          setState(() {
            _file = file;
          });
        })
        .catchError((Object _) {
          if (!mounted || requestId != _requestId) {
            return;
          }
          setState(() {
            _file = null;
          });
        });
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file == null) {
      return widget.placeholder;
    }
    return Image.file(
      file,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      errorBuilder: (context, error, stackTrace) => widget.placeholder,
    );
  }
}

class _PlainTextDialog extends StatefulWidget {
  const _PlainTextDialog({required this.title, required this.hintText});

  final String title;
  final String hintText;

  @override
  State<_PlainTextDialog> createState() => _PlainTextDialogState();
}

class _PlainTextDialogState extends State<_PlainTextDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: _responsiveDialogInsetPadding(context),
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: _responsiveDialogConstraints(context, maxWidth: 560),
        child: TextField(
          controller: _controller,
          minLines: 8,
          maxLines: 12,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: widget.hintText,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('导入'),
        ),
      ],
    );
  }
}

class _LibraryHome extends StatelessWidget {
  const _LibraryHome({
    required this.controller,
    required this.searchController,
    required this.searchScope,
    required this.selectedHomeTab,
    required this.onSearch,
    required this.onSearchScopeChanged,
    required this.onSuggestionSelected,
    required this.onHomeTabChanged,
    required this.onOpenDiscoveryAlbum,
    required this.onPlayDiscoverySection,
    required this.onOpenPlaylist,
    required this.onPlayPlaylist,
    required this.onOpenTrackCollection,
    required this.onShowLibrarySection,
    required this.onCreatePlaylist,
    required this.onRefreshFavorites,
    required this.onRefreshPlaylists,
    required this.onRefreshRadioStations,
    required this.onOpenDailyRecommendation,
    required this.onRefreshDailyRecommendation,
    required this.onOpenCasualListening,
    required this.onRefreshCasualListening,
    required this.onStartLibraryShuffle,
    required this.onRefreshLibrary,
    required this.onOpenPlaylistCollection,
    required this.onOpenMetadataManager,
    required this.onOpenLogViewer,
  });

  final AppController controller;
  final TextEditingController searchController;
  final LibrarySearchScope searchScope;
  final _HomeTab selectedHomeTab;
  final VoidCallback onSearch;
  final ValueChanged<LibrarySearchScope> onSearchScopeChanged;
  final ValueChanged<_RemoteSearchSuggestion> onSuggestionSelected;
  final ValueChanged<_HomeTab> onHomeTabChanged;
  final Future<void> Function(
    HomeDiscoverySection section,
    LibrarySectionItem item,
  )
  onOpenDiscoveryAlbum;
  final Future<void> Function(
    HomeDiscoverySection section,
    List<LibrarySectionItem> albums,
  )
  onPlayDiscoverySection;
  final Future<void> Function(LibrarySectionItem item) onOpenPlaylist;
  final Future<void> Function(LibrarySectionItem item) onPlayPlaylist;
  final void Function(String title, List<Track> tracks) onOpenTrackCollection;
  final ValueChanged<LibrarySectionType> onShowLibrarySection;
  final VoidCallback onCreatePlaylist;
  final Future<void> Function() onRefreshFavorites;
  final Future<void> Function() onRefreshPlaylists;
  final Future<void> Function() onRefreshRadioStations;
  final VoidCallback onOpenDailyRecommendation;
  final Future<void> Function() onRefreshDailyRecommendation;
  final VoidCallback onOpenCasualListening;
  final Future<void> Function() onRefreshCasualListening;
  final Future<void> Function() onStartLibraryShuffle;
  final Future<void> Function() onRefreshLibrary;
  final ValueChanged<_PlaylistCollection> onOpenPlaylistCollection;
  final VoidCallback onOpenMetadataManager;
  final VoidCallback onOpenLogViewer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 640;
        return Column(
          children: [
            if (selectedHomeTab == _HomeTab.music) ...[
              Padding(
                key: const ValueKey('home-search-row'),
                padding: EdgeInsets.fromLTRB(
                  compact ? 12 : 16,
                  compact ? 6 : 18,
                  compact ? 12 : 16,
                  0,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 700),
                    child: KeyedSubtree(
                      key: const ValueKey('home-search-bar'),
                      child: _LibrarySearchBar(
                        controller: searchController,
                        scope: searchScope,
                        isBusy: controller.isBusy,
                        onScopeChanged: onSearchScopeChanged,
                        onSearch: onSearch,
                        onLoadSuggestions: (query, scope) => controller
                            .searchRemoteSuggestions(query, scope: scope),
                        onSuggestionSelected: onSuggestionSelected,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: compact ? 6 : 14),
            ],
            Expanded(
              child: switch (selectedHomeTab) {
                _HomeTab.music => _MusicHomeTab(
                  controller: controller,
                  onOpenDiscoveryAlbum: onOpenDiscoveryAlbum,
                  onPlayDiscoverySection: onPlayDiscoverySection,
                  onOpenPlaylist: onOpenPlaylist,
                  onPlayPlaylist: onPlayPlaylist,
                  onOpenTrackCollection: onOpenTrackCollection,
                  onShowLibrarySection: onShowLibrarySection,
                  onCreatePlaylist: onCreatePlaylist,
                  onRefreshFavorites: onRefreshFavorites,
                  onRefreshPlaylists: onRefreshPlaylists,
                  onRefreshRadioStations: onRefreshRadioStations,
                  onOpenDailyRecommendation: onOpenDailyRecommendation,
                  onRefreshDailyRecommendation: onRefreshDailyRecommendation,
                  onOpenCasualListening: onOpenCasualListening,
                  onRefreshCasualListening: onRefreshCasualListening,
                  onStartLibraryShuffle: onStartLibraryShuffle,
                  onOpenPlaylistCollection: onOpenPlaylistCollection,
                ),
                _HomeTab.settings => _SettingsPage(
                  controller: controller,
                  onBack: () => onHomeTabChanged(_HomeTab.music),
                  onRefreshLibrary: onRefreshLibrary,
                  onOpenMetadataManager: onOpenMetadataManager,
                  onOpenLogViewer: onOpenLogViewer,
                  showBack: false,
                ),
              },
            ),
          ],
        );
      },
    );
  }
}

class _HomeTabStrip extends StatelessWidget {
  const _HomeTabStrip({
    required this.selectedTab,
    required this.compact,
    required this.onChanged,
  });

  final _HomeTab selectedTab;
  final bool compact;
  final ValueChanged<_HomeTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = <(_HomeTab, IconData, String)>[
      (_HomeTab.music, Icons.music_note_rounded, '音乐'),
      (_HomeTab.settings, Icons.settings_rounded, '设置'),
    ];
    if (compact) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final item in items) ...[
            _HomeTabButton(
              tab: item.$1,
              icon: item.$2,
              label: item.$3,
              selected: selectedTab == item.$1,
              compact: true,
              onChanged: onChanged,
            ),
            if (item != items.last) const SizedBox(width: 24),
          ],
        ],
      );
    }
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            _HomeTabButton(
              tab: item.$1,
              icon: item.$2,
              label: item.$3,
              selected: selectedTab == item.$1,
              compact: false,
              onChanged: onChanged,
            ),
        ],
      ),
    );
  }
}

class _HomeTabButton extends StatelessWidget {
  const _HomeTabButton({
    required this.tab,
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onChanged,
  });

  final _HomeTab tab;
  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final ValueChanged<_HomeTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? colorScheme.primary
        : colorScheme.onSurfaceVariant;
    if (compact) {
      return Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => onChanged(tab),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: foreground, size: 25),
                const SizedBox(height: 2),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 32,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? colorScheme.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(
          backgroundColor: selected
              ? colorScheme.primaryContainer
              : Colors.transparent,
          foregroundColor: selected
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurfaceVariant,
          minimumSize: const Size(118, 44),
        ),
        onPressed: () => onChanged(tab),
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class _DiscoveryAlbumSection extends StatelessWidget {
  const _DiscoveryAlbumSection({
    required this.title,
    required this.emptyText,
    required this.items,
    required this.onTap,
    required this.onPlayAll,
  });

  final String title;
  final String emptyText;
  final List<LibrarySectionItem> items;
  final Future<void> Function(LibrarySectionItem item) onTap;
  final Future<void> Function() onPlayAll;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ValueKey('discovery-section-$title'),
      child: _LibraryPreviewSection(
        title: title,
        emptyText: emptyText,
        icon: Icons.album_outlined,
        items: items,
        style: _LibraryPreviewStyle.album,
        expanded: false,
        showToggle: false,
        showCount: false,
        titleAction: _AsyncPlayButton(
          key: ValueKey('play-discovery-$title'),
          tooltip: '播放$title',
          onPressed: items.isEmpty ? null : onPlayAll,
        ),
        onToggle: () {},
        onTap: (item) => unawaited(onTap(item)),
      ),
    );
  }
}

class _AlbumSectionPair extends StatelessWidget {
  const _AlbumSectionPair({required this.left, this.right});

  final Widget left;
  final Widget? right;

  @override
  Widget build(BuildContext context) {
    final right = this.right;
    if (right == null) {
      return left;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 820) {
          return Column(children: [left, right]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 28),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

class _MusicHomeTab extends StatelessWidget {
  const _MusicHomeTab({
    required this.controller,
    required this.onOpenDiscoveryAlbum,
    required this.onPlayDiscoverySection,
    required this.onOpenPlaylist,
    required this.onPlayPlaylist,
    required this.onOpenTrackCollection,
    required this.onShowLibrarySection,
    required this.onCreatePlaylist,
    required this.onRefreshFavorites,
    required this.onRefreshPlaylists,
    required this.onRefreshRadioStations,
    required this.onOpenDailyRecommendation,
    required this.onRefreshDailyRecommendation,
    required this.onOpenCasualListening,
    required this.onRefreshCasualListening,
    required this.onStartLibraryShuffle,
    required this.onOpenPlaylistCollection,
  });

  final AppController controller;
  final Future<void> Function(
    HomeDiscoverySection section,
    LibrarySectionItem item,
  )
  onOpenDiscoveryAlbum;
  final Future<void> Function(
    HomeDiscoverySection section,
    List<LibrarySectionItem> albums,
  )
  onPlayDiscoverySection;
  final Future<void> Function(LibrarySectionItem item) onOpenPlaylist;
  final Future<void> Function(LibrarySectionItem item) onPlayPlaylist;
  final void Function(String title, List<Track> tracks) onOpenTrackCollection;
  final ValueChanged<LibrarySectionType> onShowLibrarySection;
  final VoidCallback onCreatePlaylist;
  final Future<void> Function() onRefreshFavorites;
  final Future<void> Function() onRefreshPlaylists;
  final Future<void> Function() onRefreshRadioStations;
  final VoidCallback onOpenDailyRecommendation;
  final Future<void> Function() onRefreshDailyRecommendation;
  final VoidCallback onOpenCasualListening;
  final Future<void> Function() onRefreshCasualListening;
  final Future<void> Function() onStartLibraryShuffle;
  final ValueChanged<_PlaylistCollection> onOpenPlaylistCollection;

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    final settings = controller.settings;
    final discoverySections = [
      for (final section in settings.visibleHomeDiscoveryOrder)
        _discoverySection(section),
    ];
    final discoveryRows = <Widget>[];
    for (var index = 0; index < discoverySections.length; index += 2) {
      discoveryRows.add(
        _AlbumSectionPair(
          left: discoverySections[index],
          right: index + 1 < discoverySections.length
              ? discoverySections[index + 1]
              : null,
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 0, compact ? 12 : 16, 32),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (settings.visibleHomePlaybackOrder.isNotEmpty ||
                    settings.visibleHomeShortcutOrder.isNotEmpty) ...[
                  _MusicFunctionGrid(
                    controller: controller,
                    onOpenDailyRecommendation: onOpenDailyRecommendation,
                    onOpenCasualListening: onOpenCasualListening,
                    onStartLibraryShuffle: onStartLibraryShuffle,
                    onOpenFavorites: () => onOpenTrackCollection(
                      '我喜欢的',
                      controller.libraryOverview.favoriteTracks,
                    ),
                    onShowMyPlaylists: () =>
                        onOpenPlaylistCollection(_PlaylistCollection.mine),
                    onShowPublicPlaylists: () =>
                        onOpenPlaylistCollection(_PlaylistCollection.public),
                    onShowRadio: () =>
                        onShowLibrarySection(LibrarySectionType.radio),
                    onRefreshFavorites: onRefreshFavorites,
                    onRefreshPlaylists: onRefreshPlaylists,
                    onRefreshRadioStations: onRefreshRadioStations,
                    onRefreshDailyRecommendation: onRefreshDailyRecommendation,
                    onRefreshCasualListening: onRefreshCasualListening,
                  ),
                  SizedBox(height: compact ? 10 : 28),
                ],
                ...discoveryRows,
                if (settings.showMyPlaylistSection)
                  KeyedSubtree(
                    key: const ValueKey('home-my-playlists-section'),
                    child: _LibraryPreviewSection(
                      title: '我的歌单',
                      emptyText: '暂无我的歌单',
                      icon: Icons.queue_music_outlined,
                      items: controller.myPlaylists,
                      style: _LibraryPreviewStyle.playlist,
                      expanded: false,
                      showToggle: false,
                      action: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (controller.canCreateRemotePlaylist) ...[
                            IconButton(
                              tooltip: '新建歌单',
                              onPressed: onCreatePlaylist,
                              icon: const Icon(Icons.add),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Tooltip(
                            message: '更多歌单',
                            child: TextButton(
                              onPressed: () => onOpenPlaylistCollection(
                                _PlaylistCollection.mine,
                              ),
                              child: const Text('更多'),
                            ),
                          ),
                        ],
                      ),
                      onToggle: () {},
                      onTap: (item) => unawaited(onOpenPlaylist(item)),
                      onPlay: onPlayPlaylist,
                    ),
                  ),
                if (settings.showPublicPlaylistSection)
                  KeyedSubtree(
                    key: const ValueKey('home-public-playlists-section'),
                    child: _LibraryPreviewSection(
                      title: '公开歌单',
                      emptyText: '暂无公开歌单',
                      icon: Icons.public_rounded,
                      items: controller.publicPlaylists,
                      style: _LibraryPreviewStyle.playlist,
                      expanded: false,
                      showToggle: false,
                      action: TextButton(
                        onPressed: () => onOpenPlaylistCollection(
                          _PlaylistCollection.public,
                        ),
                        child: const Text('更多'),
                      ),
                      onToggle: () {},
                      onTap: (item) => unawaited(onOpenPlaylist(item)),
                      onPlay: onPlayPlaylist,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _discoverySection(HomeDiscoverySection section) {
    final overview = controller.libraryOverview;
    return switch (section) {
      HomeDiscoverySection.latestAlbums => _DiscoveryAlbumSection(
        title: '最新专辑',
        emptyText: '暂无最新专辑',
        items: overview.latestAlbums.isEmpty
            ? overview.albums
            : overview.latestAlbums,
        onTap: (item) => onOpenDiscoveryAlbum(section, item),
        onPlayAll: () => onPlayDiscoverySection(
          section,
          overview.latestAlbums.isEmpty
              ? overview.albums
              : overview.latestAlbums,
        ),
      ),
      HomeDiscoverySection.randomAlbums => _DiscoveryAlbumSection(
        title: '随机专辑',
        emptyText: '暂无随机专辑',
        items: overview.randomAlbums,
        onTap: (item) => onOpenDiscoveryAlbum(section, item),
        onPlayAll: () => onPlayDiscoverySection(section, overview.randomAlbums),
      ),
      HomeDiscoverySection.recentAlbums => _DiscoveryAlbumSection(
        title: '最近播放',
        emptyText: '暂无最近播放信息',
        items: overview.recentAlbums,
        onTap: (item) => onOpenDiscoveryAlbum(section, item),
        onPlayAll: () => onPlayDiscoverySection(section, overview.recentAlbums),
      ),
      HomeDiscoverySection.frequentAlbums => _DiscoveryAlbumSection(
        title: '最多播放',
        emptyText: '暂无最多播放信息',
        items: overview.frequentAlbums,
        onTap: (item) => onOpenDiscoveryAlbum(section, item),
        onPlayAll: () =>
            onPlayDiscoverySection(section, overview.frequentAlbums),
      ),
    };
  }
}

// Kept for compatibility with older widget snapshots; no longer shown.
// ignore: unused_element
class _SourceSummaryCard extends StatelessWidget {
  const _SourceSummaryCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final server = controller.selectedServer;
    final songCount = controller.libraryOverview.songCount;
    final compact = _isPhoneWidth(context);
    final title = '音源：${server?.name ?? '未设置'}';
    return _GlassSurface(
      padding: EdgeInsets.all(compact ? 8 : 18),
      darkAlpha: 0.18,
      child: Row(
        children: [
          Container(
            width: compact ? 48 : 76,
            height: compact ? 48 : 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Icon(
              server?.isLocalFolder == true
                  ? Icons.folder_open_outlined
                  : Icons.album_outlined,
              size: compact ? 26 : 42,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
          SizedBox(width: compact ? 10 : 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      (compact
                              ? Theme.of(context).textTheme.titleLarge
                              : Theme.of(context).textTheme.headlineSmall)
                          ?.copyWith(fontWeight: FontWeight.w800),
                ),
                SizedBox(height: compact ? 3 : 6),
                Text(
                  [
                    if (server == null) '请在设置中添加音源',
                    if (songCount != null) '歌曲数：$songCount',
                    if (controller.isRefreshingLibrary) '扫描中',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: '刷新音源',
            constraints: compact
                ? const BoxConstraints.tightFor(width: 42, height: 42)
                : null,
            padding: compact ? EdgeInsets.zero : null,
            iconSize: compact ? 22 : null,
            onPressed: controller.isBusy
                ? null
                : () => unawaited(controller.loadLibraryOverview()),
            icon: controller.isRefreshingLibrary
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}

class _MusicFunctionGrid extends StatelessWidget {
  const _MusicFunctionGrid({
    required this.controller,
    required this.onOpenDailyRecommendation,
    required this.onOpenCasualListening,
    required this.onStartLibraryShuffle,
    required this.onOpenFavorites,
    required this.onShowMyPlaylists,
    required this.onShowPublicPlaylists,
    required this.onShowRadio,
    required this.onRefreshFavorites,
    required this.onRefreshPlaylists,
    required this.onRefreshRadioStations,
    required this.onRefreshDailyRecommendation,
    required this.onRefreshCasualListening,
  });

  final AppController controller;
  final VoidCallback onOpenDailyRecommendation;
  final VoidCallback onOpenCasualListening;
  final Future<void> Function() onStartLibraryShuffle;
  final VoidCallback onOpenFavorites;
  final VoidCallback onShowMyPlaylists;
  final VoidCallback onShowPublicPlaylists;
  final VoidCallback onShowRadio;
  final Future<void> Function() onRefreshFavorites;
  final Future<void> Function() onRefreshPlaylists;
  final Future<void> Function() onRefreshRadioStations;
  final Future<void> Function() onRefreshDailyRecommendation;
  final Future<void> Function() onRefreshCasualListening;

  @override
  Widget build(BuildContext context) {
    final shortcutEntries = <HomeShortcutSection, _MusicFunctionEntry>{
      HomeShortcutSection.favorites: _MusicFunctionEntry(
        icon: Icons.favorite,
        label: '我喜欢的',
        subtitle: '${controller.libraryOverview.favoriteTracks.length} 首',
        onTap: onOpenFavorites,
        onPlay: controller.libraryOverview.favoriteTracks.isEmpty
            ? null
            : () => controller.playTrackList(
                controller.libraryOverview.favoriteTracks,
                0,
              ),
        onRefresh: onRefreshFavorites,
      ),
      HomeShortcutSection.myPlaylists: _MusicFunctionEntry(
        icon: Icons.playlist_play_outlined,
        label: '我的歌单',
        subtitle: '${controller.myPlaylists.length} 个',
        onTap: onShowMyPlaylists,
        onRefresh: onRefreshPlaylists,
      ),
      HomeShortcutSection.publicPlaylists: _MusicFunctionEntry(
        icon: Icons.public_rounded,
        label: '公开歌单',
        subtitle: '${controller.publicPlaylists.length} 个',
        onTap: onShowPublicPlaylists,
        onRefresh: onRefreshPlaylists,
      ),
      HomeShortcutSection.publicRadio: _MusicFunctionEntry(
        icon: Icons.radio_outlined,
        label: '电台',
        subtitle: '${controller.libraryOverview.radioStations.length} 个',
        onTap: onShowRadio,
        onRefresh: onRefreshRadioStations,
      ),
    };
    final shortcutItems = [
      for (final section in controller.settings.visibleHomeShortcutOrder)
        shortcutEntries[section]!,
    ];
    final playbackEntries = <HomePlaybackSection, _MusicFunctionEntry>{
      HomePlaybackSection.dailyRecommendation: _MusicFunctionEntry(
        icon: Icons.auto_awesome_rounded,
        label: '每日推荐',
        subtitle: controller.isLoadingRecommendations
            ? '生成中'
            : '${controller.recommendedTracks.length} 首',
        onTap: onOpenDailyRecommendation,
        onPlay: controller.recommendedTracks.isEmpty
            ? null
            : () => controller.playTrackList(controller.recommendedTracks, 0),
        onRefresh: onRefreshDailyRecommendation,
        isRefreshing: controller.isLoadingRecommendations,
      ),
      HomePlaybackSection.casualListening: _MusicFunctionEntry(
        icon: Icons.explore_outlined,
        label: '随便听听',
        subtitle: controller.isLoadingCasualListening
            ? '生成中'
            : '${controller.casualListeningTracks.length} 首',
        onTap: onOpenCasualListening,
        onPlay: controller.casualListeningTracks.isEmpty
            ? null
            : () =>
                  controller.playTrackList(controller.casualListeningTracks, 0),
        onRefresh: onRefreshCasualListening,
        isRefreshing: controller.isLoadingCasualListening,
      ),
      HomePlaybackSection.libraryShuffle: _MusicFunctionEntry(
        icon: Icons.casino_outlined,
        label: '曲库随机',
        subtitle: controller.isLoadingLibraryShuffle ? '准备中' : '连续随机播放',
        onTap: () => unawaited(onStartLibraryShuffle()),
        onPlay: controller.isLoadingLibraryShuffle
            ? null
            : onStartLibraryShuffle,
      ),
    };
    final playbackItems = [
      for (final section in controller.settings.visibleHomePlaybackOrder)
        playbackEntries[section]!,
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = _isPhoneWidth(context);
        final spacing = compact ? 8.0 : 12.0;
        Widget buildGroup(List<_MusicFunctionEntry> items, int maxColumns) {
          final availableColumns = compact
              ? 2
              : constraints.maxWidth >= 620
              ? maxColumns
              : 2;
          final columns = math.min(availableColumns, items.length);
          final itemWidth =
              (constraints.maxWidth - spacing * (columns - 1)) / columns;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final item in items)
                SizedBox(
                  key: ValueKey('music-function-${item.label}'),
                  width: itemWidth,
                  child: _MusicFunctionTile(entry: item),
                ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (playbackItems.isNotEmpty) buildGroup(playbackItems, 3),
            if (playbackItems.isNotEmpty && shortcutItems.isNotEmpty)
              SizedBox(height: spacing),
            if (shortcutItems.isNotEmpty) buildGroup(shortcutItems, 4),
          ],
        );
      },
    );
  }
}

class _MusicFunctionEntry {
  const _MusicFunctionEntry({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.onPlay,
    this.onRefresh,
    this.isRefreshing = false,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final Future<void> Function()? onPlay;
  final Future<void> Function()? onRefresh;
  final bool isRefreshing;
}

class _MusicFunctionTile extends StatefulWidget {
  const _MusicFunctionTile({required this.entry});

  final _MusicFunctionEntry entry;

  @override
  State<_MusicFunctionTile> createState() => _MusicFunctionTileState();
}

class _MusicFunctionTileState extends State<_MusicFunctionTile> {
  bool _isRefreshing = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final isRefreshing = entry.isRefreshing || _isRefreshing;
    final compact = _isPhoneWidth(context);
    return _GlassSurface(
      darkAlpha: 0.14,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: entry.onTap,
          child: Padding(
            padding: EdgeInsets.all(compact ? 6 : 14),
            child: Row(
              children: [
                Icon(
                  entry.icon,
                  color: Theme.of(context).colorScheme.primary,
                  size: compact ? 22 : 30,
                ),
                SizedBox(width: compact ? 7 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            (compact
                                    ? Theme.of(context).textTheme.bodyMedium
                                    : Theme.of(context).textTheme.titleSmall)
                                ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      SizedBox(height: compact ? 0 : 3),
                      Text(
                        entry.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (entry.onPlay != null)
                  IconButton(
                    tooltip: '播放${entry.label}',
                    onPressed: () => unawaited(entry.onPlay!()),
                    icon: const Icon(Icons.play_arrow_rounded),
                    iconSize: compact ? 18 : 22,
                    constraints: BoxConstraints.tightFor(
                      width: compact ? 30 : 36,
                      height: compact ? 30 : 36,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                if (entry.onRefresh != null)
                  IconButton(
                    tooltip: '刷新${entry.label}',
                    onPressed: isRefreshing
                        ? null
                        : () => unawaited(_refresh()),
                    icon: isRefreshing
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    iconSize: compact ? 18 : 22,
                    constraints: BoxConstraints.tightFor(
                      width: compact ? 30 : 36,
                      height: compact ? 30 : 36,
                    ),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    final onRefresh = widget.entry.onRefresh;
    if (onRefresh == null || _isRefreshing || widget.entry.isRefreshing) {
      return;
    }
    setState(() => _isRefreshing = true);
    try {
      await onRefresh();
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
  }
}

class _SearchResultsPage extends StatelessWidget {
  const _SearchResultsPage({
    required this.controller,
    required this.searchController,
    required this.searchScope,
    required this.selectedSearchTab,
    required this.onSearch,
    required this.onSearchScopeChanged,
    required this.onSuggestionSelected,
    required this.onSearchTabChanged,
    required this.onSearchLibraryItem,
    required this.onPreviousSongPage,
    required this.onNextSongPage,
    required this.onBack,
  });

  final AppController controller;
  final TextEditingController searchController;
  final LibrarySearchScope searchScope;
  final _SearchResultTab selectedSearchTab;
  final VoidCallback onSearch;
  final ValueChanged<LibrarySearchScope> onSearchScopeChanged;
  final ValueChanged<_RemoteSearchSuggestion> onSuggestionSelected;
  final ValueChanged<_SearchResultTab> onSearchTabChanged;
  final Future<void> Function(LibrarySectionItem item) onSearchLibraryItem;
  final Future<void> Function()? onPreviousSongPage;
  final Future<void> Function()? onNextSongPage;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      children: [
        _DetailPageHeading(title: '搜索结果', onBack: onBack),
        const SizedBox(height: 14),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 700),
                    child: KeyedSubtree(
                      key: const ValueKey('search-results-search-bar'),
                      child: _LibrarySearchBar(
                        controller: searchController,
                        scope: searchScope,
                        isBusy: controller.isBusy,
                        onScopeChanged: onSearchScopeChanged,
                        onSearch: onSearch,
                        onLoadSuggestions: (query, scope) => controller
                            .searchRemoteSuggestions(query, scope: scope),
                        onSuggestionSelected: onSuggestionSelected,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (controller.isBusy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 14),
                ],
                _SearchResultsSection(
                  controller: controller,
                  selectedTab: selectedSearchTab,
                  onTabChanged: onSearchTabChanged,
                  onSearchLibraryItem: onSearchLibraryItem,
                  onPreviousSongPage: onPreviousSongPage,
                  onNextSongPage: onNextSongPage,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LibraryItemSongsPage extends StatelessWidget {
  const _LibraryItemSongsPage({
    required this.controller,
    required this.item,
    required this.pageTitle,
    required this.hideTrackArtwork,
    required this.onBack,
    super.key,
  });

  final AppController controller;
  final LibrarySectionItem item;
  final String pageTitle;
  final bool hideTrackArtwork;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tracks = controller.visibleTracks;
    final compact = _isPhoneWidth(context);
    final artworkSize = compact ? 84.0 : 88.0;
    final titleStyle = Theme.of(context).textTheme.titleLarge;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      children: [
        _DetailPageHeading(title: pageTitle, onBack: onBack),
        const SizedBox(height: 14),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  key: const ValueKey('library-item-header'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PlayableArtwork(
                      onPlay: tracks.isEmpty
                          ? null
                          : () => controller.playTrackList(tracks, 0),
                      artwork: _LibraryItemArtwork(
                        item: item,
                        fallbackIcon: _librarySectionIcon(item.type),
                        size: artworkSize,
                        circle: item.type == LibrarySectionType.artists,
                      ),
                    ),
                    SizedBox(width: compact ? 12 : 16),
                    Expanded(
                      child: SizedBox(
                        height: artworkSize,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle?.copyWith(
                                fontSize: (titleStyle.fontSize ?? 22) + 1,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_librarySectionTitle(item.type)} · ${tracks.length} 首',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.subtitle.isEmpty ? '未知歌手' : item.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (controller.isBusy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                const Divider(height: 24),
                tracks.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('暂无歌曲')),
                      )
                    : _TrackList(
                        controller: controller,
                        tracks: tracks,
                        shrinkWrap: true,
                        showArtwork: !hideTrackArtwork,
                        padding: EdgeInsets.zero,
                      ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TrackCollectionPage extends StatelessWidget {
  const _TrackCollectionPage({
    required this.title,
    required this.tracks,
    required this.controller,
    required this.onBack,
    this.onRefresh,
    this.onPlayAll,
    this.onSave,
    this.isLoading = false,
  });

  final String title;
  final List<Track> tracks;
  final AppController controller;
  final VoidCallback onBack;
  final Future<void> Function()? onRefresh;
  final Future<void> Function()? onPlayAll;
  final Future<void> Function()? onSave;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      children: [
        _DetailPageHeading(
          title: title,
          onBack: onBack,
          actions: [
            if (onPlayAll != null)
              IconButton(
                tooltip: '播放全部',
                onPressed: isLoading ? null : () => unawaited(onPlayAll!()),
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            if (onRefresh != null)
              IconButton(
                tooltip: '刷新$title',
                onPressed: isLoading ? null : () => unawaited(onRefresh!()),
                icon: isLoading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            if (onSave != null)
              IconButton(
                tooltip: '保存到歌单',
                onPressed: isLoading ? null : () => unawaited(onSave!()),
                icon: const Icon(Icons.playlist_add_rounded),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Divider(height: 24),
                tracks.isEmpty && isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : tracks.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('暂无歌曲')),
                      )
                    : _TrackList(
                        controller: controller,
                        tracks: tracks,
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                      ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

typedef _RemoteSearchSuggestion = ({
  String id,
  String title,
  String subtitle,
  LibrarySearchScope scope,
  LibrarySectionItem? libraryItem,
});

const int _remoteSearchSuggestionLimit = 5;
const Duration _remoteSearchDebounce = Duration(milliseconds: 300);

bool _shouldLoadRemoteSearchSuggestions(String value) {
  final query = value.trim();
  if (query.isEmpty) {
    return false;
  }
  if (RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]').hasMatch(query)) {
    return true;
  }
  return RegExp(r'[A-Za-z0-9]').allMatches(query).length >= 3;
}

List<_RemoteSearchSuggestion> _remoteSearchSuggestions(
  LibrarySearchResults results,
) {
  final suggestions = <_RemoteSearchSuggestion>[
    for (final track in results.songs)
      (
        id: track.id,
        title: track.title,
        subtitle: [
          '歌曲',
          if (track.artist.trim().isNotEmpty) track.artist.trim(),
        ].join(' · '),
        scope: LibrarySearchScope.songs,
        libraryItem: null,
      ),
    for (final artist in results.artists)
      (
        id: artist.id,
        title: artist.title,
        subtitle: '歌手',
        scope: LibrarySearchScope.artists,
        libraryItem: artist,
      ),
    for (final album in results.albums)
      (
        id: album.id,
        title: album.title,
        subtitle: album.subtitle.trim().isEmpty
            ? '专辑'
            : '专辑 · ${album.subtitle.trim()}',
        scope: LibrarySearchScope.albums,
        libraryItem: album,
      ),
  ];
  return suggestions.take(_remoteSearchSuggestionLimit).toList();
}

IconData _remoteSearchSuggestionIcon(LibrarySearchScope scope) {
  return switch (scope) {
    LibrarySearchScope.songs => Icons.music_note_rounded,
    LibrarySearchScope.artists => Icons.person_outline_rounded,
    LibrarySearchScope.albums => Icons.album_outlined,
    LibrarySearchScope.all => Icons.search_rounded,
  };
}

class _LibrarySearchBar extends StatefulWidget {
  const _LibrarySearchBar({
    required this.controller,
    required this.scope,
    required this.isBusy,
    required this.onScopeChanged,
    required this.onSearch,
    required this.onLoadSuggestions,
    required this.onSuggestionSelected,
  });

  final TextEditingController controller;
  final LibrarySearchScope scope;
  final bool isBusy;
  final ValueChanged<LibrarySearchScope> onScopeChanged;
  final VoidCallback onSearch;
  final Future<LibrarySearchResults> Function(
    String query,
    LibrarySearchScope scope,
  )
  onLoadSuggestions;
  final ValueChanged<_RemoteSearchSuggestion> onSuggestionSelected;

  @override
  State<_LibrarySearchBar> createState() => _LibrarySearchBarState();
}

class _LibrarySearchBarState extends State<_LibrarySearchBar> {
  final FocusNode _focusNode = FocusNode();
  final MenuController _suggestionMenuController = MenuController();
  final GlobalKey _searchLeadingKey = GlobalKey();
  Timer? _suggestionDebounceTimer;
  Timer? _focusLossTimer;
  int _suggestionRequestId = 0;
  List<_RemoteSearchSuggestion> _suggestions = const [];
  String? _suggestionMessage;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(_LibrarySearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      _cancelSuggestionRequest();
    }
  }

  @override
  void dispose() {
    _cancelSuggestionRequest();
    _focusLossTimer?.cancel();
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    _focusLossTimer?.cancel();
    if (_focusNode.hasFocus) {
      setState(() {});
      return;
    }
    _focusLossTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || _focusNode.hasFocus) {
        return;
      }
      _cancelSuggestionRequest();
      setState(() {});
    });
  }

  void _cancelSuggestionRequest() {
    _suggestionDebounceTimer?.cancel();
    _suggestionDebounceTimer = null;
    _suggestionRequestId += 1;
    _suggestions = const [];
    _suggestionMessage = null;
    if (_suggestionMenuController.isOpen) {
      _suggestionMenuController.close();
    }
  }

  void _scheduleSuggestionRequest(String value) {
    _cancelSuggestionRequest();
    final query = value.trim();
    if (!_shouldLoadRemoteSearchSuggestions(query)) {
      setState(() {});
      return;
    }

    final requestId = _suggestionRequestId;
    _suggestionDebounceTimer = Timer(_remoteSearchDebounce, () {
      _suggestionDebounceTimer = null;
      if (!mounted ||
          requestId != _suggestionRequestId ||
          !_focusNode.hasFocus ||
          widget.controller.text.trim() != query) {
        return;
      }
      setState(() => _suggestionMessage = '正在搜索...');
      _openSuggestionMenu();
      unawaited(_completeSuggestionRequest(query, requestId));
    });
  }

  Future<void> _completeSuggestionRequest(String query, int requestId) async {
    try {
      final results = await widget.onLoadSuggestions(
        query,
        LibrarySearchScope.all,
      );
      if (!mounted ||
          requestId != _suggestionRequestId ||
          !_focusNode.hasFocus ||
          widget.controller.text.trim() != query) {
        return;
      }
      final suggestions = _remoteSearchSuggestions(results);
      setState(() {
        _suggestions = suggestions;
        _suggestionMessage = suggestions.isEmpty ? '未找到相关内容' : null;
      });
      _openSuggestionMenu();
    } catch (error, stackTrace) {
      if (!mounted || requestId != _suggestionRequestId) {
        return;
      }
      AppLogger.instance.error(
        'search',
        '加载远程搜索联想失败',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _suggestions = const [];
        _suggestionMessage = '联想搜索失败';
      });
      _openSuggestionMenu();
    }
  }

  void _openSuggestionMenu() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_focusNode.hasFocus ||
          (_suggestions.isEmpty && _suggestionMessage == null) ||
          _suggestionMenuController.isOpen) {
        return;
      }
      _suggestionMenuController.open();
    });
  }

  void _selectSuggestion(_RemoteSearchSuggestion suggestion) {
    _cancelSuggestionRequest();
    widget.controller.value = TextEditingValue(
      text: suggestion.title,
      selection: TextSelection.collapsed(offset: suggestion.title.length),
    );
    widget.onSuggestionSelected(suggestion);
  }

  void _submitSearch() {
    _cancelSuggestionRequest();
    widget.onSearch();
  }

  double _searchLeadingWidth() {
    final renderObject = _searchLeadingKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return 0;
    }
    return renderObject.size.width;
  }

  Widget _buildSuggestionsMenu(BuildContext context, double width) {
    final message = _suggestionMessage;
    final itemCount = message == null ? _suggestions.length : 1;
    return SizedBox(
      key: const ValueKey('remote-search-suggestions'),
      width: width,
      height: math.min(248, itemCount * 48 + 8).toDouble(),
      child: Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: message != null
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (message == '正在搜索...') ...[
                      const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(message),
                  ],
                )
              : ListView.builder(
                  primary: false,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _suggestions.length,
                  itemBuilder: (context, index) {
                    final suggestion = _suggestions[index];
                    return Semantics(
                      button: true,
                      label:
                          '${_searchScopeLabel(suggestion.scope)}：${suggestion.title}',
                      child: InkWell(
                        key: ValueKey(
                          'remote-search-suggestion-${suggestion.scope.name}-${suggestion.id}',
                        ),
                        onTap: () => _selectSuggestion(suggestion),
                        child: SizedBox(
                          height: 48,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                Icon(
                                  _remoteSearchSuggestionIcon(suggestion.scope),
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        suggestion.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        suggestion.subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    return _GlassSurface(
      darkAlpha: 0.16,
      child: Row(
        children: [
          Row(
            key: _searchLeadingKey,
            mainAxisSize: MainAxisSize.min,
            children: [
              _SearchScopeMenu(
                scope: widget.scope,
                isBusy: widget.isBusy,
                onChanged: (value) {
                  widget.onScopeChanged(value);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      _focusNode.requestFocus();
                    }
                  });
                },
              ),
              SizedBox(
                height: compact ? 30 : 36,
                child: VerticalDivider(width: compact ? 14 : 18),
              ),
            ],
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final leadingWidth = _searchLeadingWidth();
                return MenuAnchor(
                  controller: _suggestionMenuController,
                  childFocusNode: _focusNode,
                  alignmentOffset: Offset(-leadingWidth, 4),
                  style: const MenuStyle(
                    padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
                      EdgeInsets.zero,
                    ),
                  ),
                  menuChildren: [
                    if (_suggestions.isNotEmpty || _suggestionMessage != null)
                      _buildSuggestionsMenu(
                        context,
                        constraints.maxWidth + leadingWidth,
                      ),
                  ],
                  builder: (context, controller, child) {
                    return TextField(
                      controller: widget.controller,
                      focusNode: _focusNode,
                      textAlign: TextAlign.start,
                      textAlignVertical: TextAlignVertical.center,
                      textInputAction: TextInputAction.search,
                      onChanged: _scheduleSuggestionRequest,
                      onSubmitted: (_) {
                        if (_suggestions.isNotEmpty) {
                          _selectSuggestion(_suggestions.first);
                        } else {
                          _submitSearch();
                        }
                      },
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        hintText: _focusNode.hasFocus ? null : '输入关键词',
                        suffixIconConstraints: BoxConstraints(
                          minHeight: compact ? 42 : 48,
                          minWidth: compact ? 42 : 48,
                        ),
                        suffixIcon: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: widget.controller,
                          builder: (context, value, child) {
                            final hasText = value.text.isNotEmpty;
                            return SizedBox(
                              width: hasText ? 96 : 48,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (hasText)
                                    IconButton(
                                      tooltip: '清空搜索',
                                      onPressed: () {
                                        _cancelSuggestionRequest();
                                        widget.controller.clear();
                                        _focusNode.requestFocus();
                                      },
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                                  IconButton(
                                    tooltip: '搜索',
                                    onPressed: widget.isBusy
                                        ? null
                                        : _submitSearch,
                                    icon: const Icon(Icons.arrow_forward),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchScopeMenu extends StatefulWidget {
  const _SearchScopeMenu({
    required this.scope,
    required this.isBusy,
    required this.onChanged,
  });

  final LibrarySearchScope scope;
  final bool isBusy;
  final ValueChanged<LibrarySearchScope> onChanged;

  @override
  State<_SearchScopeMenu> createState() => _SearchScopeMenuState();
}

class _SearchScopeMenuState extends State<_SearchScopeMenu> {
  final MenuController _menuController = MenuController();
  Timer? _closeTimer;
  bool _anchorHovered = false;
  bool _menuHovered = false;

  bool get _hoverEnabled => _supportsDesktopSettings(defaultTargetPlatform);

  @override
  void didUpdateWidget(covariant _SearchScopeMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isBusy && !oldWidget.isBusy) {
      _closeMenu();
    }
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _menuController,
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final value in const [
          LibrarySearchScope.songs,
          LibrarySearchScope.artists,
          LibrarySearchScope.albums,
        ])
          MouseRegion(
            onEnter: (_) {
              _menuHovered = true;
              _closeTimer?.cancel();
            },
            onExit: (_) {
              _menuHovered = false;
              _scheduleClose();
            },
            child: MenuItemButton(
              key: ValueKey('search-scope-option-${value.name}'),
              onPressed: widget.isBusy ? null : () => _select(value),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_searchScopeLabel(value)),
                  const SizedBox(width: 10),
                  Icon(
                    value == widget.scope
                        ? Icons.check_rounded
                        : _remoteSearchSuggestionIcon(value),
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
      ],
      builder: (context, controller, child) {
        return MouseRegion(
          key: const ValueKey('search-scope-hover-target'),
          onEnter: (_) {
            _anchorHovered = true;
            _closeTimer?.cancel();
            if (_hoverEnabled && !widget.isBusy && !controller.isOpen) {
              controller.open();
            }
          },
          onExit: (_) {
            _anchorHovered = false;
            _scheduleClose();
          },
          child: TextButton(
            onPressed: widget.isBusy
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              padding: const EdgeInsets.only(left: 12, right: 8),
              minimumSize: const Size(0, 48),
              shape: const RoundedRectangleBorder(),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_searchScopeLabel(widget.scope)),
                const SizedBox(width: 2),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  void _select(LibrarySearchScope value) {
    _closeTimer?.cancel();
    _menuController.close();
    if (value != widget.scope) {
      widget.onChanged(value);
    }
  }

  void _scheduleClose() {
    if (!_hoverEnabled) {
      return;
    }
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 180), () {
      if (!_anchorHovered && !_menuHovered) {
        _closeMenu();
      }
    });
  }

  void _closeMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
    }
  }
}

// Kept for compatibility with older widget snapshots; no longer shown.
// ignore: unused_element
class _ArtistAlbumSections extends StatelessWidget {
  const _ArtistAlbumSections({
    required this.controller,
    required this.onShowSection,
    required this.onSearchLibraryItem,
  });

  final AppController controller;
  final ValueChanged<LibrarySectionType> onShowSection;
  final Future<void> Function(LibrarySectionItem item) onSearchLibraryItem;

  @override
  Widget build(BuildContext context) {
    final artists = _LibraryPreviewSection(
      title: '歌手',
      emptyText: '暂无歌手信息',
      icon: Icons.person_outline,
      items: controller.libraryOverview.artists,
      style: _LibraryPreviewStyle.artist,
      expanded: false,
      onToggle: () => onShowSection(LibrarySectionType.artists),
      onTap: onSearchLibraryItem,
    );
    final albums = _LibraryPreviewSection(
      title: '专辑',
      emptyText: '暂无专辑信息',
      icon: Icons.album_outlined,
      items: controller.libraryOverview.albums,
      style: _LibraryPreviewStyle.album,
      expanded: false,
      onToggle: () => onShowSection(LibrarySectionType.albums),
      onTap: onSearchLibraryItem,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 820) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [artists, albums],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: artists),
            const SizedBox(width: 28),
            Expanded(child: albums),
          ],
        );
      },
    );
  }
}

enum _SearchResultTab { songs, artists, albums }

String _searchScopeLabel(LibrarySearchScope scope) {
  return switch (scope) {
    LibrarySearchScope.all => '所有',
    LibrarySearchScope.songs => '歌曲',
    LibrarySearchScope.artists => '歌手',
    LibrarySearchScope.albums => '专辑',
  };
}

_SearchResultTab _defaultSearchResultTab(
  LibrarySearchScope scope,
  List<Track> songs,
  LibrarySearchResults results,
) {
  return switch (scope) {
    LibrarySearchScope.songs => _SearchResultTab.songs,
    LibrarySearchScope.artists => _SearchResultTab.artists,
    LibrarySearchScope.albums => _SearchResultTab.albums,
    LibrarySearchScope.all =>
      songs.isNotEmpty
          ? _SearchResultTab.songs
          : results.artists.isNotEmpty
          ? _SearchResultTab.artists
          : results.albums.isNotEmpty
          ? _SearchResultTab.albums
          : _SearchResultTab.songs,
  };
}

class _SearchResultsSection extends StatelessWidget {
  const _SearchResultsSection({
    required this.controller,
    required this.selectedTab,
    required this.onTabChanged,
    required this.onSearchLibraryItem,
    required this.onPreviousSongPage,
    required this.onNextSongPage,
  });

  final AppController controller;
  final _SearchResultTab selectedTab;
  final ValueChanged<_SearchResultTab> onTabChanged;
  final Future<void> Function(LibrarySectionItem item) onSearchLibraryItem;
  final Future<void> Function()? onPreviousSongPage;
  final Future<void> Function()? onNextSongPage;

  @override
  Widget build(BuildContext context) {
    final songs = controller.visibleTracks;
    final artists = controller.searchResults.artists;
    final albums = controller.searchResults.albums;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DefaultTabController(
          key: ValueKey(selectedTab),
          length: _SearchResultTab.values.length,
          initialIndex: selectedTab.index,
          child: TabBar(
            onTap: (index) => onTabChanged(_SearchResultTab.values[index]),
            tabs: [
              const Tab(text: '歌曲'),
              const Tab(text: '歌手'),
              const Tab(text: '专辑'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        switch (selectedTab) {
          _SearchResultTab.songs => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (songs.isEmpty)
                const Text('暂无歌曲结果')
              else
                _TrackList(
                  controller: controller,
                  tracks: songs,
                  shrinkWrap: true,
                ),
              if (controller.searchSongPageIndex > 0 ||
                  controller.hasNextSearchSongPage) ...[
                const SizedBox(height: 12),
                _SearchPaginationBar(
                  pageIndex: controller.searchSongPageIndex,
                  onPrevious: controller.isBusy
                      ? null
                      : onPreviousSongPage == null
                      ? null
                      : () => unawaited(onPreviousSongPage!()),
                  onNext: controller.isBusy
                      ? null
                      : onNextSongPage == null
                      ? null
                      : () => unawaited(onNextSongPage!()),
                ),
              ],
            ],
          ),
          _SearchResultTab.artists => _LibraryPreviewSection(
            title: '歌手',
            emptyText: '暂无歌手结果',
            icon: Icons.person_outline,
            items: artists,
            style: _LibraryPreviewStyle.artist,
            expanded: true,
            showToggle: false,
            onToggle: () {},
            onTap: onSearchLibraryItem,
          ),
          _SearchResultTab.albums => _LibraryPreviewSection(
            title: '专辑',
            emptyText: '暂无专辑结果',
            icon: Icons.album_outlined,
            items: albums,
            style: _LibraryPreviewStyle.album,
            expanded: true,
            showToggle: false,
            onToggle: () {},
            onTap: onSearchLibraryItem,
          ),
        },
      ],
    );
  }
}

enum _LibraryPreviewStyle { artist, album, playlist }

int _libraryPreviewLimit(_LibraryPreviewStyle style) {
  return style == _LibraryPreviewStyle.playlist ? 9 : 6;
}

class _LibraryPreviewSection extends StatelessWidget {
  const _LibraryPreviewSection({
    required this.title,
    required this.emptyText,
    required this.icon,
    required this.items,
    required this.style,
    required this.expanded,
    required this.onToggle,
    required this.onTap,
    this.showToggle = true,
    this.showCount = true,
    this.titleAction,
    this.action,
    this.onPlay,
  });

  final String title;
  final String emptyText;
  final IconData icon;
  final List<LibrarySectionItem> items;
  final _LibraryPreviewStyle style;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<LibrarySectionItem> onTap;
  final bool showToggle;
  final bool showCount;
  final Widget? titleAction;
  final Widget? action;
  final Future<void> Function(LibrarySectionItem item)? onPlay;

  @override
  Widget build(BuildContext context) {
    final previewLimit = _libraryPreviewLimit(style);
    final visibleItems = expanded ? items : items.take(previewLimit).toList();
    final compact = _isPhoneWidth(context);

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 10 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LibrarySectionHeader(
            title: title,
            countText: showCount && items.isNotEmpty ? '${items.length}' : null,
            titleAction: titleAction,
            action:
                _headerAction(
                  showToggle: showToggle,
                  shouldShowToggle: items.length > previewLimit,
                  expanded: expanded,
                  onToggle: onToggle,
                ) ??
                action,
          ),
          SizedBox(height: compact ? 4 : 10),
          if (items.isEmpty)
            Text(emptyText)
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final spacing = style == _LibraryPreviewStyle.playlist
                    ? (compact ? 5.0 : 8.0)
                    : (compact ? 6.0 : 12.0);
                final columns = _libraryPreviewColumnCount(
                  constraints.maxWidth,
                  visibleItems.length,
                  style,
                );
                final itemWidth =
                    (constraints.maxWidth - spacing * (columns - 1)) / columns;

                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final item in visibleItems)
                      SizedBox(
                        width: itemWidth,
                        child: _LibraryPreviewTile(
                          item: item,
                          icon: icon,
                          style: style,
                          onTap: () => onTap(item),
                          onPlay: onPlay == null ? null : () => onPlay!(item),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

Widget? _headerAction({
  required bool showToggle,
  required bool shouldShowToggle,
  required bool expanded,
  required VoidCallback onToggle,
}) {
  return showToggle && shouldShowToggle
      ? TextButton(onPressed: onToggle, child: Text(expanded ? '收起' : '更多'))
      : null;
}

class _LibrarySectionHeader extends StatelessWidget {
  const _LibrarySectionHeader({
    required this.title,
    this.countText,
    this.titleAction,
    this.action,
  });

  final String title;
  final String? countText;
  final Widget? titleAction;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (titleAction != null) ...[
                const SizedBox(width: 2),
                titleAction!,
              ],
              if (countText != null) ...[
                const SizedBox(width: 8),
                Text(
                  countText!,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ],
          ),
        ),
        ?action,
      ],
    );
  }
}

class _AsyncPlayButton extends StatefulWidget {
  const _AsyncPlayButton({
    required this.tooltip,
    required this.onPressed,
    this.artworkOverlay = false,
    this.size = 30,
    this.iconSize = 20,
    super.key,
  });

  final String tooltip;
  final Future<void> Function()? onPressed;
  final bool artworkOverlay;
  final double size;
  final double iconSize;

  @override
  State<_AsyncPlayButton> createState() => _AsyncPlayButtonState();
}

class _AsyncPlayButtonState extends State<_AsyncPlayButton> {
  bool _isRunning = false;

  Future<void> _run() async {
    final onPressed = widget.onPressed;
    if (_isRunning || onPressed == null) {
      return;
    }
    setState(() => _isRunning = true);
    try {
      await onPressed();
    } finally {
      if (mounted) {
        setState(() => _isRunning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = widget.artworkOverlay
        ? Colors.white
        : colorScheme.primary;
    return IconButton(
      tooltip: widget.tooltip,
      style: IconButton.styleFrom(
        fixedSize: Size.square(widget.size),
        minimumSize: Size.square(widget.size),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: foreground,
        disabledForegroundColor: foreground.withValues(alpha: 0.65),
        backgroundColor: widget.artworkOverlay
            ? Colors.black.withValues(alpha: 0.46)
            : Colors.transparent,
      ),
      constraints: BoxConstraints.tightFor(
        width: widget.size,
        height: widget.size,
      ),
      onPressed: _isRunning || widget.onPressed == null ? null : _run,
      icon: _isRunning
          ? SizedBox.square(
              dimension: widget.iconSize * 0.72,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          : Icon(Icons.play_arrow_rounded, size: widget.iconSize),
    );
  }
}

class _LibraryPreviewTile extends StatelessWidget {
  const _LibraryPreviewTile({
    required this.item,
    required this.icon,
    required this.style,
    required this.onTap,
    this.onPlay,
  });

  final LibrarySectionItem item;
  final IconData icon;
  final _LibraryPreviewStyle style;
  final VoidCallback onTap;
  final Future<void> Function()? onPlay;

  @override
  Widget build(BuildContext context) {
    final isArtist = style == _LibraryPreviewStyle.artist;
    final compact = _isPhoneWidth(context);
    final artworkSize = compact
        ? (isArtist ? 30.0 : 34.0)
        : (isArtist ? 48.0 : 54.0);
    final tileHeight = compact ? 52.0 : 72.0;
    final textTheme = Theme.of(context).textTheme;
    final subtitle = item.type == LibrarySectionType.radio
        ? '电台'
        : item.subtitle;

    return _GlassSurface(
      darkAlpha: 0.14,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              SizedBox(
                width: double.infinity,
                height: tileHeight,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 7 : 10,
                    vertical: compact ? 4 : 8,
                  ),
                  child: Row(
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          _LibraryItemArtwork(
                            item: item,
                            fallbackIcon: icon,
                            size: artworkSize,
                            circle: isArtist,
                          ),
                          if (style == _LibraryPreviewStyle.playlist &&
                              onPlay != null)
                            _AsyncPlayButton(
                              key: ValueKey('play-playlist-${item.id}'),
                              tooltip: '播放${item.title}',
                              onPressed: onPlay,
                              artworkOverlay: true,
                              size: compact ? 24 : 30,
                              iconSize: compact ? 17 : 21,
                            ),
                        ],
                      ),
                      SizedBox(width: compact ? 7 : 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  (compact
                                          ? textTheme.bodySmall
                                          : textTheme.bodyMedium)
                                      ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (!isArtist && subtitle.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall?.copyWith(
                                  fontSize: compact ? 11 : null,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (item.isLocal ||
                  (style == _LibraryPreviewStyle.playlist &&
                      item.isPublic == true))
                Positioned(
                  top: 6,
                  right: 6,
                  child: _SmallBadge(label: item.isLocal ? '本地' : '公开'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

int _libraryPreviewColumnCount(
  double maxWidth,
  int itemCount,
  _LibraryPreviewStyle style,
) {
  final preferredColumns = switch (style) {
    _LibraryPreviewStyle.artist =>
      maxWidth >= 980
          ? 5
          : maxWidth >= 720
          ? 4
          : maxWidth >= 520
          ? 3
          : 2,
    _LibraryPreviewStyle.album =>
      maxWidth >= 980
          ? 5
          : maxWidth >= 720
          ? 4
          : maxWidth >= 520
          ? 3
          : 2,
    _LibraryPreviewStyle.playlist =>
      maxWidth >= 860
          ? 3
          : maxWidth >= 560
          ? 2
          : 1,
  };
  if (itemCount <= 0) {
    return 1;
  }
  return itemCount < preferredColumns ? itemCount : preferredColumns;
}

class _LibraryItemArtwork extends StatelessWidget {
  const _LibraryItemArtwork({
    required this.item,
    required this.fallbackIcon,
    this.size = 40,
    this.circle = false,
  });

  final LibrarySectionItem item;
  final IconData fallbackIcon;
  final double size;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final coverUrl = item.coverUrl;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(8),
      ),
      child: SizedBox.square(dimension: size, child: Icon(fallbackIcon)),
    );
    if (coverUrl == null || coverUrl.isEmpty) {
      return placeholder;
    }

    if (item.isLocal) {
      final file = File(coverUrl);
      if (!file.existsSync()) {
        return placeholder;
      }
      final image = Image.file(
        file,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => placeholder,
      );
      return circle
          ? ClipOval(child: image)
          : ClipRRect(borderRadius: BorderRadius.circular(8), child: image);
    }

    final image = _CachedArtworkImage(
      imageUrl: coverUrl,
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholder: placeholder,
    );
    if (circle) {
      return ClipOval(child: image);
    }
    return ClipRRect(borderRadius: BorderRadius.circular(8), child: image);
  }
}

class _LibraryBrowsePage extends StatefulWidget {
  const _LibraryBrowsePage({
    required this.type,
    required this.items,
    required this.onBack,
    required this.onTap,
    this.onRefresh,
    this.onCreatePlaylist,
    this.titleOverride,
    this.emptyTextOverride,
    this.actions = const [],
  });

  final LibrarySectionType type;
  final List<LibrarySectionItem> items;
  final VoidCallback onBack;
  final Future<void> Function(LibrarySectionItem item) onTap;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onCreatePlaylist;
  final String? titleOverride;
  final String? emptyTextOverride;
  final List<Widget> actions;

  @override
  State<_LibraryBrowsePage> createState() => _LibraryBrowsePageState();
}

class _LibraryBrowsePageState extends State<_LibraryBrowsePage> {
  int _pageIndex = 0;

  @override
  Widget build(BuildContext context) {
    final title = widget.titleOverride ?? _librarySectionTitle(widget.type);
    final emptyText =
        widget.emptyTextOverride ?? _librarySectionEmptyText(widget.type);
    final icon = _librarySectionIcon(widget.type);
    final style = _librarySectionPreviewStyle(widget.type);
    final pageCount = libraryBrowsePageCount(widget.items.length);
    final pageIndex = pageCount == 0 ? 0 : _pageIndex.clamp(0, pageCount - 1);
    final items = libraryBrowsePageItems(widget.items, pageIndex);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
      children: [
        _DetailPageHeading(
          title: title,
          titleKey: const ValueKey('library-browse-title'),
          onBack: widget.onBack,
          actions: [
            ...widget.actions,
            if (widget.onRefresh != null)
              IconButton(
                tooltip: '刷新$title',
                onPressed: () => unawaited(widget.onRefresh!()),
                icon: const Icon(Icons.refresh),
              ),
            if (widget.onCreatePlaylist != null)
              IconButton(
                tooltip: '新建歌单',
                onPressed: widget.onCreatePlaylist,
                icon: const Icon(Icons.add),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(child: Text(emptyText)),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final spacing = style == _LibraryPreviewStyle.album
                          ? 12.0
                          : 10.0;
                      final columns = _libraryBrowseColumnCount(
                        constraints.maxWidth,
                        style,
                      );
                      final itemWidth =
                          (constraints.maxWidth - spacing * (columns - 1)) /
                          columns;

                      return Wrap(
                        spacing: spacing,
                        runSpacing: spacing,
                        children: [
                          for (final item in items)
                            SizedBox(
                              width: itemWidth,
                              child: _LibraryPreviewTile(
                                item: item,
                                icon: icon,
                                style: style,
                                onTap: () async {
                                  await widget.onTap(item);
                                },
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                const SizedBox(height: 18),
                _PaginationBar(
                  pageIndex: pageIndex,
                  pageCount: pageCount,
                  onPrevious: pageIndex <= 0
                      ? null
                      : () => _setPage(pageIndex - 1, pageCount),
                  onNext: pageIndex >= pageCount - 1
                      ? null
                      : () => _setPage(pageIndex + 1, pageCount),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _setPage(int value, int pageCount) {
    setState(() {
      _pageIndex = pageCount == 0 ? 0 : value.clamp(0, pageCount - 1);
    });
  }
}

class _PaginationBar extends StatelessWidget {
  const _PaginationBar({
    required this.pageIndex,
    required this.pageCount,
    required this.onPrevious,
    required this.onNext,
  });

  final int pageIndex;
  final int pageCount;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('library-pagination-bar'),
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            pageCount == 0 ? '第 0 / 0 页' : '第 ${pageIndex + 1} / $pageCount 页',
            textAlign: TextAlign.center,
          ),
        ),
        IconButton(
          tooltip: '下一页',
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

class _SearchPaginationBar extends StatelessWidget {
  const _SearchPaginationBar({
    required this.pageIndex,
    required this.onPrevious,
    required this.onNext,
  });

  final int pageIndex;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const ValueKey('search-pagination-bar'),
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text('第 ${pageIndex + 1} 页', textAlign: TextAlign.center),
        ),
        IconButton(
          tooltip: '下一页',
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

String _librarySectionTitle(LibrarySectionType type) {
  return switch (type) {
    LibrarySectionType.artists => '歌手',
    LibrarySectionType.albums => '专辑',
    LibrarySectionType.playlists => '歌单',
    LibrarySectionType.radio => '电台',
  };
}

String _librarySectionEmptyText(LibrarySectionType type) {
  return switch (type) {
    LibrarySectionType.artists => '暂无歌手信息',
    LibrarySectionType.albums => '暂无专辑信息',
    LibrarySectionType.playlists => '暂无歌单信息',
    LibrarySectionType.radio => '暂无电台信息',
  };
}

IconData _librarySectionIcon(LibrarySectionType type) {
  return switch (type) {
    LibrarySectionType.artists => Icons.person_outline,
    LibrarySectionType.albums => Icons.album_outlined,
    LibrarySectionType.playlists => Icons.queue_music_outlined,
    LibrarySectionType.radio => Icons.radio_outlined,
  };
}

_LibraryPreviewStyle _librarySectionPreviewStyle(LibrarySectionType type) {
  return switch (type) {
    LibrarySectionType.artists => _LibraryPreviewStyle.artist,
    LibrarySectionType.albums => _LibraryPreviewStyle.album,
    LibrarySectionType.playlists => _LibraryPreviewStyle.playlist,
    LibrarySectionType.radio => _LibraryPreviewStyle.playlist,
  };
}

int _libraryBrowseColumnCount(double maxWidth, _LibraryPreviewStyle style) {
  final preferredColumns = switch (style) {
    _LibraryPreviewStyle.artist =>
      maxWidth >= 980
          ? 4
          : maxWidth >= 680
          ? 3
          : 2,
    _LibraryPreviewStyle.album =>
      maxWidth >= 980
          ? 3
          : maxWidth >= 680
          ? 2
          : 1,
    _LibraryPreviewStyle.playlist => maxWidth >= 760 ? 2 : 1,
  };
  return preferredColumns;
}

bool get _usesDesktopTrackSelection =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS;

class _TrackList extends StatefulWidget {
  const _TrackList({
    required this.controller,
    required this.tracks,
    this.playbackTracks,
    this.indexOffset = 0,
    this.shrinkWrap = false,
    this.showArtwork = true,
    this.padding,
    this.allowTrackActions = true,
    this.selectedIndexes,
    this.onSelectionChanged,
    this.onRemoveFromRemotePlaylist,
  });

  final AppController controller;
  final List<Track> tracks;
  final List<Track>? playbackTracks;
  final int indexOffset;
  final bool shrinkWrap;
  final bool showArtwork;
  final EdgeInsetsGeometry? padding;
  final bool allowTrackActions;
  final Set<int>? selectedIndexes;
  final void Function(int index, bool selected)? onSelectionChanged;
  final Future<void> Function(int index, Track track)?
  onRemoveFromRemotePlaylist;

  @override
  State<_TrackList> createState() => _TrackListState();
}

class _TrackListState extends State<_TrackList> {
  String? _desktopSelectedTrackId;

  AppController get controller => widget.controller;
  List<Track> get tracks => widget.tracks;
  List<Track>? get playbackTracks => widget.playbackTracks;
  int get indexOffset => widget.indexOffset;
  bool get shrinkWrap => widget.shrinkWrap;
  bool get showArtwork => widget.showArtwork;
  EdgeInsetsGeometry? get padding => widget.padding;
  bool get allowTrackActions => widget.allowTrackActions;
  Set<int>? get selectedIndexes => widget.selectedIndexes;
  void Function(int index, bool selected)? get onSelectionChanged =>
      widget.onSelectionChanged;
  Future<void> Function(int index, Track track)?
  get onRemoveFromRemotePlaylist => widget.onRemoveFromRemotePlaylist;

  @override
  void didUpdateWidget(covariant _TrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selectedTrackId = _desktopSelectedTrackId;
    if (selectedTrackId != null &&
        !widget.tracks.any((track) => track.id == selectedTrackId)) {
      _desktopSelectedTrackId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.queue_music_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                '搜索音源，或选择本地音频后开始播放。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: padding ?? EdgeInsets.all(_isPhoneWidth(context) ? 8 : 10),
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final sourceIndex = index + indexOffset;
        final isCurrent = controller.player.currentTrack?.id == track.id;
        final isManagedLocalTrack =
            track.sourceType == MusicSourceType.localFile &&
            (track.sourceServerId?.isNotEmpty ?? false);
        final subtitle = track.artist.trim().isEmpty
            ? '未知歌手'
            : track.artist.trim();

        final canRemove =
            track.sourceType == MusicSourceType.customStream ||
            (track.sourceType == MusicSourceType.localFile &&
                !isManagedLocalTrack);

        final canFavorite = controller.canFavoriteTrack(track);
        final isFavorite = controller.isFavoriteTrack(track);
        final isFavoriteToggling = controller.isFavoriteTrackToggling(track);
        final compact = _isPhoneWidth(context);
        final rowHeight = showArtwork
            ? (compact ? 52.0 : 62.0)
            : (compact ? 44.0 : 50.0);
        final artworkSize = compact ? 36.0 : 46.0;
        final actionSize = compact ? 30.0 : 40.0;
        final colorScheme = Theme.of(context).colorScheme;
        final selectionMode = onSelectionChanged != null;
        final isSelected = selectedIndexes?.contains(sourceIndex) ?? false;
        final isDesktopSelected =
            !selectionMode &&
            _usesDesktopTrackSelection &&
            _desktopSelectedTrackId == track.id;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapDown: selectionMode
              ? null
              : (details) => _showTrackMenu(
                  context,
                  details.globalPosition,
                  track,
                  sourceIndex,
                  canRemove,
                  allowTrackActions,
                ),
          onLongPressStart: selectionMode
              ? null
              : (details) => _showTrackMenu(
                  context,
                  details.globalPosition,
                  track,
                  sourceIndex,
                  canRemove,
                  allowTrackActions,
                ),
          child: Material(
            color: isSelected || isDesktopSelected
                ? colorScheme.primaryContainer.withValues(alpha: 0.18)
                : isCurrent
                ? colorScheme.primaryContainer.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              key: ValueKey('track-row-${track.id}'),
              borderRadius: BorderRadius.circular(8),
              onTap: selectionMode
                  ? () => onSelectionChanged?.call(sourceIndex, !isSelected)
                  : () => _handleTrackTap(track, sourceIndex),
              onDoubleTap: selectionMode || !_usesDesktopTrackSelection
                  ? null
                  : () => _playDesktopTrack(track, sourceIndex),
              child: SizedBox(
                height: rowHeight,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 6 : 10,
                    vertical: showArtwork
                        ? (compact ? 5 : 7)
                        : (compact ? 2 : 3),
                  ),
                  child: Row(
                    children: [
                      if (selectionMode) ...[
                        SizedBox.square(
                          dimension: actionSize,
                          child: Checkbox(
                            key: ValueKey(
                              'remote-playlist-track-selection-$index',
                            ),
                            value: isSelected,
                            visualDensity: VisualDensity.compact,
                            onChanged: (value) =>
                                onSelectionChanged?.call(index, value ?? false),
                          ),
                        ),
                        SizedBox(width: compact ? 4 : 8),
                      ],
                      if (showArtwork) ...[
                        KeyedSubtree(
                          key: ValueKey('track-artwork-${track.id}'),
                          child: _TrackArtwork(track: track, size: artworkSize),
                        ),
                        SizedBox(width: compact ? 8 : 10),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _TrackTitle(
                              track: track,
                              compact: compact,
                              textStyle: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: isCurrent
                                        ? colorScheme.primary
                                        : null,
                                    fontSize: compact ? 14 : 15,
                                    fontWeight: isCurrent
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(fontSize: compact ? 12 : null),
                            ),
                          ],
                        ),
                      ),
                      if (!selectionMode) ...[
                        SizedBox(width: compact ? 4 : 8),
                        SizedBox.square(
                          dimension: actionSize,
                          child: IconButton(
                            tooltip: _favoriteTrackTooltip(
                              isFavorite,
                              isFavoriteToggling,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: BoxConstraints.tight(
                              Size.square(actionSize),
                            ),
                            iconSize: compact ? 20 : 24,
                            onPressed: canFavorite
                                ? () => unawaited(
                                    controller.toggleFavoriteTrack(track),
                                  )
                                : null,
                            icon: _FavoriteHeartIcon(
                              isFavorite: isFavorite,
                              isToggling: isFavoriteToggling,
                              iconSize: compact ? 20 : 24,
                            ),
                          ),
                        ),
                        SizedBox.square(
                          dimension: actionSize,
                          child: IconButton(
                            tooltip: '播放',
                            style: IconButton.styleFrom(
                              fixedSize: Size.square(actionSize),
                              padding: EdgeInsets.zero,
                            ),
                            iconSize: compact ? 20 : 24,
                            onPressed: () =>
                                controller.playTrackList(tracks, index),
                            icon: Icon(
                              isCurrent ? Icons.graphic_eq : Icons.play_arrow,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemCount: tracks.length,
    );
  }

  void _handleTrackTap(Track track, int index) {
    if (!_usesDesktopTrackSelection) {
      unawaited(controller.playTrackList(playbackTracks ?? tracks, index));
      return;
    }
    if (_desktopSelectedTrackId == track.id) {
      unawaited(controller.playTrackList(playbackTracks ?? tracks, index));
      return;
    }
    setState(() => _desktopSelectedTrackId = track.id);
  }

  void _playDesktopTrack(Track track, int index) {
    if (_desktopSelectedTrackId != track.id) {
      setState(() => _desktopSelectedTrackId = track.id);
    }
    unawaited(controller.playTrackList(playbackTracks ?? tracks, index));
  }

  Future<void> _showTrackMenu(
    BuildContext context,
    Offset position,
    Track track,
    int index,
    bool canRemove,
    bool allowManagementActions,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'play_next',
          child: ListTile(
            leading: Icon(Icons.queue_play_next_rounded),
            title: Text('下一首播放'),
          ),
        ),
        if (controller.canAddTrackToRemotePlaylist(track))
          const PopupMenuItem(
            value: 'add_to_playlist',
            child: ListTile(
              leading: Icon(Icons.playlist_add_outlined),
              title: Text('加入歌单'),
            ),
          ),
        if (allowManagementActions &&
            track.sourceType == MusicSourceType.localFile)
          const PopupMenuItem(
            value: 'edit_metadata',
            child: ListTile(
              leading: Icon(Icons.edit_note_outlined),
              title: Text('编辑元数据'),
            ),
          ),
        if (allowManagementActions && onRemoveFromRemotePlaylist != null)
          const PopupMenuItem(
            value: 'remove_from_remote_playlist',
            child: ListTile(
              leading: Icon(Icons.playlist_remove_outlined),
              title: Text('从歌单移除'),
            ),
          ),
        if (allowManagementActions && canRemove)
          const PopupMenuItem(
            value: 'remove',
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('删除'),
            ),
          ),
      ],
    );
    if (!context.mounted || action == null) {
      return;
    }

    switch (action) {
      case 'play_next':
        await controller.playTrackNext(track);
        if (context.mounted) {
          _showSourceMessage(context, controller.statusMessage ?? '已设为下一首播放。');
        }
      case 'add_to_playlist':
        await _addTrackToPlaylist(context, track);
      case 'edit_metadata':
        await _editLocalMetadata(context, track);
      case 'remove_from_remote_playlist':
        await onRemoveFromRemotePlaylist?.call(index, track);
      case 'remove':
        await controller.removeCustomTrack(track.id);
    }
  }

  Future<void> _addTrackToPlaylist(BuildContext context, Track track) async {
    final playlists = controller.manageablePlaylists;
    if (playlists.isEmpty) {
      _showSourceMessage(context, '暂无可编辑歌单。');
      return;
    }
    final playlist = await showDialog<LibrarySectionItem>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('加入歌单'),
        children: [
          for (final playlist in playlists)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(playlist),
              child: Row(
                children: [
                  _RemotePlaylistCover(playlist: playlist, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      playlist.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (playlist.isPublic == true) const _SmallBadge(label: '公开'),
                ],
              ),
            ),
        ],
      ),
    );
    if (playlist == null) {
      return;
    }
    try {
      await controller.addTracksToRemotePlaylist(playlist, [track]);
      if (context.mounted) {
        _showSourceMessage(context, controller.statusMessage ?? '已加入歌单。');
      }
    } catch (error) {
      if (context.mounted) {
        _showSourceMessage(context, _formatError(error));
      }
    }
  }

  Future<void> _editLocalMetadata(BuildContext context, Track track) async {
    final uri = Uri.tryParse(track.streamUrl);
    if (uri == null || uri.scheme != 'file') {
      _showSourceMessage(context, '无法打开本地文件。');
      return;
    }
    await showMetadataAdminDialog(
      context,
      controller,
      initialPath: uri.toFilePath(),
    );
  }
}

class _TrackTitle extends StatelessWidget {
  const _TrackTitle({
    required this.track,
    this.compact = false,
    this.textStyle,
  });

  final Track track;
  final bool compact;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final audioFormat = track.audioFormat;
    return Row(
      children: [
        Flexible(
          fit: FlexFit.loose,
          child: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
        if (audioFormat != null && audioFormat.isNotEmpty) ...[
          SizedBox(width: compact ? 4 : 5),
          _AudioFormatChip(format: audioFormat),
        ],
      ],
    );
  }
}

class _AudioFormatChip extends StatelessWidget {
  const _AudioFormatChip({required this.format});

  final String format;

  @override
  Widget build(BuildContext context) {
    final palette = _AudioFormatPalette.forFormat(format);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: palette.border, width: 0.7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        child: Text(
          format,
          maxLines: 1,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: palette.foreground,
            fontSize: 8,
            height: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _AudioFormatPalette {
  const _AudioFormatPalette({
    required this.background,
    required this.foreground,
    required this.border,
  });

  final Color background;
  final Color foreground;
  final Color border;

  static _AudioFormatPalette forFormat(String format) {
    return switch (format.trim().toUpperCase()) {
      'APE' => const _AudioFormatPalette(
        background: Color(0xFF1E6F52),
        foreground: Color(0xFFE9FFF4),
        border: Color(0xFF62D9A3),
      ),
      'FLAC' => const _AudioFormatPalette(
        background: Color(0xFF096A73),
        foreground: Color(0xFFE4FCFF),
        border: Color(0xFF58D6E0),
      ),
      'MP3' => const _AudioFormatPalette(
        background: Color(0xFF285EA8),
        foreground: Color(0xFFEAF3FF),
        border: Color(0xFF78AAEA),
      ),
      'WAV' => const _AudioFormatPalette(
        background: Color(0xFF6D3FA0),
        foreground: Color(0xFFF5ECFF),
        border: Color(0xFFC39BF2),
      ),
      'AAC' || 'OGG' => const _AudioFormatPalette(
        background: Color(0xFF936029),
        foreground: Color(0xFFFFF4E7),
        border: Color(0xFFE5AE66),
      ),
      _ => const _AudioFormatPalette(
        background: Color(0xFF4B5563),
        foreground: Color(0xFFF3F4F6),
        border: Color(0xFF9CA3AF),
      ),
    };
  }
}

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({
    required this.track,
    this.size = 52,
    this.circle = false,
  });

  final Track track;
  final double size;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final coverUrl = track.coverUrl;
    final borderRadius = BorderRadius.circular(circle ? size / 2 : 8);
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: borderRadius,
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(Icons.music_note, size: size * 0.46),
      ),
    );

    if (coverUrl == null || coverUrl.isEmpty) {
      return placeholder;
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: _CachedArtworkImage(
        imageUrl: coverUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: placeholder,
      ),
    );
  }
}

class _PlayerArtworkButton extends StatelessWidget {
  const _PlayerArtworkButton({required this.track, required this.onTap});

  final Track track;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '播放详情',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: _TrackArtwork(track: track),
      ),
    );
  }
}

class _NowPlayingView extends StatelessWidget {
  const _NowPlayingView({
    required this.controller,
    required this.onClose,
    required this.onArtistTap,
    required this.onAlbumTap,
  });

  final AppController controller;
  final VoidCallback onClose;
  final ValueChanged<String> onArtistTap;
  final ValueChanged<String> onAlbumTap;

  @override
  Widget build(BuildContext context) {
    final track = controller.player.currentTrack;
    if (track == null) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 860;
              if (constraints.maxWidth < _mobilePlayerWidthBreakpoint) {
                return _MobileNowPlayingView(
                  controller: controller,
                  track: track,
                  onClose: onClose,
                  onArtistTap: onArtistTap,
                  onAlbumTap: onAlbumTap,
                );
              }
              final content = isWide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _NowPlayingInfo(
                            controller: controller,
                            track: track,
                            onArtistTap: onArtistTap,
                            onAlbumTap: onAlbumTap,
                          ),
                        ),
                        const SizedBox(width: 48),
                        Expanded(
                          child: _LyricsPanel(
                            controller: controller,
                            track: track,
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 72, 20, 96),
                      children: [
                        _NowPlayingInfo(
                          controller: controller,
                          track: track,
                          onArtistTap: onArtistTap,
                          onAlbumTap: onAlbumTap,
                          compact: true,
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          height: 420,
                          child: _LyricsPanel(
                            controller: controller,
                            track: track,
                          ),
                        ),
                      ],
                    );

              return Padding(
                padding: isWide
                    ? const EdgeInsets.fromLTRB(56, 44, 56, 84)
                    : EdgeInsets.zero,
                child: content,
              );
            },
          ),
        ),
        if (MediaQuery.sizeOf(context).width >= _mobilePlayerWidthBreakpoint)
          Positioned(
            left: 16,
            top: 16,
            child: IconButton.filledTonal(
              tooltip: '返回',
              onPressed: onClose,
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
          ),
      ],
    );
  }
}

class _MobileNowPlayingView extends StatefulWidget {
  const _MobileNowPlayingView({
    required this.controller,
    required this.track,
    required this.onClose,
    required this.onArtistTap,
    required this.onAlbumTap,
  });

  final AppController controller;
  final Track track;
  final VoidCallback onClose;
  final ValueChanged<String> onArtistTap;
  final ValueChanged<String> onAlbumTap;

  @override
  State<_MobileNowPlayingView> createState() => _MobileNowPlayingViewState();
}

class _MobileNowPlayingViewState extends State<_MobileNowPlayingView> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final artworkSize = math.min(260.0, size.width * 0.58);
    return SafeArea(
      child: StreamBuilder<Duration>(
        stream: widget.controller.player.positionStream,
        initialData: widget.controller.player.position,
        builder: (context, snapshot) {
          final position = snapshot.data ?? Duration.zero;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                    const Spacer(),
                    _MobileNowPlayingTab(
                      label: '歌曲',
                      selected: _tabIndex == 0,
                      onTap: () => setState(() => _tabIndex = 0),
                    ),
                    const SizedBox(width: 24),
                    _MobileNowPlayingTab(
                      label: '歌词',
                      selected: _tabIndex == 1,
                      onTap: () => setState(() => _tabIndex = 1),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48),
                  ],
                ),
                Expanded(
                  child: _tabIndex == 0
                      ? _MobileSongNowPlayingPane(
                          controller: widget.controller,
                          track: widget.track,
                          artworkSize: artworkSize,
                          position: position,
                          onArtistTap: widget.onArtistTap,
                          onAlbumTap: widget.onAlbumTap,
                        )
                      : _LyricsPanel(
                          controller: widget.controller,
                          track: widget.track,
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MobileNowPlayingTab extends StatelessWidget {
  const _MobileNowPlayingTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _MobileSongNowPlayingPane extends StatelessWidget {
  const _MobileSongNowPlayingPane({
    required this.controller,
    required this.track,
    required this.artworkSize,
    required this.position,
    required this.onArtistTap,
    required this.onAlbumTap,
  });

  final AppController controller;
  final Track track;
  final double artworkSize;
  final Duration position;
  final ValueChanged<String> onArtistTap;
  final ValueChanged<String> onAlbumTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Center(
          child: _RecordArtwork(track: track, size: artworkSize),
        ),
        const Spacer(),
        Row(
          children: [
            Expanded(
              child: Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _FavoriteTrackButton(
              controller: controller,
              track: track,
              compact: true,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (track.artist.trim().isNotEmpty)
              Flexible(
                child: _NowPlayingMetadataLink(
                  key: const ValueKey('now-playing-artist-link'),
                  label: '歌手：${track.artist}',
                  onTap: () => onArtistTap(track.artist),
                ),
              ),
            if (track.artist.trim().isNotEmpty && track.album.trim().isNotEmpty)
              const SizedBox(width: 6),
            if (track.album.trim().isNotEmpty)
              Flexible(
                child: _NowPlayingMetadataLink(
                  key: const ValueKey('now-playing-album-link'),
                  label: '专辑：${track.album}',
                  onTap: () => onAlbumTap(track.album),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        _SeekBar(controller: controller, position: position),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _PlaybackModeButton(controller: controller),
            IconButton(
              tooltip: '上一首',
              onPressed: controller.player.canSkipPrevious
                  ? controller.player.playPrevious
                  : null,
              icon: const Icon(Icons.skip_previous, size: 30),
            ),
            IconButton.filled(
              tooltip: controller.player.isPlaying ? '暂停' : '播放',
              iconSize: 34,
              onPressed: controller.player.currentTrack == null
                  ? null
                  : controller.player.togglePlay,
              icon: Icon(
                controller.player.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            ),
            IconButton(
              tooltip: '下一首',
              onPressed: controller.player.canSkipNext
                  ? controller.player.playNext
                  : null,
              icon: const Icon(Icons.skip_next, size: 30),
            ),
            _QueueButton(controller: controller),
          ],
        ),
      ],
    );
  }
}

class _NowPlayingInfo extends StatelessWidget {
  const _NowPlayingInfo({
    required this.controller,
    required this.track,
    required this.onArtistTap,
    required this.onAlbumTap,
    this.compact = false,
  });

  final AppController controller;
  final Track track;
  final ValueChanged<String> onArtistTap;
  final ValueChanged<String> onAlbumTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 220.0 : 320.0;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _RecordArtwork(track: track, size: size),
            const SizedBox(height: 28),
            Text(
              track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (track.album.trim().isNotEmpty)
                  Flexible(
                    flex: 3,
                    child: _NowPlayingMetadataLink(
                      key: const ValueKey('now-playing-album-link'),
                      label: '专辑：${track.album}',
                      onTap: () => onAlbumTap(track.album),
                    ),
                  ),
                if (track.album.trim().isNotEmpty &&
                    track.artist.trim().isNotEmpty)
                  const SizedBox(width: 6),
                if (track.artist.trim().isNotEmpty)
                  Flexible(
                    flex: 3,
                    child: _NowPlayingMetadataLink(
                      key: const ValueKey('now-playing-artist-link'),
                      label: '歌手：${track.artist}',
                      onTap: () => onArtistTap(track.artist),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingMetadataLink extends StatelessWidget {
  const _NowPlayingMetadataLink({
    required this.label,
    required this.onTap,
    super.key,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordArtwork extends StatelessWidget {
  const _RecordArtwork({required this.track, required this.size});

  final Track track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.surfaceContainerHighest,
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: const Icon(Icons.music_note, size: 80),
      ),
    );

    final coverUrl = track.coverUrl;
    final artwork = coverUrl == null || coverUrl.isEmpty
        ? placeholder
        : ClipOval(
            child: _CachedArtworkImage(
              imageUrl: coverUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: placeholder,
            ),
          );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 24,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: artwork,
    );
  }
}

const double _lyricLineExtent = 54;
const Duration _lyricPreviewTimeout = Duration(seconds: 3);

class _LyricsPanel extends StatefulWidget {
  const _LyricsPanel({required this.controller, required this.track});

  final AppController controller;
  final Track track;

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  final ScrollController _scrollController = ScrollController();
  late String _lyrics;
  late List<LyricLine> _timeline;
  late List<String> _plainLines;
  int? _lastScrolledIndex;
  int? _previewIndex;
  bool _isUserScrolling = false;
  Timer? _previewResetTimer;

  @override
  void initState() {
    super.initState();
    _syncLyrics();
  }

  @override
  void didUpdateWidget(covariant _LyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.track.lyrics != widget.track.lyrics) {
      _syncLyrics();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _previewResetTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '歌词',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _timeline.isEmpty
                ? _PlainLyricsList(
                    lines: _plainLines,
                    hasLyrics: _lyrics.isNotEmpty,
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final edgePadding = math.max(
                        0.0,
                        (constraints.maxHeight - _lyricLineExtent) / 2,
                      );
                      return StreamBuilder<Duration>(
                        stream: widget.controller.player.positionStream,
                        initialData: widget.controller.player.position,
                        builder: (context, snapshot) {
                          final position = snapshot.data ?? Duration.zero;
                          final currentIndex = currentLyricIndex(
                            _timeline,
                            position,
                          );
                          _scrollToCurrentLine(currentIndex);
                          final selectedIndex = _previewIndex ?? currentIndex;
                          return NotificationListener<ScrollNotification>(
                            onNotification: _handleLyricScroll,
                            child: Listener(
                              onPointerSignal: _handleLyricPointerSignal,
                              child: ListView.builder(
                                key: const ValueKey('timed-lyrics-list'),
                                controller: _scrollController,
                                padding: EdgeInsets.symmetric(
                                  vertical: edgePadding,
                                ),
                                itemExtent: _lyricLineExtent,
                                itemCount: _timeline.length,
                                itemBuilder: (context, index) {
                                  return _TimedLyricLine(
                                    key: ValueKey('timed-lyric-$index'),
                                    text: _timeline[index].text,
                                    selected: index == selectedIndex,
                                    showSeekButton: index == _previewIndex,
                                    onTap: () => _selectLyric(index),
                                    onSeek: () => _confirmLyricSeek(index),
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _syncLyrics() {
    _previewResetTimer?.cancel();
    _lyrics = widget.track.lyrics.trim();
    _timeline = parseLyricsTimeline(_lyrics);
    _plainLines = _lyrics.isEmpty
        ? const ['暂无歌词']
        : _lyrics
              .split(RegExp(r'\r?\n'))
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toList();
    _lastScrolledIndex = null;
    _previewIndex = null;
    _isUserScrolling = false;
  }

  void _scrollToCurrentLine(int currentIndex) {
    if (_isUserScrolling ||
        currentIndex < 0 ||
        currentIndex == _lastScrolledIndex) {
      return;
    }
    _lastScrolledIndex = currentIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      final maxScrollExtent = _scrollController.position.maxScrollExtent;
      final offset = currentIndex * _lyricLineExtent;
      _scrollController.animateTo(
        offset.clamp(0, maxScrollExtent),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  bool _handleLyricScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _setPreviewIndex(_centeredLyricIndex(notification.metrics));
      return false;
    }
    if (!_isUserScrolling) {
      return false;
    }
    if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _setPreviewIndex(_centeredLyricIndex(notification.metrics));
    } else if (notification is ScrollEndNotification) {
      _schedulePreviewReset();
    }
    return false;
  }

  void _handleLyricPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && !_isUserScrolling) {
      setState(() => _isUserScrolling = true);
      _schedulePreviewReset();
    }
  }

  int _centeredLyricIndex(ScrollMetrics metrics) {
    return (metrics.pixels / _lyricLineExtent).round().clamp(
      0,
      _timeline.length - 1,
    );
  }

  void _setPreviewIndex(int index) {
    if (!_isUserScrolling || _previewIndex != index) {
      setState(() {
        _isUserScrolling = true;
        _previewIndex = index;
      });
    }
    _schedulePreviewReset();
  }

  void _selectLyric(int index) {
    _setPreviewIndex(index);
  }

  void _schedulePreviewReset() {
    _previewResetTimer?.cancel();
    if (!_isUserScrolling || _previewIndex == null) {
      return;
    }
    _previewResetTimer = Timer(_lyricPreviewTimeout, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _isUserScrolling = false;
        _previewIndex = null;
        _lastScrolledIndex = null;
      });
    });
  }

  void _confirmLyricSeek(int index) {
    _previewResetTimer?.cancel();
    unawaited(_seekToLyric(index));
  }

  Future<void> _seekToLyric(int index) async {
    await widget.controller.player.seek(_timeline[index].time);
    if (!mounted) {
      return;
    }
    setState(() {
      _isUserScrolling = false;
      _previewIndex = null;
      _lastScrolledIndex = null;
    });
  }
}

class _PlainLyricsList extends StatelessWidget {
  const _PlainLyricsList({required this.lines, required this.hasLyrics});

  final List<String> lines;
  final bool hasLyrics;

  @override
  Widget build(BuildContext context) {
    if (!hasLyrics) {
      return Center(
        child: Text(
          '暂无歌词',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 72),
      itemBuilder: (context, index) {
        final selected = index == 0;
        return Text(
          lines[index],
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        );
      },
      separatorBuilder: (context, index) => const SizedBox(height: 14),
      itemCount: lines.length,
    );
  }
}

class _TimedLyricLine extends StatelessWidget {
  const _TimedLyricLine({
    super.key,
    required this.text,
    required this.selected,
    required this.showSeekButton,
    required this.onTap,
    required this.onSeek,
  });

  final String text;
  final bool selected;
  final bool showSeekButton;
  final VoidCallback onTap;
  final VoidCallback onSeek;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onTap,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                style:
                    Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: selected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.62,
                            ),
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                      fontSize: selected ? 20 : 17,
                    ) ??
                    TextStyle(
                      color: selected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    ),
                child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 40,
          height: 40,
          child: showSeekButton
              ? IconButton(
                  key: const ValueKey('lyric-seek-button'),
                  tooltip: '从这句播放',
                  onPressed: onSeek,
                  icon: const Icon(Icons.play_arrow_rounded),
                  color: colorScheme.primary,
                  iconSize: 24,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                )
              : null,
        ),
      ],
    );
  }
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final queue = controller.player.queue;
    final current = controller.player.currentTrack;
    final isRadioQueue = current != null && isRadioTrack(current);
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('queue-side-panel'),
      color: Colors.transparent,
      child: SizedBox(
        width: 360,
        child: ClipRRect(
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(18),
          ),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Column(
              children: [
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _glassFillColor(
                        context,
                        lightAlpha: 0.92,
                        darkAlpha: 0.78,
                      ),
                      border: Border.all(color: _glassBorderColor(context)),
                      boxShadow: _glassShadow(context),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
                          child: Row(
                            children: [
                              Text(
                                isRadioQueue ? '电台频道' : '播放队列',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: '关闭',
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: _glassBorderColor(context)),
                        Expanded(
                          child: queue.isEmpty
                              ? Center(
                                  child: Text(
                                    '暂无播放队列',
                                    style: TextStyle(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  itemBuilder: (context, index) {
                                    final track = queue[index];
                                    final isCurrent = current?.id == track.id;
                                    return GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onSecondaryTapDown: isRadioQueue
                                          ? null
                                          : (details) => _showQueueTrackMenu(
                                              context,
                                              details.globalPosition,
                                              track,
                                            ),
                                      child: Material(
                                        color: Colors.transparent,
                                        child: ListTile(
                                          dense: true,
                                          visualDensity: VisualDensity.compact,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 2,
                                              ),
                                          horizontalTitleGap: 10,
                                          selected: isCurrent,
                                          leading: _TrackArtwork(
                                            track: track,
                                            size: 38,
                                          ),
                                          title: _TrackTitle(
                                            track: track,
                                            compact: true,
                                            textStyle: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: isCurrent
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                                ),
                                          ),
                                          subtitle: Text(
                                            track.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              _FavoriteTrackButton(
                                                controller: controller,
                                                track: track,
                                                compact: true,
                                              ),
                                              if (isCurrent)
                                                const Padding(
                                                  padding: EdgeInsets.only(
                                                    left: 2,
                                                  ),
                                                  child: Icon(Icons.graphic_eq),
                                                ),
                                            ],
                                          ),
                                          onTap: () {
                                            Navigator.of(context).pop();
                                            controller.playTrackList(
                                              queue,
                                              index,
                                            );
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                  separatorBuilder: (context, index) => Divider(
                                    height: 1,
                                    color: _glassBorderColor(context),
                                  ),
                                  itemCount: queue.length,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showQueueTrackMenu(
    BuildContext context,
    Offset position,
    Track track,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: 'play_next',
          child: ListTile(
            leading: Icon(Icons.queue_play_next_rounded),
            title: Text('下一首播放'),
          ),
        ),
      ],
    );
    if (!context.mounted || action != 'play_next') {
      return;
    }
    await controller.playTrackNext(track);
    if (context.mounted) {
      _showSourceMessage(context, controller.statusMessage ?? '已设为下一首播放。');
    }
  }
}

Future<void> _showQueueSheet(BuildContext context, AppController controller) {
  if (controller.isLibraryShuffleActive) {
    return Future<void>.value();
  }
  final barrierLabel = MaterialLocalizations.of(
    context,
  ).modalBarrierDismissLabel;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) {
      return SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 56,
              right: 0,
              bottom: 72,
              child: _QueueSheet(controller: controller),
            ),
          ],
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.08, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.controller,
    required this.reduceArtworkMotion,
    required this.onArtworkTap,
    required this.volume,
    required this.onVolumeChanged,
    required this.onMuteToggle,
  });

  final AppController controller;
  final bool reduceArtworkMotion;
  final VoidCallback? onArtworkTap;
  final double volume;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onMuteToggle;

  @override
  Widget build(BuildContext context) {
    final player = controller.player;
    final track = player.currentTrack;
    final isPhoneShell =
        MediaQuery.sizeOf(context).width < _mobilePlayerWidthBreakpoint;
    final content = SafeArea(
      top: false,
      child: Padding(
        padding: isPhoneShell
            ? const EdgeInsets.fromLTRB(16, 6, 16, 10)
            : const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: track == null
            ? const SizedBox(height: 56, child: Center(child: Text('暂无播放内容')))
            : isPhoneShell
            ? _mobileMiniPlayer(context)
            : StreamBuilder<Duration>(
                stream: player.positionStream,
                initialData: player.position,
                builder: (context, snapshot) {
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final position = snapshot.data ?? Duration.zero;
                      final isWide = constraints.maxWidth >= 1040;
                      return isWide
                          ? _widePlayer(context, position)
                          : _narrowPlayer(context, position);
                    },
                  );
                },
              ),
      ),
    );
    if (isPhoneShell) {
      return content;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glassContent = DecoratedBox(
      decoration: BoxDecoration(
        color: _glassFillColor(context, lightAlpha: 0.42, darkAlpha: 0.28),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: isDark ? 0.18 : 0.72),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.1),
            blurRadius: 18,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: content,
    );
    if (reduceArtworkMotion) {
      return glassContent;
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: glassContent,
      ),
    );
  }

  Widget _widePlayer(BuildContext context, Duration position) {
    final player = controller.player;
    final track = player.currentTrack!;

    return Row(
      children: [
        _PlayerArtworkButton(track: track, onTap: onArtworkTap),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: _TrackText(track: track)),
        const SizedBox(width: 6),
        _FavoriteTrackButton(controller: controller, track: track),
        const SizedBox(width: 8),
        _TransportControls(controller: controller),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: _SeekBar(controller: controller, position: position),
        ),
        const SizedBox(width: 12),
        _QueueButton(controller: controller, extended: true),
        const SizedBox(width: 12),
        _VolumeControl(
          volume: volume,
          onChanged: onVolumeChanged,
          onMuteToggle: onMuteToggle,
        ),
      ],
    );
  }

  Widget _narrowPlayer(BuildContext context, Duration position) {
    final track = controller.player.currentTrack!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _PlayerArtworkButton(track: track, onTap: onArtworkTap),
            const SizedBox(width: 12),
            Expanded(child: _TrackText(track: track)),
            _FavoriteTrackButton(controller: controller, track: track),
            const SizedBox(width: 4),
            _TransportControls(controller: controller),
            const SizedBox(width: 4),
            _QueueButton(controller: controller),
            const SizedBox(width: 4),
            _VolumeControl(
              volume: volume,
              onChanged: onVolumeChanged,
              onMuteToggle: onMuteToggle,
            ),
          ],
        ),
        const SizedBox(height: 8),
        _SeekBar(controller: controller, position: position),
      ],
    );
  }

  Widget _mobileMiniPlayer(BuildContext context) {
    final track = controller.player.currentTrack!;
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: '播放详情',
      child: InkWell(
        onTap: onArtworkTap,
        borderRadius: BorderRadius.circular(28),
        child: SizedBox(
          height: 56,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: _glassBorderColor(context)),
                    boxShadow: _glassShadow(context),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 6, 8),
                child: Row(
                  children: [
                    _RotatingMiniArtwork(
                      track: track,
                      playing: controller.player.isPlaying,
                      animate: !reduceArtworkMotion,
                      size: 40,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _TrackTitle(
                            track: track,
                            compact: true,
                            textStyle: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: colorScheme.onPrimaryContainer,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: colorScheme.onPrimaryContainer
                                      .withValues(alpha: 0.78),
                                ),
                          ),
                        ],
                      ),
                    ),
                    _FavoriteTrackButton(
                      controller: controller,
                      track: track,
                      compact: true,
                    ),
                    IconButton(
                      tooltip: controller.player.isPlaying ? '暂停' : '播放',
                      constraints: const BoxConstraints.tightFor(
                        width: 38,
                        height: 38,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 24,
                      onPressed: controller.player.currentTrack == null
                          ? null
                          : controller.player.togglePlay,
                      icon: Icon(
                        controller.player.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                    if (controller.isLibraryShuffleActive)
                      IconButton(
                        tooltip: '下一首',
                        constraints: const BoxConstraints.tightFor(
                          width: 38,
                          height: 38,
                        ),
                        padding: EdgeInsets.zero,
                        iconSize: 24,
                        onPressed: controller.player.canSkipNext
                            ? controller.player.playNext
                            : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      )
                    else
                      _QueueButton(controller: controller, compact: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RotatingMiniArtwork extends StatefulWidget {
  const _RotatingMiniArtwork({
    required this.track,
    required this.playing,
    required this.animate,
    required this.size,
  });

  final Track track;
  final bool playing;
  final bool animate;
  final double size;

  @override
  State<_RotatingMiniArtwork> createState() => _RotatingMiniArtworkState();
}

class _RotatingMiniArtworkState extends State<_RotatingMiniArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _RotatingMiniArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.animate != widget.animate) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.playing && widget.animate) {
      _controller.repeat();
    } else {
      _controller.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      key: const ValueKey('mobile-mini-artwork-rotation'),
      turns: _controller,
      child: _TrackArtwork(
        track: widget.track,
        size: widget.size,
        circle: true,
      ),
    );
  }
}

class _FavoriteTrackButton extends StatelessWidget {
  const _FavoriteTrackButton({
    required this.controller,
    required this.track,
    this.compact = false,
  });

  final AppController controller;
  final Track track;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isFavorite = controller.isFavoriteTrack(track);
    final isFavoriteToggling = controller.isFavoriteTrackToggling(track);
    final canFavorite = controller.canFavoriteTrack(track);
    final size = compact ? 34.0 : 40.0;
    return IconButton(
      tooltip: isRadioTrack(track)
          ? '电台不支持收藏'
          : _favoriteTrackTooltip(isFavorite, isFavoriteToggling),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      iconSize: compact ? 20 : 22,
      onPressed: canFavorite
          ? () => unawaited(controller.toggleFavoriteTrack(track))
          : null,
      icon: _FavoriteHeartIcon(
        isFavorite: isFavorite,
        isToggling: isFavoriteToggling,
        iconSize: compact ? 20 : 22,
      ),
    );
  }
}

String _favoriteTrackTooltip(bool isFavorite, bool isToggling) {
  if (isToggling) {
    return isFavorite ? '正在取消收藏' : '正在收藏';
  }
  return isFavorite ? '取消收藏' : '收藏';
}

class _FavoriteHeartIcon extends StatefulWidget {
  const _FavoriteHeartIcon({
    required this.isFavorite,
    required this.isToggling,
    required this.iconSize,
  });

  final bool isFavorite;
  final bool isToggling;
  final double iconSize;

  @override
  State<_FavoriteHeartIcon> createState() => _FavoriteHeartIconState();
}

class _FavoriteHeartIconState extends State<_FavoriteHeartIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 650),
      value: widget.isFavorite ? 1 : 0,
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(covariant _FavoriteHeartIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final targetFill = widget.isToggling
        ? (widget.isFavorite ? 0.0 : 1.0)
        : (widget.isFavorite ? 1.0 : 0.0);
    if ((_controller.value - targetFill).abs() < 0.001) {
      return;
    }
    unawaited(_controller.animateTo(targetFill, curve: Curves.easeInOutCubic));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ?? Theme.of(context).iconTheme.color;
    final heartColor = color ?? Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final fillFraction = _controller.value.clamp(0.0, 1.0);
        return SizedBox.square(
          dimension: widget.iconSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                Icons.favorite_border,
                size: widget.iconSize,
                color: heartColor.withValues(alpha: 0.76),
              ),
              ClipRect(
                clipper: _FavoriteFillClipper(fillFraction),
                child: Icon(
                  Icons.favorite,
                  size: widget.iconSize,
                  color: heartColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FavoriteFillClipper extends CustomClipper<Rect> {
  const _FavoriteFillClipper(this.fillFraction);

  final double fillFraction;

  @override
  Rect getClip(Size size) {
    final fill = fillFraction.clamp(0.0, 1.0);
    return Rect.fromLTWH(
      0,
      size.height * (1 - fill),
      size.width,
      size.height * fill,
    );
  }

  @override
  bool shouldReclip(covariant _FavoriteFillClipper oldClipper) {
    return oldClipper.fillFraction != fillFraction;
  }
}

class _QueueButton extends StatelessWidget {
  const _QueueButton({
    required this.controller,
    this.extended = false,
    this.compact = false,
  });

  final AppController controller;
  final bool extended;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const tooltip = '列表';
    if (controller.isLibraryShuffleActive) {
      return SizedBox(
        width: compact
            ? 38
            : extended
            ? 52
            : 48,
        height: compact ? 38 : 42,
      );
    }
    if (extended) {
      return Tooltip(
        message: tooltip,
        child: IconButton(
          constraints: BoxConstraints.tightFor(
            width: compact ? 38 : 52,
            height: compact ? 38 : 42,
          ),
          padding: EdgeInsets.zero,
          iconSize: compact ? 22 : 24,
          onPressed: () => _showQueueSheet(context, controller),
          icon: const Icon(Icons.queue_music_outlined),
        ),
      );
    }
    return IconButton(
      tooltip: tooltip,
      constraints: compact
          ? const BoxConstraints.tightFor(width: 38, height: 38)
          : null,
      padding: compact ? EdgeInsets.zero : null,
      iconSize: compact ? 22 : null,
      onPressed: () => _showQueueSheet(context, controller),
      icon: const Icon(Icons.queue_music_outlined),
    );
  }
}

class _VolumeControl extends StatefulWidget {
  const _VolumeControl({
    required this.volume,
    required this.onChanged,
    required this.onMuteToggle,
  });

  final double volume;
  final ValueChanged<double> onChanged;
  final VoidCallback onMuteToggle;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  Timer? _hideTimer;
  bool _targetHovered = false;
  bool _overlayHovered = false;

  @override
  void didUpdateWidget(covariant _VolumeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    final overlayEntry = _overlayEntry;
    if (overlayEntry == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_overlayEntry, overlayEntry)) {
        overlayEntry.markNeedsBuild();
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hideOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          _targetHovered = true;
          _hideTimer?.cancel();
          _showOverlay();
        },
        onExit: (_) {
          _targetHovered = false;
          _scheduleHideOverlay();
        },
        child: IconButton(
          tooltip: widget.volume <= 0 ? '取消静音' : '静音',
          onPressed: widget.onMuteToggle,
          icon: Icon(_volumeIcon(widget.volume)),
        ),
      ),
    );
  }

  void _showOverlay() {
    if (_overlayEntry != null) {
      return;
    }
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned.fill(
          child: IgnorePointer(
            ignoring: false,
            child: Stack(
              children: [
                CompositedTransformFollower(
                  link: _layerLink,
                  showWhenUnlinked: false,
                  offset: const Offset(-6, -212),
                  child: MouseRegion(
                    onEnter: (_) {
                      _overlayHovered = true;
                      _hideTimer?.cancel();
                    },
                    onExit: (_) {
                      _overlayHovered = false;
                      _scheduleHideOverlay();
                    },
                    child: Material(
                      color: Colors.transparent,
                      child: _GlassSurface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        darkAlpha: 0.32,
                        child: SizedBox(
                          key: const ValueKey('desktop-volume-slider-panel'),
                          width: 44,
                          height: 196,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${(widget.volume * 100).round()}%',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: RotatedBox(
                                  quarterTurns: -1,
                                  child: Slider(
                                    value: widget.volume.clamp(0.0, 1.0),
                                    onChanged: widget.onChanged,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    overlay.insert(_overlayEntry!);
  }

  void _scheduleHideOverlay() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 180), () {
      if (!_targetHovered && !_overlayHovered) {
        _hideOverlay();
      }
    });
  }

  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }
}

IconData _volumeIcon(double volume) {
  if (volume <= 0) {
    return Icons.volume_off_outlined;
  }
  if (volume < 0.45) {
    return Icons.volume_down_outlined;
  }
  return Icons.volume_up_outlined;
}

class _TrackText extends StatelessWidget {
  const _TrackText({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final audioFormat = track.audioFormat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              fit: FlexFit.loose,
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (audioFormat != null && audioFormat.isNotEmpty) ...[
              const SizedBox(width: 8),
              _AudioFormatChip(format: audioFormat),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(
          track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _TransportControls extends StatelessWidget {
  const _TransportControls({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final player = controller.player;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PlaybackModeButton(controller: controller),
        IconButton(
          tooltip: '上一首',
          onPressed: player.canSkipPrevious ? player.playPrevious : null,
          icon: const Icon(Icons.skip_previous),
        ),
        IconButton.filled(
          tooltip: player.isPlaying ? '暂停' : '播放',
          onPressed: player.currentTrack == null ? null : player.togglePlay,
          icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        IconButton(
          tooltip: '下一首',
          onPressed: player.canSkipNext ? player.playNext : null,
          icon: const Icon(Icons.skip_next),
        ),
      ],
    );
  }
}

class _PlaybackModeButton extends StatelessWidget {
  const _PlaybackModeButton({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final player = controller.player;
    final playbackMode = controller.isLibraryShuffleActive
        ? PlaybackMode.shuffle
        : player.playbackMode;
    final currentTrack = player.currentTrack;
    final disabled =
        controller.isLibraryShuffleActive ||
        (currentTrack != null && isRadioTrack(currentTrack));
    return IconButton(
      tooltip: _playbackModeTooltip(playbackMode),
      onPressed: disabled
          ? null
          : () => player.setPlaybackMode(_nextPlaybackMode(playbackMode)),
      icon: _PlaybackModeIcon(mode: playbackMode),
    );
  }
}

PlaybackMode _nextPlaybackMode(PlaybackMode mode) {
  return switch (mode) {
    PlaybackMode.sequential => PlaybackMode.shuffle,
    PlaybackMode.shuffle => PlaybackMode.repeatOne,
    PlaybackMode.repeatOne => PlaybackMode.repeatAll,
    PlaybackMode.repeatAll => PlaybackMode.sequential,
  };
}

class _PlaybackModeIcon extends StatelessWidget {
  const _PlaybackModeIcon({required this.mode});

  final PlaybackMode mode;

  @override
  Widget build(BuildContext context) {
    if (mode != PlaybackMode.sequential) {
      return Icon(_playbackModeIcon(mode));
    }

    final iconTheme = IconTheme.of(context);
    final size = iconTheme.size ?? 24;
    final color = iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      key: const ValueKey('sequential-playback-icon'),
      width: size,
      height: size,
      child: CustomPaint(painter: _SequentialPlaybackIconPainter(color: color)),
    );
  }
}

class _SequentialPlaybackIconPainter extends CustomPainter {
  const _SequentialPlaybackIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (size.shortestSide * 0.095).clamp(1.8, 2.2)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    void drawArrow(double y) {
      final start = Offset(size.width * 0.18, y);
      final tip = Offset(size.width * 0.78, y);
      final headX = size.width * 0.62;
      final headY = size.height * 0.12;
      canvas
        ..drawLine(start, tip, paint)
        ..drawLine(tip, Offset(headX, y - headY), paint)
        ..drawLine(tip, Offset(headX, y + headY), paint);
    }

    drawArrow(size.height * 0.36);
    drawArrow(size.height * 0.64);
  }

  @override
  bool shouldRepaint(_SequentialPlaybackIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

IconData _playbackModeIcon(PlaybackMode mode) {
  return switch (mode) {
    PlaybackMode.sequential => Icons.arrow_forward,
    PlaybackMode.shuffle => Icons.shuffle,
    PlaybackMode.repeatOne => Icons.repeat_one,
    PlaybackMode.repeatAll => Icons.repeat,
  };
}

String _playbackModeTooltip(PlaybackMode mode) {
  return switch (mode) {
    PlaybackMode.sequential => '顺序播放',
    PlaybackMode.shuffle => '随机播放',
    PlaybackMode.repeatOne => '单曲循环',
    PlaybackMode.repeatAll => '列表循环',
  };
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.controller, required this.position});

  static const double _thumbIndicatorSize = 22;
  static const double _sliderHorizontalInset = 24;

  final AppController controller;
  final Duration position;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final player = widget.controller.player;
    final currentTrack = player.currentTrack;
    final isRadio = currentTrack != null && isRadioTrack(currentTrack);
    final duration = isRadio ? null : player.duration;
    final isBuffering = !isRadio && player.isBuffering;
    final maxMs = duration == null || duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final positionMs = isRadio
        ? 0.0
        : widget.position.inMilliseconds.toDouble();
    final currentValue = positionMs < 0
        ? 0.0
        : (positionMs > maxMs ? maxMs : positionMs);
    final dragValue = _dragValue;
    final value = dragValue == null
        ? currentValue
        : dragValue.clamp(0.0, maxMs).toDouble();
    final displayPosition = Duration(milliseconds: value.round());

    return Row(
      key: const ValueKey('player-seek-bar'),
      children: [
        Text(_formatDuration(displayPosition)),
        Expanded(
          child: StreamBuilder<Duration>(
            stream: widget.controller.player.bufferedPositionStream,
            initialData: widget.controller.player.bufferedPosition,
            builder: (context, snapshot) {
              final bufferedPosition = snapshot.data ?? Duration.zero;
              final bufferedMs = bufferedPosition.inMilliseconds
                  .toDouble()
                  .clamp(0.0, maxMs);

              return LayoutBuilder(
                builder: (context, constraints) {
                  final ratio = maxMs <= 0
                      ? 0.0
                      : (value / maxMs).clamp(0.0, 1.0);
                  final trackWidth =
                      constraints.maxWidth -
                      _SeekBar._sliderHorizontalInset * 2;
                  final usableTrackWidth = trackWidth.clamp(
                    0.0,
                    double.infinity,
                  );
                  final maxLeft =
                      constraints.maxWidth <= _SeekBar._thumbIndicatorSize
                      ? 0.0
                      : constraints.maxWidth - _SeekBar._thumbIndicatorSize;
                  final left =
                      (_SeekBar._sliderHorizontalInset +
                              usableTrackWidth * ratio -
                              _SeekBar._thumbIndicatorSize / 2)
                          .clamp(0.0, maxLeft);
                  final colorScheme = Theme.of(context).colorScheme;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final trackBaseColor = colorScheme.onSurface.withValues(
                    alpha: isDark ? 0.22 : 0.16,
                  );
                  final bufferedTrackColor = colorScheme.primary.withValues(
                    alpha: isDark ? 0.45 : 0.32,
                  );
                  final playedTrackColor = colorScheme.primary;

                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: playedTrackColor,
                          inactiveTrackColor: trackBaseColor,
                          secondaryActiveTrackColor: bufferedTrackColor,
                          disabledActiveTrackColor: playedTrackColor.withValues(
                            alpha: 0.38,
                          ),
                          disabledInactiveTrackColor: trackBaseColor,
                          disabledSecondaryActiveTrackColor: bufferedTrackColor
                              .withValues(alpha: 0.38),
                          trackHeight: 5,
                        ),
                        child: Slider(
                          value: value,
                          max: maxMs,
                          secondaryTrackValue: isRadio || duration == null
                              ? null
                              : bufferedMs,
                          onChanged: isRadio || duration == null
                              ? null
                              : (value) => setState(() {
                                  _dragValue = value;
                                }),
                          onChangeEnd: isRadio || duration == null
                              ? null
                              : (value) {
                                  setState(() => _dragValue = null);
                                  unawaited(
                                    widget.controller.player.seek(
                                      Duration(milliseconds: value.round()),
                                    ),
                                  );
                                },
                        ),
                      ),
                      if (isBuffering)
                        Positioned(
                          left: left,
                          top: 0,
                          bottom: 0,
                          width: _SeekBar._thumbIndicatorSize,
                          child: const IgnorePointer(
                            child: Center(
                              child: _BufferingThumbIndicator(
                                size: _SeekBar._thumbIndicatorSize,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
        Text(_formatDuration(isRadio ? Duration.zero : duration)),
      ],
    );
  }
}

class _BufferingThumbIndicator extends StatefulWidget {
  const _BufferingThumbIndicator({required this.size});

  final double size;

  @override
  State<_BufferingThumbIndicator> createState() =>
      _BufferingThumbIndicatorState();
}

class _BufferingThumbIndicatorState extends State<_BufferingThumbIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : colorScheme.onPrimary;
    final fill = isDark
        ? Colors.black.withValues(alpha: 0.72)
        : colorScheme.primary;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: foreground.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SizedBox.square(
        dimension: widget.size,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: RotationTransition(
            turns: _rotationController,
            child: CustomPaint(
              painter: _SegmentedLoadingPainter(color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

class _SegmentedLoadingPainter extends CustomPainter {
  const _SegmentedLoadingPainter({required this.color});

  static const int _segments = 12;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final shortestSide = math.min(size.width, size.height);
    final innerRadius = shortestSide * 0.26;
    final outerRadius = shortestSide * 0.46;
    final strokeWidth = shortestSide * 0.11;

    for (var index = 0; index < _segments; index += 1) {
      final angle = -math.pi / 2 + index * 2 * math.pi / _segments;
      final alpha = (1 - index / _segments).clamp(0.24, 1.0);
      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = strokeWidth;
      final start = Offset(
        center.dx + math.cos(angle) * innerRadius,
        center.dy + math.sin(angle) * innerRadius,
      );
      final end = Offset(
        center.dx + math.cos(angle) * outerRadius,
        center.dy + math.sin(angle) * outerRadius,
      );
      canvas.drawLine(start, end, paint);
    }
  }

  @override
  bool shouldRepaint(_SegmentedLoadingPainter oldDelegate) {
    return oldDelegate.color != color;
  }

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) {
    return '_SegmentedLoadingPainter(segments: $_segments)';
  }
}

// Legacy source editor retained only for old stored-data migration tests.
// ignore: unused_element
class _SourceManagerPanel extends StatelessWidget {
  const _SourceManagerPanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    final showAddLocalSource =
        Theme.of(context).platform != TargetPlatform.android;
    final actionButtons = _SourceManagerActionButtons(
      onImportFromText: () => _importFromText(context),
      onAddServer: () => _addServer(context),
      onAddLocalSource: showAddLocalSource
          ? () => _addLocalSource(context)
          : null,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(12, compact ? 2 : 4, 12, compact ? 10 : 12),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final sourceList = controller.servers.isEmpty
              ? Padding(
                  padding: EdgeInsets.fromLTRB(4, compact ? 4 : 8, 4, 4),
                  child: Text(
                    '还没有音源。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : RadioGroup<String>(
                  groupValue: controller.selectedServer?.id,
                  onChanged: (serverId) {
                    if (serverId != null) {
                      controller.selectServer(serverId);
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: controller.servers.map((server) {
                      return _SourceListItem(
                        server: server,
                        compact: compact,
                        isBusy: controller.isBusy,
                        onSelected: () => controller.selectServer(server.id),
                        onTest: () => _testServer(context, server),
                        onExport: () => _exportText(context, server),
                        onEdit: () => _editServer(context, server),
                        onDelete: () => controller.removeServer(server.id),
                      );
                    }).toList(),
                  ),
                );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '音源',
                    style: compact
                        ? Theme.of(context).textTheme.titleSmall
                        : Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: actionButtons,
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 12 : 10),
              sourceList,
            ],
          );
        },
      ),
    );
  }

  Future<void> _testServer(BuildContext context, ServerConfig server) async {
    await controller.testServer(server);
    if (context.mounted) {
      _showSourceMessage(context, controller.statusMessage ?? '测试完成。');
    }
  }

  Future<void> _addServer(BuildContext context) async {
    final result = await showDialog<ServerConfig>(
      context: context,
      builder: (context) => _ServerDialog(controller: controller),
    );
    if (result != null) {
      await controller.saveServer(result);
    }
  }

  Future<void> _addLocalSource(BuildContext context) async {
    final result = await showDialog<ServerConfig>(
      context: context,
      builder: (context) => const _LocalSourceDialog(),
    );
    if (result != null) {
      await controller.saveServer(result);
    }
  }

  Future<void> _editServer(BuildContext context, ServerConfig server) async {
    final result = await showDialog<ServerConfig>(
      context: context,
      builder: (context) => server.isLocalFolder
          ? _LocalSourceDialog(initial: server)
          : _ServerDialog(controller: controller, initial: server),
    );
    if (result != null) {
      await controller.saveServer(result, previousId: server.id);
    }
  }

  Future<void> _importFromText(BuildContext context) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => const _SourceConfigTextDialog(),
    );
    if (value == null || value.trim().isEmpty) {
      return;
    }
    try {
      final count = await controller.importServerConfigText(value);
      if (context.mounted) {
        _showSourceMessage(context, '已导入 $count 个音源。');
      }
    } catch (error) {
      if (context.mounted) {
        _showSourceMessage(context, _formatError(error));
      }
    }
  }

  Future<void> _exportText(BuildContext context, ServerConfig server) async {
    try {
      final value = controller.exportSingleServerConfigText(server);
      await Clipboard.setData(ClipboardData(text: value));
      if (context.mounted) {
        _showSourceMessage(context, '已复制到剪贴板。');
      }
    } catch (error) {
      if (context.mounted) {
        _showSourceMessage(context, _formatError(error));
      }
    }
  }
}

class _SourceManagerActionButtons extends StatelessWidget {
  const _SourceManagerActionButtons({
    required this.onImportFromText,
    required this.onAddServer,
    required this.onAddLocalSource,
  });

  final VoidCallback onImportFromText;
  final VoidCallback onAddServer;
  final VoidCallback? onAddLocalSource;

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.symmetric(horizontal: 8, vertical: 4);
    final textButtonStyle = TextButton.styleFrom(
      minimumSize: Size.zero,
      padding: padding,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    final filledButtonStyle = FilledButton.styleFrom(
      minimumSize: Size.zero,
      padding: padding,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: onImportFromText,
            style: textButtonStyle,
            icon: const Icon(Icons.content_paste_outlined, size: 18),
            label: const Text('导入'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: onAddServer,
            style: filledButtonStyle,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加'),
          ),
          if (onAddLocalSource != null) ...[
            const SizedBox(width: 4),
            FilledButton.tonalIcon(
              onPressed: onAddLocalSource,
              style: filledButtonStyle,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('添加'),
            ),
          ],
        ],
      ),
    );
  }
}

const _imageTypeGroup = XTypeGroup(
  label: '图片文件',
  extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
);
const double _androidHdWidthBreakpoint = 510;
const double _mobilePlayerWidthBreakpoint = 600;

void _showSourceMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    return;
  }
  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(duration: const Duration(seconds: 2), content: Text(message)),
    );
}

bool _isPhoneWidth(BuildContext context) {
  return MediaQuery.sizeOf(context).width < _androidHdWidthBreakpoint;
}

bool _usesAndroidPhoneBackGesture(double width) {
  return defaultTargetPlatform == TargetPlatform.android &&
      width < _mobilePlayerWidthBreakpoint;
}

bool _supportsDesktopSettings(TargetPlatform platform) {
  return platform == TargetPlatform.windows ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.linux;
}

bool _usesDesktopHomeTabs(BuildContext context) {
  return _supportsDesktopSettings(defaultTargetPlatform) &&
      MediaQuery.sizeOf(context).width >= 760;
}

EdgeInsets _responsiveDialogInsetPadding(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < _androidHdWidthBreakpoint) {
    return const EdgeInsets.symmetric(horizontal: 12, vertical: 18);
  }
  if (width < _mobilePlayerWidthBreakpoint) {
    return const EdgeInsets.symmetric(horizontal: 24, vertical: 22);
  }
  return EdgeInsets.symmetric(horizontal: 40, vertical: 24);
}

BoxConstraints _responsiveDialogConstraints(
  BuildContext context, {
  required double maxWidth,
  double maxHeightFactor = 0.72,
}) {
  final size = MediaQuery.sizeOf(context);
  final inset = _responsiveDialogInsetPadding(context);
  return BoxConstraints(
    maxWidth: math.max(240, math.min(maxWidth, size.width - inset.horizontal)),
    maxHeight: math.max(280, size.height * maxHeightFactor),
  );
}

String _formatError(Object error) {
  return error
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('FormatException: ', '');
}

class _SourceConfigTextDialog extends StatefulWidget {
  const _SourceConfigTextDialog();

  @override
  State<_SourceConfigTextDialog> createState() =>
      _SourceConfigTextDialogState();
}

class _SourceConfigTextDialogState extends State<_SourceConfigTextDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: _responsiveDialogInsetPadding(context),
      title: const Text('导入'),
      content: ConstrainedBox(
        constraints: _responsiveDialogConstraints(context, maxWidth: 560),
        child: TextField(
          controller: _controller,
          minLines: 8,
          maxLines: 12,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '粘贴 base64 编码后的音源配置',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('导入'),
        ),
      ],
    );
  }
}

class _SourceListItem extends StatelessWidget {
  const _SourceListItem({
    required this.server,
    required this.compact,
    required this.isBusy,
    required this.onSelected,
    required this.onTest,
    required this.onExport,
    required this.onEdit,
    required this.onDelete,
  });

  final ServerConfig server;
  final bool compact;
  final bool isBusy;
  final VoidCallback onSelected;
  final Future<void> Function() onTest;
  final Future<void> Function() onExport;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitle = _serverSubtitle(server);
    if (!compact) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Radio<String>(value: server.id),
        title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: _SourceActionRow(
          isBusy: isBusy,
          onTest: onTest,
          onExport: onExport,
          onEdit: onEdit,
          onDelete: onDelete,
        ),
        onTap: onSelected,
      );
    }

    return InkWell(
      onTap: onSelected,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 36,
                  child: Radio<String>(
                    value: server.id,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          server.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _SourceActionRow(
                isBusy: isBusy,
                compact: true,
                onTest: onTest,
                onExport: onExport,
                onEdit: onEdit,
                onDelete: onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceActionRow extends StatefulWidget {
  const _SourceActionRow({
    required this.isBusy,
    required this.onTest,
    required this.onExport,
    required this.onEdit,
    required this.onDelete,
    this.compact = false,
  });

  final bool isBusy;
  final Future<void> Function() onTest;
  final Future<void> Function() onExport;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool compact;

  @override
  State<_SourceActionRow> createState() => _SourceActionRowState();
}

class _SourceActionRowState extends State<_SourceActionRow> {
  Timer? _exportFeedbackTimer;
  bool _exportCopied = false;

  @override
  void dispose() {
    _exportFeedbackTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleExport() async {
    await widget.onExport();
    if (!mounted) {
      return;
    }
    setState(() => _exportCopied = true);
    _exportFeedbackTimer?.cancel();
    _exportFeedbackTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _exportCopied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _sourceIconButton(
          tooltip: '测试连接',
          compact: widget.compact,
          onPressed: widget.isBusy
              ? null
              : () async {
                  await widget.onTest();
                },
          icon: Icons.wifi_tethering,
        ),
        _sourceIconButton(
          tooltip: '导出',
          compact: widget.compact,
          onPressed: () => unawaited(_handleExport()),
          icon: _exportCopied ? Icons.check : Icons.copy_all_outlined,
        ),
        _sourceIconButton(
          tooltip: '编辑',
          compact: widget.compact,
          onPressed: widget.onEdit,
          icon: Icons.edit_outlined,
        ),
        _sourceIconButton(
          tooltip: '删除',
          compact: widget.compact,
          onPressed: widget.onDelete,
          icon: Icons.delete_outline,
        ),
      ],
    );
  }
}

Widget _sourceIconButton({
  required String tooltip,
  required VoidCallback? onPressed,
  required IconData icon,
  bool compact = false,
}) {
  final size = compact ? 32.0 : 40.0;
  return SizedBox.square(
    dimension: size,
    child: IconButton(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      onPressed: onPressed,
      iconSize: compact ? 18 : null,
      icon: Icon(icon),
    ),
  );
}

String _serverSubtitle(ServerConfig server) {
  if (server.isLocalFolder) {
    return server.localPath;
  }
  return server.normalizedBaseUrl;
}

class _LocalSourceDialog extends StatefulWidget {
  const _LocalSourceDialog({this.initial});

  final ServerConfig? initial;

  @override
  State<_LocalSourceDialog> createState() => _LocalSourceDialogState();
}

class _LocalSourceDialogState extends State<_LocalSourceDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _pathController;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _pathController = TextEditingController(text: initial?.localPath ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = _isPhoneWidth(context);
    return AlertDialog(
      insetPadding: _responsiveDialogInsetPadding(context),
      title: Text(widget.initial == null ? '添加本地音源' : '编辑本地音源'),
      content: ConstrainedBox(
        constraints: _responsiveDialogConstraints(context, maxWidth: 520),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '名称'),
                  validator: _required,
                ),
                const SizedBox(height: 8),
                if (compact)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _pathController,
                        decoration: const InputDecoration(
                          labelText: '音乐文件夹',
                          hintText: r'D:\Music',
                        ),
                        validator: _localFolder,
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _pickFolder,
                          icon: const Icon(Icons.folder_open_outlined),
                          label: const Text('选择'),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _pathController,
                          decoration: const InputDecoration(
                            labelText: '音乐文件夹',
                            hintText: r'D:\Music',
                          ),
                          validator: _localFolder,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton.icon(
                          onPressed: _pickFolder,
                          icon: const Icon(Icons.folder_open_outlined),
                          label: const Text('选择'),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '保存后会扫描文件夹内的音频文件，并支持在歌曲列表中查看/编辑本地文件元数据。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(
      initialDirectory: _pathController.text.trim().isEmpty
          ? null
          : _pathController.text.trim(),
    );
    if (path == null) {
      return;
    }
    setState(() {
      _pathController.text = path;
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = _folderName(path);
      }
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    Navigator.of(context).pop(_sourceFromFields());
  }

  ServerConfig _sourceFromFields() {
    final localPath = _pathController.text.trim();
    return ServerConfig(
      id: localSourceId(localPath),
      name: _nameController.text.trim(),
      baseUrl: '',
      username: '',
      password: '',
      sourceKind: MusicSourceKind.localFolder,
      localPath: localPath,
    );
  }
}

class _ServerDialog extends StatefulWidget {
  const _ServerDialog({required this.controller, this.initial});

  final AppController controller;
  final ServerConfig? initial;

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _isTesting = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _urlController = TextEditingController(text: initial?.baseUrl ?? '');
    _usernameController = TextEditingController(text: initial?.username ?? '');
    _passwordController = TextEditingController(text: initial?.password ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: _responsiveDialogInsetPadding(context),
      title: Text(widget.initial == null ? '添加音源' : '编辑音源'),
      content: ConstrainedBox(
        constraints: _responsiveDialogConstraints(context, maxWidth: 460),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '名称'),
                  validator: _required,
                ),
                TextFormField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: '服务地址',
                    hintText: 'https://music.example.com',
                  ),
                  keyboardType: TextInputType.url,
                  validator: _url,
                ),
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(labelText: '用户名'),
                  validator: _required,
                ),
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(labelText: '密码'),
                  obscureText: true,
                  validator: _required,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        OutlinedButton.icon(
          onPressed: _isTesting ? null : _testConnection,
          icon: _isTesting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_tethering),
          label: Text(_isTesting ? '测试中' : '测试连接'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isTesting = true;
    });
    await widget.controller.testServer(_serverFromFields());
    if (!mounted) {
      return;
    }
    setState(() {
      _isTesting = false;
    });
    _showSourceMessage(context, widget.controller.statusMessage ?? '测试完成。');
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    Navigator.of(context).pop(_serverFromFields());
  }

  ServerConfig _serverFromFields() {
    final baseUrl = _urlController.text.trim();
    return ServerConfig(
      id: normalizeServerUrl(baseUrl),
      name: _nameController.text.trim(),
      baseUrl: baseUrl,
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
  }
}

String? _required(String? value) {
  if (value == null || value.trim().isEmpty) {
    return '必填';
  }
  return null;
}

String? _url(String? value) {
  final requiredError = _required(value);
  if (requiredError != null) {
    return requiredError;
  }
  final uri = Uri.tryParse(value!.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return '请输入有效 URL';
  }
  return null;
}

String? _localFolder(String? value) {
  final requiredError = _required(value);
  if (requiredError != null) {
    return requiredError;
  }
  final path = value!.trim();
  if (!Directory(path).existsSync()) {
    return '文件夹不存在';
  }
  return null;
}

String _folderName(String path) {
  final parts = path
      .split(RegExp(r'[\\/]'))
      .where((part) => part.trim().isNotEmpty)
      .toList();
  return parts.isEmpty ? '本地音乐' : parts.last;
}

String _formatGb(int bytes) {
  final value = bytes / gb;
  if (value == value.roundToDouble()) {
    return '${value.toStringAsFixed(0)}G';
  }
  return '${value.toStringAsFixed(1)}G';
}

String _formatDuration(Duration? value) {
  if (value == null) {
    return '--:--';
  }

  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (value.inHours > 0) {
    return '${value.inHours}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}
