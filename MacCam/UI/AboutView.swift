import SwiftUI

struct AboutView: View {
    private static let repoURL = URL(string: "https://github.com/polyackiy/MacCam")!
    private static let licenseURL = URL(string: "https://github.com/polyackiy/MacCam/blob/main/LICENSE")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("MacCam")
                .font(.title).bold()
            Text("Private, offline motion-detecting security camera")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Version \(version) (\(build))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Link("GitHub", destination: Self.repoURL)
                Link("License", destination: Self.licenseURL)
            }
            .font(.callout)
            Text("MIT © MacCam contributors")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 320)
    }
}
