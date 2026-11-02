import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'music_ext_session.dart';

class MusicExtUploadException implements Exception {
  const MusicExtUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MusicExtUploadResult {
  const MusicExtUploadResult(this.filename, this.directory);

  final String filename;
  final String directory;
}

/// Owned by the metadata page; credentials and staged-file tokens stay in memory.
class MusicExtUploadClient {
  MusicExtUploadClient(this.address, this.server);

  final String address;
  final ServerConfig server;
  final http.Client _client = http.Client();
  Future<MusicExtSession>? _sessionFuture;
  Completer<void>? _activeAbort;
  bool _closed = false;
  String? _pendingToken;
  String? lyricsConfirmationMessage;

  static const _uncertainResult = '保存结果未确认，请检查 Music Ext 保存目录后再决定是否重传。';
  static const _extensions = {'mp3', 'flac', 'm4a', 'ogg', 'opus', 'wav'};

  Future<MusicExtSession> _session() async {
    if (_closed) {
      throw const MusicExtUploadException('上传连接已关闭。');
    }
    try {
      final session = await (_sessionFuture ??= MusicExtSession.open(
        address,
        server,
      ));
      if (_closed) {
        await session.close();
        throw const MusicExtUploadException('上传连接已关闭。');
      }
      return session;
    } on MusicExtUploadException {
      rethrow;
    } on FormatException catch (error) {
      _sessionFuture = null;
      throw MusicExtUploadException(error.message);
    } catch (_) {
      _sessionFuture = null;
      throw const MusicExtUploadException('连接 Music Ext 失败，请检查网络后重试。');
    }
  }

