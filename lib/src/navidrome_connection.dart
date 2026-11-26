import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_logger.dart';

/// Keeps the saved server URL (and therefore library/cache identities) stable.
/// Only requests to the configured Navidrome REST endpoint are routed.
class NavidromeConnection extends ChangeNotifier {
  NavidromeConnection({
    this.discoveryUrl = const String.fromEnvironment('ZMUSIC_STUN_RULES_URL'),
  });

  final String discoveryUrl;
  final http.Client _probeClient = http.Client();
  final Set<Completer<void>> _pendingRequests = {};
  final Set<Completer<void>> _pendingProbes = {};
  Future<Uri?>? _startupAddressLookup;
  Future<bool>? _recovery;
  Uri? _relay;
  Uri? _cachedDirectAddress;
  Uri? _direct;
  Uri? _pendingDirect;
  bool _preferP2p = true;
  bool _retrying = false;
  bool _relayOnly = false;
  bool _disposed = false;
  int _generation = 0;

  bool get isP2p => _relay != null && _direct != null && !_relayOnly;
  String get label => isP2p ? 'p2p' : 'relay';
  bool get supportsP2p => _relay != null && discoveryUrl.trim().isNotEmpty;
  bool get retrying => _retrying;
  bool get hasPendingP2p => _pendingDirect != null;

  Future<void> prepare(String serverUrl, {required bool preferP2p}) async {
    final relay = Uri.tryParse(serverUrl);
    if (_disposed || _relay == relay) {
      return;
    }
    _invalidateChecks();
    _relay = null;
    _direct = null;
    _preferP2p = preferP2p;
    // This discovery rule belongs to this server, never to a custom server.
    if (relay == null ||
        relay.scheme != 'https' ||
        relay.host.isEmpty ||
        relay.origin != 'https://fnnav.zuitimes.com' ||
        (relay.path.isNotEmpty && relay.path != '/')) {
      notifyListeners();
      return;
    }
    _relay = relay;
    if (supportsP2p) {
      final generation = _generation;
      final lookup = _startupAddressLookup ??= _lookupDirectAddress(generation);
      if (_preferP2p && !_relayOnly) {
        await lookup;
        if (_disposed || generation != _generation) return;
        final candidate = _cachedDirectAddress;
        final reachable = candidate != null && await _probe(candidate);
        if (_disposed || generation != _generation) return;
        if (reachable) _direct = candidate;
      }
    }
    AppLogger.instance.info('connection', 'Navidrome 连接方式：$label');
    notifyListeners();
  }

  void setPreference({required bool preferP2p}) {
    if (preferP2p == _preferP2p) return;
    _preferP2p = preferP2p;
    if (!preferP2p) {
      _invalidateChecks();
      _relayOnly = true;
    }
    notifyListeners();
  }

  Future<bool?> retryP2p({
    required Future<bool Function()?> Function(Uri Function(Uri), Future<void>)
    preparePlaybackSwitch,
  }) async {
    if (_disposed ||
        !supportsP2p ||
        !_preferP2p ||
        isP2p ||
        _retrying ||
        hasPendingP2p) {
      return null;
    }
    final generation = _generation;
    _retrying = true;
    notifyListeners();
    final direct = await _findReachableDirectAddress(generation);
    if (_disposed || generation != _generation) return null;
    bool Function()? commitPlaybackSwitch;
    if (direct != null) {
      final abort = Completer<void>();
      _pendingProbes.add(abort);
      try {
        commitPlaybackSwitch = await preparePlaybackSwitch(
          (uri) => canRouteStream(uri) ? _withOrigin(uri, direct) : uri,
          abort.future,
        );
      } finally {
        _pendingProbes.remove(abort);
        if (!abort.isCompleted) abort.complete();
      }
    }
    if (_disposed || generation != _generation) return null;
    _retrying = false;
    _pendingDirect = direct;
    if (commitPlaybackSwitch?.call() == true) {
      activatePendingP2p();
    } else {
      notifyListeners();
    }
    return direct != null;
  }

