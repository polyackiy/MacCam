# MacCam — Recording modes (trigger + content). Design / spec

**Date:** 2026-06-26
**Status:** approved for implementation
**Branch base:** `feat/voice-trigger` (needs the voice trigger / VoiceDetector)

Two axes of "how/what to record":
- **D — Trigger mode:** what starts a clip — Continuous / Motion / Voice /
  Motion+Voice (a picker, replacing the standalone voice toggle).
- **E — Audio-only:** record only audio (no video track), with the camera off,
  available when the trigger is Continuous or Voice (motion needs video).

Fully offline. Defaults preserve current behavior (Motion trigger, video+audio).

---

## D — Trigger mode

### D.1 Setting & pure seam

Replace `voiceTriggerEnabled: Bool` with:

```swift
enum TriggerMode: String, CaseIterable, Identifiable {
    case continuous, motion, voice, motionAndVoice
    var id: String { rawValue }
    var usesMotion: Bool { self == .motion || self == .motionAndVoice }
    var usesVoice: Bool { self == .voice || self == .motionAndVoice }
    var isContinuous: Bool { self == .continuous }
    var allowsAudioOnly: Bool { self == .continuous || self == .voice }
    var label: String   // "Continuous" / "Motion" / "Voice" / "Motion + Voice"
}
```

`voiceSensitivity` stays. Default `triggerMode = .motion`. The old
`voiceTriggerEnabled` key is dropped (no migration; users re-pick if needed).

### D.2 Trigger computation (video path)

`CaptureDelegate` holds a lock-guarded `triggerMode`, set by `AppDelegate`
(`setTriggerMode(_:)`, like the other staged settings). In the **video** branch:

- `continuous` → trigger `true` (skip motion analysis).
- `motion` → run `detector.analyze`; trigger = `lastMotion`.
- `voice` → trigger = `voiceDetector.isActive()` (skip motion analysis).
- `motionAndVoice` → run motion; trigger = `lastMotion || voiceDetector.isActive()`.

Motion analysis (`detector.analyze`) runs only when `mode.usesMotion` — a CPU
saving in continuous/voice modes. `AppDelegate.applyToDetector` sets
`voiceDetector.requestUpdate(enabled: mode.usesVoice && audioEnabled, …)` so voice
analysis runs only when needed.

The detector throttle/state is unaffected; only the trigger source changes.

---

## E — Audio-only recording

### E.1 Setting

`audioOnly: Bool` (default false). Effective only when `audioEnabled` AND
`triggerMode.allowsAudioOnly` (Continuous or Voice). The UI shows the toggle only
in that case; the capture/recorder code also guards on it so a stale value is
inert.

### E.2 Capture session

`CameraManager.reconfigure` gains an audio-only branch:
- **Normal** (`!audioOnly`): camera input + `AVCaptureVideoDataOutput` (+ mic +
  `AVCaptureAudioDataOutput` if audio). Existing behavior.
- **Audio-only** (`audioOnly && audioEnabled`): **no camera input, no video
  output** (camera off → CPU/battery saving). Add the mic input + audio output
  only. `formatDescription` is set to "Audio only".

`AppSettings` carries `audioOnly`; `CameraManager` reads it from its snapshot.

### E.3 Recording path (FSM driven by audio)

`RecordingController` gains `recordVideo: Bool` (from the snapshot;
`recordVideo == !audioOnly`). Two drive paths share the FSM, schedule gate, and
rotation logic:

- **Video path** — `handle(video:motion:)` (existing). Drives the FSM and writes
  video (+ audio appended via `handle(audio:)`).
- **Audio-only path** — a new `handle(audioOnly:trigger:)` that, when
  `!recordVideo`, drives the FSM with `trigger` and the **audio** PTS as `now`,
  opens an **audio-only** writer on `.startClip`/`.rotate`, and appends the audio
  buffer. The recording-schedule gate (`trigger && allowed`) AND the disk-storage
  gate (`storageAllowsNewClip()` before opening) apply exactly as in the video
  path — the audio-only path reuses the same FSM/gates, only the writer shape and
  the drive source differ.

`openWriter` is generalized to optionally include the video and/or audio inputs:

