import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

final Uri appUpdateManifestUri = Uri.parse(
  'https://file.zuitimes.com/zmusic/0/update.json',
);

const MethodChannel _androidTaskChannel = MethodChannel('com.zmusic.app/task');

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.latestVersion,
    required this.versionCode,
    required this.downloadUri,
    required this.fileName,
    required this.updateContent,
    required this.releaseTime,
  });

  final String latestVersion;
  final int versionCode;
  final Uri downloadUri;
  final String fileName;
  final List<String> updateContent;
  final String releaseTime;
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
    final response = httpClient == null
        ? await http.get(manifestUri)
        : await httpClient!.get(manifestUri);
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
    final downloadUri = Uri.tryParse(_requiredString(platform, 'downloadUrl'));
    if (downloadUri == null ||
        !downloadUri.hasScheme ||
        (downloadUri.scheme != 'http' && downloadUri.scheme != 'https')) {
      throw const FormatException('更新下载地址无效。');
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
      fileName: _optionalString(platform['fileName']),
      updateContent: updateContent,
      releaseTime: _optionalString(platform['releaseTime']),
    );
  }

  Future<File> downloadUpdate(
    AppUpdateInfo update, {
    required ValueChanged<AppUpdateDownloadProgress> onProgress,
    Directory? destinationDirectory,
  }) async {
    final directory =
        destinationDirectory ??
        Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}zmusic-updates',
        );
    await directory.create(recursive: true);

    final fileName = _safeUpdateFileName(
      update.fileName.isEmpty
          ? update.downloadUri.pathSegments.last
          : update.fileName,
    );
    final destination = File(
      '${directory.path}${Platform.pathSeparator}$fileName',
    );

    final createdClient = httpClient == null ? http.Client() : null;
    final client = httpClient ?? createdClient!;
    onProgress(
      const AppUpdateDownloadProgress(receivedBytes: 0, totalBytes: null),
    );

    try {
      final request = http.Request('GET', update.downloadUri);
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
      return destination;
    } catch (_) {
      if (destination.existsSync()) {
        try {
          destination.deleteSync();
        } catch (_) {}
      }
      rethrow;
    } finally {
      createdClient?.close();
    }
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
