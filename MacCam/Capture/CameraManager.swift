import Foundation
import AVFoundation
import Combine
import CoreAudio

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

        if settings.effectiveAudioOnly {
            videoOutput = nil
            currentDevice = nil
            audioOutput = nil
            if let aInput = makeAudioInput() {
                session.addInput(aInput)
                let aout = AVCaptureAudioDataOutput()
                aout.setSampleBufferDelegate(delegate, queue: audioQueue)
                if session.canAddOutput(aout) { session.addOutput(aout) }
                audioOutput = aout
                Log.capture.info("Audio-only input: \(aInput.device.localizedName, privacy: .public)")
            } else {
                Log.capture.error("Audio-only enabled but no usable microphone input was found")
            }
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.formatDescription = loc("Audio only")
                self.statusMessage = loc("Audio only")
            }
            return
        }

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
            if let aInput = makeAudioInput() {
                session.addInput(aInput)
                let aout = AVCaptureAudioDataOutput()
                aout.setSampleBufferDelegate(delegate, queue: audioQueue)
                if session.canAddOutput(aout) { session.addOutput(aout) }
                audioOutput = aout
                Log.capture.info("Audio input: \(aInput.device.localizedName, privacy: .public)")
            } else {
                Log.capture.error("Audio enabled but no usable microphone input was found")
            }
        }

        session.commitConfiguration()
        updateFormatString(device)
    }

    /// All audio capture devices, deduped and ordered with the built-in
    /// microphone first (Bluetooth last). The system DiscoverySession audio
    /// types are unreliable on macOS, so `devices(for:)` is included too.
    func availableMicrophones() -> [AVCaptureDevice] {
        var candidates: [AVCaptureDevice] = []
        var seen = Set<String>()
        func add(_ device: AVCaptureDevice?) {
            guard let device, seen.insert(device.uniqueID).inserted else { return }
            candidates.append(device)
        }
        if #available(macOS 14.0, *) {
            AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                             mediaType: .audio, position: .unspecified)
                .devices.forEach(add)
        }
        AVCaptureDevice.devices(for: .audio).forEach(add)   // reliable on macOS; includes built-in
        add(AVCaptureDevice.default(for: .audio))
        return candidates.sorted { transportRank($0) < transportRank($1) }
    }

    /// Pick an audio device that yields a usable capture input. The user-selected
    /// device (if any and present) is tried first; otherwise the built-in
    /// microphone is preferred. The system default can be an un-capturable
    /// Bluetooth/output device, so each candidate is tried until one produces a
    /// valid input. Returns nil if none work.
    private func makeAudioInput() -> AVCaptureDeviceInput? {
        var ordered = availableMicrophones()
        if let id = settings.audioDeviceID, !id.isEmpty,
           let index = ordered.firstIndex(where: { $0.uniqueID == id }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        for device in ordered {
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                return input
            }
        }
        return nil
    }

    /// Built-in microphone first, unknown second, Bluetooth last.
    private func transportRank(_ device: AVCaptureDevice) -> Int {
        switch UInt32(bitPattern: device.transportType) {
        case kAudioDeviceTransportTypeBuiltIn: return 0
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 2
        default: return 1
        }
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

    // MARK: Live preview (for the zone editor)

    private var previewSession: AVCaptureSession?

    /// Provide a running camera session for a live preview in the zone editor.
    /// Reuses the monitoring session when it already runs the camera (motion
    /// modes) — so there is never a second session contending for the same
    /// camera; otherwise spins up a dedicated camera-only session (the camera is
    /// free when idle or in audio-only mode). The dedicated session has no data
    /// output, so previewing never starts recording. Delivers nil if no camera.
    ///
    /// Known limitations (both require toggling monitoring while the editor stays
    /// open, so they're rare and left unhandled): a reused monitoring session that
    /// later stops or reconfigures to audio-only leaves the preview frozen until
    /// the editor is reopened; and in the brief window where monitoring has been
    /// configured but `isRunning` is not yet true, this falls to the dedicated
    /// branch — harmless because both run on `sessionQueue`, but it could briefly
    /// open a second session as monitoring starts.
    func startPreview(_ completion: @escaping (AVCaptureSession?) -> Void) {
        sessionQueue.async {
            let hasCamera = self.session.inputs.contains {
                ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) ?? false
            }
            if self.session.isRunning && hasCamera {
                DispatchQueue.main.async { completion(self.session) }
                return
            }
            guard let device = self.pickDevice(self.settings.cameraID),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            self.previewSession = session
            session.startRunning()
            DispatchQueue.main.async { completion(session) }
        }
    }

    /// Tear down the dedicated preview session. No-op if the monitoring session
    /// was reused — that one must keep running.
    func stopPreview() {
        sessionQueue.async {
            self.previewSession?.stopRunning()
            self.previewSession = nil
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
