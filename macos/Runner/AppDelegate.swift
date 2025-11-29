import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as? FlutterViewController

    // Register clipboard plugin
    if let registrar = controller?.registrar(forPlugin: "ClipboardPlugin") {
      ClipboardPlugin.register(with: registrar)
    }

    // Register bookmark plugin for security-scoped folder access
    if let registrar = controller?.registrar(forPlugin: "BookmarkPlugin") {
      BookmarkPlugin.register(with: registrar)
    }
  }
}
