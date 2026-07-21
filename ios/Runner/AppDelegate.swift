import AVFoundation
import Flutter
import MediaPlayer
import UIKit

private final class IOSMediaSession {
  private let channel: FlutterMethodChannel
  private let commandCenter = MPRemoteCommandCenter.shared()
  private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
  private var notificationObservers: [NSObjectProtocol] = []
  private var commandsInstalled = false
  private var audioSessionActive = false
  private var isPlaying = false
  private var wasPlayingBeforeInterruption = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.zmusic.app/media_session",
      binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(
          FlutterError(
            code: "MEDIA_SESSION_UNAVAILABLE",
            message: "The iOS media session is unavailable.",
            details: nil))
        return
      }
      self.handle(call, result: result)
    }
    observeAudioSession()
  }

  deinit {
    for entry in commandTargets {
      entry.command.removeTarget(entry.target)
    }
    for observer in notificationObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      installCommandsIfNeeded()
      result(nil)
    case "updateState":
      guard let arguments = call.arguments as? [String: Any] else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "Media state must be a map.",
            details: nil))
        return
      }
      do {
        try updateState(arguments)
        result(nil)
      } catch {
        result(
          FlutterError(
            code: "AUDIO_SESSION_ERROR",
            message: "Unable to configure iOS audio playback.",
            details: error.localizedDescription))
      }
    case "clear":
      clear()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func installCommandsIfNeeded() {
    guard !commandsInstalled else {
      return
    }
    commandsInstalled = true
    addCommand(commandCenter.playCommand, action: "play")
    addCommand(commandCenter.pauseCommand, action: "pause")
    addCommand(commandCenter.togglePlayPauseCommand, action: "playPause")
    addCommand(commandCenter.nextTrackCommand, action: "next")
    addCommand(commandCenter.previousTrackCommand, action: "previous")
    setCommandsEnabled(
      hasTrack: false,
      isPlaying: false,
      canSkipPrevious: false,
      canSkipNext: false)
  }

  private func addCommand(_ command: MPRemoteCommand, action: String) {
    let target = command.addTarget { [weak self] _ in
      guard let self = self else {
        return .commandFailed
      }
      DispatchQueue.main.async {
        self.channel.invokeMethod("mediaButton", arguments: action)
      }
      return .success
    }
    commandTargets.append((command: command, target: target))
  }

  private func updateState(_ arguments: [String: Any]) throws {
    installCommandsIfNeeded()
    guard boolValue(arguments["hasTrack"]) else {
      clear()
      return
    }

    isPlaying = boolValue(arguments["isPlaying"])
    try configureAudioSession(activate: isPlaying)

    let duration = millisecondsValue(arguments["durationMs"]) / 1000
    let position = millisecondsValue(arguments["positionMs"]) / 1000
    var nowPlayingInfo: [String: Any] = [
      MPMediaItemPropertyTitle: stringValue(arguments["title"]),
      MPMediaItemPropertyArtist: stringValue(arguments["artist"]),
      MPMediaItemPropertyAlbumTitle: stringValue(arguments["album"]),
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if duration > 0 {
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
    }

    setCommandsEnabled(
      hasTrack: true,
      isPlaying: isPlaying,
      canSkipPrevious: boolValue(arguments["canSkipPrevious"]),
      canSkipNext: boolValue(arguments["canSkipNext"]))
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
  }

  private func configureAudioSession(activate: Bool) throws {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playback, mode: .default)
    guard activate && !audioSessionActive else {
      return
    }
    try audioSession.setActive(true)
    UIApplication.shared.beginReceivingRemoteControlEvents()
    audioSessionActive = true
  }

  private func setCommandsEnabled(
    hasTrack: Bool,
    isPlaying: Bool,
    canSkipPrevious: Bool,
    canSkipNext: Bool
  ) {
    commandCenter.playCommand.isEnabled = hasTrack && !isPlaying
    commandCenter.pauseCommand.isEnabled = hasTrack && isPlaying
    commandCenter.togglePlayPauseCommand.isEnabled = hasTrack
    commandCenter.previousTrackCommand.isEnabled = hasTrack && canSkipPrevious
    commandCenter.nextTrackCommand.isEnabled = hasTrack && canSkipNext
  }

  private func clear() {
    isPlaying = false
    wasPlayingBeforeInterruption = false
    setCommandsEnabled(
      hasTrack: false,
      isPlaying: false,
      canSkipPrevious: false,
      canSkipNext: false)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    guard audioSessionActive else {
      return
    }
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation)
    UIApplication.shared.endReceivingRemoteControlEvents()
    audioSessionActive = false
  }

  private func observeAudioSession() {
    let center = NotificationCenter.default
    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        self?.handleInterruption(notification)
      })
    notificationObservers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        self?.handleRouteChange(notification)
      })
  }

  private func handleInterruption(_ notification: Notification) {
    guard
      let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else {
      return
    }
    switch type {
    case .began:
      wasPlayingBeforeInterruption = isPlaying
      if isPlaying {
        channel.invokeMethod("mediaButton", arguments: "pause")
      }
    case .ended:
      let rawOptions =
        notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        .contains(.shouldResume)
      if shouldResume && wasPlayingBeforeInterruption {
        channel.invokeMethod("mediaButton", arguments: "play")
      }
      wasPlayingBeforeInterruption = false
    @unknown default:
      break
    }
  }

  private func handleRouteChange(_ notification: Notification) {
    guard
      isPlaying,
      let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
    else {
      return
    }
    channel.invokeMethod("mediaButton", arguments: "pause")
  }

  private func boolValue(_ value: Any?) -> Bool {
    return (value as? NSNumber)?.boolValue ?? false
  }

  private func millisecondsValue(_ value: Any?) -> Double {
    return (value as? NSNumber)?.doubleValue ?? 0
  }

  private func stringValue(_ value: Any?) -> String {
    return value as? String ?? ""
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaSession: IOSMediaSession?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZmusicNativeBridge") {
      mediaSession = IOSMediaSession(messenger: registrar.messenger())
    }
  }
}
