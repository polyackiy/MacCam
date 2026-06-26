import SwiftUI

@main
struct MacCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Real settings UI is attached in a later task; agent app has no main window.
        Settings {
            EmptyView()
        }
    }
}
