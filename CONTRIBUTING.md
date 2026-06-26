# Contributing to MacCam

Thanks for your interest in improving MacCam! This document explains how to get
set up and what we expect from contributions.

## Getting started

1. Fork and clone the repository.
2. Open `MacCam.xcodeproj` in Xcode 15+ (macOS 13+ SDK), or use the `Makefile`.
3. Build and run:
   ```sh
   make build
   make test
   ```

## Development workflow

- **Branch** off `main` for your change (`feat/...`, `fix/...`, `docs/...`).
- **Write tests** for any pure logic you add or change. The project keeps
  business logic in testable seams (`Motion/`, `Recording/`, `Storage/`,
  `Capture/FormatSelector.swift`) — extend the XCTest target in `MacCamTests/`.
- **Keep the capture/recording glue verifiable.** When you touch the
  `AVAssetWriter` path, make sure `RecordingIntegrationTests` still passes — it
  writes and validates a real clip without a camera.
- **Run the suite before pushing:**
  ```sh
  make test
  make lint
  ```
- **Match the existing style.** Run SwiftLint; keep files focused and small,
  one clear responsibility each.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):
`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`. Keep the subject
imperative and under ~72 chars; explain the "why" in the body.

## Pull requests

- Keep PRs focused; one logical change per PR.
- Fill in the PR template, describe testing, and link any related issues.
- CI (build + test + lint) must pass.
- Update `CHANGELOG.md` under "Unreleased" for user-facing changes.

## Design principles

- **Offline only.** MacCam must never add network code, telemetry, or analytics.
  Any entitlement beyond camera / microphone / user-selected files needs a strong
  justification.
- **Performance matters.** Motion analysis runs on every frame — keep it on the
  downscaled path, avoid allocations in the hot loop, and don't block the capture
  queue.
- **Privacy first.** Clips stay local; settings stay in `UserDefaults`; no data
  leaves the machine.

## Reporting bugs / requesting features

Open an issue using the templates. For security vulnerabilities, follow
[`SECURITY.md`](SECURITY.md) instead of filing a public issue.
