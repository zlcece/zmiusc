import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as media_kit;

import 'app_logger.dart';
import 'audio_cache.dart';
import 'models.dart';
import 'playback_source.dart';
import 'streaming_audio_cache_source.dart';

const Duration _playbackOpenInterruptTimeout = Duration(seconds: 3);

class PlayerController extends ChangeNotifier {
  PlayerController({
    @visibleForTesting PlaybackEngine? playbackEngine,
    @visibleForTesting
    this._startupRecoveryTimeout = const Duration(seconds: 20),
    @visibleForTesting this._startupRecoveryAttempts = 2,
    @visibleForTesting Duration? startupSwitchSettleDelay,
  }) : _audioPlayer = playbackEngine ?? _createPlaybackEngine(),
       _startupSwitchSettleDelay =
           startupSwitchSettleDelay ??
           (_isFlutterTestEnvironment()
               ? Duration.zero
               : const Duration(milliseconds: 600)) {
    _completedSubscription = _audioPlayer.completedStream.listen((completed) {
      if (completed) {
        unawaited(_handlePlaybackCompleted());
        return;
      }
      notifyListeners();
    });
    _durationSubscription = _audioPlayer.durationStream.listen((_) {
      if (_streamingCacheProgress != null) {
        _emitBufferedPosition();
      }
      notifyListeners();
    });
    _playingSubscription = _audioPlayer.playingStream.listen((playing) {
      if (playing && _directFallbackRequestId == _playRequestId) {
        AppLogger.instance.info('player', '原始音频流已由播放器接收并开始播放');
        _directFallbackRequestId = null;
      }
      if (playing) {
        _maybeStartNextTrackPrefetch();
      } else {
        unawaited(_clearNextTrackPrefetch());
      }
      notifyListeners();
    });
    _bufferingSubscription = _audioPlayer.bufferingStream.listen((_) {
      notifyListeners();
    });
  }

  final PlaybackEngine _audioPlayer;
  final Duration _startupRecoveryTimeout;
  final int _startupRecoveryAttempts;
  final Duration _startupSwitchSettleDelay;
  final Random _random = Random();

  Future<PlaybackTrack> Function(Track track)? trackResolver;
  Future<List<Track>> Function()? sequentialQueueCompletionProvider;
  VoidCallback? onPlaybackSessionChanged;

  late final StreamSubscription<bool> _completedSubscription;
  late final StreamSubscription<Duration?> _durationSubscription;
  late final StreamSubscription<bool> _playingSubscription;
  late final StreamSubscription<bool> _bufferingSubscription;
  StreamSubscription<double>? _cacheProgressSubscription;
  StreamingAudioCacheProxy? _streamingCacheProxy;
  File? _activePlaybackCacheFile;
  StreamSubscription<double>? _nextTrackPrefetchProgressSubscription;
  _NextTrackPrefetch? _nextTrackPrefetch;
  final StreamController<Duration> _cacheBufferedPositionController =
      StreamController<Duration>.broadcast();

  List<Track> _queue = [];
  int? _currentIndex;
  Track? _pendingNextTrack;
  int? _transientQueueIndex;
  int? _transientPreviousQueueIndex;
  int? _transientResumeQueueIndex;
  PlaybackMode _playbackMode = PlaybackMode.sequential;
  bool _handlingPlaybackCompleted = false;
  bool _streamingCacheCompleteMarked = false;
  double? _streamingCacheProgress;
  Future<void>? _streamingCacheCompletionFuture;
  int? _startupRecoveryInFlightRequestId;
  int _playRequestId = 0;
  int _playSessionId = 0;
  int _nextTrackPrefetchRequestId = 0;
  int? _preparedShuffleNextIndex;
  int? _openingPlaybackRequestId;
  int? _directFallbackRequestId;
  bool _currentTrackNeedsOpening = false;
  double _volume = 0.55;
  Timer? _startupRecoveryTimer;
  Future<void> _audioOperation = Future.value();

  List<Track> get queue {
    final transientIndex = _transientQueueIndex;
    if (transientIndex == null ||
        transientIndex < 0 ||
        transientIndex >= _queue.length) {
      return List.unmodifiable(_queue);
    }
    return List.unmodifiable([
      ..._queue.take(transientIndex),
      ..._queue.skip(transientIndex + 1),
    ]);
  }

  Track? get pendingNextTrack => _pendingNextTrack;

  Set<String> get activeStreamingCachePaths {
    final paths = <String>{
      if (_streamingCacheProxy case final proxy?) proxy.cacheFile.path,
      if (_nextTrackPrefetch case final prefetch?) prefetch.cacheFile.path,
      if (_activePlaybackCacheFile case final file?) file.path,
    };
    final currentUri = Uri.tryParse(currentTrack?.streamUrl ?? '');
    if (currentUri != null && currentUri.scheme == 'file') {
      paths.add(currentUri.toFilePath());
    }
    return paths;
  }

  PlaybackMode get playbackMode => _playbackMode;

  int? get currentQueueIndex {
    if (_isPlayingTransientTrack) {
      return _transientPreviousQueueIndex;
    }
    return _currentIndex;
  }

  Track? get currentTrack {
    final index = _currentIndex;
    if (index == null || index < 0 || index >= _queue.length) {
      return null;
    }
    return _queue[index];
  }

  bool get isPlaying => _audioPlayer.playing;

  double get volume => _volume;

  int get playSessionId => _playSessionId;

  bool get isBuffering {
    return _audioPlayer.buffering;
  }

  bool get canSkipPrevious {
    if (_isPlayingTransientTrack) {
      return _transientPreviousQueueIndex != null;
    }
    if (_currentIndex == null) {
      return false;
    }
    return switch (_playbackMode) {
      PlaybackMode.shuffle || PlaybackMode.repeatAll => _queue.length > 1,
      PlaybackMode.sequential || PlaybackMode.repeatOne => _currentIndex! > 0,
    };
  }

  bool get canSkipNext {
    if (_isPlayingTransientTrack) {
      return _transientResumeQueueIndex != null;
    }
    if (_currentIndex == null) {
      return false;
    }
    return switch (_playbackMode) {
      PlaybackMode.shuffle || PlaybackMode.repeatAll => _queue.length > 1,
      PlaybackMode.sequential ||
      PlaybackMode.repeatOne => _currentIndex! < _queue.length - 1,
    };
  }

  Duration get position => _audioPlayer.position;

  Duration? get duration => displayPlaybackDuration(
    reportedDuration: _audioPlayer.duration,
    trackDuration: currentTrack?.duration,
  );

  Duration get bufferedPosition => cacheProgressBufferedPosition(
    duration: duration,
    cacheProgress: _streamingCacheProgress,
    fallback: _audioPlayer.bufferedPosition,
  );

  Stream<Duration> get positionStream => _audioPlayer.positionStream;

