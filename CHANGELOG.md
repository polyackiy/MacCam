# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Seven more interface languages — Spanish, French, German, Brazilian
  Portuguese, Italian, Simplified Chinese, and Japanese — alongside English and
  Russian. Covers the whole UI and the system camera/microphone permission
  prompts; the app follows the system language automatically.
- Manual language picker in Settings → General: override the interface language
  instead of following the system (applies after you reopen MacCam).

### Fixed
- The detection-zone editor kept the camera running after the window was closed
  and then showed a black preview (and never recovered) on reopen. Teardown is
  now driven by the window closing — SwiftUI's `onDisappear` doesn't fire for the
  editor's hosted window — and a stale preview session can no longer contend with
  a new one for the camera.

## [1.1.0] - 2026-06-27

### Added
- Recording trigger modes — Continuous (always record), Motion, Voice, or
  Motion + Voice — chosen in Settings. Continuous and Voice skip motion analysis
  to save CPU.
- Voice-activated recording: detect human speech on-device (SoundAnalysis) as a
  trigger, with adjustable sensitivity. Requires audio enabled.
- Audio-only recording: capture sound with the camera off, saved as an `.m4a`
  (AAC) file. Available with the Continuous or Voice trigger.
- Detection zones: paint a 16×9 ignore mask over a live camera preview to skip
  busy areas (a swaying tree, a street) and reduce false triggers.
- Weekly schedules: auto start/stop monitoring within a time window, and gate
  recording to its own window (per-weekday, overnight supported). A manual Start
  always takes priority.
- Disk-space limits: cap total clip size and/or keep a minimum amount of free
  space, then loop (delete oldest) or stop & notify. Settings show current usage.
- Microphone picker in Settings: choose the audio device or "Automatic"
  (built-in preferred), with a fallback if the chosen device is unavailable.

### Changed
- Settings redesigned as a sidebar window (Camera, Detection, Recording,
  Schedule, Storage, General) with grouped sections and inline help, replacing
  the single scrolling list.
- Tidier menu-bar dropdown: the current state shows as a clear section header and
  the commands are uniformly aligned with consistent icons.

### Fixed
- Audio was never recorded: the hardened runtime needs the
  `com.apple.security.device.audio-input` entitlement (distinct from the sandbox
  `device.microphone` key), which was missing, so the microphone was blocked.
  Also, a capturable microphone is now chosen (built-in preferred) instead of the
  system default — which may be an un-capturable Bluetooth/output device — and
  microphone access is requested when monitoring starts so the prompt appears.

## [1.0.0] - 2026-06-26

First public release.

### Added
- Menu-bar agent that captures the camera at the maximum available resolution.
- `vImage` motion detection with adjustable sensitivity (0–4).
- Motion-triggered HEVC/H.264 recording with cooldown, min/max clip length,
  seamless rotation, and optional pre-roll.
- Local clip storage with a user-selectable folder (security-scoped bookmark)
  and optional auto-cleanup of old clips.
- Guard mode that monitors while the screen is locked (manual start takes
  priority), and launch-at-login via `SMAppService`.
- Discreet menu-bar mode: a neutral icon identical in every state, with a choice
  of glyphs.
- English/Russian localization of the interface and permission prompts.
- About window showing version and project links.
- Fully offline operation: no network entitlements, no telemetry.
- Project icon, MIT license, contribution guide, code of conduct, security
  policy, English README, and architecture document.
- Continuous integration (build + test + lint) and a tagged release pipeline
  that publishes a DMG.

[Unreleased]: https://github.com/polyackiy/MacCam/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/polyackiy/MacCam/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/polyackiy/MacCam/releases/tag/v1.0.0
