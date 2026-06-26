import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService` (macOS 13+) for launch-at-login.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("MacCam: launch-at-login change failed: \(error)")
            return false
        }
    }
}
