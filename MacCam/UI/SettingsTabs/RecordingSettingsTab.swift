import SwiftUI

/// How clips are produced: timing (length, cooldown, pre-roll) and output
/// format (audio-only, codec, quality). The trigger and audio inputs live on the
/// Detection and Camera tabs.
struct RecordingSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
            Section("Clips") {
                Stepper("Min clip length: \(Int(settings.minClipLength)) s",
                        value: $settings.minClipLength, in: 1...30, step: 1)
                Stepper("Max clip length: \(Int(settings.maxClipLength)) s",
                        value: $settings.maxClipLength, in: 10...600, step: 5)
                Stepper("Cooldown after motion: \(Int(settings.postMotionCooldown)) s",
                        value: $settings.postMotionCooldown, in: 1...60, step: 1)
                Text("Keeps recording this long after the trigger stops; longer "
                    + "events split into clips of the max length.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Pre-roll (record seconds before motion)", isOn: $settings.preRollEnabled)
                if settings.preRollEnabled {
                    Stepper("Pre-roll: \(Int(settings.preRoll)) s",
                            value: $settings.preRoll, in: 1...10, step: 1)
                }
            }
            Section("Format") {
                Toggle("Record audio only (no video)", isOn: Binding(
                    get: { settings.audioOnly },
                    set: { settings.audioOnly = $0; context.onReconfigure() }))
                    .disabled(!settings.audioOnlyAvailable)
                if !settings.audioOnlyAvailable {
                    Text("Available with the Continuous or Voice trigger and Record audio on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Codec", selection: $settings.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
