import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

final Uri appUpdateManifestUri = Uri.parse(
  'https://file.zuitimes.com/zmusic/0/update.json',
);

const MethodChannel _androidTaskChannel = MethodChannel('com.zmusic.app/task');
const String _pendingUpdateMetadataFileName = 'pending-update.json';

enum AppUpdateDownloadChannel { defaultChannel, github }

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.latestVersion,
    required this.versionCode,
    required this.downloadUri,
    this.githubDownloadUri,
    required this.fileName,
    required this.sha256Checksum,
    required this.updateContent,
    required this.releaseTime,
  });

  final String latestVersion;
  final int versionCode;
  final Uri downloadUri;
  final Uri? githubDownloadUri;
  final String fileName;
  final String sha256Checksum;
  final List<String> updateContent;
  final String releaseTime;

  Uri downloadUriFor(AppUpdateDownloadChannel channel) {
    if (channel == AppUpdateDownloadChannel.github) {
      return githubDownloadUri ?? downloadUri;
    }
    return downloadUri;
  }
}

class AppUpdateDownloadProgress {
  const AppUpdateDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0, 1).toDouble();
  }
}

class AppUpdateService {
  AppUpdateService({this.httpClient, Uri? manifestUri})
    : manifestUri = manifestUri ?? appUpdateManifestUri;

  final http.Client? httpClient;
  final Uri manifestUri;

  Future<AppUpdateInfo> fetchForPlatform(String platformKey) async {
    final requestUri = _withCacheBust(manifestUri);
    final response = httpClient == null
        ? await http.get(requestUri, headers: _noCacheHeaders)
        : await httpClient!.get(requestUri, headers: _noCacheHeaders);
    if (response.statusCode != 200) {
      throw Exception('更新服务返回状态码 ${response.statusCode}。');
    }

    final source = utf8.decode(response.bodyBytes).replaceFirst('\ufeff', '');
    final root = _decodeManifest(source);
    final platforms = root['platforms'];
    if (platforms is! Map<String, dynamic>) {
      throw const FormatException('更新清单缺少 platforms。');
    }
    final platform = platforms[platformKey];
    if (platform is! Map<String, dynamic>) {
      throw FormatException('更新清单缺少 $platformKey。');
    }

    final latestVersion = _requiredString(platform, 'latestVersion');
    final sha256Checksum = _requiredString(platform, 'sha256').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256Checksum)) {
      throw const FormatException('更新清单中的 SHA256 无效。');
    }
    final downloadUri = Uri.tryParse(_requiredString(platform, 'downloadUrl'));
    if (downloadUri == null ||
        !downloadUri.hasScheme ||
        (downloadUri.scheme != 'http' && downloadUri.scheme != 'https')) {
      throw const FormatException('更新下载地址无效。');
    }
    final githubDownloadUrl = _optionalString(platform['githubDownloadUrl']);
    final githubDownloadUri = githubDownloadUrl.isEmpty
        ? null
        : Uri.tryParse(githubDownloadUrl);
    if (githubDownloadUrl.isNotEmpty &&
        (githubDownloadUri == null ||
            !githubDownloadUri.hasScheme ||
            (githubDownloadUri.scheme != 'http' &&
                githubDownloadUri.scheme != 'https'))) {
      throw const FormatException('GitHub 更新下载地址无效。');
    }
    final content = platform['updateContent'];
    final updateContent = content is List
        ? content
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(growable: false)
        : const <String>[];

    return AppUpdateInfo(
      latestVersion: latestVersion,
      versionCode: _readInt(platform['versionCode']),
      downloadUri: downloadUri,
      githubDownloadUri: githubDownloadUri,
      fileName: _optionalString(platform['fileName']),
      sha256Checksum: sha256Checksum,
      updateContent: updateContent,
      releaseTime: _optionalString(platform['releaseTime']),
    );
  }

  Future<void> cleanupInstalledUpdate({
    required int installedVersionCode,
    Directory? destinationDirectory,
  }) async {
    if (installedVersionCode <= 0) {
      return;
    }
    final directory = await _resolveUpdateDirectory(destinationDirectory);
    final metadataFile = File(
      '${directory.path}${Platform.pathSeparator}$_pendingUpdateMetadataFileName',
    );
    if (!await metadataFile.exists()) {
      return;
    }
    try {
      final metadata = jsonDecode(await metadataFile.readAsString());
      final targetVersionCode = metadata is Map<String, dynamic>
          ? _readInt(metadata['versionCode'])
          : 0;
      if (targetVersionCode <= 0) {
        await directory.delete(recursive: true);
        return;
      }
      if (installedVersionCode >= targetVersionCode) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      rethrow;
    } on FormatException {
      await directory.delete(recursive: true);
    }
  }

  Future<File> downloadUpdate(
    AppUpdateInfo update, {
    AppUpdateDownloadChannel channel = AppUpdateDownloadChannel.defaultChannel,
    required ValueChanged<AppUpdateDownloadProgress> onProgress,
    Directory? destinationDirectory,
  }) async {
    final directory = await _resolveUpdateDirectory(destinationDirectory);
    await directory.create(recursive: true);

    final downloadUri = update.downloadUriFor(channel);
    final fileName = _safeUpdateFileName(
      update.fileName.isEmpty ? downloadUri.pathSegments.last : update.fileName,
    );
    final destination = File(
      '${directory.path}${Platform.pathSeparator}$fileName',
    );
    final metadataFile = File(
      '${directory.path}${Platform.pathSeparator}$_pendingUpdateMetadataFileName',
    );

    onProgress(
      const AppUpdateDownloadProgress(receivedBytes: 0, totalBytes: null),
    );
    if (await destination.exists()) {
      try {
        final cachedSize = await destination.length();
        final cachedSha256 = await _fileSha256(destination);
        if (cachedSha256 == update.sha256Checksum) {
          await _writePendingUpdateMetadata(
            metadataFile,
            update: update,
            fileName: fileName,
          );
          onProgress(
            AppUpdateDownloadProgress(
              receivedBytes: cachedSize,
              totalBytes: cachedSize,
            ),
          );
          return destination;
        }
      } on FileSystemException {
        // Invalid or inaccessible cached packages are replaced by a new download.
      }
      await _deleteFileIfPresent(destination);
      await _deleteFileIfPresent(metadataFile);
    }

    final createdClient = httpClient == null ? http.Client() : null;
    final client = httpClient ?? createdClient!;

    try {
      final requestUri = _withCacheBust(downloadUri);
      final request = http.Request('GET', requestUri)
        ..headers.addAll(_noCacheHeaders);
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('更新文件下载失败：HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength;
      var receivedBytes = 0;
      onProgress(
        AppUpdateDownloadProgress(
          receivedBytes: receivedBytes,
          totalBytes: totalBytes,
        ),
      );

      final sink = destination.openWrite();
      try {
        await for (final chunk in response.stream) {
          receivedBytes += chunk.length;
          sink.add(chunk);
          onProgress(
            AppUpdateDownloadProgress(
              receivedBytes: receivedBytes,
              totalBytes: totalBytes,
            ),
          );
        }
      } finally {
        await sink.close();
      }
      final downloadedSha256 = await _fileSha256(destination);
      if (downloadedSha256 != update.sha256Checksum) {
        throw Exception(
          '更新文件 SHA256 校验失败，期望 ${update.sha256Checksum.toUpperCase()}，'
          '实际 ${downloadedSha256.toUpperCase()}。',
        );
      }
      await _writePendingUpdateMetadata(
        metadataFile,
        update: update,
        fileName: fileName,
      );
      return destination;
    } catch (_) {
      await _deleteFileIfPresent(destination);
      await _deleteFileIfPresent(metadataFile);
      rethrow;
    } finally {
      createdClient?.close();
    }
  }
}

