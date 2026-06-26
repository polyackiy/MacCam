import SwiftUI

/// When monitoring/recording is active: guard mode plus the two weekly schedules.
struct ScheduleSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
            Section("Guard") {
                Toggle("Guard mode: monitor while screen is locked", isOn: $settings.guardMode)
                Text("A manual Start always takes priority over guard mode and schedules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScheduleEditor(title: "Monitoring schedule",
                           schedule: $settings.monitoringSchedule,
                           onChange: context.onReconfigure)
            ScheduleEditor(title: "Recording schedule",
                           schedule: $settings.recordingSchedule,
                           onChange: context.onReconfigure)
        }
        .formStyle(.grouped)
    }
}