  Future<http.Response> _send(
    String method,
    String path, {
    File? file,
    int? length,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? query,
    bool savingFile = false,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final session = await _session();
    final abort = Completer<void>();
    _activeAbort = abort;
    final uri = session.baseUri.resolve(path).replace(queryParameters: query);
    final http.BaseRequest request;
    if (file != null) {
      request = _AudioUploadRequest(
        uri,
        file,
        length!,
        onProgress!,
        abort.future,
      );
    } else {
      final jsonRequest = http.AbortableRequest(
        method,
        uri,
        abortTrigger: abort.future,
      );
      if (method == 'POST') {
        jsonRequest.body = '{}';
      }
      request = jsonRequest;
    }
    request
      ..followRedirects = false
      ..headers.addAll({
        'Cookie': 'music_ext_session=${session.cookie}',
        'X-CSRF-Token': session.csrf,
        'Origin': session.baseUri.origin,
        'Content-Type': file == null
            ? 'application/json'
            : 'application/octet-stream',
      });
    try {
      return await (() async {
        return http.Response.fromStream(await _client.send(request));
      })().timeout(
        timeout,
        onTimeout: () {
          if (!abort.isCompleted) {
            abort.complete();
          }
          throw MusicExtUploadException(
            savingFile ? '上传请求超时。$_uncertainResult' : 'Music Ext 请求超时，请稍后重试。',
          );
        },
      );
    } on MusicExtUploadException {
      rethrow;
    } catch (_) {
      // Never expose request headers or automatically resend a possible save.
      throw MusicExtUploadException(
        savingFile ? '上传连接中断。$_uncertainResult' : '无法连接 Music Ext，请检查网络后重试。',
      );
    } finally {
      if (identical(_activeAbort, abort)) {
        _activeAbort = null;
      }
    }
  }

  Map<String, dynamic> _json(http.Response response) {
    try {
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  void _requireSuccess(http.Response response, {bool savingFile = false}) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    final detail = _json(response)['detail'];
    final fallback = switch (response.statusCode) {
      401 => 'Music Ext 登录已失效，请重新点击上传。',
      403 => '没有上传权限或来源验证失败，请检查 Music Ext 配置。',
      404 => '上传接口或确认令牌不存在，令牌可能已过期。',
      408 => '上传请求超时。',
      413 => '文件超过 Music Ext 允许的大小。',
      415 => '不支持此音频格式，或音频文件校验失败。',
      422 => '内嵌元数据不完整，请检查标题、歌手、专辑和封面。',
      429 => 'Music Ext 当前繁忙或请求过于频繁，请稍后重试。',
      _ => 'Music Ext 请求失败（${response.statusCode}）。',
    };
    final message = detail is String && detail.trim().isNotEmpty
        ? detail
        : detail is Map && detail['message'] is String
        ? detail['message'] as String
        : fallback;
    throw MusicExtUploadException(
      savingFile &&
              (response.statusCode == 408 ||
                  response.statusCode >= 500 ||
                  response.isRedirect)
          ? '$message $_uncertainResult'
          : message,
    );
  }

  Future<MusicExtUploadResult?> upload(
    File file, {
    required void Function(int sent, int total) onProgress,
  }) async {
    final filename = file.uri.pathSegments.last;
    if (!_extensions.contains(filename.split('.').last.toLowerCase())) {
      throw const MusicExtUploadException('上传仅支持 MP3、FLAC、M4A、OGG、Opus 和 WAV。');
    }
    final length = await file.length();
    if (length <= 0 || length > 512 * 1024 * 1024) {
      throw const MusicExtUploadException('请选择非空音频文件，大小不能超过 512 MiB。');
    }
    final capability = await _send('GET', 'api/uploads');
    _requireSuccess(capability);
    final config = _json(capability);
    if (config['can_upload'] != true) {
      throw const MusicExtUploadException('当前账号没有 Music Ext 上传权限。');
    }
    final maxBytes = config['max_bytes'];
    if (maxBytes is! num || maxBytes <= 0) {
      throw const MusicExtUploadException('Music Ext 返回的上传配置无效。');
    }
    if (length > maxBytes) {
      throw const MusicExtUploadException('文件超过 Music Ext 当前允许的大小。');
    }
    final response = await _send(
      'POST',
      'api/uploads',
      query: {'filename': filename},
      file: file,
      length: length,
      onProgress: onProgress,
      savingFile: true,
      timeout: const Duration(minutes: 15),
    );
    final detail = _json(response)['detail'];
    if (response.statusCode == 428 &&
        detail is Map &&
        detail['code'] == 'lyrics_confirmation_required' &&
        detail['token'] is String &&
        (detail['token'] as String).isNotEmpty) {
      _pendingToken = detail['token'] as String;
      lyricsConfirmationMessage = detail['message'] is String
          ? detail['message'] as String
          : '未检测到有效的内嵌歌词，仍要保存这个文件吗？';
      return null;
    }
    return _savedResult(response);
  }

  MusicExtUploadResult _savedResult(http.Response response) {
    _requireSuccess(response, savingFile: true);
    final result = _json(response);
    final filename = result['filename'];
    final directory = result['directory'];
    if (filename is! String ||
        filename.isEmpty ||
        directory is! String ||
        directory.isEmpty) {
      throw const MusicExtUploadException('服务器保存响应不完整。$_uncertainResult');
    }
    _pendingToken = null;
    lyricsConfirmationMessage = null;
    return MusicExtUploadResult(filename, directory);
  }

  Future<MusicExtUploadResult> confirm() async {
    final token = _pendingToken;
    if (token == null) {
      throw const MusicExtUploadException('没有待确认的上传文件。');
    }
    return _savedResult(
      await _send(
        'POST',
        'api/uploads/${Uri.encodeComponent(token)}/confirm',
        savingFile: true,
        timeout: const Duration(minutes: 2),
      ),
    );
  }

  Future<void> cancelPending() async {
    final token = _pendingToken;
    if (token == null) {
      return;
    }
    final response = await _send(
      'POST',
      'api/uploads/${Uri.encodeComponent(token)}/cancel',
    );
    _requireSuccess(response);
    _pendingToken = null;
    lyricsConfirmationMessage = null;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final abort = _activeAbort;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
    _client.close();
    final sessionFuture = _sessionFuture;
    if (sessionFuture == null) {
      return;
    }
    try {
      final session = await sessionFuture;
      final token = _pendingToken;
      if (token != null) {
        final cleanup = http.Client();
        try {
          final request =
              http.Request(
                  'POST',
                  session.baseUri.resolve(
                    'api/uploads/${Uri.encodeComponent(token)}/cancel',
                  ),
                )
                ..followRedirects = false
                ..headers.addAll({
                  'Cookie': 'music_ext_session=${session.cookie}',
                  'X-CSRF-Token': session.csrf,
                  'Origin': session.baseUri.origin,
                  'Content-Type': 'application/json',
                })
                ..body = '{}';
          await (() async {
            await http.Response.fromStream(await cleanup.send(request));
          })().timeout(const Duration(seconds: 10));
        } catch (_) {
          // An unreachable staged file expires on the server after ten minutes.
        } finally {
          cleanup.close();
        }
      }
      await session.close();
    } catch (_) {
      // Closing the page must not surface a stale authentication failure.
    }
  }
}

class _AudioUploadRequest extends http.BaseRequest with http.Abortable {
  _AudioUploadRequest(
    Uri uri,
    this.file,
    int length,
    this.onProgress,
    this.abortTrigger,
  ) : super('POST', uri) {
    contentLength = length;
  }

  final File file;
  final void Function(int sent, int total) onProgress;
  @override
  final Future<void> abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    var sent = 0;
    final total = contentLength!;
    return http.ByteStream(
      file.openRead(0, total).map((chunk) {
        sent += chunk.length;
        onProgress(sent, total);
        return chunk;
      }),
    );
  }
}
