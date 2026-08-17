import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_paths.dart';
import 'app_logger.dart';
import 'models.dart';
import 'playback_source.dart';
import 'settings_models.dart';

class AudioCacheManager {
  AudioCacheManager({http.Client? httpClient});

  Future<void> _trimQueue = Future<void>.value();
  Future<void>? _scheduledTrim;

  Future<String> defaultCacheDirectory() async {
    if (shouldUseInstallDirectoryData()) {
      return joinPath(installCacheDirectory().path, ['audio']);
    }
    final directory = await getApplicationCacheDirectory();
    return Directory('${directory.path}${Platform.pathSeparator}audio').path;
  }

  Future<PlaybackTrack> resolveForPlayback(
    Track track,
    AppSettings settings,
  ) async {
    if (isRadioTrack(track)) {
      return PlaybackTrack(track: track);
    }

    final uri = Uri.tryParse(track.streamUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        settings.cacheSizeBytes <= 0) {
      return PlaybackTrack(track: track);
    }

    final cacheDirectory = await _cacheDirectory(settings);
    await cacheDirectory.create(recursive: true);
    final cachedFile = File(
      '${cacheDirectory.path}${Platform.pathSeparator}${_cacheFileName(track, uri)}',
    );
    if (isCompletedAudioCacheFile(cachedFile)) {
      try {
        await _ensureAudioCacheCompletionMarker(cachedFile);
        await cachedFile.setLastModified(DateTime.now());
        return PlaybackTrack(
          track: track.copyWith(
            streamUrl: Uri.file(cachedFile.path).toString(),
          ),
        );
      } on FileSystemException {
        // A concurrent trim may remove an old entry between validation and use.
      }
    }
    try {
      final discarded = await _discardIncompleteCacheFile(cachedFile);
      if (!discarded) {
        AppLogger.instance.warning('cache', '缓存文件正被占用，本次改用原始音频流播放');
        return PlaybackTrack(track: track);
      }
      await markAudioCachePartial(cachedFile);
    } on FileSystemException catch (error, stackTrace) {
      AppLogger.instance.warning(
        'cache',
        '准备音频缓存失败，本次改用原始音频流播放',
        error: error,
        stackTrace: stackTrace,
      );
      return PlaybackTrack(track: track);
    }
    _scheduleTrim(settings);
    return PlaybackTrack(track: track, streamingCacheFile: cachedFile);
  }

  Future<int> cacheSize(AppSettings settings) async {
    final directory = await _cacheDirectory(settings);
    if (!directory.existsSync()) {
      return 0;
    }
    var total = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<int> clearCache(
    AppSettings settings, {
    Set<String> protectedPaths = const {},
  }) {
    final operation = _trimQueue.then(
      (_) => _clearCache(settings, protectedPaths),
    );
    _trimQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<int> _clearCache(
    AppSettings settings,
    Set<String> protectedPaths,
  ) async {
    final directory = await _cacheDirectory(settings);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      return 0;
    }

    final protectedKeys = protectedPaths.map(_cachePathKey).toSet();
    final primaryFiles = <File>[];
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File && !_isAuxiliaryAudioCacheFile(entity)) {
        primaryFiles.add(entity);
      }
    }
    for (final file in primaryFiles) {
      if (protectedKeys.contains(_cachePathKey(file.path))) {
        continue;
      }
      await _tryDeleteCacheFileFamily(file);
    }

    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File || !_isAuxiliaryAudioCacheFile(entity)) {
        continue;
      }
      final primaryPath = _primaryAudioCachePath(entity.path);
      if (protectedKeys.contains(_cachePathKey(primaryPath)) ||
          await File(primaryPath).exists()) {
        continue;
      }
      await _tryDeleteFile(entity);
    }

    final directories = <Directory>[];
    await for (final entity in directory.list(recursive: true)) {
      if (entity is Directory) {
        directories.add(entity);
      }
    }
    directories.sort(
      (left, right) => right.path.length.compareTo(left.path.length),
    );
    for (final child in directories) {
      try {
        if (!await child.list().isEmpty) {
          continue;
        }
        await child.delete();
      } on FileSystemException {
        // A concurrent cache write may have recreated the directory.
      }
    }
    return cacheSize(settings);
  }

  Future<void> trimCache(AppSettings settings) async {
    final operation = _trimQueue.then((_) => _trimCache(settings));
    _trimQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _scheduleTrim(AppSettings settings) {
    if (_scheduledTrim != null) {
      return;
    }

    late final Future<void> operation;
    operation = trimCache(settings)
        .catchError((Object error, StackTrace stackTrace) {
          developer.log(
            'Failed to trim the audio cache.',
            name: 'Zmusic.AudioCache',
            error: error,
            stackTrace: stackTrace,
          );
        })
        .whenComplete(() {
          if (identical(_scheduledTrim, operation)) {
            _scheduledTrim = null;
          }
        });
    _scheduledTrim = operation;
  }

  Future<void> _trimCache(AppSettings settings) async {
    final directory = await _cacheDirectory(settings);
    if (!directory.existsSync()) {
      return;
    }

    final files = <File>[];
    var total = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      total += await entity.length();
      if (!_isAuxiliaryAudioCacheFile(entity) &&
          !await audioCachePartialMarker(entity).exists()) {
        files.add(entity);
      }
    }
    final trimTriggerSize = settings.cacheSizeBytes * 95 ~/ 100;
    if (total < trimTriggerSize) {
      return;
    }

    final targetSize = settings.cacheSizeBytes * 90 ~/ 100;
    files.sort(
      (left, right) =>
          left.lastModifiedSync().compareTo(right.lastModifiedSync()),
    );
    for (final file in files) {
      if (total <= targetSize) {
        return;
      }
      total -= await _tryDeleteCacheFileFamily(file);
    }
  }

  Future<Directory> _cacheDirectory(AppSettings settings) async {
    final configured = settings.cacheDirectory.trim();
    if (configured.isNotEmpty) {
      return Directory(configured);
    }
    return Directory(await defaultCacheDirectory());
  }
}

