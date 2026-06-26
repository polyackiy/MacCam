# Recording Modes (Trigger + Audio-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a recording-trigger picker (Continuous / Motion / Voice / Motion+Voice) replacing the standalone voice toggle, and an audio-only recording mode (camera off, single audio track) available for Continuous/Voice triggers.

**Architecture:** A pure `TriggerMode` enum drives both the trigger source (in `CaptureDelegate`) and the capture-session shape (in `CameraManager`). `RecordingController` gains an audio-driven path (`handle(audioOnly:trigger:)`) that opens a video-less writer; the existing video path is unchanged. The drive path is selected by `CaptureDelegate` (which handler it calls) and the session by `CameraManager` (whether a camera input exists), so the two paths are mutually exclusive by construction — no extra `recordVideo` flag is needed on the recorder.

**Tech Stack:** Swift 5, AVFoundation (AVCaptureSession, AVAssetWriter), SoundAnalysis (existing `VoiceDetector`), SwiftUI, XCTest. Build/test/lint via `make build` / `make test` / `make lint`.

**Branch:** `feat/recording-modes` (already checked out).

---

## File Structure

**New files:**
- `MacCam/Recording/TriggerMode.swift` — the `TriggerMode` enum (pure logic).
- `MacCamTests/TriggerModeTests.swift` — pure tests for the enum.
- `MacCamTests/RecordingControllerAudioOnlyTests.swift` — audio-only clip tests.

**Modified files:**
- `MacCam/Recording/RecordingController.swift` — `appendAudio` extraction, generalized `openWriter(dimensions:audio:startPTS:)`, new `handle(audioOnly:trigger:)`.
- `MacCam/Capture/CaptureDelegate.swift` — lock-guarded `triggerMode`/`audioOnly`, `setTriggerMode`/`setAudioOnly`, mode-based trigger + audio routing.
- `MacCam/UI/SettingsStore.swift` — `AppSettings`/store gain `triggerMode` + `audioOnly` + `effectiveAudioOnly`; `voiceTriggerEnabled` removed.
- `MacCam/App/AppDelegate.swift` — push `triggerMode`/`effectiveAudioOnly` into `CaptureDelegate`; gate voice on `triggerMode.usesVoice`.
- `MacCam/Capture/CameraManager.swift` — audio-only `reconfigure` branch (no camera input/video output).
- `MacCam/UI/SettingsTabs/RecordingSettingsTab.swift` — trigger Picker + audio-only Toggle.
- `MacCam/Localizable.xcstrings` — new UI strings.
- `CHANGELOG.md` — Unreleased entry.
- `MacCamTests/AudioRecordingTests.swift`, `MacCamTests/RecordingControllerScheduleTests.swift`, `MacCamTests/RecordingIntegrationTests.swift` — `AppSettings` literals updated.

**Task ordering rationale:** Each task's *end state* compiles. `voiceTriggerEnabled` is kept through the middle tasks and removed only in Task 8 once no code reads it, so there are never forward references or a broken build at a commit boundary.

---

### Task 1: TriggerMode enum + tests

**Files:**
- Create: `MacCam/Recording/TriggerMode.swift`
- Test: `MacCamTests/TriggerModeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MacCamTests/TriggerModeTests.swift`:

```swift
import XCTest
@testable import MacCam

final class TriggerModeTests: XCTestCase {
    func testContinuous() {
        let m = TriggerMode.continuous
        XCTAssertFalse(m.usesMotion)
        XCTAssertFalse(m.usesVoice)
        XCTAssertTrue(m.isContinuous)
        XCTAssertTrue(m.allowsAudioOnly)
    }

    func testMotion() {
        let m = TriggerMode.motion
        XCTAssertTrue(m.usesMotion)
        XCTAssertFalse(m.usesVoice)
        XCTAssertFalse(m.isContinuous)
        XCTAssertFalse(m.allowsAudioOnly)
    }

    func testVoice() {
        let m = TriggerMode.voice
        XCTAssertFalse(m.usesMotion)
        XCTAssertTrue(m.usesVoice)
        XCTAssertFalse(m.isContinuous)
        XCTAssertTrue(m.allowsAudioOnly)
    }

    func testMotionAndVoice() {
        let m = TriggerMode.motionAndVoice
        XCTAssertTrue(m.usesMotion)
        XCTAssertTrue(m.usesVoice)
        XCTAssertFalse(m.isContinuous)
        XCTAssertFalse(m.allowsAudioOnly)
    }

    func testAllCasesAndLabels() {
        XCTAssertEqual(TriggerMode.allCases.count, 4)
        XCTAssertFalse(TriggerMode.motion.label.isEmpty)
        XCTAssertEqual(TriggerMode.continuous.id, "continuous")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'TriggerMode' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `MacCam/Recording/TriggerMode.swift`:

```swift
import Foundation

