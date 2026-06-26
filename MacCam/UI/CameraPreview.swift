import SwiftUI
import AVFoundation

/// A live camera preview backed by `AVCaptureVideoPreviewLayer`. `.resize`
/// stretches the frame to fill its box so it matches the motion detector's 16×9
/// sampling, keeping the painted zones aligned with what the detector sees.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resize
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    /// Layer-hosting view whose backing layer is the preview layer.
    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
