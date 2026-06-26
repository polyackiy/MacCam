import SwiftUI

struct AppearanceSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}
