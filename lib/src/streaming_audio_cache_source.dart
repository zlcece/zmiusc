import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

class StreamingAudioCacheProxy {
  StreamingAudioCacheProxy(
    this.uri, {
    required this.cacheFile,
    this.headers,
    this.progressUpdateInterval = const Duration(milliseconds: 100),
  });

  final Uri uri;
  final File cacheFile;
  final Map<String, String>? headers;
  final Duration progressUpdateInterval;

  final StreamController<double> _downloadProgressController =
      StreamController<double>.broadcast();
  final Set<HttpClient> _clients = <HttpClient>{};
  final Completer<_OriginMetadata> _metadataCompleter =
      Completer<_OriginMetadata>();

  HttpServer? _server;
  Future<void>? _downloadFuture;
  RandomAccessFile? _cacheWriter;
  Completer<void>? _dataWaiter;
  Object? _downloadError;
  bool _canceled = false;
  bool _downloadComplete = false;
  int _downloadedBytes = 0;
  int? _sourceLength;
  String _contentType = 'audio/mpeg';
  final Stopwatch _progressStopwatch = Stopwatch()..start();
  int? _lastProgressUpdateMilliseconds;
  double? _lastProgress;

  Stream<double> get downloadProgressStream =>
      _downloadProgressController.stream;

  Future<Uri> start() async {
    if (_server != null) {
      return localUri;
    }
    await cacheFile.parent.create(recursive: true);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(
      (request) => unawaited(_handleRequest(request)),
      onError: (_) {},
    );
    return localUri;
  }

  Future<void> prefetch() async {
    await start();
    _ensureDownloadStarted();
    await _downloadFuture;
    final error = _downloadError;
    if (!_canceled && error != null) {
      throw error;
    }
  }

