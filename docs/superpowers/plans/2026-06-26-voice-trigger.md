# Voice Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add human-voice as an additional recording trigger (record on motion OR voice) using on-device SoundAnalysis.

**Architecture:** A pure sensitivity→threshold map (`VoiceMath`) and a pure hold-window (`VoiceActivity`) back a `VoiceDetector` that runs `SNAudioStreamAnalyzer` over the mic stream and flags "voice active". `CaptureDelegate` ORs that flag with motion. Requires audio enabled.

**Tech Stack:** Swift 5, AVFoundation, SoundAnalysis (`SNClassifySoundRequest`, `.version1`), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-26-voice-trigger-design.md`

**Build/test:** `xcodebuild -project MacCam.xcodeproj -scheme MacCam -configuration Debug -derivedDataPath build -destination 'platform=macOS' test` · Lint: `swiftlint --strict`

**TDD note:** `VoiceMath` and `VoiceActivity` are strict test-first. `VoiceDetector` (SoundAnalysis), `CaptureDelegate`, and `AppDelegate`/UI are glue verified by build + a manual run.

---

## File Structure

```
MacCam/
├── Motion/VoiceMath.swift          # NEW pure: sensitivity → confidence threshold
├── Motion/VoiceActivity.swift      # NEW pure: hold-window activity
├── Audio/VoiceDetector.swift       # NEW: SNAudioStreamAnalyzer glue
├── Capture/CaptureDelegate.swift   # EDIT: feed voice + OR trigger
├── App/AppDelegate.swift           # EDIT: own VoiceDetector, wire updates/reset
├── UI/SettingsStore.swift          # EDIT: voiceTriggerEnabled, voiceSensitivity
├── UI/SettingsTabs/RecordingSettingsTab.swift  # EDIT: voice toggle + slider
├── Localizable.xcstrings           # EDIT
MacCamTests/
├── VoiceMathTests.swift            # NEW
└── VoiceActivityTests.swift        # NEW
```

---

## Task 1: VoiceMath (pure) — TDD

**Files:** Create `MacCam/Motion/VoiceMath.swift`, `MacCamTests/VoiceMathTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MacCam

