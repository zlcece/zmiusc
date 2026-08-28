const int gb = 1024 * 1024 * 1024;
const int minCacheSizeBytes = gb ~/ 2;
const int maxCacheSizeBytes = 10 * gb;
const int defaultCacheSizeBytes = 2 * gb;

enum CloseButtonBehavior { exit, minimizeToTray }

enum AppLogLevel { error, warning, info, debug }

enum HomePlaybackSection {
  dailyRecommendation,
  casualListening,
  libraryShuffle,
}

enum HomeShortcutSection {
  favorites,
  myPlaylists,
  publicPlaylists,
  publicRadio,
}

enum HomeDiscoverySection {
  latestAlbums,
  randomAlbums,
  recentAlbums,
  frequentAlbums,
}

const List<HomePlaybackSection> defaultHomePlaybackOrder = [
  HomePlaybackSection.dailyRecommendation,
  HomePlaybackSection.casualListening,
  HomePlaybackSection.libraryShuffle,
];

const List<HomeShortcutSection> defaultHomeShortcutOrder = [
  HomeShortcutSection.favorites,
  HomeShortcutSection.myPlaylists,
  HomeShortcutSection.publicPlaylists,
  HomeShortcutSection.publicRadio,
];

const List<HomeDiscoverySection> defaultHomeDiscoveryOrder = [
  HomeDiscoverySection.latestAlbums,
  HomeDiscoverySection.randomAlbums,
  HomeDiscoverySection.recentAlbums,
  HomeDiscoverySection.frequentAlbums,
];

class AppSettings {
  const AppSettings({
    this.cacheDirectory = '',
    this.cacheSizeBytes = defaultCacheSizeBytes,
    this.logoPath = '',
    this.backgroundPath = '',
    this.trayIconPath = '',
    this.closeButtonBehavior = CloseButtonBehavior.exit,
    this.launchAtStartup = false,
    this.playRandomAfterSequentialQueue = false,
    this.autoPlayDailyRecommendationOnStartup = false,
    this.startupPlaybackSection = HomePlaybackSection.dailyRecommendation,
    this.skipUnplayableTracks = true,
    this.showDailyRecommendation = true,
    this.showCasualListening = true,
    this.showLibraryShuffle = true,
    this.homePlaybackOrder = defaultHomePlaybackOrder,
    this.homeShortcutOrder = defaultHomeShortcutOrder,
    this.hiddenHomeShortcuts = const <HomeShortcutSection>{},
    this.homeDiscoveryOrder = defaultHomeDiscoveryOrder,
    this.hiddenHomeDiscoveries = const <HomeDiscoverySection>{},
    this.showMyPlaylistSection = true,
    this.showPublicPlaylistSection = true,
    this.checkUpdatesOnStartup = true,
    this.logLevel = AppLogLevel.error,
  });

  final String cacheDirectory;
  final int cacheSizeBytes;
  final String logoPath;
  final String backgroundPath;
  final String trayIconPath;
  final CloseButtonBehavior closeButtonBehavior;
  final bool launchAtStartup;
  final bool playRandomAfterSequentialQueue;
  final bool autoPlayDailyRecommendationOnStartup;
  final HomePlaybackSection startupPlaybackSection;
  final bool skipUnplayableTracks;
  final bool showDailyRecommendation;
  final bool showCasualListening;
  final bool showLibraryShuffle;
  final List<HomePlaybackSection> homePlaybackOrder;
  final List<HomeShortcutSection> homeShortcutOrder;
  final Set<HomeShortcutSection> hiddenHomeShortcuts;
  final List<HomeDiscoverySection> homeDiscoveryOrder;
  final Set<HomeDiscoverySection> hiddenHomeDiscoveries;
  final bool showMyPlaylistSection;
  final bool showPublicPlaylistSection;
  final bool checkUpdatesOnStartup;
  final AppLogLevel logLevel;