Future<Directory> _resolveUpdateDirectory(
  Directory? destinationDirectory,
) async {
  if (destinationDirectory != null) {
    return destinationDirectory;
  }
  final tempDirectory = defaultTargetPlatform == TargetPlatform.android
      ? await getTemporaryDirectory()
      : Directory.systemTemp;
  return Directory(
    '${tempDirectory.path}${Platform.pathSeparator}zmusic-updates',
  );
}

Future<String> _fileSha256(File file) async {
  return (await file.openRead().transform(sha256).first)
      .toString()
      .toLowerCase();
}

Future<void> _writePendingUpdateMetadata(
  File metadataFile, {
  required AppUpdateInfo update,
  required String fileName,
}) async {
  await metadataFile.writeAsString(
    jsonEncode({
      'versionCode': update.versionCode,
      'fileName': fileName,
      'sha256': update.sha256Checksum,
    }),
    flush: true,
  );
}

Future<void> _deleteFileIfPresent(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on FileSystemException {
    // A later write will surface the useful error if the stale file is locked.
  }
}

Future<String> resolveAppUpdatePlatformKey() async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return 'windows';
  }
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return 'macos';
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return 'ios';
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      final channel = await _androidTaskChannel.invokeMethod<String>(
        'getUpdateChannel',
      );
      if (channel == 'android-dilink') {
        return 'android-dilink';
      }
    } on PlatformException {
      // Standard Android is the safe fallback when the native channel is absent.
    } on MissingPluginException {
      // Widget tests and older builds do not expose the native channel.
    }
    return 'android';
  }
  throw UnsupportedError('当前平台暂不支持应用内更新。');
}

Future<void> openAndroidUpdateInstaller(File updateFile) async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    throw UnsupportedError('当前平台不支持 Android 更新安装。');
  }
  await _androidTaskChannel.invokeMethod<void>('installUpdate', {
    'path': updateFile.path,
  });
}

bool isNewerAppVersion(String latestVersion, String currentVersion) {
  final latest = _numericVersionParts(latestVersion);
  final current = _numericVersionParts(currentVersion);
  final length = latest.length > current.length
      ? latest.length
      : current.length;
  for (var index = 0; index < length; index++) {
    final latestPart = index < latest.length ? latest[index] : 0;
    final currentPart = index < current.length ? current[index] : 0;
    if (latestPart != currentPart) {
      return latestPart > currentPart;
    }
  }
  return false;
}

Map<String, dynamic> _decodeManifest(String source) {
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    final withoutTrailingCommas = source.replaceAllMapped(
      RegExp(r',\s*([}\]])'),
      (match) => match.group(1)!,
    );
    decoded = jsonDecode(withoutTrailingCommas);
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('更新清单根节点无效。');
  }
  return decoded;
}

String _requiredString(Map<String, dynamic> values, String key) {
  final value = _optionalString(values[key]);
  if (value.isEmpty) {
    throw FormatException('更新清单缺少 $key。');
  }
  return value;
}

String _optionalString(Object? value) => value is String ? value.trim() : '';

String _safeUpdateFileName(String value) {
  final sanitized = value
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
    return 'zmusic-update.exe';
  }
  return sanitized;
}

int _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<int> _numericVersionParts(String version) {
  final mainVersion = version.trim().split(RegExp(r'[+-]')).first;
  return mainVersion
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList(growable: false);
}

const Map<String, String> _noCacheHeaders = {
  'Cache-Control': 'no-cache',
  'Pragma': 'no-cache',
};

Uri _withCacheBust(Uri uri) {
  return uri.replace(
    queryParameters: {
      ...uri.queryParameters,
      'v': DateTime.now().millisecondsSinceEpoch.toString(),
    },
  );
}
