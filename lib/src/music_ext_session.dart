import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Origin': uri.origin,
          ...headers,
        })
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
    if (handoff.statusCode != 200) {
      throw const FormatException('无法验证 Music Ext 登录，请检查服务地址与 Navidrome 配置。');
    }
    final ticket = (jsonDecode(handoff.body) as Map<String, dynamic>)['ticket'];
    if (ticket is! String || ticket.isEmpty) {
      throw const FormatException('Music Ext 返回的登录凭证无效。');
    }
    final exchange = await _post(base.resolve('api/auth/exchange'), {
      'ticket': ticket,
    });
    final cookie = RegExp(
      r'music_ext_session=([^;]+)',
    ).firstMatch(exchange.headers['set-cookie'] ?? '')?.group(1);
    if (exchange.statusCode != 200 || cookie == null) {
      throw const FormatException('Music Ext 会话创建失败，请重新打开。');
    }
    final csrf = (jsonDecode(exchange.body) as Map<String, dynamic>)['csrf'];
    if (csrf is! String) {
      throw const FormatException('Music Ext 会话响应不完整。');
    }
    return MusicExtSession._(base, cookie, csrf);
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