  AppSettings get normalized {
    final normalizedPlaybackOrder = _normalizeEnumOrder(
      homePlaybackOrder,
      HomePlaybackSection.values,
    );
    final visiblePlaybackOrder = normalizedPlaybackOrder
        .where(isHomePlaybackVisible)
        .toList();
    final normalizedStartupPlaybackSection =
        visiblePlaybackOrder.contains(startupPlaybackSection)
        ? startupPlaybackSection
        : visiblePlaybackOrder.isEmpty
        ? startupPlaybackSection
        : visiblePlaybackOrder.first;
    return copyWith(
      cacheSizeBytes: clampCacheSize(cacheSizeBytes),
      autoPlayDailyRecommendationOnStartup:
          autoPlayDailyRecommendationOnStartup &&
          visiblePlaybackOrder.isNotEmpty,
      startupPlaybackSection: normalizedStartupPlaybackSection,
      homePlaybackOrder: normalizedPlaybackOrder,
      homeShortcutOrder: _normalizeEnumOrder(
        homeShortcutOrder,
        HomeShortcutSection.values,
      ),
      hiddenHomeShortcuts: _normalizeEnumSet(
        hiddenHomeShortcuts,
        HomeShortcutSection.values,
      ),
      homeDiscoveryOrder: _normalizeEnumOrder(
        homeDiscoveryOrder,
        HomeDiscoverySection.values,
      ),
      hiddenHomeDiscoveries: _normalizeEnumSet(
        hiddenHomeDiscoveries,
        HomeDiscoverySection.values,
      ),
    );
  }

  bool isHomePlaybackVisible(HomePlaybackSection section) {
    return switch (section) {
      HomePlaybackSection.dailyRecommendation => showDailyRecommendation,
      HomePlaybackSection.casualListening => showCasualListening,
      HomePlaybackSection.libraryShuffle => showLibraryShuffle,
    };
  }

  bool isHomeShortcutVisible(HomeShortcutSection section) {
    return !hiddenHomeShortcuts.contains(section);
  }

  bool isHomeDiscoveryVisible(HomeDiscoverySection section) {
    return !hiddenHomeDiscoveries.contains(section);
  }

  List<HomePlaybackSection> get visibleHomePlaybackOrder {
    return homePlaybackOrder.where(isHomePlaybackVisible).toList();
  }

  Set<HomePlaybackSection> get hiddenHomePlaybacks {
    return {
      for (final section in HomePlaybackSection.values)
        if (!isHomePlaybackVisible(section)) section,
    };
  }

  List<HomeShortcutSection> get visibleHomeShortcutOrder {
    return homeShortcutOrder.where(isHomeShortcutVisible).toList();
  }

  List<HomeDiscoverySection> get visibleHomeDiscoveryOrder {
    return homeDiscoveryOrder.where(isHomeDiscoveryVisible).toList();
  }

  bool get shouldLoadHomePlaylists {
    return showMyPlaylistSection ||
        showPublicPlaylistSection ||
        isHomeShortcutVisible(HomeShortcutSection.myPlaylists) ||
        isHomeShortcutVisible(HomeShortcutSection.publicPlaylists);
  }

