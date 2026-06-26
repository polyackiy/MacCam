import SwiftUI

struct ScheduleSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
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