final class VoiceMathTests: XCTestCase {
    func testEndpoints() {
        XCTAssertEqual(VoiceMath.confidenceThreshold(forSensitivity: 0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(VoiceMath.confidenceThreshold(forSensitivity: 4), 0.35, accuracy: 1e-9)
    }
    func testMonotonicDecreasing() {
        let t = (0...4).map { VoiceMath.confidenceThreshold(forSensitivity: $0) }
        for i in 1..<t.count { XCTAssertLessThan(t[i], t[i - 1]) }
    }
    func testClampsOutOfRange() {
        XCTAssertEqual(VoiceMath.confidenceThreshold(forSensitivity: -3), 0.9, accuracy: 1e-9)
        XCTAssertEqual(VoiceMath.confidenceThreshold(forSensitivity: 99), 0.35, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement**

```swift
import Foundation

/// Maps the 0...4 voice sensitivity dial to the confidence required from the
/// speech classifier. Higher sensitivity ⇒ lower threshold (triggers more
/// easily). Linear between 0.9 (s=0) and 0.35 (s=4).
enum VoiceMath {
    static let highConfidence = 0.9
    static let lowConfidence = 0.35

    static func confidenceThreshold(forSensitivity s: Int) -> Double {
        let c = Double(min(4, max(0, s)))
        return highConfidence + (lowConfidence - highConfidence) * (c / 4.0)
    }
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat: VoiceMath sensitivity→threshold`.

---

## Task 2: VoiceActivity (pure) — TDD

**Files:** Create `MacCam/Motion/VoiceActivity.swift`, `MacCamTests/VoiceActivityTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MacCam

final class VoiceActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testInactiveBeforeAnySpeech() {
        let a = VoiceActivity()
        XCTAssertFalse(a.isActive(at: t0, hold: 2))
    }
    func testActiveWithinHold() {
        var a = VoiceActivity()
        a.noteSpeech(at: t0)
        XCTAssertTrue(a.isActive(at: t0.addingTimeInterval(1.5), hold: 2))
    }
    func testInactivePastHold() {
        var a = VoiceActivity()
        a.noteSpeech(at: t0)
        XCTAssertFalse(a.isActive(at: t0.addingTimeInterval(2.0), hold: 2))  // hold is exclusive
    }
    func testRefreshExtendsWindow() {
        var a = VoiceActivity()
        a.noteSpeech(at: t0)
        a.noteSpeech(at: t0.addingTimeInterval(1.5))
        XCTAssertTrue(a.isActive(at: t0.addingTimeInterval(3.0), hold: 2))   // 3.0 - 1.5 = 1.5 < 2
    }
    func testReset() {
        var a = VoiceActivity()
        a.noteSpeech(at: t0)
        a.reset()
        XCTAssertFalse(a.isActive(at: t0, hold: 2))
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement**

```swift
import Foundation

/// Keeps "voice active" true for `hold` seconds after the last detected speech,
/// smoothing the gaps between the analyzer's ~1 s windows.
struct VoiceActivity {
    private(set) var lastSpeech: Date?

    mutating func noteSpeech(at date: Date) { lastSpeech = date }
    mutating func reset() { lastSpeech = nil }

    func isActive(at date: Date, hold: TimeInterval) -> Bool {
        guard let lastSpeech else { return false }
        return date.timeIntervalSince(lastSpeech) < hold
    }
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat: VoiceActivity hold window`.

---

## Task 3: VoiceDetector (SoundAnalysis glue)

**Files:** Create `MacCam/Audio/VoiceDetector.swift` (build-verified).

- [ ] **Step 1: Implement**

```swift
import Foundation
import AVFoundation
import SoundAnalysis

/// Detects human speech in the mic stream with on-device SoundAnalysis and
/// exposes a thread-safe "voice active" flag. Fed audio buffers on the capture
/// audio queue; the SoundAnalysis observer updates activity under a lock.
final class VoiceDetector: NSObject, SNResultsObserving {
    var holdSeconds: TimeInterval = 2.0

    private let lock = NSLock()
    private var enabled = false
    private var threshold = 0.6
    private var activity = VoiceActivity()

    private var analyzer: SNAudioStreamAnalyzer?
    private var framePosition: AVAudioFramePosition = 0

    /// Thread-safe staging (called from the main queue on settings changes).
    func requestUpdate(enabled: Bool, threshold: Double) {
        lock.lock()
        self.enabled = enabled
        self.threshold = threshold
        lock.unlock()
    }

    func isActive(at date: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activity.isActive(at: date, hold: holdSeconds)
    }

    func reset() {
        lock.lock()
        activity.reset()
        analyzer = nil
        framePosition = 0
        lock.unlock()
    }

    /// Called on the capture audio queue for each audio sample buffer.
    func analyze(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); let on = enabled; lock.unlock()
        guard on, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        lock.lock()
        if analyzer == nil { setupAnalyzerLocked(format: pcm.format) }
        let analyzer = self.analyzer
        let position = framePosition
        framePosition += AVAudioFramePosition(pcm.frameLength)
        lock.unlock()

        // Not under the lock: the observer may be invoked synchronously here and
        // it also takes the lock.
        analyzer?.analyze(pcm, atAudioFramePosition: position)
    }

    private func setupAnalyzerLocked(format: AVAudioFormat) {
        let analyzer = SNAudioStreamAnalyzer(format: format)
        if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            try? analyzer.add(request, withObserver: self)
        }
        self.analyzer = analyzer
    }

    // MARK: SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let speech = result.classification(forIdentifier: "speech") else { return }
        lock.lock()
        if Double(speech.confidence) >= threshold { activity.noteSpeech(at: Date()) }
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {}
    func requestDidComplete(_ request: SNRequest) {}

    // MARK: Buffer conversion

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
```

- [ ] **Step 2: Build** → `BUILD SUCCEEDED`.
- [ ] **Step 3: Commit** `feat: VoiceDetector SoundAnalysis speech detection`.

---

## Task 4: Settings fields + CaptureDelegate + AppDelegate wiring

**Files:** Modify `UI/SettingsStore.swift`, `Capture/CaptureDelegate.swift`, `App/AppDelegate.swift`, and the three test `AppSettings` literals.

- [ ] **Step 1:** In `SettingsStore.swift` add to `AppSettings` (after `audioDeviceID`):
  `var voiceTriggerEnabled: Bool` and `var voiceSensitivity: Int`. Add `Key`s
  `voiceTriggerEnabled = "voiceTriggerEnabled"`, `voiceSensitivity = "voiceSensitivity"`.
  Add `@Published` properties:

```swift
@Published var voiceTriggerEnabled: Bool { didSet { defaults.set(voiceTriggerEnabled, forKey: Key.voiceTriggerEnabled) } }
@Published var voiceSensitivity: Int { didSet { defaults.set(voiceSensitivity, forKey: Key.voiceSensitivity) } }
```

  Register default `Key.voiceSensitivity: 2`, read in init
  (`voiceTriggerEnabled = defaults.bool(forKey: Key.voiceTriggerEnabled)`,
  `voiceSensitivity = defaults.integer(forKey: Key.voiceSensitivity)`), and add
  both to `snapshot()`.

- [ ] **Step 2:** In `CaptureDelegate.swift` add the detector and use it:

```swift
// add stored property + init param:
private let voiceDetector: VoiceDetector
init(detector: MotionDetector, recorder: RecordingController, voiceDetector: VoiceDetector) {
    self.detector = detector
    self.recorder = recorder
    self.voiceDetector = voiceDetector
}
```
In `captureOutput`, the audio branch becomes:
```swift
if output is AVCaptureAudioDataOutput {
    recorder.handle(audio: sampleBuffer)
    voiceDetector.analyze(sampleBuffer)
    return
}
```
And the video forward becomes:
```swift
let trigger = lastMotion || voiceDetector.isActive()
recorder.handle(video: sampleBuffer, motion: trigger)
```
(keep the existing `if let result = detector.analyze(...) { lastMotion = result.motion }` line above it).

- [ ] **Step 3:** In `AppDelegate.swift` add `private let voiceDetector = VoiceDetector()`,
  construct the delegate with it
  (`captureDelegate = CaptureDelegate(detector: detector, recorder: recorder, voiceDetector: voiceDetector)`),
  push settings in `applyToDetector(_:)`:

```swift
voiceDetector.requestUpdate(
    enabled: snap.voiceTriggerEnabled && snap.audioEnabled,
    threshold: VoiceMath.confidenceThreshold(forSensitivity: snap.voiceSensitivity))
```
  and reset on stop — add `voiceDetector.reset()` inside `stopMonitoring()`.

- [ ] **Step 4:** Add `voiceTriggerEnabled: false, voiceSensitivity: 2` to the
  `AppSettings(...)` literals in `MacCamTests/RecordingIntegrationTests.swift`,
  `MacCamTests/AudioRecordingTests.swift`, and
  `MacCamTests/RecordingControllerScheduleTests.swift` (right after
  `audioDeviceID: nil,`).
- [ ] **Step 5: Build + test** → `BUILD SUCCEEDED`, all prior tests pass.
- [ ] **Step 6: Commit** `feat: wire voice trigger into capture pipeline`.

---

## Task 5: Recording-tab UI

**Files:** Modify `UI/SettingsTabs/RecordingSettingsTab.swift` (glue; run-verified).

- [ ] **Step 1:** Inside the `if settings.audioEnabled { ... }` block, after the
  Microphone `Picker`, add the voice controls:

```swift
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
```
(No explicit reconfigure call needed: changing these `@Published` values flows
through `objectWillChange` → `applyLiveSettings` → `applyToDetector`, which calls
`voiceDetector.requestUpdate`.)

- [ ] **Step 2: Build + test** → `BUILD SUCCEEDED`, all tests pass.
- [ ] **Step 3: Manual run** — enable Record audio + "Trigger recording on voice",
  Start Monitoring, cover the camera (no motion) and speak → a clip starts; go
  silent → it stops after cooldown.
- [ ] **Step 4: Commit** `feat: voice trigger settings UI`.

---

## Task 6: Localization + CHANGELOG + final verification

**Files:** Modify `MacCam/Localizable.xcstrings`, `CHANGELOG.md`.

- [ ] **Step 1:** Add EN→RU entries: `"Trigger recording on voice"`→"Запускать запись по голосу". (The `"Voice sensitivity: %lld (0 = strict, 4 = sensitive)"` interpolated label may stay English, matching the motion sensitivity label.) Use the existing entry format.
- [ ] **Step 2:** `CHANGELOG.md` Unreleased → Added: "Voice-activated recording:
  start a clip when human speech is detected (on-device SoundAnalysis), as an
  additional trigger alongside motion. Requires audio recording enabled."
- [ ] **Step 3: Lint** `swiftlint --strict` → 0 violations.
- [ ] **Step 4: Full test** `make test` → all tests pass (prior + VoiceMath +
  VoiceActivity).
- [ ] **Step 5: Commit** `feat: localize voice trigger, changelog`.

---

## Self-Review

**Spec coverage:**
- C.2 VoiceMath → Task 1; VoiceActivity → Task 2. C.3 VoiceDetector → Task 3.
  C.4 pipeline (CaptureDelegate OR-trigger + AppDelegate wiring + reset) → Task 4.
  C.5 settings + UI → Tasks 4 (fields) + 5 (UI). C.6 concurrency → Task 3
  (lock discipline). C.7 tests → Tasks 1 + 2. Cross-cutting → Task 6. All covered.

**Placeholder scan:** No TBD/TODO; pure tasks have full test+impl; glue tasks have
concrete code + build/manual verification. The `analyze`-without-lock-around-
`analyzer.analyze()` comment explains the deadlock-avoidance (observer re-enters
the lock), not a gap.

**Type consistency:** `VoiceMath.confidenceThreshold(forSensitivity:)` Task 1 used
Tasks 4. `VoiceActivity` (`noteSpeech`/`isActive`/`reset`/`lastSpeech`) Task 2 used
Task 3. `VoiceDetector` (`requestUpdate`/`isActive`/`reset`/`analyze`) Task 3 used
Task 4. `voiceTriggerEnabled`/`voiceSensitivity` Task 4 used Tasks 4/5. Consistent.
