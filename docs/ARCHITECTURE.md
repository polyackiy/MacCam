# MacCam Architecture

MacCam is a single-process, App-Sandboxed macOS menu-bar agent. One
`AVCaptureSession` feeds both motion detection and recording, so the camera is
opened once and shared.

## Pipeline

```
AVCaptureSession                              (audio-only mode: a mic-only session)
  ├── AVCaptureDeviceInput (camera, activeFormat = max resolution)   [unless audio-only]
  ├── AVCaptureDeviceInput (microphone)                              [if audio enabled]
  ├── AVCaptureVideoDataOutput ──► CaptureDelegate ("capture.video") [unless audio-only]
  │        each video CMSampleBuffer, trigger per TriggerMode:
  │          • continuous → always; motion → MotionDetector.analyze (throttled ~12 Hz);
  │            voice → VoiceDetector.isActive(); motionAndVoice → either
  │          → RecordingController.handle(video:, motion: trigger)
  └── AVCaptureAudioDataOutput ──► CaptureDelegate ("capture.audio") [if audio]
           each audio CMSampleBuffer:
             • VoiceDetector.analyze(buffer)               (when voice is a trigger)
             • RecordingController.handle(audio:)          (normal), or
               RecordingController.handle(audioOnly:trigger:)  (audio-only mode)
```

Every video frame is forwarded to the recorder (smooth clips), while motion
analysis runs throttled on a downscaled copy; the last verdict is reused on
throttled frames. The `TriggerMode` (continuous / motion / voice / motion+voice)
selects which detectors run — continuous and voice skip motion analysis. In
**audio-only** mode the session has no camera, and audio buffers drive the FSM
directly, producing a single-track `.m4a`.

## Components

| File | Responsibility |
|------|----------------|
| `App/MacCamApp.swift` | `@main` SwiftUI app, `NSApplicationDelegateAdaptor` |
| `App/AppDelegate.swift` | Lifecycle, permissions, wiring, monitoring control, guard/schedule/manual priority, settings & zone windows |
| `Capture/CameraManager.swift` | `AVCaptureSession` config, device/mic discovery, audio-only session, live preview, start/stop, disconnect |
| `Capture/FormatSelector.swift` | **Pure:** pick max-area format meeting min FPS |
| `Capture/CaptureDelegate.swift` | Sample-buffer delegate; trigger-by-`TriggerMode`, routes video/audio (incl. audio-only) |
| `Audio/VoiceDetector.swift` | On-device `SoundAnalysis` speech detection; thread-safe "voice active" flag |
| `Motion/MotionDetector.swift` | `vImage` downscale + grayscale + abs-diff; zone mask; thread-safe live tunables |
| `Motion/MotionMath.swift` | **Pure:** sensitivity (0–4) → changed-pixel threshold |
| `Motion/MotionMask.swift` | **Pure:** 16×9 ignore-zone mask (encode/decode, query) |
| `Motion/VoiceMath.swift` | **Pure:** voice sensitivity (0–4) → speech-confidence threshold |
| `Motion/VoiceActivity.swift` | **Pure:** speech hold-window (active for N s after last detection) |
| `Motion/RingBuffer.swift` | **Pure:** pre-roll frame buffer (by PTS) |
| `Recording/RecordingController.swift` | `AVAssetWriter` glue: open/append/rotate/finish, pre-roll, audio-only path, disk-limit gate |
| `Recording/RecordingFSM.swift` | **Pure:** idle/recording transitions (time injected) |
| `Recording/TriggerMode.swift` | **Pure:** trigger enum (continuous/motion/voice/both) and its capabilities |
| `Recording/Bitrate.swift` | **Pure:** quality + resolution → bitrate |
| `Storage/FileStore.swift` | Destination folder, security-scoped bookmark, usage, cleanup, disk-limit enforcement |
| `Storage/ClipNaming.swift` | **Pure:** timestamp → `.mov`/`.m4a` filename, retention selection |
| `Storage/StorageMath.swift` | **Pure:** GB↔bytes, over-limit decision |
| `System/WeeklySchedule.swift` | **Pure:** per-weekday time window, "active at" (overnight-aware) |
| `System/Scheduler.swift` | Drives schedule-window transitions via a timer |
| `System/LockMonitor.swift` | Screen lock/unlock notifications → guard mode |
| `System/LaunchAtLogin.swift` | `SMAppService` register/unregister |
| `System/Localization.swift` | `loc()` helper over the String Catalog |
| `System/Log.swift` | `os.Logger` categories |
| `UI/MenuBarController.swift` | `NSStatusItem`, state-colored / discreet icon, command menu |
| `UI/SettingsView.swift` | Sidebar settings window (`NavigationSplitView`) over the panes below |
| `UI/SettingsTabs/*.swift` | The six panes: Camera, Detection, Recording, Schedule, Storage, General |
| `UI/SettingsContext.swift` | Dependencies/actions passed to each settings pane |
| `UI/SettingsStore.swift` | `UserDefaults`-backed `ObservableObject` + `AppSettings` snapshot |
| `UI/ScheduleEditor.swift` | Weekday + time-window editor for one `WeeklySchedule` |
| `UI/ZoneEditorView.swift` | Paint the detection mask over a live camera preview |
| `UI/CameraPreview.swift` | `NSViewRepresentable` over `AVCaptureVideoPreviewLayer` |
| `UI/AboutView.swift` | Version + project links |

## Testability strategy

Hardware/AppKit/AVFoundation glue can't be unit tested without a camera, so all
decision logic is isolated into **pure** seams (marked above) covered by XCTest:
sensitivity mapping, bitrate, format selection, ring buffer, recording FSM, clip
naming/retention, and the motion detector (run against synthetic
`CVPixelBuffer`s). `RecordingIntegrationTests` exercises the real `AVAssetWriter`
path end-to-end — feeding synthetic frames and asserting a valid, playable HEVC
`.mov` — so the riskiest glue is verified automatically without hardware.

## Threading

- Video frames: serial `capture.video` queue (analysis + recorder dispatch).
- Audio frames: serial `capture.audio` queue.
- `RecordingController` guards writer state with an `NSLock` so both queues can
  append safely.
- `MotionDetector` tunables are staged under a lock and applied on the analysis
  queue (`requestUpdate`), so live settings changes never race `analyze`.
- Capture-session (re)configuration runs on a dedicated `capture.session` queue.

## Concurrency & settings flow

`SettingsStore` (`@Published`, `UserDefaults`-backed) produces an immutable
`AppSettings` snapshot read atomically by the pipeline. `AppDelegate` observes
`objectWillChange` and applies detector/recorder-affecting changes live (motion
and voice thresholds, trigger mode, disk limits, schedules) without rebuilding
the session; camera/FPS/audio/audio-only changes go through a heavier reconfigure
that finalizes any open clip first. `Scheduler` and `LockMonitor` feed the same
monitoring evaluator, where a manual Start/Stop overrides guard mode and the
weekly schedule.

## Privacy / offline guarantee

No network entitlements, no network code, no telemetry. Recordings are written
only to the user-selected local folder (default `~/Movies/MacCam/`). See the
spec under `docs/superpowers/specs/` for the original design.