  Stream<Duration> get bufferedPositionStream => _streamingCacheProgress == null
      ? _audioPlayer.bufferedPositionStream
      : _cacheBufferedPositionController.stream;

  void restorePlaybackSession({
    required List<Track> queue,
    required int? currentIndex,
    required PlaybackMode playbackMode,
  }) {
    _playRequestId++;
    unawaited(_clearNextTrackPrefetch());
    _cancelStartupRecovery();
    _queue = List.of(queue);
    _currentIndex = _queue.isEmpty
        ? null
        : currentIndex != null &&
              currentIndex >= 0 &&
              currentIndex < _queue.length
        ? currentIndex
        : 0;
    _playbackMode = playbackMode;
    _currentTrackNeedsOpening = _currentIndex != null;
    _clearTransientPlaybackState();
    notifyListeners();
  }

  Future<void> playTracks(List<Track> tracks, int index) async {
    if (tracks.isEmpty || index < 0 || index >= tracks.length) {
      return;
    }

    await _clearNextTrackPrefetch();
    _clearTransientPlaybackState();
    _queue = List.of(tracks);
    await _playIndex(index, ++_playRequestId);
  }

  Future<void> playTrack(Track track) async {
    await _clearNextTrackPrefetch();
    _clearTransientPlaybackState();
    _queue = [track];
    await _playIndex(0, ++_playRequestId);
  }

  Future<void> playTrackNext(Track track) async {
    if (currentTrack == null) {
      await playTrack(track);
      return;
    }
    _pendingNextTrack = track;
    _preparedShuffleNextIndex = null;
    unawaited(
      _clearNextTrackPrefetch().then((_) => _maybeStartNextTrackPrefetch()),
    );
    notifyListeners();
  }

  void updateTrack(Track track) {
    final index = _queue.indexWhere((value) => value.id == track.id);
    if (index < 0) {
      return;
    }
    _queue[index] = track;
    _notifyPlaybackSessionChanged();
    notifyListeners();
  }

  void setPlaybackMode(PlaybackMode mode) {
    if (_playbackMode == mode) {
      return;
    }
    _playbackMode = mode;
    _preparedShuffleNextIndex = null;
    unawaited(
      _clearNextTrackPrefetch().then((_) => _maybeStartNextTrackPrefetch()),
    );
    _notifyPlaybackSessionChanged();
    notifyListeners();
  }

