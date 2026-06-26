import SwiftUI

/// Settings window with a System-Settings-style sidebar. Each pane is a small
/// focused view fed by a `SettingsContext`.
struct SettingsView: View {
    let context: SettingsContext
    @State private var selection: Pane? = .camera

    enum Pane: String, CaseIterable, Identifiable {
        case camera, detection, recording, schedule, storage, general
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .camera: return "Camera"
            case .detection: return "Detection"
            case .recording: return "Recording"
            case .schedule: return "Schedule"
            case .storage: return "Storage"
            case .general: return "General"
            }
        }

        var icon: String {
            switch self {
            case .camera: return "camera"
            case .detection: return "dot.viewfinder"
            case .recording: return "record.circle"
            case .schedule: return "calendar"
            case .storage: return "internaldrive"
            case .general: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.label, systemImage: pane.icon).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            detail(for: selection ?? .camera)
                .navigationTitle((selection ?? .camera).label)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, idealWidth: 700, minHeight: 540, idealHeight: 580)
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .camera: CameraSettingsTab(context: context)
        case .detection: DetectionSettingsTab(context: context)
        case .recording: RecordingSettingsTab(context: context)
        case .schedule: ScheduleSettingsTab(context: context)
        case .storage: StorageSettingsTab(context: context)
        case .general: GeneralSettingsTab(context: context)
        }
    }
}