  Uri get localUri {
    final server = _server;
    if (server == null) {
      throw StateError('Audio cache proxy has not been started.');
    }
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: 'audio',
    );
  }

  Future<void> cancel() async {
    if (_canceled) {
      return;
    }
    _canceled = true;
    _wakeDataWaiters();
    await _server?.close(force: true);
    _server = null;
    for (final client in List<HttpClient>.of(_clients)) {
      client.close(force: true);
    }
    await _closeCacheWriter();
    if (!_metadataCompleter.isCompleted) {
      _metadataCompleter.completeError(
        StateError('Audio cache proxy canceled'),
      );
    }
    await _downloadProgressController.close();
    try {
      await _downloadFuture;
    } catch (_) {
      // Canceling the HttpClient is expected to surface as a network error.
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_canceled) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }

    if (request.uri.path != '/audio') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    _ensureDownloadStarted();
    try {
      final metadata = await _metadataCompleter.future;
      final range = _requestRange(
        request.headers.value(HttpHeaders.rangeHeader),
        metadata.sourceLength,
      );
      if (range == null) {
        await _sendRangeNotSatisfiable(request.response, metadata.sourceLength);
        return;
      }
      final responseRange = _responseRangeForMetadata(
        range,
        metadata.sourceLength,
      );
      if (responseRange == null) {
        await _sendRangeNotSatisfiable(request.response, metadata.sourceLength);
        return;
      }
      await _sendCachedResponse(request.response, metadata, responseRange);
    } catch (_) {
      if (!_canceled) {
        request.response.statusCode = HttpStatus.badGateway;
      }
      await _closeResponse(request.response);
    }
  }

  void _ensureDownloadStarted() {
    if (_downloadFuture != null) {
      return;
    }
    _downloadFuture = _downloadToCache();
  }

  Future<void> _downloadToCache() async {
    final client = _newHttpClient();
    try {
      final request = await client.getUrl(uri);
      _applyHeaders(request);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }

      _contentType = response.headers.contentType?.toString() ?? _contentType;
      if (_looksLikeStructuredErrorResponse(_contentType)) {
        throw HttpException(
          'Audio stream returned $_contentType instead of audio.',
          uri: uri,
        );
      }
      _sourceLength = _responseSourceLength(response);
      await File('${cacheFile.path}.mime').writeAsString(_contentType);
      _cacheWriter = await cacheFile.open(mode: FileMode.write);
      _completeMetadata();

      await for (final chunk in response) {
        if (_canceled) {
          break;
        }
        await _cacheWriter?.writeFrom(chunk);
        _downloadedBytes += chunk.length;
        _emitProgress();
        _wakeDataWaiters();
      }

      await _closeCacheWriter();
      if (!_canceled) {
        _downloadComplete = true;
      }
      if (!_canceled &&
          (_sourceLength == null || _downloadedBytes >= _sourceLength!)) {
        _emitProgress(value: 1, force: true);
      }
      _wakeDataWaiters();
    } catch (error) {
      _downloadError = error;
      if (!_metadataCompleter.isCompleted) {
        _metadataCompleter.completeError(error);
      }
      _wakeDataWaiters();
    } finally {
      client.close(force: true);
      _clients.remove(client);
      await _closeCacheWriter();
    }
  }

  void _completeMetadata() {
    if (_metadataCompleter.isCompleted) {
      return;
    }
    _metadataCompleter.complete(
      _OriginMetadata(contentType: _contentType, sourceLength: _sourceLength),
    );
  }

  Future<void> _sendCachedResponse(
    HttpResponse response,
    _OriginMetadata metadata,
    _ByteRange range,
  ) async {
    final start = range.start;
    final endExclusive = range.endExclusive;
    final sourceLength = metadata.sourceLength;
    final responseEnd = endExclusive ?? sourceLength;

    response.headers.set(HttpHeaders.contentTypeHeader, metadata.contentType);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (range.isPartial) {
      response.statusCode = HttpStatus.partialContent;
      final rangeLast = responseEnd == null ? '*' : '${responseEnd - 1}';
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$rangeLast/${sourceLength ?? '*'}',
      );
      if (responseEnd != null) {
        response.contentLength = responseEnd - start;
      }
    } else {
      response.statusCode = HttpStatus.ok;
      if (sourceLength != null) {
        response.contentLength = sourceLength;
      }
    }

    await _writeCachedBytes(
      response,
      start,
      responseEnd,
      allowRemoteRangeFallback: range.isPartial,
    );
    await _closeResponse(response);
  }

  Future<void> _writeCachedBytes(
    HttpResponse response,
    int start,
    int? endExclusive, {
    required bool allowRemoteRangeFallback,
  }) async {
    var offset = start;
    var triedRemoteRangeFallback = false;
    while (!_canceled) {
      final error = _downloadError;
      if (error != null && _downloadedBytes <= offset) {
        throw error;
      }

      final availableEnd = endExclusive == null
          ? _downloadedBytes
          : math.min(_downloadedBytes, endExclusive);
      if (availableEnd > offset) {
        await response.addStream(cacheFile.openRead(offset, availableEnd));
        offset = availableEnd;
        await response.flush();
      }

      if (endExclusive != null && offset >= endExclusive) {
        return;
      }
      if (_downloadComplete && offset >= _downloadedBytes) {
        return;
      }
      if (allowRemoteRangeFallback &&
          !triedRemoteRangeFallback &&
          offset > 0 &&
          offset > _downloadedBytes &&
          await _pipeRemoteRange(response, offset, endExclusive)) {
        return;
      }
      triedRemoteRangeFallback = true;
      await _waitForMoreData();
    }
  }

  Future<bool> _pipeRemoteRange(
    HttpResponse response,
    int start,
    int? endExclusive,
  ) async {
    final sourceLength = _sourceLength;
    if (_canceled || sourceLength == null || start >= sourceLength) {
      return false;
    }
    final last = (endExclusive ?? sourceLength) - 1;
    if (last < start) {
      return false;
    }

    final client = _newHttpClient();
    try {
      final request = await client.getUrl(uri);
      _applyHeaders(request);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$last');
      final remoteResponse = await request.close();
      if (remoteResponse.statusCode != HttpStatus.partialContent) {
        await remoteResponse.drain<void>();
        return false;
      }
      final contentType =
          remoteResponse.headers.contentType?.toString() ?? _contentType;
      if (_looksLikeStructuredErrorResponse(contentType)) {
        throw HttpException(
          'Audio range returned $contentType instead of audio.',
          uri: uri,
        );
      }
      await response.addStream(remoteResponse);
      await response.flush();
      return true;
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  Future<void> _sendRangeNotSatisfiable(
    HttpResponse response,
    int? sourceLength,
  ) async {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes */${sourceLength ?? '*'}',
    );
    await _closeResponse(response);
  }

  Future<void> _waitForMoreData() {
    if (_downloadComplete || _canceled || _downloadError != null) {
      return Future<void>.value();
    }
    final waiter = _dataWaiter;
    if (waiter != null) {
      return waiter.future;
    }
    final completer = Completer<void>();
    _dataWaiter = completer;
    return completer.future;
  }

  void _wakeDataWaiters() {
    final waiter = _dataWaiter;
    if (waiter == null) {
      return;
    }
    _dataWaiter = null;
    if (!waiter.isCompleted) {
      waiter.complete();
    }
  }

  HttpClient _newHttpClient() {
    final client = HttpClient();
    _clients.add(client);
    return client;
  }

  void _applyHeaders(HttpClientRequest request) {
    final requestHeaders = headers;
    if (requestHeaders == null) {
      return;
    }
    for (final entry in requestHeaders.entries) {
      request.headers.set(entry.key, entry.value);
    }
  }

  void _emitProgress({double? value, bool force = false}) {
    final sourceLength = _sourceLength;
    if (_canceled) {
      return;
    }
    final progress =
        value ??
        (sourceLength == null || sourceLength <= 0
            ? null
            : (_downloadedBytes / sourceLength).clamp(0, 1).toDouble());
    if (progress == null || progress == _lastProgress) {
      return;
    }
    final elapsed = _progressStopwatch.elapsedMilliseconds;
    final lastUpdate = _lastProgressUpdateMilliseconds;
    if (!force &&
        lastUpdate != null &&
        elapsed - lastUpdate < progressUpdateInterval.inMilliseconds) {
      return;
    }
    _lastProgress = progress;
    _lastProgressUpdateMilliseconds = elapsed;
    _downloadProgressController.add(progress);
  }

  Future<void> _closeCacheWriter() async {
    final writer = _cacheWriter;
    if (writer == null) {
      return;
    }
    _cacheWriter = null;
    try {
      await writer.flush();
    } catch (_) {
      // The file may already be closed by a forced cancel.
    }
    try {
      await writer.close();
    } catch (_) {
      // The file may already be closed by a forced cancel.
    }
  }

  Future<void> _closeResponse(HttpResponse response) async {
    try {
      await response.close();
    } catch (_) {
      // The player may have already closed the local proxy connection.
    }
  }
}

