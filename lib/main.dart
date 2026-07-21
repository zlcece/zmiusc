import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as media_kit;

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/desktop_integration.dart';
import 'src/library_store.dart';
import 'src/player_controller.dart';
import 'src/system_media_controls.dart';

DesktopIntegration? _desktopIntegration;
SystemMediaControls? _systemMediaControls;
const MethodChannel _desktopFileDropChannel = MethodChannel(
  'com.zmusic.app/file_drop',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  media_kit.MediaKit.ensureInitialized();

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
  runApp(ZmusicApp(controller: controller));
  if (Platform.isMacOS) {
    unawaited(_notifyMacOSFileDropReady());
  }

  if (controller.isAuthenticated) {
    unawaited(controller.loadLibraryOverview());
  }
  _desktopIntegration = DesktopIntegration(controller);
  unawaited(_initializeDesktopIntegration(_desktopIntegration!));
  _systemMediaControls = SystemMediaControls(controller.player);
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
    debugPrint('Failed to initialize macOS file open channel: $error');
  }
}

Future<void> _loadController(
  AppController controller, {
  bool loadLibrary = true,
}) async {
  try {
    await controller.load(loadLibrary: loadLibrary);
  } catch (error, stackTrace) {
    debugPrint('Failed to load app state: $error');
    debugPrint('$stackTrace');
  }
}

Future<void> _initializeDesktopIntegration(
  DesktopIntegration integration,
) async {
  try {
    await integration.initialize();
  } catch (error, stackTrace) {
    debugPrint('Failed to initialize desktop integration: $error');
    debugPrint('$stackTrace');
  }
}

Future<void> _initializeSystemMediaControls(
  SystemMediaControls controls,
) async {
  try {
    await controls.initialize();
  } catch (error, stackTrace) {
    debugPrint('Failed to initialize system media controls: $error');
    debugPrint('$stackTrace');
  }
}
