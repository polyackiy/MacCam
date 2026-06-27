import SwiftUI
import AVFoundation

/// Paints a 16×9 ignore mask over a live camera preview. Ignored cells (red) are
/// excluded from motion detection, so the user can align zones against what the
/// camera actually sees.
struct ZoneEditorView: View {
    @ObservedObject var settings: SettingsStore
    let camera: CameraManager

    @State private var mask = MotionMask()
    @State private var previewSession: AVCaptureSession?

    var body: some View {
        VStack(spacing: 12) {
            Text("Tap or drag cells to ignore (red). Motion there is not detected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack {
                    if let previewSession {
                        CameraPreview(session: previewSession)
                    } else {
                        Rectangle().fill(Color.black.opacity(0.85))
                        Text("Camera preview unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    grid(in: geo.size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { paint($0.location, in: geo.size) }
                )
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)

            HStack {
                Button("Clear") { mask.clear(); persist() }
                Button("Invert") { mask.invert(); persist() }
                Spacer()
                Text("\(mask.ignoredCount) cells ignored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520, height: 380)
        .onAppear {
            mask = MotionMask(encoded: settings.detectionMask) ?? MotionMask()
            camera.startPreview { previewSession = $0 }
        }
        // Teardown is driven by the window's close (AppDelegate observes it):
        // onDisappear is unreliable for an NSWindow-hosted view that isn't
        // released, so relying on it here would leak the preview session.
    }

    private func grid(in size: CGSize) -> some View {
        let cellW = size.width / CGFloat(MotionMask.cols)
        let cellH = size.height / CGFloat(MotionMask.rows)
        return ZStack {
            ForEach(0..<MotionMask.rows, id: \.self) { row in
                ForEach(0..<MotionMask.cols, id: \.self) { col in
                    Rectangle()
                        .fill(mask.cell(col, row) ? Color.red.opacity(0.45) : Color.clear)
                        .frame(width: cellW, height: cellH)
                        .border(Color.white.opacity(0.25), width: 0.5)
                        .position(x: cellW * (CGFloat(col) + 0.5),
                                  y: cellH * (CGFloat(row) + 0.5))
                }
            }
        }
    }

    private func paint(_ point: CGPoint, in size: CGSize) {
        let col = Int(point.x / (size.width / CGFloat(MotionMask.cols)))
        let row = Int(point.y / (size.height / CGFloat(MotionMask.rows)))
        guard (0..<MotionMask.cols).contains(col), (0..<MotionMask.rows).contains(row) else { return }
        if !mask.cell(col, row) {
            mask.set(col, row, true)
            persist()
        }
    }

    private func persist() { settings.detectionMask = mask.encoded() }
}