  bool activatePendingP2p() {
    final direct = _pendingDirect;
    if (direct == null) return false;
    _pendingDirect = null;
    _direct = direct;
    _relayOnly = false;
    AppLogger.instance.info('connection', '已切换到 p2p');
    notifyListeners();
    return true;
  }

  void reset() {
    _invalidateChecks();
    _relay = null;
    _direct = null;
    notifyListeners();
  }

  void _invalidateChecks() {
    _generation++;
    _recovery = null;
    _pendingDirect = null;
    _retrying = false;
    for (final abort in _pendingProbes) {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Uri resolve(Uri canonical) {
    final relay = _relay;
    if (!isP2p || relay == null || !_isRestUri(canonical, relay)) {
      return canonical;
    }
    return _withOrigin(canonical, _direct!);
  }

  bool wasDirect(Uri uri) {
    final direct = _direct;
    return _relay != null && direct != null && _isRestUri(uri, direct);
  }

  bool canRouteStream(Uri uri) {
    final relay = _relay;
    return relay != null && (_isRestUri(uri, relay) || wasDirect(uri));
  }

  Uri currentStreamOrigin(Uri uri) =>
      canRouteStream(uri) ? _withOrigin(uri, isP2p ? _direct! : _relay!) : uri;

  static Uri _withOrigin(Uri uri, Uri base) => uri.origin == base.origin
      ? uri
      : uri.replace(scheme: base.scheme, host: base.host, port: base.port);

  void rejectDirectResume(Uri uri) {
    if (!isP2p || !wasDirect(uri)) return;
    _relayOnly = true;
    AppLogger.instance.warning('connection', 'P2P 续传失败，继续使用 relay');
    notifyListeners();
  }

  static bool _isRestUri(Uri uri, Uri base) =>
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.origin == base.origin &&
      uri.path.startsWith('/rest/');

  Future<http.Response> get(
    http.Client client,
    Uri canonical, {
    bool allowReplay = true,
  }) async {
    final target = resolve(canonical);
    if (target == canonical) {
      return client.get(canonical);
    }
    final generation = _generation;
    http.Response response;
    try {
      response = await _send(client, target, const Duration(seconds: 6));
    } on Object catch (error) {
      if (error is! TimeoutException &&
          error is! IOException &&
          error is! http.ClientException) {
        rethrow;
      }
      final recovered = await recover(target);
      if (allowReplay && recovered && generation == _generation) {
        return _send(client, canonical, const Duration(seconds: 20));
      }
      rethrow;
    }
    if (response.statusCode < 500 &&
        response.statusCode != HttpStatus.requestTimeout &&
        !(response.statusCode >= 300 && response.statusCode < 400)) {
      return response;
    }
    final recovered = await recover(target);
    if (allowReplay && recovered && generation == _generation) {
      return _send(client, canonical, const Duration(seconds: 20));
    }
    return response;
  }

  /// A single shared series of probes prevents concurrent failures from
  /// counting as multiple retries. Authentication/permission errors aren't
  /// connectivity failures.
  Future<bool> recover(Uri failedUri) async {
    if (_disposed || !wasDirect(failedUri)) {
      return false;
    }
    if (!isP2p) {
      return true;
    }
    final existing = _recovery;
    if (existing != null) return existing;
    final generation = _generation;
    late final Future<bool> recovery;
    recovery = _confirmUnavailable(generation).whenComplete(() {
      if (identical(_recovery, recovery)) _recovery = null;
    });
    _recovery = recovery;
    return recovery;
  }

  Future<bool> _confirmUnavailable(int generation) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_disposed || generation != _generation) return false;
      if (await _probe(_direct!)) return false;
      if (_disposed || generation != _generation) return false;
      AppLogger.instance.warning('connection', 'p2p 连接检测失败（${attempt + 1}/3）');
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    if (_disposed || generation != _generation) return false;
    _relayOnly = true;
    AppLogger.instance.warning('connection', 'p2p 连续 3 次不可达，已切换到 relay');
    notifyListeners();
    return true;
  }