File audioCacheCompletionMarker(File cacheFile) {
  return File('${cacheFile.path}.complete');
}

File audioCachePartialMarker(File cacheFile) {
  return File('${cacheFile.path}.part');
}

Future<void> markAudioCachePartial(File cacheFile) async {
  final marker = audioCacheCompletionMarker(cacheFile);
  if (await marker.exists()) {
    await marker.delete();
  }
  final partial = audioCachePartialMarker(cacheFile);
  if (!await partial.exists()) {
    await partial.create(recursive: true);
  }
}

Future<void> markAudioCacheComplete(File cacheFile) async {
  final marker = audioCacheCompletionMarker(cacheFile);
  final cacheLength = await cacheFile.length();
  await marker.writeAsString(cacheLength.toString(), flush: true);
  final partial = audioCachePartialMarker(cacheFile);
  if (await partial.exists()) {
    try {
      await partial.delete();
    } on FileSystemException {
      if (await partial.exists()) {
        rethrow;
      }
    }
  }
}

bool isCompletedAudioCacheFile(File cacheFile) {
  try {
    if (!cacheFile.existsSync() || cacheFile.lengthSync() <= 0) {
      return false;
    }
    final marker = audioCacheCompletionMarker(cacheFile);
    if (!marker.existsSync()) {
      return false;
    }
    final expectedLength = int.tryParse(marker.readAsStringSync().trim());
    return expectedLength != null &&
        expectedLength > 0 &&
        expectedLength == cacheFile.lengthSync();
  } on FileSystemException {
    return false;
  }
}

Future<void> _ensureAudioCacheCompletionMarker(File cacheFile) async {
  await markAudioCacheComplete(cacheFile);
}

Future<bool> _discardIncompleteCacheFile(File cacheFile) async {
  if (!cacheFile.existsSync()) {
    return true;
  }
  if (isCompletedAudioCacheFile(cacheFile)) {
    return true;
  }
  await _tryDeleteCacheFileFamily(cacheFile);
  return !await cacheFile.exists() &&
      !await audioCacheCompletionMarker(cacheFile).exists() &&
      !await _audioCacheMimeFile(cacheFile).exists() &&
      !await audioCachePartialMarker(cacheFile).exists();
}

Future<int> _tryDeleteCacheFileFamily(File cacheFile) async {
  var removedBytes = 0;
  if (await cacheFile.exists()) {
    final removed = await _tryDeleteFile(cacheFile);
    if (await cacheFile.exists()) {
      return 0;
    }
    removedBytes += removed;
  }
  for (final file in [
    audioCacheCompletionMarker(cacheFile),
    _audioCacheMimeFile(cacheFile),
    audioCachePartialMarker(cacheFile),
  ]) {
    removedBytes += await _tryDeleteFile(file);
  }
  return removedBytes;
}

Future<int> _tryDeleteFile(File file) async {
  if (!await file.exists()) {
    return 0;
  }
  var length = 0;
  try {
    length = await file.length();
    await file.delete();
    return length;
  } on FileSystemException {
    return 0;
  }
}

String _primaryAudioCachePath(String path) {
  for (final suffix in const ['.complete', '.mime', '.part']) {
    if (path.endsWith(suffix)) {
      return path.substring(0, path.length - suffix.length);
    }
  }
  return path;
}

String _cachePathKey(String path) {
  final absolute = File(path).absolute.path;
  return Platform.isWindows ? absolute.toLowerCase() : absolute;
}

File _audioCacheMimeFile(File cacheFile) {
  return File('${cacheFile.path}.mime');
}

bool _isAuxiliaryAudioCacheFile(File file) {
  final path = file.path;
  return path.endsWith('.complete') ||
      path.endsWith('.mime') ||
      path.endsWith('.part');
}

String _cacheFileName(Track track, Uri uri) {
  final extension = _cacheExtension(track, uri);
  final digest = sha1.convert(_cacheIdentity(track).codeUnits).toString();
  return '$digest$extension';
}

String _cacheIdentity(Track track) {
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

String _cacheExtension(Track track, Uri uri) {
  final requestedFormat = readAudioFormat(uri.queryParameters['format']);
  if (requestedFormat != null &&
      isSupportedAudioPath('audio.${requestedFormat.toLowerCase()}')) {
    return '.${requestedFormat.toLowerCase()}';
  }

  final extension = uri.pathSegments.isEmpty
      ? ''
      : '.${uri.pathSegments.last.split('.').last}';
  if (extension.length > 1 && isSupportedAudioPath('audio$extension')) {
    return extension;
  }
  final audioFormat = track.audioFormat?.toLowerCase();
  if (audioFormat != null && isSupportedAudioPath('audio.$audioFormat')) {
    return '.$audioFormat';
  }
  return '.mp3';
}
