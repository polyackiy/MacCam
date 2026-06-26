import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var camera: CameraManager
    let fileStore: FileStore
    var onReconfigure: () -> Void
    var onLaunchAtLoginChange: (Bool) -> Void
    var onEditZones: () -> Void

    @State private var cameras: [(id: String, name: String)] = []
    @State private var folderPath: String = ""
    @State private var usageText = "—"

    var body: some View {
        Form {
            Section("Camera") {
                Picker("Camera", selection: Binding(
                    get: { settings.cameraID ?? cameras.first?.id ?? "" },
                    set: { settings.cameraID = $0; onReconfigure() })) {
                    ForEach(cameras, id: \.id) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Resolution", value: camera.formatDescription)
                Picker("Target FPS", selection: Binding(
                    get: { settings.targetFPS },
                    set: { settings.targetFPS = $0; onReconfigure() })) {
                    Text("15").tag(15); Text("24").tag(24); Text("30").tag(30)
                }
            }

            Section("Motion") {
                VStack(alignment: .leading) {
                    Text("Sensitivity: \(settings.sensitivity) (0 = coarse, 4 = sensitive)")
                    Slider(value: Binding(
                        get: { Double(settings.sensitivity) },
                        set: { settings.sensitivity = Int($0.rounded()) }),
                           in: 0...4, step: 1)
                }
                Button("Edit Detection Zones…") { onEditZones() }
                if let mask = MotionMask(encoded: settings.detectionMask), !mask.isEmpty {
                    Text("\(mask.ignoredCount) zone cells ignored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recording") {
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
                Toggle("Record audio", isOn: Binding(
                    get: { settings.audioEnabled },
                    set: { settings.audioEnabled = $0; onReconfigure() }))
                Picker("Codec", selection: $settings.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Storage") {
                LabeledContent("Folder", value: folderPath)
                Button("Choose Folder…") { chooseFolder() }
                LabeledContent("Usage", value: usageText)
                Toggle("Auto-delete old clips", isOn: $settings.autoCleanup)
                if settings.autoCleanup {
                    Stepper("Delete after \(settings.cleanupDays) days",
                            value: $settings.cleanupDays, in: 1...365, step: 1)
                }
                Stepper("Max storage: \(Int(settings.maxStorageGB)) GB (0 = off)",
                        value: $settings.maxStorageGB, in: 0...2000, step: 5)
                Stepper("Keep free: \(Int(settings.minFreeSpaceGB)) GB (0 = off)",
                        value: $settings.minFreeSpaceGB, in: 0...2000, step: 5)
                Picker("When limit reached", selection: $settings.diskLimitPolicy) {
                    ForEach(DiskLimitPolicy.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Appearance & Privacy") {
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

            Section("System") {
                Toggle("Guard mode: monitor while screen is locked", isOn: $settings.guardMode)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0; onLaunchAtLoginChange($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
        .onAppear {
            cameras = camera.availableCameras().map { ($0.uniqueID, $0.localizedName) }
            folderPath = fileStore.currentFolder().path
            refreshUsage()
        }
    }

    private func refreshUsage() {
        let usage = fileStore.folderUsage()
        let usedGB = StorageMath.bytesToGB(usage.totalBytes)
        let freeGB = StorageMath.bytesToGB(fileStore.volumeFreeBytes())
        usageText = String(format: "%d clips · %.1f GB · %.1f GB free", usage.count, usedGB, freeGB)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            fileStore.setFolder(url)
            folderPath = fileStore.currentFolder().path
        }
    }
}
