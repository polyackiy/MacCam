import SwiftUI

struct CameraSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var camera: CameraManager
    @State private var cameras: [(id: String, name: String)] = []

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
        self.camera = context.camera
    }

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .onAppear { cameras = camera.availableCameras().map { ($0.uniqueID, $0.localizedName) } }
    }
}
