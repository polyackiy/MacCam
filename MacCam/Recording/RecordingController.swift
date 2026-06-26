import Foundation
import AVFoundation

/// Drives `AVAssetWriter` from the recording state machine. Thread-safe append
/// of interleaved video/audio sample buffers; handles pre-roll flush, seamless
/// rotation at max clip length, and clean finalization.
final class RecordingController {
    private let fileStore: FileStore
    private var fsm: RecordingFSM
    private var settings: AppSettings
    private let lock = NSLock()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStartPTS: CMTime = .invalid
    private var currentClipName: String?
    private let ring = RingBuffer<CMSampleBuffer>(duration: 10)

    /// Called on the main queue with (isRecording, lastClipName?).
    var onStateChange: ((Bool, String?) -> Void)?
    private(set) var isRecording = false
    private(set) var lastClipName: String?

    init(fileStore: FileStore, settings: AppSettings) {
        self.fileStore = fileStore
        self.settings = settings
        self.fsm = RecordingFSM(minClip: settings.minClipLength,
                                maxClip: settings.maxClipLength,
                                cooldown: settings.postMotionCooldown)
    }

    /// Apply new settings; only takes full effect on the next clip.
    func updateSettings(_ s: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        settings = s
        if !isRecording {
            fsm = RecordingFSM(minClip: s.minClipLength,
                               maxClip: s.maxClipLength,
                               cooldown: s.postMotionCooldown)
        }
    }

    // MARK: Sample handling

    func handle(video sampleBuffer: CMSampleBuffer, motion: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = CMTimeGetSeconds(pts)
        guard now.isFinite else { return }

        lock.lock(); defer { lock.unlock() }

        if fsm.state == .idle && settings.preRollEnabled {
            ring.push(sampleBuffer, pts: now)
        }

        switch fsm.step(motion: motion, now: now) {
        case .none:
            break

        case .startClip:
            if settings.preRollEnabled {
                let frames = ring.snapshot()
                let start = frames.first.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? pts
                openWriter(dimensionsFrom: frames.first ?? sampleBuffer, startPTS: start)
                for f in frames { appendVideo(f) }
                ring.clear()
            } else {
                openWriter(dimensionsFrom: sampleBuffer, startPTS: pts)
                appendVideo(sampleBuffer)
            }

        case .appendOnly:
            appendVideo(sampleBuffer)

        case .rotate:
            finishWriter()
            openWriter(dimensionsFrom: sampleBuffer, startPTS: pts)
            appendVideo(sampleBuffer)

        case .finishAndIdle:
            appendVideo(sampleBuffer)
            finishWriter()
        }
    }

    func handle(audio sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, let input = audioInput, sessionStartPTS.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(pts, sessionStartPTS) >= 0, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Finalize any in-progress clip (e.g. when monitoring stops).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if isRecording { finishWriter() }
        ring.clear()
        fsm = RecordingFSM(minClip: settings.minClipLength,
                           maxClip: settings.maxClipLength,
                           cooldown: settings.postMotionCooldown)
    }

    // MARK: Writer lifecycle (call with lock held)

    private func openWriter(dimensionsFrom sample: CMSampleBuffer, startPTS: CMTime) {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let w = Int(dims.width), h = Int(dims.height)
        let url = fileStore.nextClipURL(now: Date())

        guard let w0 = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        let codecType: AVVideoCodecType = settings.codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Bitrate.bps(quality: settings.quality, width: w, height: h),
                AVVideoExpectedSourceFrameRateKey: settings.targetFPS,
            ],
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        if w0.canAdd(vInput) { w0.add(vInput) }

        var aInput: AVAssetWriterInput?
        if settings.audioEnabled {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 64_000,
            ]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if w0.canAdd(a) { w0.add(a); aInput = a }
        }

        guard w0.startWriting() else { return }
        w0.startSession(atSourceTime: startPTS)

        writer = w0
        videoInput = vInput
        audioInput = aInput
        sessionStartPTS = startPTS
        currentClipName = url.lastPathComponent
        isRecording = true
        notifyState()
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let input = videoInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    private func finishWriter() {
        guard let w = writer else { return }
        let name = currentClipName
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        w.finishWriting { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastClipName = name
            self.lock.unlock()
            DispatchQueue.main.async { self.onStateChange?(self.isRecording, name) }
        }
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStartPTS = .invalid
        currentClipName = nil
        isRecording = false
        notifyState()
    }

    private func notifyState() {
        let recording = isRecording
        let name = lastClipName
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(recording, name) }
    }
}
