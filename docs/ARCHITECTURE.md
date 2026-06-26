# MacCam Architecture

MacCam is a single-process, App-Sandboxed macOS menu-bar agent. One
`AVCaptureSession` feeds both motion detection and recording, so the camera is
opened once and shared.

## Pipeline

```
AVCaptureSession
  ├── AVCaptureDeviceInput (camera, activeFormat = max resolution)
  ├── AVCaptureDeviceInput (microphone)            [if audio enabled]
  ├── AVCaptureVideoDataOutput ──► CaptureDelegate (queue "capture.video")
  │        each video CMSampleBuffer:
  │          1) MotionDetector.analyze(buffer)   → motion: Bool  (throttled ~12 Hz)
  │          2) RecordingController.handle(video:, motion:)
  └── AVCaptureAudioDataOutput ──► CaptureDelegate (queue "capture.audio")  [optional]
           each audio CMSampleBuffer → RecordingController.handle(audio:)
```

Every video frame is forwarded to the recorder (smooth clips), while motion
analysis runs throttled on a downscaled copy. The last verdict is reused on
throttled frames.

## Components

| File | Responsibility |
|------|----------------|
| `App/MacCamApp.swift` | `@main` SwiftUI app, `NSApplicationDelegateAdaptor` |
| `App/AppDelegate.swift` | Lifecycle, permissions, wiring, monitoring control, guard/manual priority, settings window |
| `Capture/CameraManager.swift` | `AVCaptureSession` config, device discovery, start/stop, disconnect handling |
| `Capture/FormatSelector.swift` | **Pure:** pick max-area format meeting min FPS |
| `Capture/CaptureDelegate.swift` | Sample-buffer delegate; routes video/audio |
| `Motion/MotionDetector.swift` | `vImage` downscale + grayscale + abs-diff; thread-safe live tunables |
| `Motion/MotionMath.swift` | **Pure:** sensitivity (0–4) → changed-pixel threshold |
| `Motion/RingBuffer.swift` | **Pure:** pre-roll frame buffer (by PTS) |
| `Recording/RecordingController.swift` | `AVAssetWriter` glue: open/append/rotate/finish, pre-roll flush |
| `Recording/RecordingFSM.swift` | **Pure:** idle/recording transitions (time injected) |
| `Recording/Bitrate.swift` | **Pure:** quality + resolution → bitrate |
| `Storage/FileStore.swift` | Destination folder, security-scoped bookmark, cleanup |
| `Storage/ClipNaming.swift` | **Pure:** timestamp → filename, retention selection |
| `System/LockMonitor.swift` | Screen lock/unlock notifications → guard mode |
| `System/LaunchAtLogin.swift` | `SMAppService` register/unregister |
| `UI/MenuBarController.swift` | `NSStatusItem`, state-colored / discreet icon, menu |
| `UI/SettingsView.swift` | SwiftUI settings form |
| `UI/SettingsStore.swift` | `UserDefaults`-backed `ObservableObject` + `AppSettings` snapshot |

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
`objectWillChange` and applies detector/recorder-affecting changes live without
rebuilding the session; camera/FPS/audio changes go through a heavier
reconfigure.

## Privacy / offline guarantee

No network entitlements, no network code, no telemetry. Recordings are written
only to the user-selected local folder (default `~/Movies/MacCam/`). See the
spec under `docs/superpowers/specs/` for the original design.
