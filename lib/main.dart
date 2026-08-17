import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as media_kit;

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/app_logger.dart';
import 'src/app_update.dart';
import 'src/desktop_integration.dart';
import 'src/library_store.dart';
import 'src/player_controller.dart';
import 'src/system_media_controls.dart';

DesktopIntegration? _desktopIntegration;
SystemMediaControls? _systemMediaControls;
const MethodChannel _desktopFileDropChannel = MethodChannel(
  'com.zmusic.app/file_drop',
);

void main() {
  runZonedGuarded(_bootstrap, (error, stackTrace) {
    AppLogger.instance.error(
      'app',
      '未捕获的异步异常',
      error: error,
      stackTrace: stackTrace,
    );
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.instance.initialize();
  FlutterError.onError = (details) {
    AppLogger.instance.error(
      'flutter',
      details.context?.toDescription() ?? '未捕获的 Flutter 异常',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLogger.instance.error(
      'platform',
      '未捕获的平台异常',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };
  AppLogger.instance.info('app', 'Zmusic 开始启动');
  media_kit.MediaKit.ensureInitialized();

  final isDiLinkCompatibilityBuild =
      Platform.isAndroid &&
      await resolveAppUpdatePlatformKey() == 'android-dilink';
  if (isDiLinkCompatibilityBuild) {
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache
      ..maximumSize = 128
      ..maximumSizeBytes = 24 * 1024 * 1024;
  }

  final controller = AppController(
    store: LibraryStore(),
    player: PlayerController(),
  );
  await _loadController(controller, loadLibrary: false);
  if (Platform.isWindows || Platform.isMacOS) {
    _desktopFileDropChannel.setMethodCallHandler(
      (call) => _handleDesktopFileDrop(controller, call),
    );
  }
  runApp(
    ZmusicApp(
      controller: controller,
      isDiLinkCompatibilityBuild: isDiLinkCompatibilityBuild,
    ),
  );
  if (Platform.isMacOS) {
    unawaited(_notifyMacOSFileDropReady());
  }

  if (controller.isAuthenticated) {
    unawaited(controller.loadLibraryOverview());
  }
  _desktopIntegration = DesktopIntegration(controller);
  unawaited(_initializeDesktopIntegration(_desktopIntegration!));
  _systemMediaControls = SystemMediaControls(
    controller.player,
    onExitRequested: () async {
      await _desktopIntegration?.exitApplication();
    },
  );
  unawaited(_initializeSystemMediaControls(_systemMediaControls!));
}

Future<Object?> _handleDesktopFileDrop(
  AppController controller,
  MethodCall call,
) async {
  if (call.method != 'openFiles' || call.arguments is! List<Object?>) {
    return null;
  }
  final paths = (call.arguments as List<Object?>).whereType<String>();
  return controller.playDroppedLocalAudioFiles(paths);
}

Future<void> _notifyMacOSFileDropReady() async {
  try {
    await _desktopFileDropChannel.invokeMethod<void>('ready');
  } on PlatformException catch (error) {
    AppLogger.instance.error('desktop', '初始化 macOS 文件打开通道失败', error: error);
  }
}

Future<void> _loadController(
  AppController controller, {
  bool loadLibrary = true,
}) async {
  try {
    await controller.load(loadLibrary: loadLibrary);
  } catch (error, stackTrace) {
    AppLogger.instance.error(
      'app',
      '加载应用状态失败',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _initializeDesktopIntegration(
  DesktopIntegration integration,
) async {
  try {
    await integration.initialize();
  } catch (error, stackTrace) {
    AppLogger.instance.error(
      'desktop',
      '初始化桌面集成失败',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<void> _initializeSystemMediaControls(
  SystemMediaControls controls,
) async {
  try {
    await controls.initialize();
  } catch (error, stackTrace) {
    AppLogger.instance.error(
      'media-controls',
      '初始化系统媒体控制失败',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
