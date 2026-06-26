import SwiftUI

/// App behaviour and appearance: menu-bar icon style and startup options.
struct GeneralSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Menu-bar icon", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                if settings.menuBarStyle == .discreet {
                    Picker("Discreet icon", selection: $settings.discreetIcon) {
                        ForEach(DiscreetIcon.allCases) { icon in
                            Label(icon.label, systemImage: icon.symbolName).tag(icon)
                        }
                    }
                    Text("In discreet mode the icon looks the same whether idle, "
                        + "monitoring, or recording — only this menu reveals the real status.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0; context.onLaunchAtLoginChange($0) }))
            }
        }
        .formStyle(.grouped)
    }
}
