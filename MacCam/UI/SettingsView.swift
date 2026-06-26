import SwiftUI

/// Tabbed Settings window. Each tab is a small focused view fed by a
/// `SettingsContext`.
struct SettingsView: View {
    let context: SettingsContext

    var body: some View {
        TabView {
            CameraSettingsTab(context: context)
                .tabItem { Label("Camera", systemImage: "camera") }
            MotionSettingsTab(context: context)
                .tabItem { Label("Motion", systemImage: "figure.walk") }
            RecordingSettingsTab(context: context)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            ScheduleSettingsTab(context: context)
                .tabItem { Label("Schedule", systemImage: "calendar") }
            StorageSettingsTab(context: context)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            AppearanceSettingsTab(context: context)
                .tabItem { Label("Appearance", systemImage: "eye") }
            SystemSettingsTab(context: context)
                .tabItem { Label("System", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 560)
    }
}
