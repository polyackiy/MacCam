import Foundation
import AVFoundation
import Combine

/// Adapts a real capture format to the testable `FormatInfo` protocol.
struct AVFormatAdapter: FormatInfo {
    let format: AVCaptureDevice.Format
    var width: Int { Int(CMVideoFormatDescriptionGetDimensions(format.formatDescription).width) }
    var height: Int { Int(CMVideoFormatDescriptionGetDimensions(format.formatDescription).height) }
    var maxFPS: Double { format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0 }
}

/// Owns the `AVCaptureSession`: device discovery, max-resolution format
/// selection, video/audio outputs, start/stop, and reconnection on disconnect.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "capture.video")
    private let audioQueue = DispatchQueue(label: "capture.audio")
    private let sessionQueue = DispatchQueue(label: "capture.session")

    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var currentDevice: AVCaptureDevice?
    private var delegate: CaptureDelegate?
    private var settings: AppSettings

    @Published var formatDescription = "—"
    @Published var statusMessage = ""
    @Published private(set) var isRunning = false

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceDisconnected(_:)),
            name: .AVCaptureDeviceWasDisconnected, object: nil)
    }

    func availableCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(contentsOf: [.external, .continuityCamera])
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    private func pickDevice(_ id: String?) -> AVCaptureDevice? {
        let cams = availableCameras()
        if let id, let match = cams.first(where: { $0.uniqueID == id }) { return match }
        return cams.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? cams.first
    }

    func configure(settings: AppSettings, delegate: CaptureDelegate) {
        self.settings = settings
        self.delegate = delegate
        sessionQueue.sync { self.reconfigure() }
    }

    private func reconfigure() {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = pickDevice(settings.cameraID),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.statusMessage = "No camera available" }
            return
        }
        session.addInput(input)
        currentDevice = device
        applyMaxFormat(device, targetFPS: settings.targetFPS, minFPS: 24)

        let vout = AVCaptureVideoDataOutput()
        vout.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        vout.setSampleBufferDelegate(delegate, queue: videoQueue)
        if session.canAddOutput(vout) { session.addOutput(vout) }
        videoOutput = vout

        audioOutput = nil
        if settings.audioEnabled {
            if let mic = AVCaptureDevice.default(for: .audio),
               let aInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(aInput) {
                session.addInput(aInput)
            }
            let aout = AVCaptureAudioDataOutput()
            aout.setSampleBufferDelegate(delegate, queue: audioQueue)
            if session.canAddOutput(aout) { session.addOutput(aout) }
            audioOutput = aout
        }

        session.commitConfiguration()
        updateFormatString(device)
    }

    private func applyMaxFormat(_ device: AVCaptureDevice, targetFPS: Int, minFPS: Int) {
        let adapters = device.formats.map { AVFormatAdapter(format: $0) }
        guard let best = FormatSelector.pick(from: adapters, minFPS: Double(minFPS)) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best.format
            let fps = min(Double(targetFPS), best.maxFPS)
            if fps > 0 {
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            Log.capture.error("Failed to set active format: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateFormatString(_ device: AVCaptureDevice) {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fps = device.activeVideoMinFrameDuration
        let fpsValue = fps.timescale > 0 && fps.value > 0
            ? Int((Double(fps.timescale) / Double(fps.value)).rounded()) : settings.targetFPS
        let text = "\(dims.width)×\(dims.height) @ \(fpsValue)fps"
        DispatchQueue.main.async {
            self.formatDescription = text
            self.statusMessage = device.localizedName
        }
        Log.capture.info("Selected \(device.localizedName, privacy: .public) — \(text, privacy: .public)")
    }

    func start() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    // MARK: Disconnect / runtime errors

    @objc private func handleRuntimeError(_ note: Notification) {
        Log.capture.error("Capture runtime error: \(String(describing: note.userInfo), privacy: .public)")
        DispatchQueue.main.async { self.statusMessage = "Camera error — retrying…" }
        sessionQueue.asyncAfter(deadline: .now() + 2) {
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    @objc private func deviceDisconnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice, device == currentDevice else { return }
        DispatchQueue.main.async { self.statusMessage = "Camera disconnected — waiting…" }
    }
}
