# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Disk-space limits: cap total clip size and/or keep a minimum amount of free
  space, with a loop (delete oldest) or stop-and-notify policy. Settings show
  current usage.
- Detection zones: ignore parts of the frame via a 16×9 grid mask painted over a
  camera snapshot, reducing false triggers.

### Fixed
- Audio was never recorded. The hardened runtime requires the
  `com.apple.security.device.audio-input` entitlement (distinct from the sandbox
  `device.microphone` key), which was missing, so the microphone was blocked.
  Also: a capturable microphone is now chosen (built-in preferred) instead of the
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

[Unreleased]: https://github.com/polyackiy/MacCam/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/polyackiy/MacCam/releases/tag/v1.0.0
