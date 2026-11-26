import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zmusic/src/streaming_audio_cache_source.dart';

void main() {
  for (final scenario in [
    'switch while reading',
    'origin failure',
    'changed file',
    'wrong offset',
    'range ignored',
    'no validator',
  ]) {
    test('cache route resume: $scenario', () async {
      final originalOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp('zmusic-resume-');
      final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final file = File('${directory.path}/track');
      final payload = List.generate(8192, (i) => i % 241);
      const split = 4096;
      final initial = Uri.http('127.0.0.1:${direct.port}', '/stream');
      var active = initial;
      final alternate = initial.replace(port: relay.port);
      final firstRead = Completer<void>();
      final releaseResponse = Completer<void>();
      final client = HttpClient();
      final requests = <String?>[];
      final validators = <String?>[];
      direct.listen((request) async {
        final response = request.response;
        response.headers.contentType = ContentType('audio', 'flac');
        if (scenario != 'no validator') response.headers.set('etag', '"v1"');
        response.bufferOutput = false;
        if (scenario == 'origin failure') {
          response.statusCode = 206;
          response.headers.set('content-range', 'bytes 0-4095/8192');
          response.contentLength = split;
        } else {
          response.contentLength = payload.length;
        }
        response.add(payload.sublist(0, split));
        await response.flush();
        if (scenario != 'origin failure') await releaseResponse.future;
        try {
          await response.close();
        } catch (_) {}
      });
      relay.listen((request) async {
        requests.add(request.headers.value('range'));
        validators.add(request.headers.value('if-range'));
        final response = request.response;
        response.headers.contentType = ContentType('audio', 'flac');
        response.headers.set(
          'etag',
          scenario == 'changed file' ? '"v2"' : '"v1"',
        );
        response.statusCode = scenario == 'range ignored' ? 200 : 206;
        final start = scenario == 'wrong offset' ? 4095 : split;
        response.headers.set('content-range', 'bytes $start-8191/8192');
        response.contentLength = payload.length - start;
        response.add(payload.sublist(start));
        await response.close();
      });
      final proxy = StreamingAudioCacheProxy(
        initial,
        cacheFile: file,
        resolveOrigin: (_) => active,
        checkFailedOrigin: (_) async {
          await firstRead.future;
          active = alternate;
        },
      );
      addTearDown(() async {
        if (!releaseResponse.isCompleted) releaseResponse.complete();
        if (!firstRead.isCompleted) firstRead.complete();
        client.close(force: true);
        await proxy.cancel();
        await direct.close(force: true);
        await relay.close(force: true);
        HttpOverrides.global = originalOverrides;
        await directory.delete(recursive: true);
      });
      final local = await proxy.start();
      final fetch = proxy.prefetch();
      fetch.ignore();
      final received = <int>[];
      final reading = () async {
        final response = await (await client.getUrl(local)).close();
        await for (final chunk in response) {
          received.addAll(chunk);
          if (received.length >= split && !firstRead.isCompleted) {
            firstRead.complete();
          }
        }
      }();
      reading.ignore();
      await Future.any([firstRead.future, reading, fetch]).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'prefix stalled: stored=${proxy.downloadedBytes}, delivered=${received.length}',
        ),
      );
      if (scenario != 'origin failure') {
        active = alternate;
        proxy.refreshOrigin();
      }
      if (scenario == 'switch while reading' || scenario == 'origin failure') {
        await fetch.timeout(const Duration(seconds: 5));
        await reading.timeout(const Duration(seconds: 5));
        expect(received, payload);
        expect(await file.readAsBytes(), payload);
      } else {
        await expectLater(
          fetch.timeout(const Duration(seconds: 5)),
          throwsA(isA<HttpException>()),
        );
        expect(await file.readAsBytes(), payload.sublist(0, split));
      }
      expect(requests, ['bytes=4096-']);
      expect(validators, [scenario == 'no validator' ? null : '"v1"']);
    });
  }
}
