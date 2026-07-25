import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_controller.dart';
import 'settings_models.dart';

const MethodChannel _windowsSettingsChannel = MethodChannel(
  'com.zmusic.app/windows_settings',
);
const String _macOSTrayIconAsset = 'assets/branding/zmusic_tray.png';
const Size desktopMinimumWindowSize = Size(1088, 680);

class DesktopIntegration with WindowListener, TrayListener {
  DesktopIntegration(this.controller);

  final AppController controller;
  String? _lastIconPath;
  String? _lastConfiguredIconPath;
  bool? _lastLaunchAtStartup;
  bool _toolTipApplied = false;
  bool _isTrayMenuOpen = false;
  bool _isExiting = false;

  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> initialize() async {
    if (!isSupported) {
      return;
    }

    await windowManager.ensureInitialized();
    if (Platform.isWindows || Platform.isMacOS) {
      await windowManager.setMinimumSize(desktopMinimumWindowSize);
    }
    windowManager.addListener(this);
    trayManager.addListener(this);
    controller.addListener(_handleControllerChanged);

    await windowManager.setPreventClose(true);
    _lastConfiguredIconPath = controller.settings.trayIconPath.trim();
    await _applyIcons();
    await _applyTrayMenu();
    if (Platform.isWindows) {
      await _applyLaunchAtStartup(controller.settings.launchAtStartup);
    }
  }

  Future<void> dispose() async {
    if (!isSupported) {
      return;
    }
    controller.removeListener(_handleControllerChanged);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    unawaited(_destroyTray());
  }

  @override
  Future<void> onWindowClose() async {
    if (_isExiting) {
      return;
    }
    if (controller.settings.closeButtonBehavior ==
        CloseButtonBehavior.minimizeToTray) {
      await windowManager.hide();
      return;
    }
    await exitApplication();
  }

  @override
  Future<void> onTrayIconMouseDown() async {
    await showWindow();
  }

  @override
  Future<void> onTrayIconRightMouseDown() async {
    if (_isTrayMenuOpen || _isExiting) {
      return;
    }
    _isTrayMenuOpen = true;
    try {
      if (Platform.isWindows) {
        try {
          final shown = await _windowsSettingsChannel.invokeMethod<bool>(
            'showTrayPlayer',
          );
          if (shown == true) {
            return;
          }
        } on MissingPluginException {
          // Fall back to the basic exit menu on older Windows runners.
        } on PlatformException {
          // Fall back to the basic exit menu on older Windows runners.
        }
      }
      // Windows needs a foreground owner so the native menu closes when it
      // loses focus. The guard also prevents overlapping popup requests.
      // ignore: deprecated_member_use
      await trayManager.popUpContextMenu(bringAppToFront: Platform.isWindows);
    } finally {
      _isTrayMenuOpen = false;
    }
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show_window':
        await showWindow();
      case 'toggle_play':
        await controller.player.togglePlay();
      case 'exit_app':
        await exitApplication();
    }
  }

  Future<void> showWindow() async {
    if (!isSupported) {
      return;
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> exitApplication() async {
    if (!isSupported || _isExiting) {
      return;
    }
    _isExiting = true;
    controller.removeListener(_handleControllerChanged);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    unawaited(_destroyTray());
    await controller.flushPersistentState();
    try {
      await windowManager
          .setPreventClose(false)
          .timeout(const Duration(milliseconds: 250));
    } catch (_) {
      // Some platforms can reject this during shutdown; continue closing.
    }
    try {
      await windowManager.destroy().timeout(const Duration(milliseconds: 250));
    } catch (_) {
      // A direct process exit below is the fallback for slow native shutdown.
    }
    exit(0);
  }

  Future<void> _handleControllerChanged() async {
    final configuredIconPath = controller.settings.trayIconPath.trim();
    if (configuredIconPath != _lastConfiguredIconPath) {
      _lastConfiguredIconPath = configuredIconPath;
      await _applyIcons();
    }
    final launchAtStartup = controller.settings.launchAtStartup;
    if (Platform.isWindows && launchAtStartup != _lastLaunchAtStartup) {
      await _applyLaunchAtStartup(launchAtStartup);
    }
  }

  Future<void> _applyLaunchAtStartup(bool enabled) async {
    try {
      await _windowsSettingsChannel.invokeMethod<void>(
        'setLaunchAtStartup',
        enabled,
      );
      _lastLaunchAtStartup = enabled;
    } catch (error, stackTrace) {
      debugPrint('Failed to update Windows startup entry: $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _applyIcons() async {
    if (Platform.isMacOS) {
      try {
        if (_lastIconPath != _macOSTrayIconAsset) {
          await trayManager.setIcon(
            _macOSTrayIconAsset,
            isTemplate: true,
            iconSize: 18,
          );
          _lastIconPath = _macOSTrayIconAsset;
        }
        if (!_toolTipApplied) {
          await trayManager.setToolTip('Zmusic');
          _toolTipApplied = true;
        }
      } catch (_) {
        // The app icon still comes from the macOS asset catalog if the menu
        // bar icon cannot be created.
      }
      return;
    }

    final iconPath = _effectiveIconPath();
    try {
      if (iconPath != null && iconPath != _lastIconPath) {
        await trayManager.setIcon(iconPath);
        await windowManager.setIcon(iconPath);
        _lastIconPath = iconPath;
      }
      if (!_toolTipApplied) {
        await trayManager.setToolTip('Zmusic');
        _toolTipApplied = true;
      }
    } catch (_) {
      // Icon formats vary by platform; keep the app running if a custom image
      // cannot be applied as a native icon.
    }
  }

  Future<void> _applyTrayMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: Platform.isWindows
            ? [MenuItem(key: 'exit_app', label: '退出')]
            : [
                MenuItem(key: 'show_window', label: '显示窗口'),
                MenuItem(key: 'toggle_play', label: '播放/暂停'),
                MenuItem.separator(),
                MenuItem(key: 'exit_app', label: '退出'),
              ],
      ),
    );
  }

  Future<void> _destroyTray() async {
    try {
      await trayManager.destroy();
    } catch (_) {
      // Keep shutdown fast even when the native tray backend is already gone.
    }
  }

  String? _effectiveIconPath() {
    return resolveDesktopIconPath(
      configuredIconPath: controller.settings.trayIconPath,
      executableDirectory: File(Platform.resolvedExecutable).parent.path,
      workingDirectory: Directory.current.path,
      fileExists: (path) => File(path).existsSync(),
    );
  }
}

@visibleForTesting
String? resolveDesktopIconPath({
  required String configuredIconPath,
  required String executableDirectory,
  required String workingDirectory,
  required bool Function(String path) fileExists,
}) {
  final candidates = [
    configuredIconPath.trim(),
    _joinPath(executableDirectory, ['app_icon.ico']),
    _joinPath(workingDirectory, [
      'windows',
      'runner',
      'resources',
      'app_icon.ico',
    ]),
  ];

  for (final path in candidates) {
    if (path.isNotEmpty && fileExists(path)) {
      return path;
    }
  }
  return null;
}

String _joinPath(String base, List<String> segments) {
  final separator = Platform.pathSeparator;
  final normalizedBase = base.endsWith(separator)
      ? base.substring(0, base.length - separator.length)
      : base;
  return [normalizedBase, ...segments].join(separator);
}
