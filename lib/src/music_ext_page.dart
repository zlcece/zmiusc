import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';

import 'app_controller.dart';
import 'music_ext_session.dart';

class MusicExtPage extends StatefulWidget {
  const MusicExtPage({
    required this.controller,
    required this.keyword,
    super.key,
  });

  final AppController controller;
  final String keyword;

  @override
  State<MusicExtPage> createState() => _MusicExtPageState();
}

class _MusicExtPageState extends State<MusicExtPage> {
  MusicExtSession? _session;
  PlatformInAppWebViewController? _webView;
  WindowsInAppWebViewWidget? _webViewWidget;
  Uri? _pageUri;
  String? _error;
  late final String _serverId;
  late final String _address;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _serverId = widget.controller.selectedServer!.id;
    _address = widget.controller.settings.musicExtUrl;
    widget.controller.addListener(_accountChanged);
    unawaited(_open());
  }

  void _accountChanged() {
    if (_closing || !mounted) {
      return;
    }
    if (widget.controller.selectedServer?.id != _serverId ||
        widget.controller.settings.musicExtUrl != _address) {
      _closing = true;
      Navigator.of(context).pop();
    }
  }

  Future<void> _open() async {
    try {
      if (Platform.isWindows &&
          await WindowsWebViewEnvironment.static().getAvailableVersion() ==
              null) {
        throw const FormatException(
          '请先安装 Microsoft Edge WebView2 Runtime，再打开外网搜歌。',
        );
      }
      final server = widget.controller.selectedServer;
      if (server == null || server.id != _serverId) {
        return;
      }
      final session = await MusicExtSession.open(_address, server);
      if (!mounted || _closing) {
        await session.close();
        return;
      }
      _session = session;
      final cookieSet = await WindowsCookieManager.instance().setCookie(
        url: WebUri(session.baseUri.toString()),
        name: 'music_ext_session',
        value: session.cookie,
        path: '/',
        isHttpOnly: true,
        isSecure: session.baseUri.scheme == 'https',
        sameSite: HTTPCookieSameSitePolicy.LAX,
      );
      if (!cookieSet) {
        throw const FormatException('系统 WebView 无法建立登录会话，请更新系统 WebView 后重试。');
      }
      if (!mounted || _closing) {
        await _clearSession(session);
        return;
      }
      setState(() {
        _pageUri = session.baseUri.replace(
          queryParameters: {
            'embedded': '1',
            if (widget.keyword.isNotEmpty) 'q': widget.keyword,
          },
        );
        _webViewWidget = _createWebView(_pageUri!);
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '外网搜歌暂时无法打开，请检查服务地址、网络和系统 WebView。',
        );
      }
    }
  }

  Future<void> _clearSession(MusicExtSession session) async {
    try {
      // Do not remove a newer page's cookie if this cleanup finishes late.
      final manager = WindowsCookieManager.instance();
      final uri = WebUri(session.baseUri.toString());
      final cookie = await manager.getCookie(
        url: uri,
        name: 'music_ext_session',
      );
      if (cookie?.value == session.cookie) {
        await manager.deleteCookie(
          url: uri,
          name: 'music_ext_session',
          path: '/',
        );
      }
    } catch (_) {
      // A failed WebView initialization must still revoke its server session.
    } finally {
      await session.close();
    }
  }

  @override
  void dispose() {
    _closing = true;
    widget.controller.removeListener(_accountChanged);
    _webViewWidget?.dispose();
    if (_session case final session?) {
      unawaited(_clearSession(session));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uri = _pageUri;
    return Scaffold(
      appBar: AppBar(
        title: const Text('外网搜歌'),
        actions: [
          IconButton(
            tooltip: '刷新页面',
            onPressed: _webView == null ? null : () => _webView!.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!),
              ),
            )
          : uri == null
          ? const Center(child: CircularProgressIndicator())
          : _webViewWidget!.build(context),
    );
  }

  WindowsInAppWebViewWidget _createWebView(Uri uri) {
    return WindowsInAppWebViewWidget(
      WindowsInAppWebViewWidgetCreationParams(
        initialUrlRequest: URLRequest(url: WebUri(uri.toString())),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          useShouldOverrideUrlLoading: true,
          allowFileAccess: false,
          allowContentAccess: false,
          supportMultipleWindows: false,
        ),
        onWebViewCreated: (controller) {
          if (mounted && !_closing) {
            setState(() => _webView = controller);
          }
        },
        shouldOverrideUrlLoading: (controller, action) async {
          return _sameOrigin(action.request.url, uri)
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
        onCreateWindow: (_, _) async => false,
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame == true && mounted) {
            setState(() => _error = '页面加载失败，请返回后重新打开。');
          }
        },
      ),
    );
  }

  bool _sameOrigin(Uri? candidate, Uri expected) {
    return candidate != null &&
        candidate.scheme == expected.scheme &&
        candidate.host == expected.host &&
        candidate.port == expected.port;
  }
}
