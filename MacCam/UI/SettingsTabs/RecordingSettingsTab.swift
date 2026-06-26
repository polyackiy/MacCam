import SwiftUI

struct RecordingSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var camera: CameraManager
    @State private var microphones: [(id: String, name: String)] = []

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
        self.camera = context.camera
    }

    var body: some View {
        Form {
            Stepper("Min clip length: \(Int(settings.minClipLength)) s",
                    value: $settings.minClipLength, in: 1...30, step: 1)
            Stepper("Max clip length: \(Int(settings.maxClipLength)) s",
                    value: $settings.maxClipLength, in: 10...600, step: 5)
            Stepper("Cooldown after motion: \(Int(settings.postMotionCooldown)) s",
                    value: $settings.postMotionCooldown, in: 1...60, step: 1)
            Toggle("Pre-roll (record seconds before motion)", isOn: $settings.preRollEnabled)
            if settings.preRollEnabled {
                Stepper("Pre-roll: \(Int(settings.preRoll)) s",
                        value: $settings.preRoll, in: 1...10, step: 1)
            }
            Picker("Recording trigger", selection: Binding(
                get: { settings.triggerMode },
                set: { settings.triggerMode = $0; context.onReconfigure() })) {
                ForEach(TriggerMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            if !settings.audioEnabled && settings.triggerMode.usesVoice {
                Text("Voice trigger needs \"Record audio\" enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Record audio", isOn: Binding(
                get: { settings.audioEnabled },
                set: {
                    settings.audioEnabled = $0
                    context.onReconfigure()
                    if $0 { context.onRequestAudioAccess() }
                }))
            if settings.audioEnabled {
                Picker("Microphone", selection: Binding(
                    get: { settings.audioDeviceID ?? "" },
                    set: { settings.audioDeviceID = $0.isEmpty ? nil : $0; context.onReconfigure() })) {
                    Text("Automatic (built-in preferred)").tag("")
                    ForEach(microphones, id: \.id) { Text($0.name).tag($0.id) }
                }
                if settings.triggerMode.usesVoice {
                    VStack(alignment: .leading) {
                        Text("Voice sensitivity: \(settings.voiceSensitivity) (0 = strict, 4 = sensitive)")
                        Slider(value: Binding(
                            get: { Double(settings.voiceSensitivity) },
                            set: { settings.voiceSensitivity = Int($0.rounded()) }),
                               in: 0...4, step: 1)
                    }
                }
                if settings.triggerMode.allowsAudioOnly {
                    Toggle("Record audio only (no video)", isOn: Binding(
                        get: { settings.audioOnly },
                        set: { settings.audioOnly = $0; context.onReconfigure() }))
                }
            }
            Picker("Codec", selection: $settings.codec) {
                ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
            }
            Picker("Quality", selection: $settings.quality) {
                ForEach(Quality.allCases) { Text($0.label).tag($0) }
            }
        }
        .formStyle(.grouped)
        .onAppear { microphones = camera.availableMicrophones().map { ($0.uniqueID, $0.localizedName) } }
    }
}