```swift
// dimensions != nil ⇒ add a video input; audio == true ⇒ add an AAC audio input.
private func openWriter(dimensions: (Int, Int)?, audio: Bool, startPTS: CMTime)
```
- Video mode: `dimensions = clip W×H`, `audio = settings.audioEnabled`.
- Audio-only mode: `dimensions = nil`, `audio = true`, `startPTS` = first audio PTS.

`appendVideo` no-ops when there is no video input. Pre-roll applies only to the
video path. Container stays `.mov` (a single audio track is valid and plays).

### E.4 CaptureDelegate routing

```
audio branch:
  voiceDetector.analyze(buffer)                       // if voice used
  if audioOnly:
      let trigger = mode.isContinuous || voiceDetector.isActive()
      recorder.handle(audioOnly: buffer, trigger: trigger)
  else:
      recorder.handle(audio: buffer)                  // append into the video-driven clip
video branch (only present when !audioOnly):
      ... trigger per mode ... recorder.handle(video: buffer, motion: trigger)
```

`CaptureDelegate` holds lock-guarded `triggerMode` and `audioOnly`, both set by
`AppDelegate`.

### E.5 AppDelegate wiring

- `applyToDetector`/`applyLiveSettings` push `triggerMode` and `audioOnly` to
  `CaptureDelegate`, set `voiceDetector` enabled per `mode.usesVoice && audioEnabled`,
  and `recorder.updateSettings(snap)` carries `recordVideo`.
- Switching `audioOnly` or `triggerMode` while monitoring goes through
  `reconfigureIfMonitoring` (it changes the session) so the camera is added/removed.
- `voiceDetector.reset()` on stop (already wired).

---

## Settings UI (Recording tab)

In `RecordingSettingsTab`:
- `Picker("Recording trigger", selection: triggerMode)` with the four modes.
- When `mode.usesVoice` and `audioEnabled`: the existing voice-sensitivity slider.
- When `mode.allowsAudioOnly` and `audioEnabled`:
  `Toggle("Record audio only (no video)", isOn: audioOnly)`.
- The "Record audio" toggle + mic picker stay; voice sensitivity moves under the
  trigger picker. Changing trigger/audioOnly calls `onReconfigure` (session change).

---

## Tests

- `TriggerModeTests` (pure): `usesMotion`/`usesVoice`/`isContinuous`/`allowsAudioOnly`
  for all four cases.
- `RecordingControllerAudioOnlyTests`: feed synthetic audio buffers with
  `trigger: true` to `handle(audioOnly:trigger:)` → a clip is produced with **one
  audio track and no video track**; with `trigger: false` → no clip. (Mirrors the
  existing `AudioRecordingTests` harness using synthetic LPCM buffers.)
- Existing 60 tests stay green; their `AppSettings` literals gain `triggerMode`,
  `audioOnly`, `recordVideo` (and lose `voiceTriggerEnabled`).

## Cross-cutting

- **Edited:** `UI/SettingsStore.swift` (TriggerMode, audioOnly; drop
  voiceTriggerEnabled), `Capture/CaptureDelegate.swift`, `Capture/CameraManager.swift`,
  `Recording/RecordingController.swift`, `App/AppDelegate.swift`,
  `UI/SettingsTabs/RecordingSettingsTab.swift`, `Localizable.xcstrings`,
  `CHANGELOG.md`. **New:** `Recording/TriggerMode.swift` (or in SettingsStore),
  `MacCamTests/TriggerModeTests.swift`, `MacCamTests/RecordingControllerAudioOnlyTests.swift`.
- **Concurrency:** `CaptureDelegate` mode/audioOnly under a small lock (read on the
  capture queues, set on main) — consistent with the detector pattern.
- **Offline:** unchanged. **Defaults:** `.motion`, video+audio (current behavior).

## Implementation order

1. `TriggerMode` (+tests) → `SettingsStore` (triggerMode, audioOnly; drop
   voiceTriggerEnabled; fix call sites).
2. D: `CaptureDelegate` trigger-by-mode + `AppDelegate` wiring + UI picker.
3. E: `RecordingController` `recordVideo` + generalized `openWriter` +
   `handle(audioOnly:trigger:)` (+tests) → `CameraManager` audio-only session →
   `CaptureDelegate` audio-only routing → UI audio-only toggle.
4. Localization, CHANGELOG, build/test/lint, review.
