import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    (mainFlutterWindow as? MainFlutterWindow)?.openFiles(filenames)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    sender.reply(toOpenOrPrint: .success)
  }
}
