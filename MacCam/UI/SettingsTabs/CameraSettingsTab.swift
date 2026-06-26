import SwiftUI

/// Capture inputs: the video device (camera, resolution, FPS) and the audio
/// device (record-audio toggle + microphone).
struct CameraSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var camera: CameraManager
    @State private var cameras: [(id: String, name: String)] = []
    @State private var microphones: [(id: String, name: String)] = []

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
        self.camera = context.camera
    }

    private var audioOnlyActive: Bool {
        settings.audioOnly && settings.audioEnabled && settings.triggerMode.allowsAudioOnly
    }

    var body: some View {
        Form {
            Section("Video") {
                Picker("Camera", selection: Binding(
                    get: { settings.cameraID ?? cameras.first?.id ?? "" },
                    set: { settings.cameraID = $0; context.onReconfigure() })) {
                    ForEach(cameras, id: \.id) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Resolution", value: camera.formatDescription)
                Picker("Target FPS", selection: Binding(
                    get: { settings.targetFPS },
                    set: { settings.targetFPS = $0; context.onReconfigure() })) {
                    Text("15").tag(15); Text("24").tag(24); Text("30").tag(30)
                }
                if audioOnlyActive {
                    Text("Audio-only recording is on — the camera is disabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Audio") {
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
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cameras = camera.availableCameras().map { ($0.uniqueID, $0.localizedName) }
            microphones = camera.availableMicrophones().map { ($0.uniqueID, $0.localizedName) }
        }
    }
}
