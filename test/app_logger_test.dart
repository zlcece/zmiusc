import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zmusic/src/app_logger.dart';
import 'package:zmusic/src/settings_models.dart';

void main() {
  test('logger defaults to errors and redacts credentials', () async {
    final directory = await Directory.systemTemp.createTemp('zmusic-log-test-');
    addTearDown(() => directory.delete(recursive: true));
    final logger = AppLogger();
    addTearDown(logger.dispose);
    await logger.initialize(directory: directory);

    logger.info('app', 'ignored');
    logger.error(
      'network',
      'request https://example.com/rest?p=secret&u=user&token=value failed',
      error: 'password=hidden',
    );
    await logger.flush();

    expect(logger.entries, hasLength(1));
    final content = await logger.exportText();
    expect(content, contains('[ERROR] [network]'));
    expect(content, isNot(contains('secret')));
    expect(content, isNot(contains('user')));
    expect(content, isNot(contains('value')));
    expect(content, isNot(contains('hidden')));
    expect(content, contains('<redacted>'));
  });

  test('selected level includes less verbose entries', () async {
    final directory = await Directory.systemTemp.createTemp('zmusic-log-test-');
    addTearDown(() => directory.delete(recursive: true));
    final logger = AppLogger();
    addTearDown(logger.dispose);
    await logger.initialize(directory: directory);
    logger.setLevel(AppLogLevel.info);

    logger.error('test', 'error');
    logger.warning('test', 'warning');
    logger.info('test', 'info');
    logger.debug('test', 'debug');
    await logger.flush();

    expect(logger.entries.map((entry) => entry.level), [
      AppLogLevel.error,
      AppLogLevel.warning,
      AppLogLevel.info,
    ]);
  });

  test('settings persist log level and default to errors', () {
    expect(AppSettings.fromJson(const {}).logLevel, AppLogLevel.error);
    final settings = AppSettings.fromJson(const {'logLevel': 'debug'});
    expect(settings.logLevel, AppLogLevel.debug);
    expect(settings.toJson()['logLevel'], 'debug');
  });
}
