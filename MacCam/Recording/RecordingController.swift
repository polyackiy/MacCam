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
    private var ring: RingBuffer<CMSampleBuffer>
    private var ringDuration: Double

    /// Injectable clock for the recording-schedule gate (tests override it).
    var clock: () -> Date = Date.init
    private var recordingSchedule = WeeklySchedule()
    private let scheduleCalendar = Calendar.current

    /// Called on the main queue with (isRecording, lastClipName?).
    var onStateChange: ((Bool, String?) -> Void)?
    private(set) var isRecording = false
    private(set) var lastClipName: String?

    /// Fired (on the main queue) when the `.stop` disk policy aborts recording.
    var onStorageStop: (() -> Void)?
    private var currentURL: URL?
    private var finalizingURLs: Set<URL> = []

    // Disk limits, set from AppSettings snapshots (main thread). Enforcement runs
    // on `ioQueue`, never on the capture queue; the gate reads only the cached
    // `overLimitStop` flag so the hot path stays free of disk I/O and of any
    // SettingsStore access.
    private var maxStorageBytes: Int64 = 0
    private var minFreeBytes: Int64 = 0
    private var diskPolicy: DiskLimitPolicy = .loop
    private let ioQueue = DispatchQueue(label: "recording.io", qos: .utility)
    private var overLimitStop = false
    private var maintenanceScheduled = false
    private var storageStopped = false

    init(fileStore: FileStore, settings: AppSettings) {
        self.fileStore = fileStore
        self.settings = settings
        self.ringDuration = settings.preRoll
        self.ring = RingBuffer<CMSampleBuffer>(duration: settings.preRoll)
        self.fsm = RecordingFSM(minClip: settings.minClipLength,
                                maxClip: settings.maxClipLength,
                                cooldown: settings.postMotionCooldown)
        applyDiskLimits(settings)
    }

    private func applyDiskLimits(_ s: AppSettings) {
        maxStorageBytes = StorageMath.gbToBytes(s.maxStorageGB)
        minFreeBytes = StorageMath.gbToBytes(s.minFreeSpaceGB)
        diskPolicy = s.diskLimitPolicy
        recordingSchedule = s.recordingSchedule
    }

    /// Apply new settings. Detector/threshold changes take effect immediately;
    /// clip-timing (FSM) changes apply on the next clip to avoid disrupting an
    /// in-progress recording.
    func updateSettings(_ s: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        settings = s
        applyDiskLimits(s)
        if s.preRoll != ringDuration {
            ringDuration = s.preRoll
            ring = RingBuffer<CMSampleBuffer>(duration: s.preRoll)
        }
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

        // Recording schedule gate: outside its window, ignore motion so no clip
        // starts (monitoring keeps running).
        let effectiveMotion = motion && recordingScheduleAllows()

        switch fsm.step(motion: effectiveMotion, now: now) {
        case .none:
            break

        case .startClip:
            guard storageAllowsNewClip() else { break }
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
            guard storageAllowsNewClip() else { break }
            openWriter(dimensionsFrom: sampleBuffer, startPTS: pts)
            appendVideo(sampleBuffer)

        case .finishAndIdle:
            appendVideo(sampleBuffer)
            finishWriter()
        }
    }

    func handle(audio sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording else { return }
        appendAudio(sampleBuffer)
    }

    /// Audio-only path: drive the FSM from audio buffers (no video), opening a
    /// writer with a single audio track. Mirrors the video path's recording- and
    /// storage-gates. Used only when the session has no camera (audio-only mode),
    /// so it is mutually exclusive with `handle(video:motion:)`.
    func handle(audioOnly sampleBuffer: CMSampleBuffer, trigger: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = CMTimeGetSeconds(pts)
        guard now.isFinite else { return }

        lock.lock(); defer { lock.unlock() }

        let effectiveTrigger = trigger && recordingScheduleAllows()

        switch fsm.step(motion: effectiveTrigger, now: now) {
        case .none:
            break

        case .startClip:
            guard storageAllowsNewClip() else { break }
            openWriter(dimensions: nil, audio: true, startPTS: pts)
            appendAudio(sampleBuffer)

        case .appendOnly:
            appendAudio(sampleBuffer)

        case .rotate:
            finishWriter()
            guard storageAllowsNewClip() else { break }
            openWriter(dimensions: nil, audio: true, startPTS: pts)
            appendAudio(sampleBuffer)

        case .finishAndIdle:
            appendAudio(sampleBuffer)
            finishWriter()
        }
    }

    /// Finalize any in-progress clip (e.g. when monitoring stops).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if isRecording { finishWriter() }
        ring.clear()
        storageStopped = false
        overLimitStop = false
        fsm = RecordingFSM(minClip: settings.minClipLength,
                           maxClip: settings.maxClipLength,
                           cooldown: settings.postMotionCooldown)
    }

    // MARK: Writer lifecycle (call with lock held)

    /// Recording-schedule gate (call with lock held). A disabled schedule is
    /// always allowed; otherwise the current time must fall inside the window.
    /// Shared by the video and audio-only drive paths so the gate can't drift.
    private func recordingScheduleAllows() -> Bool {
        !recordingSchedule.enabled
            || recordingSchedule.isActive(at: clock(), calendar: scheduleCalendar)
    }

    /// Cheap gate (call with lock held, on the capture queue): consults only the
    /// cached limit flag and kicks off background maintenance. No disk I/O here.
    private func storageAllowsNewClip() -> Bool {
        guard maxStorageBytes > 0 || minFreeBytes > 0 else { return true }
        scheduleStorageMaintenance()
        if diskPolicy == .stop && overLimitStop {
            if !storageStopped {
                storageStopped = true
                DispatchQueue.main.async { [weak self] in self?.onStorageStop?() }
            }
            return false
        }
        return true
    }

    /// Run folder enumeration / deletion off the capture queue. Coalesced so at
    /// most one maintenance pass is in flight. Call with lock held.
    private func scheduleStorageMaintenance() {
        guard !maintenanceScheduled else { return }
        maintenanceScheduled = true
        let maxB = maxStorageBytes, minFree = minFreeBytes, policy = diskPolicy
        ioQueue.async { [weak self] in
            guard let self else { return }
            // Read the protected set at execution time so a clip opened after
            // scheduling is still protected from deletion.
            self.lock.lock()
            var protectedURLs = self.finalizingURLs
            if let current = self.currentURL { protectedURLs.insert(current) }
            self.lock.unlock()

            if policy == .loop {
                self.fileStore.enforce(maxBytes: maxB, minFreeBytes: minFree, protecting: protectedURLs)
            }
            let total = self.fileStore.folderUsage().totalBytes
            let free = self.fileStore.volumeFreeBytes()
            let over = StorageMath.overLimit(totalBytes: total, freeBytes: free,
                                             maxBytes: maxB, minFreeBytes: minFree)
            self.lock.lock()
            self.overLimitStop = over
            self.maintenanceScheduled = false
            self.lock.unlock()
        }
    }

    /// Thin wrapper for the video path: derive W×H from a sample, then open a
    /// writer with a video input and (optionally) an audio input.
    private func openWriter(dimensionsFrom sample: CMSampleBuffer, startPTS: CMTime) {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        openWriter(dimensions: (Int(dims.width), Int(dims.height)),
                   audio: settings.audioEnabled, startPTS: startPTS)
    }

    /// Open an `AVAssetWriter`. `dimensions != nil` adds a video input; `audio`
    /// adds an AAC audio input. Audio-only clips pass `dimensions: nil`.
    private func openWriter(dimensions: (Int, Int)?, audio: Bool, startPTS: CMTime) {
        let url = fileStore.nextClipURL(now: Date())
        guard let w0 = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        var vInput: AVAssetWriterInput?
        if let (w, h) = dimensions {
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
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            v.expectsMediaDataInRealTime = true
            if w0.canAdd(v) { w0.add(v); vInput = v }
        }

        var aInput: AVAssetWriterInput?
        if audio {
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
        currentURL = url
        isRecording = true
        notifyState()
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let input = videoInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Append an audio buffer to the current clip if one is open and the buffer
    /// is at or after the session start. Call with the lock held.
    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let input = audioInput, sessionStartPTS.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(pts, sessionStartPTS) >= 0, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    private func finishWriter() {
        guard let w = writer else { return }
        let name = currentClipName
        let finishedURL = currentURL
        if let url = finishedURL { finalizingURLs.insert(url) }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        w.finishWriting { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastClipName = name
            if let url = finishedURL { self.finalizingURLs.remove(url) }
            self.lock.unlock()
            DispatchQueue.main.async { self.onStateChange?(self.isRecording, name) }
        }
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStartPTS = .invalid
        currentClipName = nil
        currentURL = nil
        isRecording = false
        notifyState()
    }

    private func notifyState() {
        let recording = isRecording
        let name = lastClipName
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(recording, name) }
    }
}
