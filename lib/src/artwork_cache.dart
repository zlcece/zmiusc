import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_paths.dart';
import 'models.dart';

class ArtworkCacheManager {
  ArtworkCacheManager({http.Client? httpClient, this.cacheDirectoryProvider})
    : _httpClient = httpClient ?? http.Client();

  static final ArtworkCacheManager instance = ArtworkCacheManager();

  final http.Client _httpClient;
  final Future<Directory> Function()? cacheDirectoryProvider;
  final Map<String, Future<File?>> _inFlight = {};
  final Set<String> _missingLocalArtwork = {};

  Future<File?> cacheArtwork(String? imageUrl) {
    final value = imageUrl?.trim() ?? '';
    final uri = Uri.tryParse(value);
    if (uri?.scheme == localEmbeddedArtworkScheme) {
      return _cacheLocalArtwork(uri?.queryParameters['path'] ?? '');
    }
    if (uri?.scheme == 'file') {
      final file = File.fromUri(uri!);
      return file.exists().then((exists) => exists ? file : null);
    }
    if (uri != null && uri.scheme.isEmpty && value.isNotEmpty) {
      final file = File(value);
      return file.exists().then((exists) => exists ? file : null);
    }
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return Future<File?>.value(null);
    }

    final key = stableArtworkCacheKey(uri.toString());
    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }

    late final Future<File?> future;
    future = _cacheArtwork(uri, key).whenComplete(() {
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
      }
    });
    _inFlight[key] = future;
    return future;
  }

  Future<String?> cacheEmbeddedArtwork(
    String sourcePath,
    List<int> bytes,
  ) async {
    if (bytes.isEmpty) {
      return null;
    }
    final file = await _cacheLocalArtwork(sourcePath, embeddedBytes: bytes);
    return file == null ? null : localEmbeddedArtworkUrl(sourcePath);
  }

  Future<File?> _cacheLocalArtwork(
    String sourcePath, {
    List<int>? embeddedBytes,
  }) async {
    if (sourcePath.trim().isEmpty) {
      return null;
    }
    final source = File(sourcePath);
    if (!await source.exists()) {
      return null;
    }

    final stat = await source.stat();
    final normalizedPath = Platform.isWindows
        ? source.absolute.path.toLowerCase()
        : source.absolute.path;
    final digest = sha1
        .convert(
          utf8.encode(
            '$normalizedPath|${stat.size}|${stat.modified.microsecondsSinceEpoch}',
          ),
        )
        .toString();
    final key = 'local-$digest';
    final directory = await _cacheDirectory();
    await directory.create(recursive: true);
    final file = File(joinPath(directory.path, ['$key.img']));
    if (await file.exists() && await file.length() > 0) {
      await file.setLastModified(DateTime.now());
      return file;
    }
    if (embeddedBytes == null && _missingLocalArtwork.contains(key)) {
      return null;
    }

    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }
    late final Future<File?> future;
    future =
        _writeLocalArtwork(
          source: source,
          destination: file,
          key: key,
          embeddedBytes: embeddedBytes,
        ).whenComplete(() {
          if (identical(_inFlight[key], future)) {
            _inFlight.remove(key);
          }
        });
    _inFlight[key] = future;
    return future;
  }

  Future<File?> _writeLocalArtwork({
    required File source,
    required File destination,
    required String key,
    List<int>? embeddedBytes,
  }) async {
    var bytes = embeddedBytes;
    if (bytes == null) {
      try {
        final metadata = readMetadata(source, getImage: true);
        if (metadata.pictures.isEmpty) {
          _missingLocalArtwork.add(key);
          return null;
        }
        final picture = metadata.pictures.firstWhere(
          (item) => item.pictureType == PictureType.coverFront,
          orElse: () => metadata.pictures.first,
        );
        bytes = picture.bytes;
      } catch (_) {
        return null;
      }
    }
    if (bytes.isEmpty) {
      _missingLocalArtwork.add(key);
      return null;
    }

    _missingLocalArtwork.remove(key);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await destination.exists()) {
      await destination.delete();
    }
    try {
      return await temporary.rename(destination.path);
    } on FileSystemException {
      await temporary.copy(destination.path);
      await temporary.delete();
      return destination;
    }
  }

  Future<File?> _cacheArtwork(Uri uri, String key) async {
    final directory = await _cacheDirectory();
    await directory.create(recursive: true);
    final file = File(joinPath(directory.path, ['$key.img']));
    if (await file.exists() && await file.length() > 0) {
      await file.setLastModified(DateTime.now());
      return file;
    }

    final response = await _httpClient.get(uri);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.bodyBytes.isEmpty) {
      return null;
    }

    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(response.bodyBytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    try {
      return await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.copy(file.path);
      await temporary.delete();
      return file;
    }
  }

  Future<void> clearCache() async {
    _missingLocalArtwork.clear();
    final directory = await _cacheDirectory();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);
  }

  Future<Directory> _cacheDirectory() async {
    final provider = cacheDirectoryProvider;
    if (provider != null) {
      return provider();
    }
    if (shouldUseInstallDirectoryData()) {
      return Directory(joinPath(installCacheDirectory().path, ['artwork']));
    }
    final directory = await getApplicationCacheDirectory();
    return Directory(joinPath(directory.path, ['artwork']));
  }
}

String stableArtworkCacheKey(String imageUrl) {
  final uri = Uri.tryParse(imageUrl.trim());
  if (uri == null || !uri.hasScheme) {
    return sha1.convert(imageUrl.trim().codeUnits).toString();
  }

  final entries = <MapEntry<String, String>>[];
  for (final entry in uri.queryParametersAll.entries) {
    if (_ignoredArtworkQueryParameters.contains(entry.key.toLowerCase())) {
      continue;
    }
    for (final value in entry.value) {
      entries.add(MapEntry(entry.key, value));
    }
  }
  entries.sort((left, right) {
    final byKey = left.key.compareTo(right.key);
    if (byKey != 0) {
      return byKey;
    }
    return left.value.compareTo(right.value);
  });

  final normalized = Uri(
    scheme: uri.scheme.toLowerCase(),
    userInfo: uri.userInfo,
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: entries.isEmpty ? null : Map.fromEntries(entries),
  );
  return sha1.convert(normalized.toString().codeUnits).toString();
}

const Set<String> _ignoredArtworkQueryParameters = {
  'u',
  't',
  's',
  'p',
  'v',
  'c',
  'f',
  '_',
  'token',
  'salt',
};
