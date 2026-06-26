import SwiftUI

struct MotionSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
            VStack(alignment: .leading) {
                Text("Sensitivity: \(settings.sensitivity) (0 = coarse, 4 = sensitive)")
                Slider(value: Binding(
                    get: { Double(settings.sensitivity) },
                    set: { settings.sensitivity = Int($0.rounded()) }),
                       in: 0...4, step: 1)
            }
            Button("Edit Detection Zones…") { context.onEditZones() }
            if let mask = MotionMask(encoded: settings.detectionMask), !mask.isEmpty {
                Text("\(mask.ignoredCount) zone cells ignored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
