import Foundation

/// Dependencies passed to each Settings tab, so a tab takes one parameter
/// instead of many. `settings`/`camera` are observable; the rest are actions.
struct SettingsContext {
    let settings: SettingsStore
    let camera: CameraManager
    let fileStore: FileStore
    let onReconfigure: () -> Void
    let onLaunchAtLoginChange: (Bool) -> Void
    let onEditZones: () -> Void
    let onRequestAudioAccess: () -> Void
}