class _OriginMetadata {
  const _OriginMetadata({
    required this.contentType,
    required this.sourceLength,
  });

  final String contentType;
  final int? sourceLength;
}

class _ByteRange {
  const _ByteRange({
    required this.start,
    required this.endExclusive,
    required this.isPartial,
  });

  final int start;
  final int? endExclusive;
  final bool isPartial;
}

_ByteRange? _requestRange(String? header, int? sourceLength) {
  if (header == null || header.trim().isEmpty) {
    return const _ByteRange(start: 0, endExclusive: null, isPartial: false);
  }

  final normalized = header.trim().toLowerCase();
  if (!normalized.startsWith('bytes=')) {
    return null;
  }
  final rawRange = normalized.substring('bytes='.length).split(',').first;
  final separator = rawRange.indexOf('-');
  if (separator < 0) {
    return null;
  }

  final startText = rawRange.substring(0, separator).trim();
  final endText = rawRange.substring(separator + 1).trim();
  if (startText.isEmpty) {
    final suffixLength = int.tryParse(endText);
    if (suffixLength == null || suffixLength <= 0 || sourceLength == null) {
      return null;
    }
    final start = math.max(0, sourceLength - suffixLength);
    return _ByteRange(
      start: start,
      endExclusive: sourceLength,
      isPartial: true,
    );
  }

  final start = int.tryParse(startText);
  if (start == null || start < 0) {
    return null;
  }
  if (sourceLength != null && start >= sourceLength) {
    return null;
  }

  int? endExclusive;
  if (endText.isNotEmpty) {
    final endInclusive = int.tryParse(endText);
    if (endInclusive == null || endInclusive < start) {
      return null;
    }
    endExclusive = endInclusive + 1;
    if (sourceLength != null) {
      endExclusive = math.min(endExclusive, sourceLength);
    }
  }

  return _ByteRange(start: start, endExclusive: endExclusive, isPartial: true);
}

_ByteRange? _responseRangeForMetadata(_ByteRange range, int? sourceLength) {
  if (sourceLength != null || !range.isPartial) {
    return range;
  }
  if (range.start == 0 && range.endExclusive == null) {
    return const _ByteRange(start: 0, endExclusive: null, isPartial: false);
  }
  if (range.endExclusive == null) {
    return null;
  }
  return range;
}

int? _responseSourceLength(HttpClientResponse response) {
  final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
  final rangeLength = _contentRangeSourceLength(contentRange);
  if (rangeLength != null) {
    return rangeLength;
  }
  return response.contentLength < 0 ? null : response.contentLength;
}

int? _contentRangeSourceLength(String? value) {
  if (value == null) {
    return null;
  }
  final slash = value.lastIndexOf('/');
  if (slash < 0 || slash == value.length - 1) {
    return null;
  }
  final length = value.substring(slash + 1).trim();
  if (length == '*') {
    return null;
  }
  return int.tryParse(length);
}

bool _looksLikeStructuredErrorResponse(String contentType) {
  final normalized = contentType.toLowerCase();
  return normalized.contains('json') || normalized.contains('xml');
}
