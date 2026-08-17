import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'artwork_cache.dart';
import 'app_logger.dart';
import 'player_controller.dart';

const String systemMediaControlsChannelName = 'com.zmusic.app/media_session';

bool supportsSystemMediaControls(TargetPlatform platform) {
  return platform == TargetPlatform.windows ||
      platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      platform == TargetPlatform.macOS;
}

class SystemMediaControls {
  SystemMediaControls(
    this.player, {
    MethodChannel? channel,
    bool? supported,
    ArtworkCacheManager? artworkCacheManager,
    this._onExitRequested,
  }) : _channel =
           channel ?? const MethodChannel(systemMediaControlsChannelName),
       _supported =
           supported ?? supportsSystemMediaControls(defaultTargetPlatform),
       _artworkCacheManager =
           defaultTargetPlatform == TargetPlatform.windows && channel == null
           ? artworkCacheManager ?? ArtworkCacheManager.instance
           : null;

  final PlayerController player;
  final MethodChannel _channel;
  final bool _supported;
  final ArtworkCacheManager? _artworkCacheManager;
  final AsyncCallback? _onExitRequested;

  bool _initialized = false;
  bool _disposed = false;
  bool _stateUpdateScheduled = false;
  String _artworkSource = '';
  String _artworkPath = '';
  int _artworkRequestId = 0;

  Future<void> initialize() async {
    if (!_supported || _initialized || _disposed) {
      return;
    }

    _channel.setMethodCallHandler(_handleNativeCall);
    player.addListener(_handlePlayerChanged);
    try {
      await _channel.invokeMethod<void>('initialize');
      if (_disposed) {
        return;
      }
      _initialized = true;
      await _pushState();
    } catch (_) {
      player.removeListener(_handlePlayerChanged);
      _channel.setMethodCallHandler(null);
      rethrow;
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'setVolume' && call.arguments is num) {
      await player.setVolume((call.arguments as num).toDouble());
      return;
    }
    if (call.method != 'mediaButton' || call.arguments is! String) {
      return;
    }
    await handleMediaCommand(call.arguments as String);
  }

  @visibleForTesting
  Future<void> handleMediaCommand(String command) async {
    switch (command) {
      case 'play':
        await player.play();
      case 'pause':
        await player.pause();
      case 'playPause':
        await player.togglePlay();
      case 'next':
        await player.playNext();
      case 'previous':
        await player.playPrevious();
      case 'exit':
        await _onExitRequested?.call();
    }
  }

  void _handlePlayerChanged() {
    if (!_initialized || _disposed || _stateUpdateScheduled) {
      return;
    }
    _stateUpdateScheduled = true;
    scheduleMicrotask(() {
      _stateUpdateScheduled = false;
      if (!_disposed) {
        unawaited(_pushState());
      }
    });
  }

  Future<void> _pushState() async {
    final track = player.currentTrack;
    final artworkPath = _resolveTaskbarArtwork(track?.coverUrl);
    try {
      await _channel.invokeMethod<void>('updateState', {
        'hasTrack': track != null,
        'isPlaying': player.isPlaying,
        'canSkipPrevious': player.canSkipPrevious,
        'canSkipNext': player.canSkipNext,
        'volume': player.volume,
        'title': track?.title ?? '',
        'artist': track?.artist ?? '',
        'album': track?.album ?? '',
        'artworkUrl': track?.coverUrl ?? '',
        'artworkPath': artworkPath,
        'positionMs': player.position.inMilliseconds,
        'durationMs': player.duration?.inMilliseconds ?? 0,
      });
    } on MissingPluginException catch (error) {
      AppLogger.instance.warning('media-controls', '系统媒体控制不可用', error: error);
    } on PlatformException catch (error) {
      AppLogger.instance.error('media-controls', '更新系统媒体控制失败', error: error);
    }
  }

  String _resolveTaskbarArtwork(String? source) {
    final manager = _artworkCacheManager;
    final normalizedSource = source?.trim() ?? '';
    if (manager == null) {
      return '';
    }
    if (normalizedSource == _artworkSource) {
      return _artworkPath;
    }

    _artworkSource = normalizedSource;
    _artworkPath = '';
    final requestId = ++_artworkRequestId;
    if (normalizedSource.isNotEmpty) {
      unawaited(_cacheTaskbarArtwork(manager, normalizedSource, requestId));
    }
    return '';
  }

  Future<void> _cacheTaskbarArtwork(
    ArtworkCacheManager manager,
    String source,
    int requestId,
  ) async {
    String resolvedPath = '';
    try {
      resolvedPath = (await manager.cacheArtwork(source))?.path ?? '';
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'media-controls',
        '缓存 Windows 任务栏封面失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (_disposed ||
        requestId != _artworkRequestId ||
        source != _artworkSource) {
      return;
    }
    _artworkPath = resolvedPath;
    await _pushState();
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _artworkRequestId++;
    player.removeListener(_handlePlayerChanged);
    _channel.setMethodCallHandler(null);
    if (_initialized) {
      unawaited(_channel.invokeMethod<void>('clear'));
    }
  }
}
