# MacCam — Voice-activated recording (Feature C). Design / spec

**Date:** 2026-06-26
**Status:** approved for implementation
**Branch base:** `feat/settings-redesign-scheduling` (needs the tabbed Recording tab)

Add **voice** as an additional recording trigger alongside motion: record when
**motion OR voice** is present. Voice is detected on-device with Apple
SoundAnalysis (`SNClassifySoundRequest`, built-in `speech` label). Fully offline,
no network, no word recognition — only "speech present". Requires "Record audio"
(the microphone must already be in the capture session).

## C.1 Goal & scope

- A toggle "Trigger recording on voice" plus a 0–4 sensitivity, both in the
  Recording tab, shown only when audio is enabled.
- When enabled (and audio on), human speech in the mic stream starts/continues a
  clip exactly like motion does; the recording FSM's cooldown handles the tail.
- Out of scope: word/keyword recognition, speaker ID, transcription.

## C.2 Pure seams

```swift
enum VoiceMath {
    static let highConfidence = 0.9   // sensitivity 0 (needs confident speech)
    static let lowConfidence = 0.35   // sensitivity 4 (easily triggered)
    /// 0...4 → confidence threshold; higher sensitivity ⇒ lower threshold.
    static func confidenceThreshold(forSensitivity s: Int) -> Double
}

/// Holds "voice active" for a short window after the last speech detection, so
/// the verdict doesn't flicker between the analyzer's ~1 s windows.
struct VoiceActivity {
    private(set) var lastSpeech: Date?
    mutating func noteSpeech(at date: Date)
    func isActive(at date: Date, hold: TimeInterval) -> Bool   // false if never noted
    mutating func reset()
}
```

`confidenceThreshold` interpolates linearly from `highConfidence` (s=0) to
`lowConfidence` (s=4), clamped to 0...4. `VoiceActivity.isActive` returns
`lastSpeech != nil && date - lastSpeech < hold`.

## C.3 VoiceDetector (glue)

`Audio/VoiceDetector.swift` wraps `SNAudioStreamAnalyzer` + `SNClassifySoundRequest`.

```swift
final class VoiceDetector: NSObject, SNResultsObserving {
    var holdSeconds: TimeInterval = 2.0
    func configure(format: AVAudioFormat)          // once, from the first audio buffer
    func requestUpdate(enabled: Bool, threshold: Double)   // thread-safe staging
    func analyze(_ sampleBuffer: CMSampleBuffer)   // called on the audio queue
    func isActive(at date: Date = Date()) -> Bool  // thread-safe read
    func reset()
}
```

- `analyze` (audio queue): if disabled, no-op. Converts the audio `CMSampleBuffer`
  to an `AVAudioPCMBuffer` and calls `streamAnalyzer.analyze(_:atAudioFramePosition:)`.
  On the first buffer it lazily `configure`s the analyzer with the buffer's
  `AVAudioFormat` and adds the classify request.
- `SNResultsObserving.request(_:didProduce:)` (analyzer's queue): for a
  classification result, if the `speech` label's confidence ≥ the staged
  threshold, `noteSpeech(now)` on the lock-guarded `VoiceActivity`.
- `isActive(at:)` reads `VoiceActivity.isActive(at:hold: holdSeconds)` under the
  lock. The enabled flag and threshold are staged under the lock (like
  `MotionDetector.requestUpdate`), applied in `analyze`/the observer.
- `reset()` clears activity and the analyzer (called when monitoring stops or the
  setting toggles off).

No new entitlement: SoundAnalysis is on-device and consumes the existing mic
stream.

## C.4 Pipeline integration

- `CaptureDelegate` gains a `voiceDetector` and forwards each **audio** buffer to
  both `recorder.handle(audio:)` and `voiceDetector.analyze(_:)`. For each
  **video** frame it passes `motion || voiceDetector.isActive()` as the trigger
  to `recorder.handle(video:motion:)`. (The audio buffer continues to be written
  to the clip unchanged — voice only influences the trigger.)
- `AppDelegate` owns the `VoiceDetector`, constructs `CaptureDelegate` with it,
  and in `applyToDetector`/`applyLiveSettings` calls
  `voiceDetector.requestUpdate(enabled: snap.voiceTriggerEnabled && snap.audioEnabled, threshold: VoiceMath.confidenceThreshold(forSensitivity: snap.voiceSensitivity))`.
  On monitoring stop, `voiceDetector.reset()`.
- The voice trigger only operates when audio is enabled (mic present). When audio
  is off, `requestUpdate` is called with `enabled: false`, so the detector is
  inert and no audio buffers flow anyway.

## C.5 Settings & UI

- `SettingsStore`/`AppSettings`: `voiceTriggerEnabled: Bool` (default false),
  `voiceSensitivity: Int` (default 2). Persisted in UserDefaults.
- `RecordingSettingsTab` (shown when `audioEnabled`, beneath the microphone
  picker): `Toggle("Trigger recording on voice")` and, when enabled, a 0–4
  `Slider` labelled "Voice sensitivity". Editing applies live via the existing
  `objectWillChange` → `applyLiveSettings` path.

## C.6 Concurrency

- `analyze` runs on the `capture.audio` queue; the SoundAnalysis observer fires
  on the analyzer's queue. Both touch `VoiceActivity` and the staged
  `enabled`/`threshold` only under the detector's `NSLock`.
- `CaptureDelegate` reads `isActive()` on the `capture.video` queue (lock-guarded).
- No shared state is read off-lock; consistent with `MotionDetector`.

## C.7 Tests

- `VoiceMathTests`: endpoints (s=0 → 0.9, s=4 → 0.35), monotonic decreasing,
  clamps out-of-range.
- `VoiceActivityTests`: inactive before any speech; active within hold after
  `noteSpeech`; inactive past hold; refresh extends the window; `reset` clears.
- SoundAnalysis glue (`VoiceDetector`) is verified by build + a manual run
  (speak with motion absent → a clip starts; silence → cooldown stops it).

## Cross-cutting

- **New files:** `Audio/VoiceDetector.swift`, `Motion/VoiceMath.swift`,
  `Motion/VoiceActivity.swift`, `MacCamTests/VoiceMathTests.swift`,
  `MacCamTests/VoiceActivityTests.swift`.
- **Edited:** `Capture/CaptureDelegate.swift`, `App/AppDelegate.swift`,
  `UI/SettingsStore.swift`, `UI/SettingsTabs/RecordingSettingsTab.swift`,
  `Localizable.xcstrings`, `CHANGELOG.md`.
- **Offline:** no network; on-device classification.
- **Defaults preserve current behavior:** voice trigger off.

## Implementation order

1. `VoiceMath` + `VoiceActivity` (+tests).
2. `VoiceDetector` (SoundAnalysis glue).
3. Settings fields → `CaptureDelegate` wiring → `AppDelegate` wiring.
4. Recording-tab UI, localization, CHANGELOG, build/test/lint, review.
