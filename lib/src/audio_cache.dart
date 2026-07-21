import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_paths.dart';
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
      await _ensureAudioCacheCompletionMarker(cachedFile);
      await cachedFile.setLastModified(DateTime.now());
      return PlaybackTrack(
        track: track.copyWith(streamUrl: Uri.file(cachedFile.path).toString()),
      );
    }
    await _discardIncompleteCacheFile(cachedFile);
    await markAudioCachePartial(cachedFile);
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

  Future<void> clearCache(AppSettings settings) async {
    final directory = await _cacheDirectory(settings);
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);
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
      final length = await _cacheFileFamilySize(file);
      await _deleteCacheFileFamily(file);
      total -= length;
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
  if (!await marker.exists()) {
    await marker.create(recursive: true);
  }
  final partial = audioCachePartialMarker(cacheFile);
  if (await partial.exists()) {
    await partial.delete();
  }
}

bool isCompletedAudioCacheFile(File cacheFile) {
  if (!cacheFile.existsSync() || cacheFile.lengthSync() <= 0) {
    return false;
  }
  if (audioCacheCompletionMarker(cacheFile).existsSync()) {
    return true;
  }
  return _audioCacheMimeFile(cacheFile).existsSync() &&
      !_audioCachePartialFile(cacheFile).existsSync();
}

Future<void> _ensureAudioCacheCompletionMarker(File cacheFile) async {
  await markAudioCacheComplete(cacheFile);
}

Future<void> _discardIncompleteCacheFile(File cacheFile) async {
  if (!cacheFile.existsSync()) {
    return;
  }
  if (isCompletedAudioCacheFile(cacheFile)) {
    return;
  }
  await _deleteCacheFileFamily(cacheFile);
}

Future<int> _cacheFileFamilySize(File cacheFile) async {
  var total = 0;
  for (final file in [
    cacheFile,
    audioCacheCompletionMarker(cacheFile),
    _audioCacheMimeFile(cacheFile),
    audioCachePartialMarker(cacheFile),
  ]) {
    if (await file.exists()) {
      total += await file.length();
    }
  }
  return total;
}

Future<void> _deleteCacheFileFamily(File cacheFile) async {
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  final marker = audioCacheCompletionMarker(cacheFile);
  if (await marker.exists()) {
    await marker.delete();
  }
  final mimeFile = File('${cacheFile.path}.mime');
  if (await mimeFile.exists()) {
    await mimeFile.delete();
  }
  final partial = audioCachePartialMarker(cacheFile);
  if (await partial.exists()) {
    await partial.delete();
  }
}

File _audioCachePartialFile(File cacheFile) {
  return audioCachePartialMarker(cacheFile);
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
