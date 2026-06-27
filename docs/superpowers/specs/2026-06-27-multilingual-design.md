# MacCam — Multilingual (i18n) design / spec

**Date:** 2026-06-27
**Status:** approved for implementation

Make the app fully multilingual. Today it ships **en** (source) + **ru**; add
**es, fr, de, pt-BR, it, zh-Hans, ja** (the "top global" set — no RTL).

## Scope

Two String Catalogs + a couple of code touch-ups + language registration. No
business-logic changes; no new unit tests (existing 70 stay green).

### 1. Complete string coverage (close the English-only gaps)

These user-facing strings are not yet translatable; bring them into the catalog.

**a. Interpolated SwiftUI labels (no Swift change — SwiftUI already emits the
format key; just add the keys to `Localizable.xcstrings`):**
- `Sensitivity: %lld (0 = coarse, 4 = sensitive)`
- `Voice sensitivity: %lld (0 = strict, 4 = sensitive)`
- `%lld cells ignored`
- `%lld zone cells ignored`
- `Min clip length: %lld s`
- `Max clip length: %lld s`
- `Cooldown after motion: %lld s`
- `Pre-roll: %lld s`
- `Delete after %lld days`
- `Max storage: %lld GB (0 = off)`
- `Keep free: %lld GB (0 = off)`

**b. Two raw strings that need a small code change to become catalog-backed:**
- `StorageSettingsTab.usageText`: `String(format: "%d clips · %.1f GB · %.1f GB free", …)`
  → `loc("%d clips · %.1f GB · %.1f GB free", usage.count, usedGB, freeGB)` and add the key.
- `StorageSettingsTab` folder picker `panel.prompt = "Choose"` →
  `panel.prompt = loc("Choose")` and add the key.

**Not in scope:** `CameraManager.statusMessage` raw strings ("No camera
available", "Camera error — retrying…", "Camera disconnected — waiting…") — no
view renders `statusMessage`, so they are not user-facing. Left as-is.

### 2. Translations

- `Localizable.xcstrings`: 95 existing keys + 13 new = **108 keys**, each gets the
  7 new languages (ru already present on the 95; the 13 new keys also get ru).
- `InfoPlist.xcstrings`: the 2 system permission descriptions
  (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`) get the 7 new
  languages (en/ru already present).
- Translations produced by the assistant. To keep ~900 catalog entries
  well-formed, a **Python merge script** (`scripts/i18n/merge_translations.py`)
  injects a `{key: {lang: value}}` map into the `.xcstrings` files (valid JSON,
  `state: "translated"`, existing entries preserved). The script is committed as
  a reusable helper for future strings/languages.
- **Placeholders** (`%lld`, `%@`, `%d`, `%.1f`) are preserved verbatim and kept in
  order; technical tokens (`GB`, `s`, `MacCam`) follow each locale's convention.
- **Plurals:** simple number substitution (no per-CLDR-form plural variations).
  Acceptable for the few count captions; a possible future refinement.

### 3. Language registration

- `Info.plist` `CFBundleLocalizations`: add the 7 languages (currently `[en, ru]`).
- `MacCam.xcodeproj` `knownRegions`: add the 7 languages (currently `[en, Base]`;
  `ru` already works via the catalog, but list all for completeness).
- Language selection is the standard macOS behavior (follows the system language);
  no in-app switcher.

## Verification

- `make build` succeeds; both `.xcstrings` are valid JSON.
- A coverage check asserts every Localizable key has all 9 languages and every
  InfoPlist key has all 9.
- Built `MacCam.app` contains a compiled `.lproj` (or `.loctable`) for each
  language.
- Spot-check: launch with `defaults`/`-AppleLanguages "(fr)"` and confirm the UI
  renders in the chosen language.

## Out of scope

Plural CLDR forms, RTL languages, in-app language switcher, translating
non-rendered `statusMessage` strings, README translation (stays English).
