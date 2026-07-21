import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'player_controller.dart';

const String systemMediaControlsChannelName = 'com.zmusic.app/media_session';

bool supportsSystemMediaControls(TargetPlatform platform) {
  return platform == TargetPlatform.windows ||
      platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      platform == TargetPlatform.macOS;
}

class SystemMediaControls {
  SystemMediaControls(this.player, {MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(systemMediaControlsChannelName),
      _supported =
          supported ?? supportsSystemMediaControls(defaultTargetPlatform);

  final PlayerController player;
  final MethodChannel _channel;
  final bool _supported;

  bool _initialized = false;
  bool _disposed = false;
  bool _stateUpdateScheduled = false;

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
    try {
      await _channel.invokeMethod<void>('updateState', {
        'hasTrack': track != null,
        'isPlaying': player.isPlaying,
        'canSkipPrevious': player.canSkipPrevious,
        'canSkipNext': player.canSkipNext,
        'title': track?.title ?? '',
        'artist': track?.artist ?? '',
        'album': track?.album ?? '',
        'artworkUrl': track?.coverUrl ?? '',
        'positionMs': player.position.inMilliseconds,
        'durationMs': player.duration?.inMilliseconds ?? 0,
      });
    } on MissingPluginException catch (error) {
      debugPrint('System media controls are unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint('Failed to update system media controls: $error');
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    player.removeListener(_handlePlayerChanged);
    _channel.setMethodCallHandler(null);
    if (_initialized) {
      unawaited(_channel.invokeMethod<void>('clear'));
    }
  }
}
