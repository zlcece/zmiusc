import Cocoa
import FlutterMacOS
import MediaPlayer

private final class MacOSMediaSession {
  private let channel: FlutterMethodChannel
  private let commandCenter = MPRemoteCommandCenter.shared()
  private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
  private var commandsInstalled = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.zmusic.app/media_session",
      binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  deinit {
    for entry in commandTargets {
      entry.command.removeTarget(entry.target)
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
      updateState(arguments)
      result(nil)
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

  private func updateState(_ arguments: [String: Any]) {
    installCommandsIfNeeded()
    guard boolValue(arguments["hasTrack"]) else {
      clear()
      return
    }

    let isPlaying = boolValue(arguments["isPlaying"])
    let duration = millisecondsValue(arguments["durationMs"]) / 1000
    let position = millisecondsValue(arguments["positionMs"]) / 1000
    var nowPlayingInfo: [String: Any] = [
      MPMediaItemPropertyTitle: stringValue(arguments["title"]),
      MPMediaItemPropertyArtist: stringValue(arguments["artist"]),
      MPMediaItemPropertyAlbumTitle: stringValue(arguments["album"]),
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
    ]
    if duration > 0 {
      nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
    }

    commandCenter.playCommand.isEnabled = !isPlaying
    commandCenter.pauseCommand.isEnabled = isPlaying
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.previousTrackCommand.isEnabled = boolValue(
      arguments["canSkipPrevious"])
    commandCenter.nextTrackCommand.isEnabled = boolValue(arguments["canSkipNext"])
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
  }

  private func clear() {
    commandCenter.playCommand.isEnabled = false
    commandCenter.pauseCommand.isEnabled = false
    commandCenter.togglePlayPauseCommand.isEnabled = false
    commandCenter.previousTrackCommand.isEnabled = false
    commandCenter.nextTrackCommand.isEnabled = false
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
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

class MainFlutterWindow: NSWindow {
  private var fileDropChannel: FlutterMethodChannel?
  private var mediaSession: MacOSMediaSession?
  private var pendingOpenFiles: [String] = []
  private var flutterAcceptsOpenFiles = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let minimumContentSize = NSSize(width: 1088, height: 680)
    self.contentMinSize = minimumContentSize
    self.contentViewController = flutterViewController
    self.displayIfNeeded()
    self.setContentSize(minimumContentSize)

    let registrar = flutterViewController.registrar(forPlugin: "ZmusicNativeBridge")
    let fileDropChannel = FlutterMethodChannel(
      name: "com.zmusic.app/file_drop",
      binaryMessenger: registrar.messenger)
    fileDropChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "ready" {
        self?.flutterAcceptsOpenFiles = true
        self?.flushPendingOpenFiles()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.fileDropChannel = fileDropChannel
    self.mediaSession = MacOSMediaSession(messenger: registrar.messenger)
    self.registerForDraggedTypes([.fileURL])

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  func openFiles(_ paths: [String]) {
    let usablePaths = paths.filter { !$0.isEmpty }
    guard !usablePaths.isEmpty else {
      return
    }
    if flutterAcceptsOpenFiles {
      fileDropChannel?.invokeMethod("openFiles", arguments: usablePaths)
    } else {
      pendingOpenFiles.append(contentsOf: usablePaths)
    }
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let canReadFiles = sender.draggingPasteboard.canReadObject(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true])
    return canReadFiles ? .copy : []
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
    else {
      return false
    }
    let paths = urls.compactMap { $0.filePathURL?.path }
    openFiles(paths)
    return !paths.isEmpty
  }

  private func flushPendingOpenFiles() {
    guard flutterAcceptsOpenFiles, !pendingOpenFiles.isEmpty else {
      return
    }
    let paths = pendingOpenFiles
    pendingOpenFiles.removeAll()
    fileDropChannel?.invokeMethod("openFiles", arguments: paths)
  }
}