  AppSettings copyWith({
    String? cacheDirectory,
    int? cacheSizeBytes,
    String? logoPath,
    String? backgroundPath,
    String? trayIconPath,
    CloseButtonBehavior? closeButtonBehavior,
    bool? launchAtStartup,
    bool? playRandomAfterSequentialQueue,
    bool? autoPlayDailyRecommendationOnStartup,
    HomePlaybackSection? startupPlaybackSection,
    bool? skipUnplayableTracks,
    bool? showDailyRecommendation,
    bool? showCasualListening,
    bool? showLibraryShuffle,
    List<HomePlaybackSection>? homePlaybackOrder,
    List<HomeShortcutSection>? homeShortcutOrder,
    Set<HomeShortcutSection>? hiddenHomeShortcuts,
    List<HomeDiscoverySection>? homeDiscoveryOrder,
    Set<HomeDiscoverySection>? hiddenHomeDiscoveries,
    bool? showMyPlaylistSection,
    bool? showPublicPlaylistSection,
    bool? checkUpdatesOnStartup,
    AppLogLevel? logLevel,
  }) {
    return AppSettings(
      cacheDirectory: cacheDirectory ?? this.cacheDirectory,
      cacheSizeBytes: cacheSizeBytes ?? this.cacheSizeBytes,
      logoPath: logoPath ?? this.logoPath,
      backgroundPath: backgroundPath ?? this.backgroundPath,
      trayIconPath: trayIconPath ?? this.trayIconPath,
      closeButtonBehavior: closeButtonBehavior ?? this.closeButtonBehavior,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      playRandomAfterSequentialQueue:
          playRandomAfterSequentialQueue ?? this.playRandomAfterSequentialQueue,
      autoPlayDailyRecommendationOnStartup:
          autoPlayDailyRecommendationOnStartup ??
          this.autoPlayDailyRecommendationOnStartup,
      startupPlaybackSection:
          startupPlaybackSection ?? this.startupPlaybackSection,
      skipUnplayableTracks: skipUnplayableTracks ?? this.skipUnplayableTracks,
      showDailyRecommendation:
          showDailyRecommendation ?? this.showDailyRecommendation,
      showCasualListening: showCasualListening ?? this.showCasualListening,
      showLibraryShuffle: showLibraryShuffle ?? this.showLibraryShuffle,
      homePlaybackOrder: homePlaybackOrder ?? this.homePlaybackOrder,
      homeShortcutOrder: homeShortcutOrder ?? this.homeShortcutOrder,
      hiddenHomeShortcuts: hiddenHomeShortcuts ?? this.hiddenHomeShortcuts,
      homeDiscoveryOrder: homeDiscoveryOrder ?? this.homeDiscoveryOrder,
      hiddenHomeDiscoveries:
          hiddenHomeDiscoveries ?? this.hiddenHomeDiscoveries,
      showMyPlaylistSection:
          showMyPlaylistSection ?? this.showMyPlaylistSection,
      showPublicPlaylistSection:
          showPublicPlaylistSection ?? this.showPublicPlaylistSection,
      checkUpdatesOnStartup:
          checkUpdatesOnStartup ?? this.checkUpdatesOnStartup,
      logLevel: logLevel ?? this.logLevel,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'cacheDirectory': cacheDirectory,
      'cacheSizeBytes': cacheSizeBytes,
      'logoPath': logoPath,
      'backgroundPath': backgroundPath,
      'trayIconPath': trayIconPath,
      'closeButtonBehavior': closeButtonBehavior.name,
      'launchAtStartup': launchAtStartup,
      'playRandomAfterSequentialQueue': playRandomAfterSequentialQueue,
      'autoPlayDailyRecommendationOnStartup':
          autoPlayDailyRecommendationOnStartup,
      'startupPlaybackSection': startupPlaybackSection.name,
      'skipUnplayableTracks': skipUnplayableTracks,
      'showDailyRecommendation': showDailyRecommendation,
      'showCasualListening': showCasualListening,
      'showLibraryShuffle': showLibraryShuffle,
      'homePlaybackOrder': homePlaybackOrder
          .map((section) => section.name)
          .toList(),
      'homeShortcutOrder': homeShortcutOrder
          .map((section) => section.name)
          .toList(),
      'hiddenHomeShortcuts': [
        for (final section in HomeShortcutSection.values)
          if (hiddenHomeShortcuts.contains(section)) section.name,
      ],
      'homeDiscoveryOrder': homeDiscoveryOrder
          .map((section) => section.name)
          .toList(),
      'hiddenHomeDiscoveries': [
        for (final section in HomeDiscoverySection.values)
          if (hiddenHomeDiscoveries.contains(section)) section.name,
      ],
      'showMyPlaylistSection': showMyPlaylistSection,
      'showPublicPlaylistSection': showPublicPlaylistSection,
      'checkUpdatesOnStartup': checkUpdatesOnStartup,
      'logLevel': logLevel.name,
    };
  }

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final logoPath = _readString(json, 'logoPath');
    final backgroundPath = _readString(json, 'backgroundPath');
    return AppSettings(
      cacheDirectory: _readString(json, 'cacheDirectory'),
      cacheSizeBytes: clampCacheSize(_readInt(json, 'cacheSizeBytes')),
      logoPath: logoPath,
      backgroundPath: json.containsKey('backgroundPath')
          ? backgroundPath
          : logoPath,
      trayIconPath: _readString(json, 'trayIconPath'),
      closeButtonBehavior: CloseButtonBehavior.values.firstWhere(
        (value) => value.name == _readString(json, 'closeButtonBehavior'),
        orElse: () => CloseButtonBehavior.exit,
      ),
      launchAtStartup: _readBool(json, 'launchAtStartup', fallback: false),
      playRandomAfterSequentialQueue: _readBool(
        json,
        'playRandomAfterSequentialQueue',
        fallback: false,
      ),
      autoPlayDailyRecommendationOnStartup: _readBool(
        json,
        'autoPlayDailyRecommendationOnStartup',
        fallback: false,
      ),
      startupPlaybackSection: HomePlaybackSection.values.firstWhere(
        (value) => value.name == _readString(json, 'startupPlaybackSection'),
        orElse: () => HomePlaybackSection.dailyRecommendation,
      ),
      skipUnplayableTracks: _readBool(
        json,
        'skipUnplayableTracks',
        fallback: true,
      ),
      showDailyRecommendation: _readBool(
        json,
        'showDailyRecommendation',
        fallback: true,
      ),
      showCasualListening: _readBool(
        json,
        'showCasualListening',
        fallback: true,
      ),
      showLibraryShuffle: _readBool(json, 'showLibraryShuffle', fallback: true),
      homePlaybackOrder: _readEnumList(
        json,
        'homePlaybackOrder',
        HomePlaybackSection.values,
        defaultHomePlaybackOrder,
      ),
      homeShortcutOrder: _readEnumList(
        json,
        'homeShortcutOrder',
        HomeShortcutSection.values,
        defaultHomeShortcutOrder,
      ),
      hiddenHomeShortcuts: _readEnumSet(
        json,
        'hiddenHomeShortcuts',
        HomeShortcutSection.values,
      ),
      homeDiscoveryOrder: _readEnumList(
        json,
        'homeDiscoveryOrder',
        HomeDiscoverySection.values,
        defaultHomeDiscoveryOrder,
      ),
      hiddenHomeDiscoveries: _readEnumSet(
        json,
        'hiddenHomeDiscoveries',
        HomeDiscoverySection.values,
      ),
      showMyPlaylistSection: _readBool(
        json,
        'showMyPlaylistSection',
        fallback: true,
      ),
      showPublicPlaylistSection: _readBool(
        json,
        'showPublicPlaylistSection',
        fallback: true,
      ),
      checkUpdatesOnStartup: _readBool(
        json,
        'checkUpdatesOnStartup',
        fallback: true,
      ),
      logLevel: AppLogLevel.values.firstWhere(
        (value) => value.name == _readString(json, 'logLevel'),
        orElse: () => AppLogLevel.error,
      ),
    ).normalized;
  }
}

