import SwiftUI

struct SystemSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
            Toggle("Guard mode: monitor while screen is locked", isOn: $settings.guardMode)
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0; context.onLaunchAtLoginChange($0) }))
        }
        .formStyle(.grouped)
    }
}