  Future<void> togglePlay() async {
    if (currentTrack == null) {
      return;
    }
    if (_audioPlayer.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    if (currentTrack == null || _audioPlayer.playing) {
      return;
    }
    final index = _currentIndex;
    if (_currentTrackNeedsOpening && index != null) {
      await _playIndex(index, ++_playRequestId);
      return;
    }
    await _audioPlayer.play();
    notifyListeners();
  }

  Future<void> pause() async {
    if (currentTrack == null || !_audioPlayer.playing) {
      return;
    }
    _cancelStartupRecovery();
    unawaited(_clearNextTrackPrefetch());
    await _audioPlayer.pause();
    notifyListeners();
  }

  Future<void> stop() async {
    _playRequestId += 1;
    await _clearNextTrackPrefetch();
    _cancelStartupRecovery();
    await _runAudioOperation(() async {
      await _audioPlayer.stop();
      await _clearStreamingCacheProgress();
    });
    _activePlaybackCacheFile = null;
    _queue = [];
    _currentIndex = null;
    _currentTrackNeedsOpening = false;
    _clearTransientPlaybackState();
    _notifyPlaybackSessionChanged();
    notifyListeners();
  }

  Future<void> playPrevious() async {
    if (_isPlayingTransientTrack) {
      await _leaveTransientTrack(playPrevious: true);
      return;
    }
    await _clearNextTrackPrefetch();
    _pendingNextTrack = null;
    if (!canSkipPrevious) {
      return;
    }
    final requestId = ++_playRequestId;
    if (_playbackMode == PlaybackMode.shuffle) {
      await _playRandom(requestId, usePreparedPrefetch: false);
      return;
    }
    if (_playbackMode == PlaybackMode.repeatAll && _currentIndex == 0) {
      await _playIndex(_queue.length - 1, requestId);
      return;
    }
    await _playIndex(_currentIndex! - 1, requestId);
  }

  Future<void> playNext() async {
    if (_isPlayingTransientTrack) {
      await _leaveTransientTrack(playPrevious: false);
      return;
    }
    final hadPendingNextTrack = _pendingNextTrack != null;
    _pendingNextTrack = null;
    if (hadPendingNextTrack) {
      await _clearNextTrackPrefetch();
    }
    if (!canSkipNext) {
      await _clearNextTrackPrefetch();
      _playRequestId++;
      await _runAudioOperation(() async {
        await _stopAudioForTransition();
        await _clearStreamingCacheProgress();
      });
      _activePlaybackCacheFile = null;
      notifyListeners();
      return;
    }
    final requestId = ++_playRequestId;
    if (_playbackMode == PlaybackMode.shuffle) {
      await _playRandom(requestId);
      return;
    }
    if (_playbackMode == PlaybackMode.repeatAll &&
        _currentIndex == _queue.length - 1) {
      await _playIndex(0, requestId);
      return;
    }
    await _playIndex(_currentIndex! + 1, requestId);
  }

  Future<void> seek(Duration position) async {
    final shouldResume = shouldResumePlaybackAfterSeek(
      wasPlaying: _audioPlayer.playing,
      currentTrack: currentTrack,
    );
    await _audioPlayer.seek(position);
    if (shouldResume) {
      await _audioPlayer.play();
    }
    notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    final normalized = volume.clamp(0, 1).toDouble();
    await _audioPlayer.setVolume(normalized);
    if (_volume == normalized) {
      return;
    }
    _volume = normalized;
    notifyListeners();
  }

  Future<void> _playIndex(
    int index,
    int requestId, {
    int? startupRecoveryAttemptsRemaining,
    bool startNewSession = true,
    bool bypassStreamingCache = false,
  }) async {
    _directFallbackRequestId = null;
    final recoveryAttemptsRemaining =
        startupRecoveryAttemptsRemaining ?? _startupRecoveryAttempts;
    final shouldSettleStartupSwitch =
        _startupSwitchSettleDelay > Duration.zero &&
        (_currentIndex == null ||
            _currentTrackNeedsOpening ||
            _openingPlaybackRequestId != null ||
            (_audioPlayer.position < const Duration(seconds: 1) &&
                (_audioPlayer.buffering || _audioPlayer.playing)));
    _cancelStartupRecovery();
    _currentIndex = index;
    _currentTrackNeedsOpening = true;
    _notifyPlaybackSessionChanged();
    if (startNewSession) {
      _playSessionId++;
    }
    var track = _queue[index];
    final prefetchedPlayback = _takeNextTrackPrefetchForPlayback(track);
    if (prefetchedPlayback == null) {
      await _clearNextTrackPrefetch();
    }
    var playbackTrack = PlaybackTrack(track: track);
    if (prefetchedPlayback != null) {
      track = prefetchedPlayback.track;
      playbackTrack = PlaybackTrack(
        track: track,
        streamingCacheFile: prefetchedPlayback.cacheFile,
      );
      _queue[index] = track;
    }
    notifyListeners();

    await _interruptSupersededOpening(requestId);
    if (!_shouldApplyPlaybackRequest(requestId, index)) {
      return;
    }

    if (shouldSettleStartupSwitch) {
      await Future<void>.delayed(_startupSwitchSettleDelay);
      if (!_shouldApplyPlaybackRequest(requestId, index)) {
        return;
      }
    }
    await _clearStreamingCacheProgress();
    _activePlaybackCacheFile = null;
    if (!_shouldApplyPlaybackRequest(requestId, index)) {
      return;
    }

    final resolver = trackResolver;
    if (resolver != null && prefetchedPlayback == null) {
      playbackTrack = await resolver(track);
      if (!_shouldApplyPlaybackRequest(requestId, index)) {
        return;
      }
      track = playbackTrack.track;
      _queue[index] = track;
      notifyListeners();
    }

    final playbackUri = Uri.tryParse(track.streamUrl);
    final useStreamingCacheProxy =
        !bypassStreamingCache &&
        playbackUri != null &&
        (playbackUri.scheme == 'http' || playbackUri.scheme == 'https') &&
        playbackTrack.streamingCacheFile != null;
    if (recoveryAttemptsRemaining >= 0) {
      _armStartupRecovery(
        requestId,
        index,
        recoveryAttemptsRemaining,
        bypassStreamingCache: bypassStreamingCache || useStreamingCacheProxy,
      );
    }
    _openingPlaybackRequestId = requestId;
    try {
      await _runAudioOperation(() async {
        if (!_shouldApplyPlaybackRequest(requestId, index)) {
          return;
        }
        final uri = playbackUri;
        if (uri != null && uri.scheme == 'file') {
          _activePlaybackCacheFile = File(uri.toFilePath());
          AppLogger.instance.info('player', '播放链路：本地完整缓存');
          await _audioPlayer.openAndPlay(uri.toString());
        } else if (useStreamingCacheProxy) {
          AppLogger.instance.info('player', '播放链路：缓存代理（边播边缓存）');
          final cacheFile = playbackTrack.streamingCacheFile!;
          final proxy =
              prefetchedPlayback?.proxy ??
              StreamingAudioCacheProxy(playbackUri, cacheFile: cacheFile);
          final localUri = prefetchedPlayback?.localUri ?? await proxy.start();
          _watchStreamingCacheProgress(
            proxy,
            cacheFile,
            requestId,
            index,
            recoveryAttemptsRemaining,
          );
          await _audioPlayer.openAndPlay(localUri.toString());
        } else {
          if (bypassStreamingCache &&
              uri != null &&
              (uri.scheme == 'http' || uri.scheme == 'https')) {
            _directFallbackRequestId = requestId;
            AppLogger.instance.info('player', '播放链路：原始音频流（直连，缓存代理停滞兜底）');
          } else {
            AppLogger.instance.info('player', '播放链路：原始音频流（直连）');
          }
          await _audioPlayer.openAndPlay(track.streamUrl);
          if (_directFallbackRequestId == requestId && _audioPlayer.playing) {
            AppLogger.instance.info('player', '原始音频流已由播放器接收并开始播放');
            _directFallbackRequestId = null;
          }
        }
        if (!_shouldApplyPlaybackRequest(requestId, index)) {
          return;
        }
      });
    } catch (error, stackTrace) {
      if (!_shouldApplyPlaybackRequest(requestId, index)) {
        return;
      }
      _cancelStartupRecovery();
      AppLogger.instance.warning(
        'player',
        '播放启动失败，正在执行恢复',
        error: error,
        stackTrace: stackTrace,
      );
      await _recoverStalledStartup(
        index,
        requestId,
        recoveryAttemptsRemaining,
        bypassStreamingCache: bypassStreamingCache || useStreamingCacheProxy,
      );
      return;
    } finally {
      if (_openingPlaybackRequestId == requestId) {
        _openingPlaybackRequestId = null;
      }
    }
    if (!_shouldApplyPlaybackRequest(requestId, index)) {
      return;
    }
    _currentTrackNeedsOpening = !_audioPlayer.playing;
    _maybeStartNextTrackPrefetch();
    notifyListeners();
  }

  Future<void> _interruptSupersededOpening(int requestId) async {
    final openingRequestId = _openingPlaybackRequestId;
    final audioPlayer = _audioPlayer;
    final replacingStartup =
        audioPlayer.position < const Duration(seconds: 1) &&
        (audioPlayer.buffering || audioPlayer.playing);
    if ((openingRequestId == null || openingRequestId == requestId) &&
        !replacingStartup) {
      return;
    }
    if (audioPlayer is! _InterruptiblePlaybackEngine) {
      return;
    }
    final interruptiblePlayer = audioPlayer as _InterruptiblePlaybackEngine;
    _openingPlaybackRequestId = null;
    final interruption = () async {
      try {
        await interruptiblePlayer.interruptPendingOpen().timeout(
          _playbackOpenInterruptTimeout,
        );
      } catch (error, stackTrace) {
        AppLogger.instance.warning(
          'player',
          '中断上一个播放加载失败',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }();

    // A stalled open must not keep every later playback request queued behind
    // its never-completing Future. The interrupt becomes the new queue head.
    _audioOperation = interruption;
    await interruption;
  }

  void _watchStreamingCacheProgress(
    StreamingAudioCacheProxy proxy,
    File cacheFile,
    int requestId,
    int index,
    int recoveryAttemptsRemaining,
  ) {
    _cacheProgressSubscription?.cancel();
    _streamingCacheProxy = proxy;
    _activePlaybackCacheFile = null;
    _streamingCacheProgress = 0;
    _streamingCacheCompleteMarked = false;
    _streamingCacheCompletionFuture = null;
    _emitBufferedPosition();
    notifyListeners();
    _cacheProgressSubscription = proxy.downloadProgressStream.listen((
      progress,
    ) {
      final normalized = progress.clamp(0.0, 1.0).toDouble();
      _streamingCacheProgress = normalized;
      if (normalized >= 1 && !_streamingCacheCompleteMarked) {
        _streamingCacheCompleteMarked = true;
        final completion = _finalizeStreamingCache(proxy, cacheFile);
        _streamingCacheCompletionFuture = completion;
        unawaited(
          completion.then((_) {
            if (!identical(_streamingCacheProxy, proxy) ||
                !_shouldApplyPlaybackRequest(requestId, index) ||
                _audioPlayer.position >= const Duration(seconds: 1) ||
                (!_audioPlayer.buffering && _audioPlayer.playing)) {
              return;
            }
            unawaited(
              _recoverStalledStartup(
                index,
                requestId,
                recoveryAttemptsRemaining,
                bypassStreamingCache: true,
              ),
            );
          }),
        );
      }
      _emitBufferedPosition();
    });
    unawaited(
      proxy.prefetch().catchError((Object error, StackTrace stackTrace) {
        if (!identical(_streamingCacheProxy, proxy)) {
          return;
        }
        AppLogger.instance.warning(
          'cache',
          '后台缓存当前歌曲失败',
          error: error,
          stackTrace: stackTrace,
        );
        if (_shouldApplyPlaybackRequest(requestId, index)) {
          unawaited(
            _recoverStalledStartup(
              index,
              requestId,
              recoveryAttemptsRemaining,
              bypassStreamingCache: true,
            ),
          );
        }
      }),
    );
  }

  Future<void> _finalizeStreamingCache(
    StreamingAudioCacheProxy proxy,
    File cacheFile,
  ) async {
    try {
      // Progress reaches 100% before the proxy download Future has returned.
      // Wait for the writer to close before publishing the completion marker.
      await proxy.prefetch();
      await _markStreamingCacheComplete(cacheFile);
      if (identical(_streamingCacheProxy, proxy)) {
        _maybeStartNextTrackPrefetch();
      }
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'cache',
        '确认音频缓存完成失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _markStreamingCacheComplete(File cacheFile) async {
    try {
      for (var attempt = 0; attempt < 50; attempt++) {
        if (await cacheFile.exists() && await cacheFile.length() > 0) {
          await markAudioCacheComplete(cacheFile);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'cache',
        '标记音频缓存完成失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _clearStreamingCacheProgress({bool waitForProxy = true}) async {
    final subscription = _cacheProgressSubscription;
    final proxy = _streamingCacheProxy;
    _cacheProgressSubscription = null;
    _streamingCacheProxy = null;
    _streamingCacheProgress = null;
    _streamingCacheCompleteMarked = false;
    _streamingCacheCompletionFuture = null;
    await subscription?.cancel();
    final cancellation = proxy?.cancel();
    if (cancellation == null) {
      return;
    }
    if (waitForProxy) {
      try {
        await cancellation.timeout(const Duration(seconds: 2));
      } catch (error, stackTrace) {
        AppLogger.instance.warning(
          'cache',
          '等待上一个音频缓存代理关闭超时',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }
    unawaited(
      cancellation.catchError((Object error, StackTrace stackTrace) {
        AppLogger.instance.warning(
          'cache',
          '关闭上一个音频缓存代理失败',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> _clearNextTrackPrefetch({
    bool clearPreparedShuffleIndex = true,
  }) async {
    _nextTrackPrefetchRequestId++;
    await _nextTrackPrefetchProgressSubscription?.cancel();
    _nextTrackPrefetchProgressSubscription = null;
    final prefetch = _nextTrackPrefetch;
    _nextTrackPrefetch = null;
    if (clearPreparedShuffleIndex) {
      _preparedShuffleNextIndex = null;
    }
    final cancellation = prefetch?.proxy.cancel();
    if (cancellation == null) {
      return;
    }
    unawaited(
      cancellation.catchError((Object error, StackTrace stackTrace) {
        AppLogger.instance.warning(
          'cache',
          '关闭下一首预取代理失败',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  _NextTrackPrefetch? _takeNextTrackPrefetchForPlayback(Track track) {
    final prefetch = _nextTrackPrefetch;
    if (prefetch == null || prefetch.key != _trackPrefetchKey(track)) {
      return null;
    }
    _nextTrackPrefetchRequestId++;
    unawaited(_nextTrackPrefetchProgressSubscription?.cancel());
    _nextTrackPrefetchProgressSubscription = null;
    _nextTrackPrefetch = null;
    _preparedShuffleNextIndex = null;
    return prefetch;
  }

  void _maybeStartNextTrackPrefetch() {
    if (_isFlutterTestEnvironment() ||
        trackResolver == null ||
        !_audioPlayer.playing ||
        _currentTrackNeedsOpening) {
      return;
    }
    final progress = _streamingCacheProgress;
    if (progress != null && progress < 1) {
      return;
    }
    final target = _nextTrackToPrefetch();
    if (target == null) {
      unawaited(_clearNextTrackPrefetch());
      return;
    }
    final currentTrack = this.currentTrack;
    if (currentTrack != null &&
        _trackCacheIdentity(currentTrack) == _trackCacheIdentity(target)) {
      unawaited(_clearNextTrackPrefetch());
      return;
    }
    final key = _trackPrefetchKey(target);
    final currentPrefetch = _nextTrackPrefetch;
    if (currentPrefetch != null && currentPrefetch.key == key) {
      return;
    }
    unawaited(
      _clearNextTrackPrefetch(clearPreparedShuffleIndex: false).then((_) {
        _nextTrackPrefetchRequestId++;
        unawaited(
          _startNextTrackPrefetch(target, key, _nextTrackPrefetchRequestId),
        );
      }),
    );
  }

  Future<void> _startNextTrackPrefetch(
    Track track,
    String key,
    int requestId,
  ) async {
    final resolver = trackResolver;
    if (resolver == null) {
      return;
    }
    try {
      final playbackTrack = await resolver(track);
      if (!_shouldContinueNextTrackPrefetch(requestId, key)) {
        return;
      }
      final uri = Uri.tryParse(playbackTrack.track.streamUrl);
      final cacheFile = playbackTrack.streamingCacheFile;
      if (uri == null ||
          cacheFile == null ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        return;
      }
      final proxy = StreamingAudioCacheProxy(uri, cacheFile: cacheFile);
      final localUri = await proxy.start();
      if (!_shouldContinueNextTrackPrefetch(requestId, key)) {
        await proxy.cancel();
        return;
      }
      _nextTrackPrefetch = _NextTrackPrefetch(
        key: key,
        track: playbackTrack.track,
        cacheFile: cacheFile,
        proxy: proxy,
        localUri: localUri,
      );
      await _nextTrackPrefetchProgressSubscription?.cancel();
      _nextTrackPrefetchProgressSubscription = null;
      await proxy.prefetch();
      if (!_shouldContinueNextTrackPrefetch(requestId, key)) {
        return;
      }
      await _markStreamingCacheComplete(cacheFile);
      if (identical(_nextTrackPrefetch?.proxy, proxy)) {
        await _clearNextTrackPrefetch(clearPreparedShuffleIndex: false);
      }
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'cache',
        '预取下一首歌曲失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (_shouldContinueNextTrackPrefetch(requestId, key)) {
        await _clearNextTrackPrefetch();
      }
    }
  }

  bool _shouldContinueNextTrackPrefetch(int requestId, String key) {
    return requestId == _nextTrackPrefetchRequestId &&
        _audioPlayer.playing &&
        (_nextTrackPrefetch == null || _nextTrackPrefetch?.key == key);
  }

  Track? _nextTrackToPrefetch() {
    final currentIndex = _currentIndex;
    if (currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= _queue.length) {
      return null;
    }
    final pending = _pendingNextTrack;
    if (pending != null) {
      return pending;
    }
    if (_isPlayingTransientTrack) {
      final resumeIndex = _transientResumeQueueIndex;
      if (resumeIndex != null &&
          resumeIndex >= 0 &&
          resumeIndex < _queue.length) {
        return _queue[resumeIndex];
      }
      return null;
    }
    if (shouldReplayCurrentOnPlaybackCompleted(
      playbackMode: _playbackMode,
      currentIndex: currentIndex,
      queueLength: _queue.length,
    )) {
      return null;
    }
    if (!shouldAutoAdvanceOnPlaybackCompleted(
      playbackMode: _playbackMode,
      currentIndex: currentIndex,
      queueLength: _queue.length,
    )) {
      return null;
    }
    if (_playbackMode == PlaybackMode.shuffle) {
      final prepared = _preparedShuffleNextIndex;
      if (prepared != null &&
          prepared >= 0 &&
          prepared < _queue.length &&
          prepared != currentIndex) {
        return _queue[prepared];
      }
      var nextIndex = _random.nextInt(_queue.length);
      if (nextIndex == currentIndex) {
        nextIndex = (nextIndex + 1) % _queue.length;
      }
      _preparedShuffleNextIndex = nextIndex;
      return _queue[nextIndex];
    }
    final nextIndex = _playbackMode == PlaybackMode.repeatAll
        ? repeatAllNextIndexOnPlaybackCompleted(
            currentIndex: currentIndex,
            queueLength: _queue.length,
          )
        : sequentialNextIndexOnPlaybackCompleted(
            currentIndex: currentIndex,
            queueLength: _queue.length,
          );
    return nextIndex >= 0 && nextIndex < _queue.length
        ? _queue[nextIndex]
        : null;
  }

  String _trackPrefetchKey(Track track) {
    return [
      track.sourceType.name,
      track.sourceServerId ?? '',
      track.sourceItemId ?? '',
      track.id,
    ].join('|');
  }

  String _trackCacheIdentity(Track track) {
    final sourceServerId = track.sourceServerId?.trim();
    final sourceItemId = track.sourceItemId?.trim();
    if (sourceServerId != null &&
        sourceServerId.isNotEmpty &&
        sourceItemId != null &&
        sourceItemId.isNotEmpty) {
      return '${track.sourceType.name}:$sourceServerId:$sourceItemId';
    }
    return track.streamUrl;
  }

  Future<void> _stopAudioForTransition() async {
    try {
      await _audioPlayer.stop().timeout(const Duration(seconds: 3));
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'player',
        '切歌时停止旧音频超时',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _armStartupRecovery(
    int requestId,
    int index,
    int recoveryAttemptsRemaining, {
    required bool bypassStreamingCache,
  }) {
    _cancelStartupRecovery();
    if (_startupRecoveryTimeout <= Duration.zero) {
      return;
    }
    _startupRecoveryTimer = Timer(_startupRecoveryTimeout, () {
      _startupRecoveryTimer = null;
      if (!_shouldApplyPlaybackRequest(requestId, index)) {
        return;
      }
      final opening = _openingPlaybackRequestId == requestId;
      if (!opening && _audioPlayer.position > const Duration(seconds: 1)) {
        return;
      }
      final stalled =
          opening || _audioPlayer.buffering || !_audioPlayer.playing;
      if (!stalled) {
        return;
      }
      unawaited(
        _recoverStalledStartup(
          index,
          requestId,
          recoveryAttemptsRemaining,
          bypassStreamingCache: bypassStreamingCache,
        ),
      );
    });
  }

  Future<void> _recoverStalledStartup(
    int index,
    int requestId,
    int recoveryAttemptsRemaining, {
    required bool bypassStreamingCache,
  }) async {
    if (!_shouldApplyPlaybackRequest(requestId, index)) {
      return;
    }
    if (_startupRecoveryInFlightRequestId == requestId) {
      return;
    }
    _startupRecoveryInFlightRequestId = requestId;
    final proxy = _streamingCacheProxy;
    final proxyDownloadedBytes = proxy?.downloadedBytes;
    AppLogger.instance.warning(
      'player',
      bypassStreamingCache && proxyDownloadedBytes != null
          ? '缓存代理启动停滞（已接收 $proxyDownloadedBytes 字节），正在刷新地址并改用原始音频流'
          : bypassStreamingCache
          ? '原始音频流启动停滞，正在重试直连'
          : '播放启动停滞，正在重试当前歌曲',
    );
    try {
      final cacheFinished = (_streamingCacheProgress ?? 0) >= 1;
      final completedCacheFile = cacheFinished
          ? _streamingCacheProxy?.cacheFile
          : null;
      final cacheCompletion = cacheFinished
          ? _streamingCacheCompletionFuture
          : null;
      if (cacheCompletion != null) {
        await cacheCompletion;
        if (!_shouldApplyPlaybackRequest(requestId, index)) {
          return;
        }
      }
      if (completedCacheFile != null &&
          isCompletedAudioCacheFile(completedCacheFile)) {
        await _recoverFromCompletedCache(index, requestId, completedCacheFile);
        return;
      }
      if (recoveryAttemptsRemaining <= 0) {
        await _failStalledStartup(
          index,
          requestId,
          directStreamAttempt: bypassStreamingCache,
        );
        return;
      }
      final retryRequestId = ++_playRequestId;
      await _playIndex(
        index,
        retryRequestId,
        startupRecoveryAttemptsRemaining: recoveryAttemptsRemaining - 1,
        startNewSession: false,
        bypassStreamingCache: bypassStreamingCache,
      );
    } finally {
      if (_startupRecoveryInFlightRequestId == requestId) {
        _startupRecoveryInFlightRequestId = null;
      }
    }
  }

  Future<void> _failStalledStartup(
    int index,
    int requestId, {
    required bool directStreamAttempt,
  }) async {
    if (!_shouldApplyPlaybackRequest(requestId, index)) {
      return;
    }
    final failureRequestId = ++_playRequestId;
    _cancelStartupRecovery();
    await _interruptSupersededOpening(failureRequestId);
    if (!_shouldApplyPlaybackRequest(failureRequestId, index)) {
      return;
    }
    await _stopAudioForTransition();
    await _clearStreamingCacheProgress(waitForProxy: false);
    _activePlaybackCacheFile = null;
    _directFallbackRequestId = null;
    _currentTrackNeedsOpening = true;
    AppLogger.instance.error(
      'player',
      directStreamAttempt
          ? '原始音频流多次启动失败，服务端音频流当前不可播放'
          : '播放启动多次失败，已停止缓冲，可手动重试当前歌曲',
    );
    notifyListeners();
  }

  Future<void> _recoverFromCompletedCache(
    int index,
    int requestId,
    File cacheFile,
  ) async {
    if (!_shouldApplyPlaybackRequest(requestId, index)) {
      return;
    }
    final retryRequestId = ++_playRequestId;
    _cancelStartupRecovery();
    await _interruptSupersededOpening(retryRequestId);
    if (!_shouldApplyPlaybackRequest(retryRequestId, index)) {
      return;
    }
    await _clearStreamingCacheProgress();
    if (!_shouldApplyPlaybackRequest(retryRequestId, index)) {
      return;
    }
    _activePlaybackCacheFile = cacheFile;
    _openingPlaybackRequestId = retryRequestId;
    try {
      await _runAudioOperation(() async {
        if (!_shouldApplyPlaybackRequest(retryRequestId, index)) {
          return;
        }
        AppLogger.instance.info('player', '播放链路：本地完整缓存（代理下载完成）');
        await _audioPlayer.openAndPlay(Uri.file(cacheFile.path).toString());
      });
    } finally {
      if (_openingPlaybackRequestId == retryRequestId) {
        _openingPlaybackRequestId = null;
      }
    }
    if (!_shouldApplyPlaybackRequest(retryRequestId, index)) {
      return;
    }
    _currentTrackNeedsOpening = !_audioPlayer.playing;
    _maybeStartNextTrackPrefetch();
    notifyListeners();
  }

  void _cancelStartupRecovery() {
    _startupRecoveryTimer?.cancel();
    _startupRecoveryTimer = null;
  }

  void _emitBufferedPosition() {
    if (!_cacheBufferedPositionController.isClosed) {
      _cacheBufferedPositionController.add(bufferedPosition);
    }
  }

  bool _shouldApplyPlaybackRequest(int requestId, int requestedIndex) {
    return shouldApplyPlaybackRequest(
      requestId: requestId,
      latestRequestId: _playRequestId,
      requestedIndex: requestedIndex,
      currentIndex: _currentIndex,
    );
  }

  Future<void> _runAudioOperation(Future<void> Function() action) async {
    final operation = _audioOperation.then((_) => action());
    _audioOperation = operation.catchError((Object _, StackTrace _) {});
    await operation;
  }

  bool get _isPlayingTransientTrack {
    final transientIndex = _transientQueueIndex;
    return transientIndex != null && _currentIndex == transientIndex;
  }

  void _clearTransientPlaybackState() {
    _pendingNextTrack = null;
    _transientQueueIndex = null;
    _transientPreviousQueueIndex = null;
    _transientResumeQueueIndex = null;
    _preparedShuffleNextIndex = null;
  }

  void _notifyPlaybackSessionChanged() {
    onPlaybackSessionChanged?.call();
  }

  int? _resumeIndexAfterCompletion(int currentIndex) {
    if (shouldReplayCurrentOnPlaybackCompleted(
      playbackMode: _playbackMode,
      currentIndex: currentIndex,
      queueLength: _queue.length,
    )) {
      return currentIndex;
    }
    if (!shouldAutoAdvanceOnPlaybackCompleted(
      playbackMode: _playbackMode,
      currentIndex: currentIndex,
      queueLength: _queue.length,
    )) {
      return null;
    }
    if (_playbackMode == PlaybackMode.shuffle) {
      var nextIndex = _random.nextInt(_queue.length);
      if (nextIndex == currentIndex) {
        nextIndex = (nextIndex + 1) % _queue.length;
      }
      return nextIndex;
    }
    return _playbackMode == PlaybackMode.repeatAll
        ? repeatAllNextIndexOnPlaybackCompleted(
            currentIndex: currentIndex,
            queueLength: _queue.length,
          )
        : sequentialNextIndexOnPlaybackCompleted(
            currentIndex: currentIndex,
            queueLength: _queue.length,
          );
  }

  Future<bool> _playPendingNextTrack({
    required int previousIndex,
    required int? resumeIndex,
  }) async {
    final track = _pendingNextTrack;
    if (track == null) {
      return false;
    }
    _pendingNextTrack = null;
    _transientPreviousQueueIndex = previousIndex;
    _transientResumeQueueIndex = resumeIndex;
    _transientQueueIndex = _queue.length;
    _queue.add(track);
    await _playIndex(_transientQueueIndex!, ++_playRequestId);
    return true;
  }

  Future<void> _finishTransientTrack() async {
    final transientIndex = _transientQueueIndex;
    if (transientIndex == null || transientIndex >= _queue.length) {
      _clearTransientPlaybackState();
      return;
    }
    final previousIndex = _transientPreviousQueueIndex;
    final resumeIndex = _transientResumeQueueIndex;
    _queue.removeAt(transientIndex);
    _currentIndex = null;
    _transientQueueIndex = null;
    _transientPreviousQueueIndex = null;
    _transientResumeQueueIndex = null;

    if (_pendingNextTrack != null && previousIndex != null) {
      await _playPendingNextTrack(
        previousIndex: previousIndex,
        resumeIndex: resumeIndex,
      );
      return;
    }
    if (resumeIndex != null && resumeIndex < _queue.length) {
      await _playIndex(resumeIndex, ++_playRequestId);
      return;
    }
    _currentIndex = previousIndex;
    _currentTrackNeedsOpening = previousIndex != null;
    _notifyPlaybackSessionChanged();
    await _audioPlayer.pause();
    await _audioPlayer.seek(Duration.zero);
  }

  Future<void> _leaveTransientTrack({required bool playPrevious}) async {
    final transientIndex = _transientQueueIndex;
    if (transientIndex == null || transientIndex >= _queue.length) {
      _clearTransientPlaybackState();
      return;
    }
    final targetIndex = playPrevious
        ? _transientPreviousQueueIndex
        : _transientResumeQueueIndex;
    final fallbackIndex = _transientPreviousQueueIndex;
    _pendingNextTrack = null;
    _queue.removeAt(transientIndex);
    _currentIndex = null;
    _transientQueueIndex = null;
    _transientPreviousQueueIndex = null;
    _transientResumeQueueIndex = null;
    if (targetIndex != null && targetIndex < _queue.length) {
      await _playIndex(targetIndex, ++_playRequestId);
      return;
    }
    _currentIndex = fallbackIndex;
    _currentTrackNeedsOpening = fallbackIndex != null;
    _notifyPlaybackSessionChanged();
    _playRequestId++;
    await _runAudioOperation(() async {
      await _stopAudioForTransition();
      await _clearStreamingCacheProgress();
    });
    notifyListeners();
  }

  Future<void> _handlePlaybackCompleted() async {
    if (_handlingPlaybackCompleted) {
      return;
    }

    _handlingPlaybackCompleted = true;
    try {
      final currentIndex = _currentIndex;
      if (_isPlayingTransientTrack) {
        await _finishTransientTrack();
        return;
      }
      if (currentIndex != null && _pendingNextTrack != null) {
        await _playPendingNextTrack(
          previousIndex: currentIndex,
          resumeIndex: _resumeIndexAfterCompletion(currentIndex),
        );
        return;
      }
      if (shouldReplayCurrentOnPlaybackCompleted(
        playbackMode: _playbackMode,
        currentIndex: currentIndex,
        queueLength: _queue.length,
      )) {
        _playSessionId++;
        await _audioPlayer.seek(Duration.zero);
        await _audioPlayer.play();
        return;
      }

      if (shouldAutoAdvanceOnPlaybackCompleted(
        playbackMode: _playbackMode,
        currentIndex: currentIndex,
        queueLength: _queue.length,
      )) {
        if (_playbackMode == PlaybackMode.shuffle) {
          await _playRandom(++_playRequestId);
        } else {
          final requestId = ++_playRequestId;
          await _playIndex(
            _playbackMode == PlaybackMode.repeatAll
                ? repeatAllNextIndexOnPlaybackCompleted(
                    currentIndex: currentIndex!,
                    queueLength: _queue.length,
                  )
                : sequentialNextIndexOnPlaybackCompleted(
                    currentIndex: currentIndex!,
                    queueLength: _queue.length,
                  ),
            requestId,
          );
        }
        return;
      }

      final sequentialQueueCompletionProvider =
          this.sequentialQueueCompletionProvider;
      if (_playbackMode == PlaybackMode.sequential &&
          currentIndex != null &&
          currentIndex == _queue.length - 1 &&
          sequentialQueueCompletionProvider != null) {
        final completionRequestId = _playRequestId;
        final completionSessionId = _playSessionId;
        List<Track> nextQueue;
        try {
          nextQueue = await sequentialQueueCompletionProvider();
        } catch (error, stackTrace) {
          AppLogger.instance.error(
            'player',
            '顺序队列结束后加载随机歌曲失败',
            error: error,
            stackTrace: stackTrace,
          );
          nextQueue = const [];
        }
        if (_playRequestId != completionRequestId ||
            _playSessionId != completionSessionId ||
            _playbackMode != PlaybackMode.sequential ||
            _currentIndex != currentIndex) {
          return;
        }
        if (nextQueue.isNotEmpty) {
          await playTracks(nextQueue, 0);
          return;
        }
      }

      await _audioPlayer.pause();
      await _audioPlayer.seek(Duration.zero);
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        'player',
        '处理歌曲播放完成事件失败',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _handlingPlaybackCompleted = false;
      notifyListeners();
    }
  }

  Future<void> _playRandom(
    int requestId, {
    bool usePreparedPrefetch = true,
  }) async {
    final currentIndex = _currentIndex;
    if (_queue.length <= 1 || currentIndex == null) {
      return;
    }

    var nextIndex = usePreparedPrefetch ? _preparedShuffleNextIndex : null;
    if (nextIndex == null ||
        nextIndex < 0 ||
        nextIndex >= _queue.length ||
        nextIndex == currentIndex) {
      nextIndex = _random.nextInt(_queue.length);
      if (nextIndex == currentIndex) {
        nextIndex = (nextIndex + 1) % _queue.length;
      }
    }
    _preparedShuffleNextIndex = null;
    await _playIndex(nextIndex, requestId);
  }

  @override
  void dispose() {
    _cancelStartupRecovery();
    _completedSubscription.cancel();
    _durationSubscription.cancel();
    _playingSubscription.cancel();
    _bufferingSubscription.cancel();
    _cacheProgressSubscription?.cancel();
    _nextTrackPrefetchProgressSubscription?.cancel();
    unawaited(_streamingCacheProxy?.cancel());
    unawaited(_nextTrackPrefetch?.proxy.cancel());
    _cacheBufferedPositionController.close();
    unawaited(_audioPlayer.dispose());
    super.dispose();
  }
}

PlaybackEngine _createPlaybackEngine() {
  if (_isFlutterTestEnvironment()) {
    return _MemoryPlaybackEngine();
  }
  media_kit.MediaKit.ensureInitialized();
  return _MediaKitPlaybackEngine();
}

bool _isFlutterTestEnvironment() {
  final executable = Platform.resolvedExecutable.toLowerCase();
  return Platform.environment['FLUTTER_TEST'] == 'true' ||
      executable.contains('flutter_tester');
}

class _NextTrackPrefetch {
  const _NextTrackPrefetch({
    required this.key,
    required this.track,
    required this.cacheFile,
    required this.proxy,
    required this.localUri,
  });

  final String key;
  final Track track;
  final File cacheFile;
  final StreamingAudioCacheProxy proxy;
  final Uri localUri;
}

abstract class PlaybackEngine {
  bool get playing;
  bool get buffering;
  Duration get position;
  Duration? get duration;
  Duration get bufferedPosition;

  Stream<bool> get completedStream;
  Stream<Duration?> get durationStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get bufferedPositionStream;
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;

  Future<void> open(String url);
  Future<void> openAndPlay(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

abstract interface class _InterruptiblePlaybackEngine {
  Future<void> interruptPendingOpen();
}

class _MediaKitPlaybackEngine
    implements PlaybackEngine, _InterruptiblePlaybackEngine {
  _MediaKitPlaybackEngine() {
    _player = _createPlayer();
    _bindPlayer(_player);
  }

  late media_kit.Player _player;
  int _playerGeneration = 0;
  List<StreamSubscription<dynamic>> _playerSubscriptions = const [];
  final StreamController<bool> _completedController =
      StreamController<bool>.broadcast();
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _bufferController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();

  static media_kit.Player _createPlayer() {
    return media_kit.Player(
      configuration: const media_kit.PlayerConfiguration(
        title: 'Zmusic',
        bufferSize: 64 * 1024 * 1024,
      ),
    );
  }

  void _bindPlayer(media_kit.Player player) {
    final generation = ++_playerGeneration;
    bool current() =>
        generation == _playerGeneration && identical(player, _player);
    _playerSubscriptions = [
      player.stream.completed.listen((value) {
        if (current() && !_completedController.isClosed) {
          _completedController.add(value);
        }
      }),
      player.stream.duration.listen((value) {
        if (current() && !_durationController.isClosed) {
          _durationController.add(value == Duration.zero ? null : value);
        }
      }),
      player.stream.position.listen((value) {
        if (current() && !_positionController.isClosed) {
          _positionController.add(value);
        }
      }),
      player.stream.buffer.listen((value) {
        if (current() && !_bufferController.isClosed) {
          _bufferController.add(value);
        }
      }),
      player.stream.playing.listen((value) {
        if (current() && !_playingController.isClosed) {
          _playingController.add(value);
        }
      }),
      player.stream.buffering.listen((value) {
        if (current() && !_bufferingController.isClosed) {
          _bufferingController.add(value);
        }
      }),
    ];
  }

  @override
  bool get playing => _player.state.playing;

  @override
  bool get buffering => _player.state.buffering;

  @override
  Duration get position => _player.state.position;

  @override
  Duration? get duration {
    final duration = _player.state.duration;
    return duration == Duration.zero ? null : duration;
  }

  @override
  Duration get bufferedPosition => _player.state.buffer;

  @override
  Stream<bool> get completedStream => _completedController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get bufferedPositionStream => _bufferController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;

  @override
  Future<void> open(String url) async {
    await _open(url, play: false);
  }

  @override
  Future<void> openAndPlay(String url) async {
    await _open(url, play: true);
  }

  Future<void> _open(String url, {required bool play}) async {
    final player = _player;
    final platform = player.platform;
    if (platform is media_kit.NativePlayer) {
      await platform.open(
        media_kit.Media(url),
        play: play,
        synchronized: false,
      );
      return;
    }
    await player.open(media_kit.Media(url), play: play);
  }

  @override
  Future<void> interruptPendingOpen() async {
    final previousPlayer = _player;
    final previousSubscriptions = _playerSubscriptions;
    final volume = previousPlayer.state.volume;
    _player = _createPlayer();
    _bindPlayer(_player);
    await Future.wait(previousSubscriptions.map((value) => value.cancel()));
    await _player.setVolume(volume);
    unawaited(
      previousPlayer.dispose().timeout(const Duration(seconds: 3)).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        AppLogger.instance.warning(
          'player',
          '释放已被替换的播放器失败',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume * 100);

  @override
  Future<void> dispose() async {
    _playerGeneration++;
    await Future.wait(_playerSubscriptions.map((value) => value.cancel()));
    await _player.dispose();
    await _completedController.close();
    await _durationController.close();
    await _positionController.close();
    await _bufferController.close();
    await _playingController.close();
    await _bufferingController.close();
  }
}

class _MemoryPlaybackEngine implements PlaybackEngine {
  final StreamController<bool> _completedController =
      StreamController<bool>.broadcast();
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _bufferController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();

  bool _playing = false;
  bool _buffering = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  Duration _bufferedPosition = Duration.zero;

  @override
  bool get playing => _playing;

  @override
  bool get buffering => _buffering;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  Duration get bufferedPosition => _bufferedPosition;

  @override
  Stream<bool> get completedStream => _completedController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get bufferedPositionStream => _bufferController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;

  @override
  Future<void> open(String url) async {
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _duration = null;
    _positionController.add(_position);
    _bufferController.add(_bufferedPosition);
    _durationController.add(_duration);
  }

  @override
  Future<void> openAndPlay(String url) async {
    await open(url);
    await play();
  }

  @override
  Future<void> play() async {
    _playing = true;
    _playingController.add(_playing);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _playingController.add(_playing);
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _position = Duration.zero;
    _buffering = false;
    _playingController.add(_playing);
    _positionController.add(_position);
    _bufferingController.add(_buffering);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    _positionController.add(_position);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {
    await _completedController.close();
    await _durationController.close();
    await _positionController.close();
    await _bufferController.close();
    await _playingController.close();
    await _bufferingController.close();
  }
}

const Duration _maximumDisplayDuration = Duration(days: 2);

@visibleForTesting
Duration? displayPlaybackDuration({
  required Duration? reportedDuration,
  required Duration? trackDuration,
}) {
  final reported = _isDisplayDurationUsable(reportedDuration)
      ? reportedDuration
      : null;
  final metadata = _isDisplayDurationUsable(trackDuration)
      ? trackDuration
      : null;

  if (reported == null) {
    return metadata;
  }
  if (metadata == null) {
    return reported;
  }

  if (reported.inMilliseconds > metadata.inMilliseconds * 4) {
    return metadata;
  }
  return reported;
}

bool _isDisplayDurationUsable(Duration? duration) {
  return duration != null &&
      duration > Duration.zero &&
      duration <= _maximumDisplayDuration;
}

@visibleForTesting
Duration cacheProgressBufferedPosition({
  required Duration? duration,
  required double? cacheProgress,
  required Duration fallback,
}) {
  final progress = cacheProgress;
  if (duration == null || progress == null) {
    return fallback;
  }
  return Duration(
    milliseconds: (duration.inMilliseconds * progress.clamp(0.0, 1.0)).round(),
  );
}

@visibleForTesting
bool shouldAutoAdvanceOnPlaybackCompleted({
  required PlaybackMode playbackMode,
  required int? currentIndex,
  required int queueLength,
}) {
  if (currentIndex == null || queueLength <= 0) {
    return false;
  }
  return switch (playbackMode) {
    PlaybackMode.sequential => currentIndex < queueLength - 1,
    PlaybackMode.shuffle => queueLength > 1,
    PlaybackMode.repeatOne => false,
    PlaybackMode.repeatAll => queueLength > 1,
  };
}

@visibleForTesting
bool shouldReplayCurrentOnPlaybackCompleted({
  required PlaybackMode playbackMode,
  required int? currentIndex,
  required int queueLength,
}) {
  if (currentIndex == null || queueLength <= 0) {
    return false;
  }
  return playbackMode == PlaybackMode.repeatOne ||
      (playbackMode == PlaybackMode.repeatAll && queueLength == 1);
}

@visibleForTesting
int sequentialNextIndexOnPlaybackCompleted({
  required int currentIndex,
  required int queueLength,
}) {
  if (queueLength <= 0) {
    return 0;
  }
  return (currentIndex + 1).clamp(0, queueLength - 1);
}

@visibleForTesting
int repeatAllNextIndexOnPlaybackCompleted({
  required int currentIndex,
  required int queueLength,
}) {
  if (queueLength <= 0) {
    return 0;
  }
  return (currentIndex + 1) % queueLength;
}

@visibleForTesting
bool shouldApplyPlaybackRequest({
  required int requestId,
  required int latestRequestId,
  required int requestedIndex,
  required int? currentIndex,
}) {
  return requestId == latestRequestId && requestedIndex == currentIndex;
}

@visibleForTesting
bool shouldResumePlaybackAfterSeek({
  required bool wasPlaying,
  required Track? currentTrack,
}) {
  return wasPlaying && currentTrack != null;
}
