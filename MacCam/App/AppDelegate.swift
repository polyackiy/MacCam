import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent (menu-bar) app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        NSLog("MacCam launched")
    }
}