  Future<Uri?> _findReachableDirectAddress(int generation) async {
    await _startupAddressLookup;
    if (_disposed || generation != _generation) return null;
    final cached = _cachedDirectAddress;
    if (cached != null && await _probe(cached)) return cached;
    if (_disposed || generation != _generation) return null;
    final refreshed = await _lookupDirectAddress(generation);
    if (_disposed || generation != _generation) return null;
    return refreshed != null && await _probe(refreshed) ? refreshed : null;
  }

  Future<Uri?> _lookupDirectAddress(int generation) async {
    final uri = Uri.tryParse(discoveryUrl.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return null;
    }
    try {
      final response = await _send(
        _probeClient,
        uri,
        const Duration(seconds: 5),
      );
      if (_disposed || generation != _generation) return null;
      if (response.statusCode != 200) {
        AppLogger.instance.warning(
          'connection',
          '公网地址查询返回 HTTP ${response.statusCode}，使用 relay',
        );
        return null;
      }
      final candidate = _publicAddress(jsonDecode(response.body));
      if (candidate != null) _cachedDirectAddress = candidate;
      return candidate;
    } on Object {
      // Never log the discovery URL, openToken or the API response.
      if (!_disposed && generation == _generation) {
        AppLogger.instance.warning('connection', '公网地址查询失败，使用 relay');
      }
    }
    return null;
  }

  static Uri? _publicAddress(Object? value) {
    if (value is! Map || value['ModuleEnable'] != true || value['ret'] != 0) {
      return null;
    }
    final rules = value['list'];
    if (rules is! List) return null;
    for (final rule in rules.whereType<Map>()) {
      if (rule['Name'] != 'nav' ||
          rule['Enable'] != true ||
          (rule['StunType'] != 'tcp4' && rule['StunType'] != 'tcp6')) {
        continue;
      }
      final address = rule['PublicAddr'];
      if (address is! String || address.trim().isEmpty) continue;
      final uri = Uri.tryParse(
        address.contains('://') ? address.trim() : 'http://${address.trim()}',
      );
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          !uri.hasPort ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/')) {
        continue;
      }
      final ip = InternetAddress.tryParse(uri.host);
      if (ip == null || ip.isLoopback || ip.isLinkLocal || ip.isMulticast) {
        continue;
      }
      final bytes = ip.rawAddress;
      if (ip.type == InternetAddressType.IPv4 &&
          (bytes[0] == 0 ||
              bytes[0] == 10 ||
              bytes[0] >= 240 ||
              (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
              (bytes[0] == 192 && bytes[1] == 168) ||
              (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127))) {
        continue;
      }
      if (ip.type == InternetAddressType.IPv6 &&
          ((bytes[0] & 0xfe) == 0xfc || bytes.every((byte) => byte == 0))) {
        continue;
      }
      return uri;
    }
    return null;
  }

  Future<bool> _probe(Uri base) async {
    try {
      final response = await _send(
        _probeClient,
        base.replace(
          path: '/rest/ping.view',
          queryParameters: {'f': 'json', 'v': '1.16.1', 'c': 'zmusic'},
        ),
        const Duration(seconds: 3),
      );
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(response.body);
      final root = decoded is Map ? decoded['subsonic-response'] : null;
      // An unauthenticated ping is sufficient to check transport availability.
      return root is Map &&
          root['type']?.toString().toLowerCase() == 'navidrome' &&
          (root['status'] == 'ok' ||
              (root['status'] == 'failed' && root['error'] is Map));
    } on Object {
      return false;
    }
  }

  Future<http.Response> _send(
    http.Client client,
    Uri uri,
    Duration timeout,
  ) async {
    final abort = Completer<void>();
    final pending = identical(client, _probeClient)
        ? _pendingProbes
        : _pendingRequests;
    pending.add(abort);
    try {
      return await (() async {
        final request = http.AbortableRequest(
          'GET',
          uri,
          abortTrigger: abort.future,
        )..followRedirects = false;
        return http.Response.fromStream(await client.send(request));
      })().timeout(timeout);
    } finally {
      if (!abort.isCompleted) abort.complete();
      pending.remove(abort);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidateChecks();
    for (final abort in _pendingRequests) {
      if (!abort.isCompleted) abort.complete();
    }
    _probeClient.close();
    super.dispose();
  }
}
