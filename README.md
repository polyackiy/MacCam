<div align="center">

<img src="docs/images/icon.png" width="128" alt="MacCam icon" />

# MacCam

**Turn your Mac into a private, offline motion-detecting security camera.**

[![CI](https://github.com/polyackiy/MacCam/actions/workflows/ci.yml/badge.svg)](https://github.com/polyackiy/MacCam/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)

</div>

MacCam lives in your menu bar, watches the camera for motion, and records clips
to a local folder when something moves. It runs **fully offline** — no cloud, no
account, no network code at all — as a lightweight background agent that leans on
the Mac's hardware HEVC encoder to stay easy on CPU and battery.

A free, local-only alternative to subscription surveillance apps.

## Features

- 🎥 **Maximum resolution, automatically** — probes the device and picks the
  largest available format, so the built-in FaceTime camera records at 1080p and
  external USB / Continuity cameras up to 4K with no configuration.
- 🏃 **Fast motion detection** — downscaled `vImage` frame differencing, throttled
  to ~12 Hz; a few percent CPU at idle.
- 🔴 **Motion-triggered recording** — HEVC (or H.264) via the hardware encoder,
  cooldown after motion, seamless clip rotation, optional pre-roll.
- 🔒 **Private by design** — no network entitlements, no uploads, no telemetry.
  Clips stay in a folder you choose (local disk, external drive, or NAS).
- 🛡️ **Guard mode** — start automatically when the screen locks, stop on unlock.
- 🫥 **Discreet mode** — a neutral menu-bar icon that looks identical whether
  idle, monitoring, or recording, so onlookers can't tell the camera is active.
- 🚀 **Launch at login**, configurable sensitivity, clip lengths, FPS, quality,
  auto-cleanup of old clips, and optional audio.

> **Note on privacy indicators:** while the camera is active, macOS shows its own
> green "camera in use" indicator and the hardware LED lights up. This is a system
> anti-spyware feature that no app can disable — MacCam's own icon can be discreet,
> but the OS will still signal that the camera is on.

## Requirements

- macOS 13.0 (Ventura) or newer
- Apple Silicon or Intel Mac with a camera
- Xcode 15+ (to build from source)

## Install (build from source)

MacCam is distributed as source. Build and install with:

```sh
git clone https://github.com/polyackiy/MacCam.git
cd MacCam
make install        # builds Release and copies MacCam.app to /Applications
```

Or open `MacCam.xcodeproj` in Xcode and run (⌘R).

Because the app is ad-hoc signed (not notarized with an Apple Developer ID),
the first launch may show a Gatekeeper prompt. If macOS blocks it, right-click
the app → **Open**, or run `xattr -dr com.apple.quarantine /Applications/MacCam.app`.

On first launch, grant **camera** (and **microphone**, if you enable audio)
access when prompted.

## Usage

1. Click the MacCam menu-bar icon → **Start Monitoring**.
2. Motion in frame starts a clip; it stops after the configured cooldown.
3. Clips are saved to `~/Movies/MacCam/` by default (configurable).
4. **Settings…** lets you tune camera, sensitivity, clip length, cooldown,
   pre-roll, audio, FPS, codec/quality, destination folder, auto-cleanup,
   guard mode, launch-at-login, and the menu-bar icon style.
5. **Open Clips Folder…** reveals your recordings.

## Build & test

```sh
make build     # xcodebuild Release
make test      # run the unit + integration test suite
make lint      # SwiftLint (if installed)
```

## Architecture

A single `AVCaptureSession` feeds a delegate that runs motion detection and a
recording state machine driving `AVAssetWriter`. Pure logic (sensitivity
mapping, format selection, motion diff, ring buffer, recording FSM, file naming)
is isolated into testable seams; AVFoundation/AppKit glue is verified by build +
an end-to-end recording integration test.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design.

## Contributing

Contributions are welcome! Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) and
our [Code of Conduct](CODE_OF_CONDUCT.md). Found a security issue? See
[`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE) © MacCam contributors