/// What starts a recording clip. Replaces the old standalone "voice trigger"
/// boolean with an explicit choice. `Continuous` records whenever monitoring is
/// active; `Voice` and `Motion+Voice` require audio recording to be enabled.
/// `allowsAudioOnly` marks the modes that can record without a camera (the
/// camera is only needed when motion is a trigger source).
enum TriggerMode: String, CaseIterable, Identifiable {
    case continuous, motion, voice, motionAndVoice

    var id: String { rawValue }

    var usesMotion: Bool { self == .motion || self == .motionAndVoice }
    var usesVoice: Bool { self == .voice || self == .motionAndVoice }
    var isContinuous: Bool { self == .continuous }
    var allowsAudioOnly: Bool { self == .continuous || self == .voice }

    var label: String {
        switch self {
        case .continuous: return "Continuous"
        case .motion: return "Motion"
        case .voice: return "Voice"
        case .motionAndVoice: return "Motion + Voice"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS (new tests green; existing tests still pass).

- [ ] **Step 5: Commit**

```bash
git add MacCam/Recording/TriggerMode.swift MacCamTests/TriggerModeTests.swift
git commit -m "feat: TriggerMode enum (continuous/motion/voice/motion+voice)"
```

---

### Task 2: RecordingController audio-only path

**Files:**
- Modify: `MacCam/Recording/RecordingController.swift`
- Test: `MacCamTests/RecordingControllerAudioOnlyTests.swift`

This task is independent of the settings type change: `handle(audioOnly:trigger:)` is driven entirely by its caller's `trigger`, and `openWriter` is generalized internally. The new test builds an `AppSettings` literal using the **current** struct shape (with `voiceTriggerEnabled`); Task 4 updates it.

- [ ] **Step 1: Write the failing test**

Create `MacCamTests/RecordingControllerAudioOnlyTests.swift`:

```swift
import XCTest
import AVFoundation
import CoreMedia
@testable import MacCam

/// Drives RecordingController through the audio-only path (no video frames) and
/// asserts the produced clip has exactly one audio track and no video track.
final class RecordingControllerAudioOnlyTests: XCTestCase {
    private let sampleRate: Double = 44_100

    private func settings() -> AppSettings {
        AppSettings(cameraID: nil, targetFPS: 30, sensitivity: 2, pixelDelta: 25,
                    postMotionCooldown: 1, minClipLength: 1, maxClipLength: 60,
                    preRollEnabled: false, preRoll: 3, audioEnabled: true,
                    audioDeviceID: nil, voiceTriggerEnabled: false, voiceSensitivity: 2,
                    codec: .hevc, quality: .medium, autoCleanup: false,
                    cleanupDays: 14, guardMode: false,
                    monitoringSchedule: WeeklySchedule(), recordingSchedule: WeeklySchedule(),
                    maxStorageGB: 0, minFreeSpaceGB: 0,
                    diskLimitPolicy: .loop, detectionMask: "")
    }

    private func makeAudioSample(pts: CMTime, frames: Int) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let byteCount = frames * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                           blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                           flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                             sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: [2], sampleBufferOut: &sample)
        return sample!
    }

    private func makeStore() -> (RecordingController, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacCamAudioOnly-\(ProcessInfo.processInfo.globallyUniqueString)")
        let fileStore = FileStore(defaults: UserDefaults.standard, defaultOverride: tmp)
        return (RecordingController(fileStore: fileStore, settings: settings()), tmp)
    }

    func testAudioOnlyClipHasAudioTrackAndNoVideoTrack() throws {
        let (rc, tmp) = makeStore()
        let clipWritten = expectation(description: "clip finalized")
        clipWritten.assertForOverFulfill = false
        rc.onStateChange = { _, name in if name != nil { clipWritten.fulfill() } }

        let framesPerAudio = 1024
        var audioPTS = CMTime.zero
        // ~6s of audio: trigger true for the first half, false for the second so
        // the clip starts, satisfies minClip, then finalizes after cooldown.
        for i in 0..<260 {
            rc.handle(audioOnly: makeAudioSample(pts: audioPTS, frames: framesPerAudio),
                      trigger: i < 130)
            audioPTS = CMTimeAdd(audioPTS, CMTime(value: CMTimeValue(framesPerAudio), timescale: Int32(sampleRate)))
        }

        wait(for: [clipWritten], timeout: 10)

        let clip = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "mov" }
        let asset = AVURLAsset(url: try XCTUnwrap(clip))
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1, "audio track expected")
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 0, "no video track expected")

        try? FileManager.default.removeItem(at: tmp)
    }

    func testNoTriggerProducesNoClip() throws {
        let (rc, tmp) = makeStore()
        let framesPerAudio = 1024
        var audioPTS = CMTime.zero
        for _ in 0..<100 {
            rc.handle(audioOnly: makeAudioSample(pts: audioPTS, frames: framesPerAudio), trigger: false)
            audioPTS = CMTimeAdd(audioPTS, CMTime(value: CMTimeValue(framesPerAudio), timescale: Int32(sampleRate)))
        }
        let movs = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }) ?? []
        XCTAssertTrue(movs.isEmpty, "no clip should be produced without a trigger")
        try? FileManager.default.removeItem(at: tmp)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `incorrect argument label in call (have 'audioOnly:trigger:'...)` / no such method.

- [ ] **Step 3a: Generalize `openWriter` and extract `appendAudio`**

In `MacCam/Recording/RecordingController.swift`, replace the existing `openWriter(dimensionsFrom:startPTS:)` method (the whole method, lines beginning `private func openWriter(dimensionsFrom sample:` through its closing brace) with a thin wrapper plus a generalized core:

```swift
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
```

Then replace the body of `handle(audio:)` to delegate to a shared `appendAudio`, and add the `appendAudio` helper next to `appendVideo`:

Replace:

```swift
    func handle(audio sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording, let input = audioInput, sessionStartPTS.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(pts, sessionStartPTS) >= 0, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
```

with:

```swift
    func handle(audio sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard isRecording else { return }
        appendAudio(sampleBuffer)
    }
```

And add this helper immediately after the existing `appendVideo(_:)` method:

```swift
    /// Append an audio buffer to the current clip if one is open and the buffer
    /// is at or after the session start. Call with the lock held.
    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let input = audioInput, sessionStartPTS.isValid else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(pts, sessionStartPTS) >= 0, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
```

- [ ] **Step 3b: Add `handle(audioOnly:trigger:)`**

In `MacCam/Recording/RecordingController.swift`, immediately after `handle(audio:)`, add:

```swift
    /// Audio-only path: drive the FSM from audio buffers (no video), opening a
    /// writer with a single audio track. Mirrors the video path's recording- and
    /// storage-gates. Used only when the session has no camera (audio-only mode),
    /// so it is mutually exclusive with `handle(video:motion:)`.
    func handle(audioOnly sampleBuffer: CMSampleBuffer, trigger: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = CMTimeGetSeconds(pts)
        guard now.isFinite else { return }

        lock.lock(); defer { lock.unlock() }

        let allowed = !recordingSchedule.enabled
            || recordingSchedule.isActive(at: clock(), calendar: scheduleCalendar)
        let effectiveTrigger = trigger && allowed

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS — both new audio-only tests green; `AudioRecordingTests` and all existing tests still pass (the `openWriter` refactor preserves the video path).

- [ ] **Step 5: Commit**

```bash
git add MacCam/Recording/RecordingController.swift MacCamTests/RecordingControllerAudioOnlyTests.swift
git commit -m "feat: audio-only recording path in RecordingController"
```

---

### Task 3: CaptureDelegate mode-based routing

**Files:**
- Modify: `MacCam/Capture/CaptureDelegate.swift`

Depends on Task 1 (`TriggerMode`) and Task 2 (`handle(audioOnly:trigger:)`). Independent of the settings swap. After this task the defaults (`.motion`, `audioOnly = false`) preserve current motion behavior; nothing sets the new state until Task 5.

- [ ] **Step 1: Replace the file body**

Replace the entire contents of `MacCam/Capture/CaptureDelegate.swift` with:

```swift
import Foundation
import AVFoundation

/// Routes capture sample buffers. The trigger source depends on `triggerMode`:
/// continuous (always), motion (vImage), voice (SoundAnalysis), or both. In
/// audio-only mode there is no video output, so audio buffers drive recording
/// directly via `handle(audioOnly:trigger:)`. `triggerMode`/`audioOnly` are set
/// from the main queue and read on the capture queues under a small lock.
final class CaptureDelegate: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    private let detector: MotionDetector
    private let recorder: RecordingController
    private let voiceDetector: VoiceDetector
    private var lastMotion = false   // read/written only on the video queue

    private let lock = NSLock()
    private var triggerMode: TriggerMode = .motion
    private var audioOnly = false

    init(detector: MotionDetector, recorder: RecordingController, voiceDetector: VoiceDetector) {
        self.detector = detector
        self.recorder = recorder
        self.voiceDetector = voiceDetector
    }

    /// Staged from the main queue on settings changes.
    func setTriggerMode(_ mode: TriggerMode) { lock.lock(); triggerMode = mode; lock.unlock() }
    func setAudioOnly(_ value: Bool) { lock.lock(); audioOnly = value; lock.unlock() }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock(); let mode = triggerMode; let audioOnly = self.audioOnly; lock.unlock()

        if output is AVCaptureAudioDataOutput {
            if mode.usesVoice { voiceDetector.analyze(sampleBuffer) }
            if audioOnly {
                let trigger = mode.isContinuous || voiceDetector.isActive()
                recorder.handle(audioOnly: sampleBuffer, trigger: trigger)
            } else {
                recorder.handle(audio: sampleBuffer)
            }
            return
        }

        // Video branch — absent in audio-only mode (no video output exists).
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let trigger: Bool
        switch mode {
        case .continuous:
            trigger = true
        case .motion:
            if let result = detector.analyze(pixelBuffer, pts: pts) { lastMotion = result.motion }
            trigger = lastMotion
        case .voice:
            trigger = voiceDetector.isActive()
        case .motionAndVoice:
            if let result = detector.analyze(pixelBuffer, pts: pts) { lastMotion = result.motion }
            trigger = lastMotion || voiceDetector.isActive()
        }
        recorder.handle(video: sampleBuffer, motion: trigger)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `make build`
Expected: SUCCESS.

- [ ] **Step 3: Run tests**

Run: `make test`
Expected: PASS (no behavior change for the default `.motion` mode in existing integration tests, which drive `handle(video:motion:)` directly rather than through the delegate).

- [ ] **Step 4: Commit**

```bash
git add MacCam/Capture/CaptureDelegate.swift
git commit -m "feat: CaptureDelegate routes trigger and audio by TriggerMode"
```

---

### Task 4: SettingsStore — add triggerMode + audioOnly

**Files:**
- Modify: `MacCam/UI/SettingsStore.swift`
- Modify: `MacCamTests/AudioRecordingTests.swift`
- Modify: `MacCamTests/RecordingControllerScheduleTests.swift`
- Modify: `MacCamTests/RecordingIntegrationTests.swift`
- Modify: `MacCamTests/RecordingControllerAudioOnlyTests.swift`

Add the new fields while **keeping** `voiceTriggerEnabled` (still read by `AppDelegate`/UI until Tasks 5/7). `effectiveAudioOnly` centralizes the guard so a stale `audioOnly` is inert.

- [ ] **Step 1: Add fields to `AppSettings`**

In `MacCam/UI/SettingsStore.swift`, in `struct AppSettings`, replace:

```swift
    var voiceTriggerEnabled: Bool
    var voiceSensitivity: Int
```

with:

```swift
    var voiceTriggerEnabled: Bool
    var triggerMode: TriggerMode
    var voiceSensitivity: Int
    var audioOnly: Bool
```

Then, immediately after the `motionThreshold` computed property inside `AppSettings`, add:

```swift
    /// Audio-only is effective only when audio is on and the trigger permits it
    /// (Continuous or Voice). A stale `audioOnly` in any other combination is
    /// inert, so the camera/recorder never silently drop video.
    var effectiveAudioOnly: Bool { audioOnly && audioEnabled && triggerMode.allowsAudioOnly }
```

- [ ] **Step 2: Add persistence keys, published properties, defaults, init reads, and snapshot**

In `enum Key`, after `static let voiceTriggerEnabled = "voiceTriggerEnabled"` add:

```swift
        static let triggerMode = "triggerMode"
        static let audioOnly = "audioOnly"
```

After the `@Published var voiceTriggerEnabled` line, add:

```swift
    @Published var triggerMode: TriggerMode { didSet { defaults.set(triggerMode.rawValue, forKey: Key.triggerMode) } }
    @Published var audioOnly: Bool { didSet { defaults.set(audioOnly, forKey: Key.audioOnly) } }
```

In the `defaults.register(defaults: [ ... ])` dictionary, after the `Key.voiceSensitivity: 2,` entry add:

```swift
            Key.triggerMode: TriggerMode.motion.rawValue,
            Key.audioOnly: false,
```

In `init`, after the `voiceTriggerEnabled = defaults.bool(forKey: Key.voiceTriggerEnabled)` line add:

```swift
        triggerMode = TriggerMode(rawValue: defaults.string(forKey: Key.triggerMode) ?? "motion") ?? .motion
        audioOnly = defaults.bool(forKey: Key.audioOnly)
```

In `snapshot()`, after `voiceTriggerEnabled: voiceTriggerEnabled,` add:

```swift
            triggerMode: triggerMode,
```

and after `voiceSensitivity: voiceSensitivity,` add:

```swift
            audioOnly: audioOnly,
```

- [ ] **Step 3: Update the test `AppSettings` literals**

In each of the four test files, the `AppSettings(...)` literal currently contains `voiceTriggerEnabled: false, voiceSensitivity: 2,`. Replace that fragment with:

```swift
voiceTriggerEnabled: false, triggerMode: .motion, voiceSensitivity: 2, audioOnly: false,
```

Apply to:
- `MacCamTests/AudioRecordingTests.swift`
- `MacCamTests/RecordingControllerScheduleTests.swift`
- `MacCamTests/RecordingIntegrationTests.swift`
- `MacCamTests/RecordingControllerAudioOnlyTests.swift`

(The `RecordingControllerAudioOnlyTests` `settings()` may instead set `triggerMode: .voice, audioOnly: true` — but those fields are not read by `RecordingController`, so `.motion`/`false` is equally valid. Use the same fragment for consistency.)

- [ ] **Step 4: Build and run tests**

Run: `make test`
Expected: PASS — everything compiles (`voiceTriggerEnabled` still present and read where it was) and all tests pass.

- [ ] **Step 5: Commit**

```bash
git add MacCam/UI/SettingsStore.swift MacCamTests/AudioRecordingTests.swift MacCamTests/RecordingControllerScheduleTests.swift MacCamTests/RecordingIntegrationTests.swift MacCamTests/RecordingControllerAudioOnlyTests.swift
git commit -m "feat: AppSettings gains triggerMode + audioOnly (effectiveAudioOnly)"
```

---

### Task 5: AppDelegate wiring

**Files:**
- Modify: `MacCam/App/AppDelegate.swift`

Push `triggerMode`/`effectiveAudioOnly` into `CaptureDelegate` and gate voice on `triggerMode.usesVoice` (stops reading `voiceTriggerEnabled`).

- [ ] **Step 1: Update `applyToDetector`**

In `MacCam/App/AppDelegate.swift`, replace the `applyToDetector(_:)` method body:

```swift
    private func applyToDetector(_ snap: AppSettings) {
        // Staged and applied on the capture queue to avoid racing analyze().
        detector.requestUpdate(pixelDelta: snap.pixelDelta, threshold: snap.motionThreshold)
        detector.requestMask(MotionMask(encoded: snap.detectionMask))
        voiceDetector.requestUpdate(
            enabled: snap.voiceTriggerEnabled && snap.audioEnabled,
            threshold: VoiceMath.confidenceThreshold(forSensitivity: snap.voiceSensitivity))
    }
```

with:

```swift
    private func applyToDetector(_ snap: AppSettings) {
        // Staged and applied on the capture queue to avoid racing analyze().
        detector.requestUpdate(pixelDelta: snap.pixelDelta, threshold: snap.motionThreshold)
        detector.requestMask(MotionMask(encoded: snap.detectionMask))
        voiceDetector.requestUpdate(
            enabled: snap.triggerMode.usesVoice && snap.audioEnabled,
            threshold: VoiceMath.confidenceThreshold(forSensitivity: snap.voiceSensitivity))
        captureDelegate.setTriggerMode(snap.triggerMode)
        captureDelegate.setAudioOnly(snap.effectiveAudioOnly)
    }
```

- [ ] **Step 2: Build and run tests**

Run: `make test`
Expected: PASS — compiles (`captureDelegate` is non-nil by the time `applyToDetector` runs; `voiceTriggerEnabled` no longer read here but still exists). All tests green.

- [ ] **Step 3: Commit**

```bash
git add MacCam/App/AppDelegate.swift
git commit -m "feat: AppDelegate pushes triggerMode/audioOnly into CaptureDelegate"
```

---

### Task 6: CameraManager audio-only session

**Files:**
- Modify: `MacCam/Capture/CameraManager.swift`

Add an audio-only branch to `reconfigure()`: no camera input, no video output, only the microphone input + audio output. Reads `settings.effectiveAudioOnly`.

- [ ] **Step 1: Add the audio-only branch**

In `MacCam/Capture/CameraManager.swift`, at the very start of `reconfigure()`, after the three `session.beginConfiguration()` / remove-inputs / remove-outputs lines, insert the audio-only branch **before** the `guard let device = pickDevice(...)` block:

```swift
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
```

(The rest of `reconfigure()` — the camera path — is unchanged.)

- [ ] **Step 2: Build to verify it compiles**

Run: `make build`
Expected: SUCCESS (`loc` is the global localization helper from `MacCam/System/Localization.swift`; `"Audio only"` string is added to the catalog in Task 9).

- [ ] **Step 3: Run tests**

Run: `make test`
Expected: PASS (no test exercises a live `AVCaptureSession`; this is a build-level change).

- [ ] **Step 4: Commit**

```bash
git add MacCam/Capture/CameraManager.swift
git commit -m "feat: CameraManager audio-only session (camera off)"
```

---

### Task 7: Recording settings UI

**Files:**
- Modify: `MacCam/UI/SettingsTabs/RecordingSettingsTab.swift`

Replace the "Trigger recording on voice" toggle with a trigger Picker; show voice sensitivity when the mode uses voice; add an audio-only toggle when the mode allows it. Stops reading `voiceTriggerEnabled`.

- [ ] **Step 1: Replace the audio sub-section**

In `MacCam/UI/SettingsTabs/RecordingSettingsTab.swift`, replace this block:

```swift
            Toggle("Record audio", isOn: Binding(
                get: { settings.audioEnabled },
                set: {
                    settings.audioEnabled = $0
                    context.onReconfigure()
                    if $0 { context.onRequestAudioAccess() }
                }))
            if settings.audioEnabled {
                Picker("Microphone", selection: Binding(
                    get: { settings.audioDeviceID ?? "" },
                    set: { settings.audioDeviceID = $0.isEmpty ? nil : $0; context.onReconfigure() })) {
                    Text("Automatic (built-in preferred)").tag("")
                    ForEach(microphones, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("Trigger recording on voice", isOn: Binding(
                    get: { settings.voiceTriggerEnabled },
                    set: { settings.voiceTriggerEnabled = $0 }))
                if settings.voiceTriggerEnabled {
                    VStack(alignment: .leading) {
                        Text("Voice sensitivity: \(settings.voiceSensitivity) (0 = strict, 4 = sensitive)")
                        Slider(value: Binding(
                            get: { Double(settings.voiceSensitivity) },
                            set: { settings.voiceSensitivity = Int($0.rounded()) }),
                               in: 0...4, step: 1)
                    }
                }
            }
```

with:

```swift
            Picker("Recording trigger", selection: Binding(
                get: { settings.triggerMode },
                set: { settings.triggerMode = $0; context.onReconfigure() })) {
                ForEach(TriggerMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            if !settings.audioEnabled && settings.triggerMode.usesVoice {
                Text("Voice trigger needs \"Record audio\" enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Record audio", isOn: Binding(
                get: { settings.audioEnabled },
                set: {
                    settings.audioEnabled = $0
                    context.onReconfigure()
                    if $0 { context.onRequestAudioAccess() }
                }))
            if settings.audioEnabled {
                Picker("Microphone", selection: Binding(
                    get: { settings.audioDeviceID ?? "" },
                    set: { settings.audioDeviceID = $0.isEmpty ? nil : $0; context.onReconfigure() })) {
                    Text("Automatic (built-in preferred)").tag("")
                    ForEach(microphones, id: \.id) { Text($0.name).tag($0.id) }
                }
                if settings.triggerMode.usesVoice {
                    VStack(alignment: .leading) {
                        Text("Voice sensitivity: \(settings.voiceSensitivity) (0 = strict, 4 = sensitive)")
                        Slider(value: Binding(
                            get: { Double(settings.voiceSensitivity) },
                            set: { settings.voiceSensitivity = Int($0.rounded()) }),
                               in: 0...4, step: 1)
                    }
                }
                if settings.triggerMode.allowsAudioOnly {
                    Toggle("Record audio only (no video)", isOn: Binding(
                        get: { settings.audioOnly },
                        set: { settings.audioOnly = $0; context.onReconfigure() }))
                }
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `make build`
Expected: SUCCESS.

- [ ] **Step 3: Run tests**

Run: `make test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add MacCam/UI/SettingsTabs/RecordingSettingsTab.swift
git commit -m "feat: Recording tab trigger picker + audio-only toggle"
```

---

### Task 8: Remove `voiceTriggerEnabled`

**Files:**
- Modify: `MacCam/UI/SettingsStore.swift`
- Modify: `MacCamTests/AudioRecordingTests.swift`
- Modify: `MacCamTests/RecordingControllerScheduleTests.swift`
- Modify: `MacCamTests/RecordingIntegrationTests.swift`
- Modify: `MacCamTests/RecordingControllerAudioOnlyTests.swift`

No code reads `voiceTriggerEnabled` anymore (Tasks 5 and 7 removed the readers). Remove it cleanly.

- [ ] **Step 1: Verify no readers remain**

Run: `grep -rn "voiceTriggerEnabled" MacCam/`
Expected: only matches in `MacCam/UI/SettingsStore.swift` (declaration/persistence/snapshot). If any other file matches, stop — a reader was missed.

- [ ] **Step 2: Remove from `SettingsStore.swift`**

Delete each of these lines in `MacCam/UI/SettingsStore.swift`:

- In `struct AppSettings`: `    var voiceTriggerEnabled: Bool`
- In `enum Key`: `        static let voiceTriggerEnabled = "voiceTriggerEnabled"`
- The `@Published var voiceTriggerEnabled: Bool { didSet { defaults.set(voiceTriggerEnabled, forKey: Key.voiceTriggerEnabled) } }` line
- In `init`: `        voiceTriggerEnabled = defaults.bool(forKey: Key.voiceTriggerEnabled)`
- In `snapshot()`: `            voiceTriggerEnabled: voiceTriggerEnabled,`

(`Key.voiceTriggerEnabled` had no `register(defaults:)` entry, so there is nothing to remove there.)

- [ ] **Step 3: Remove from the four test literals**

In each test file, change the fragment:

```swift
voiceTriggerEnabled: false, triggerMode: .motion, voiceSensitivity: 2, audioOnly: false,
```

to:

```swift
triggerMode: .motion, voiceSensitivity: 2, audioOnly: false,
```

Apply to `AudioRecordingTests.swift`, `RecordingControllerScheduleTests.swift`, `RecordingIntegrationTests.swift`, `RecordingControllerAudioOnlyTests.swift`.

- [ ] **Step 4: Build and run tests**

Run: `make test`
Expected: PASS — `voiceTriggerEnabled` fully removed, everything compiles, all tests green.

- [ ] **Step 5: Commit**

```bash
git add MacCam/UI/SettingsStore.swift MacCamTests/AudioRecordingTests.swift MacCamTests/RecordingControllerScheduleTests.swift MacCamTests/RecordingIntegrationTests.swift MacCamTests/RecordingControllerAudioOnlyTests.swift
git commit -m "refactor: remove voiceTriggerEnabled (superseded by triggerMode)"
```

---

### Task 9: Localization + CHANGELOG

**Files:**
- Modify: `MacCam/Localizable.xcstrings`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add Russian translations for the new strings**

In `MacCam/Localizable.xcstrings`, add these entries to the `"strings"` object (alongside the existing keys). Match the existing formatting (one entry per key):

```json
    "Recording trigger" : { "localizations" : { "ru" : { "stringUnit" : { "state" : "translated", "value" : "Триггер записи" } } } },
    "Continuous" : { "localizations" : { "ru" : { "stringUnit" : { "state" : "translated", "value" : "Непрерывно" } } } },
    "Voice" : { "localizations" : { "ru" : { "stringUnit" : { "state" : "translated", "value" : "Голос" } } } },
    "Motion + Voice" : { "localizations" : { "ru" : { "stringUnit" : { "state" : "translated", "value" : "Движение + голос" } } } },
    "Record audio only (no video)" : { "localizations" : { "ru" : { "stringUnit" : { "state" : "translated", "value" : "Записывать только звук (без видео)" } } } },
    "Voice trigger needs \"Record audio\" enabled." : { "localizations" : { "ru" : { "stringUnit" : { "state" : "translated", "value" : "Для триггера по голосу включите «Записывать звук»." } } } },
    "Audio only" : { "localizations" : { "ru" : { "stringUnit" : { "state" : "translated", "value" : "Только звук" } } } },
```

Note: `"Motion"` is already present in the catalog (reused for the trigger label). The old `"Trigger recording on voice"` entry is now unused — leave it (harmless) or remove it; removing it is cleaner.

- [ ] **Step 2: Add a CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Added`, add:

```markdown
- Recording trigger modes: choose Continuous (always record), Motion, Voice, or
  Motion + Voice in Settings — replacing the standalone voice toggle. Continuous
  and Voice can additionally record audio only (camera off) for a single-track
  audio clip.
```

Also remove the now-superseded "Voice-activated recording" bullet's wording if it conflicts — update it to:

```markdown
- Voice-activated recording: detect human speech on-device (SoundAnalysis) as a
  recording trigger, selectable via the trigger mode. Requires audio enabled;
  adjustable sensitivity.
```

- [ ] **Step 3: Build and run tests**

Run: `make test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add MacCam/Localizable.xcstrings CHANGELOG.md
git commit -m "docs: localize recording-mode strings + CHANGELOG"
```

---

### Task 10: Full verification + review

- [ ] **Step 1: Clean build + full test run**

Run: `make build && make test`
Expected: build SUCCESS; all tests PASS (baseline 60 + `TriggerModeTests` (5) + `RecordingControllerAudioOnlyTests` (2) = ~67).

- [ ] **Step 2: Lint**

Run: `make lint`
Expected: no violations (`swiftlint --strict`).

- [ ] **Step 3: Code review**

Use the `code-review` skill (or `superpowers:requesting-code-review`) against the branch diff (`git diff feat/voice-trigger...HEAD`). Fix Critical/Important findings; re-run `make test` after fixes.

- [ ] **Step 4: Final commit (if review fixes were made)**

```bash
git add -A
git commit -m "fix: address code review on recording modes"
```

- [ ] **Step 5: Push**

```bash
git push -u origin feat/recording-modes
```

---

## Self-Review

**1. Spec coverage:**
- D.1 setting & enum → Task 1 (`TriggerMode`), Task 4 (settings).
- D.2 trigger computation per mode → Task 3 (`CaptureDelegate` switch).
- E.1 `audioOnly` + effective guard → Task 4 (`effectiveAudioOnly`).
- E.2 audio-only capture session → Task 6 (`CameraManager`).
- E.3 audio-driven FSM + generalized `openWriter` → Task 2.
- E.4 CaptureDelegate routing → Task 3.
- E.5 AppDelegate wiring → Task 5.
- Settings UI → Task 7. Tests → Tasks 1, 2. Localization/CHANGELOG → Task 9. ✓ All covered.

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**3. Type consistency:** `TriggerMode` (`usesMotion`/`usesVoice`/`isContinuous`/`allowsAudioOnly`/`label`/`id`) consistent across Tasks 1, 3, 5, 7. `effectiveAudioOnly` defined in Task 4, read in Tasks 5/6. `setTriggerMode`/`setAudioOnly` defined in Task 3, called in Task 5. `handle(audioOnly:trigger:)` defined in Task 2, called in Task 3. `openWriter(dimensions:audio:startPTS:)` + `appendAudio` defined and used in Task 2. ✓

**Spec deviation noted:** the spec mentioned a `recordVideo: Bool` on `RecordingController`; planning showed it is unnecessary — the drive path is chosen by `CaptureDelegate` (`handle(video:)` vs `handle(audioOnly:)`) and the two are mutually exclusive because `CameraManager` produces either a video output or none. Dropping it (YAGNI) keeps the recorder simpler. `effectiveAudioOnly` remains the single derived flag.