int clampCacheSize(int value) {
  return value.clamp(minCacheSizeBytes, maxCacheSizeBytes).toInt();
}

String _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is String ? value : '';
}

int _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? defaultCacheSizeBytes;
  }
  return defaultCacheSizeBytes;
}

bool _readBool(
  Map<String, Object?> json,
  String key, {
  required bool fallback,
}) {
  final value = json[key];
  return value is bool ? value : fallback;
}

List<T> _readEnumList<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values,
  List<T> fallback,
) {
  final raw = json[key];
  if (raw is! List) {
    return fallback;
  }
  final result = <T>[];
  for (final name in raw.whereType<String>()) {
    final value = _enumByName(values, name);
    if (value != null) {
      result.add(value);
    }
  }
  return result;
}

Set<T> _readEnumSet<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values,
) {
  final raw = json[key];
  if (raw is! List) {
    return <T>{};
  }
  final result = <T>{};
  for (final name in raw.whereType<String>()) {
    final value = _enumByName(values, name);
    if (value != null) {
      result.add(value);
    }
  }
  return result;
}

T? _enumByName<T extends Enum>(List<T> values, String name) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return null;
}

List<T> _normalizeEnumOrder<T extends Enum>(List<T> order, List<T> values) {
  final result = <T>[];
  for (final value in [...order, ...values]) {
    if (values.contains(value) && !result.contains(value)) {
      result.add(value);
    }
  }
  return List<T>.unmodifiable(result);
}

Set<T> _normalizeEnumSet<T extends Enum>(Set<T> selected, List<T> values) {
  return Set<T>.unmodifiable(selected.where(values.contains));
}
