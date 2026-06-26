import SwiftUI
import AppKit

/// Where clips are stored and how they are retained: location/usage plus the
/// auto-delete and disk-limit policy.
struct StorageSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore
    @State private var folderPath = ""
    @State private var usageText = "—"

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Folder", value: folderPath)
                HStack {
                    Button("Choose Folder…") { chooseFolder() }
                    Button("Open Clips Folder…") { context.fileStore.openInFinder() }
                }
                LabeledContent("Usage", value: usageText)
            }
            Section("Retention") {
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
                Text("Loop deletes the oldest clips to stay under the limit; "
                    + "Stop & notify halts recording instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            folderPath = context.fileStore.currentFolder().path
            refreshUsage()
        }
    }

    private func refreshUsage() {
        let usage = context.fileStore.folderUsage()
        let usedGB = StorageMath.bytesToGB(usage.totalBytes)
        let freeGB = StorageMath.bytesToGB(context.fileStore.volumeFreeBytes())
        usageText = String(format: "%d clips · %.1f GB · %.1f GB free", usage.count, usedGB, freeGB)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            context.fileStore.setFolder(url)
            folderPath = context.fileStore.currentFolder().path
        }
    }
}
