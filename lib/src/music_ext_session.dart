import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'app_logger.dart';
import 'models.dart';

Uri musicExtUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('请输入 Music Ext 的完整地址，使用独立域名或端口。');
  }
  return uri.replace(path: '/');
}

/// A page owns this session. Its proof, cookie and CSRF token stay in memory.
class MusicExtSession {
  MusicExtSession._(this.baseUri, this.cookie, this.csrf);

  final Uri baseUri;
  final String cookie;
  final String csrf;
  bool _closed = false;

  static Future<http.Response> _post(
    Uri uri,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) async {
    final client = http.Client();
    try {
      // Native requests have no browser origin. Let the WebView supply its own
      // browser headers; authenticate these requests with the proof/session.
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({'Content-Type': 'application/json', ...headers})
        ..body = jsonEncode(body);
      return await (() async {
        return http.Response.fromStream(await client.send(request));
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close();
    }
  }

  static Future<MusicExtSession> open(
    String address,
    ServerConfig server,
  ) async {
    final base = musicExtUri(address);
    final random = Random.secure();
    final salt = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final token = md5.convert(utf8.encode(server.password + salt)).toString();
    final handoff = await _post(base.resolve('api/auth/handoff'), {
      'username': server.username,
      'token': token,
      'salt': salt,
    });
    _requireSuccess(handoff, '登录验证');
    final ticket = (jsonDecode(handoff.body) as Map<String, dynamic>)['ticket'];
    if (ticket is! String || ticket.isEmpty) {
      throw const FormatException('Music Ext 返回的登录凭证无效。');
    }
    final exchange = await _post(base.resolve('api/auth/exchange'), {
      'ticket': ticket,
    });
    _requireSuccess(exchange, '会话创建');
    final cookie = RegExp(
      r'music_ext_session=([^;]+)',
    ).firstMatch(exchange.headers['set-cookie'] ?? '')?.group(1);
    if (cookie == null) {
      throw const FormatException('Music Ext 会话创建失败，请重新打开。');
    }
    final csrf = (jsonDecode(exchange.body) as Map<String, dynamic>)['csrf'];
    if (csrf is! String) {
      throw const FormatException('Music Ext 会话响应不完整。');
    }
    return MusicExtSession._(base, cookie, csrf);
  }

  static void _requireSuccess(http.Response response, String stage) {
    if (response.statusCode == 200) {
      return;
    }
    String? detail;
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map && body['detail'] is String) {
        detail = body['detail'] as String;
      }
    } on FormatException {
      // A reverse proxy may return an HTML error instead of the API's JSON.
    }
    final status = response.statusCode;
    final String message;
    if (status == 403 && detail == '不允许跨站请求') {
      message = 'Music Ext 拒绝本次原生请求（HTTP 403），请稍后重新打开。';
    } else if (status == 401) {
      message =
          'Music Ext $stage失败（HTTP 401）。请确认它与 Zmusic 连接同一个 Navidrome，并重新登录。';
    } else if (status == 429) {
      message = 'Music Ext 登录请求过于频繁（HTTP 429），请稍后再试。';
    } else {
      message = 'Music Ext $stage失败（HTTP $status），请检查服务及反向代理配置。';
    }
    // Only log our own messages, never response bodies or authentication data.
    AppLogger.instance.error('music-ext', message);
    throw FormatException(message);
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _post(
        baseUri.resolve('api/auth/logout'),
        {},
        headers: {'Cookie': 'music_ext_session=$cookie', 'X-CSRF-Token': csrf},
      );
    } catch (_) {
      // The local WebView cookie is removed separately, even if the NAS is offline.
    }
  }
}
