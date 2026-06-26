import SwiftUI

/// "What starts a recording": the trigger mode plus the per-source detection
/// settings (motion, voice), shown contextually for the chosen mode.
struct DetectionSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
            Section("Trigger") {
                Picker("Recording trigger", selection: Binding(
                    get: { settings.triggerMode },
                    set: { settings.triggerMode = $0; context.onReconfigure() })) {
                    ForEach(TriggerMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                Text(triggerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.triggerMode.usesMotion {
                Section("Motion") {
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
            }

            if settings.triggerMode.usesVoice {
                Section("Voice") {
                    if settings.audioEnabled {
                        VStack(alignment: .leading) {
                            Text("Voice sensitivity: \(settings.voiceSensitivity) (0 = strict, 4 = sensitive)")
                            Slider(value: Binding(
                                get: { Double(settings.voiceSensitivity) },
                                set: { settings.voiceSensitivity = Int($0.rounded()) }),
                                   in: 0...4, step: 1)
                        }
                    } else {
                        Text("Voice trigger needs \"Record audio\" enabled on the Camera tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var triggerHint: LocalizedStringKey {
        switch settings.triggerMode {
        case .continuous: return "Always records while monitoring (no detector)."
        case .motion: return "Records when motion is detected."
        case .voice: return "Records when human speech is detected."
        case .motionAndVoice: return "Records on motion or speech."
        }
    }
}
