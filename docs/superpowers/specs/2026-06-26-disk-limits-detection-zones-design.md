# MacCam — Disk limits & Detection zones. Design / spec

**Date:** 2026-06-26
**Status:** approved for implementation
**Depends on:** MacCam 1.0.0 (capture → motion → record pipeline)

Two independent features added to the existing app, each in its own section.
Both stay fully offline.

---

## Feature 1 — Disk / storage limits

### 1.1 Goal

For 24/7 operation, bound how much disk MacCam consumes. Two independent limits,
two reaction policies, never losing the clip being written.

### 1.2 Settings (SettingsStore / AppSettings)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `maxStorageGB` | Double | `0` (off) | Cap on total size of `.mov` files in the clips folder (decimal GB). |
| `minFreeSpaceGB` | Double | `0` (off) | Floor of free space on the clips volume (decimal GB). |
| `diskLimitPolicy` | enum `.loop` / `.stop` | `.loop` | What happens when a limit is hit. |

`0` disables a limit. Both off by default (opt-in). These complement the
existing age-based `autoCleanup`/`cleanupDays`.

`DiskLimitPolicy` is `String, CaseIterable, Identifiable` with a localized
`label`.

### 1.3 Pure seam — `StorageMath`

```swift
struct ClipFile { let url: URL; let size: Int64; let modified: Date }

enum StorageMath {
    /// Oldest-first selection of clips to delete so that, after deletion,
    /// total size ≤ maxBytes (if > 0) AND free ≥ minFreeBytes (if > 0).
    /// `protecting` (e.g. the clip being written) is never selected.
    /// `maxBytes`/`minFreeBytes` of 0 mean "no constraint".
    static func clipsToDelete(
        files: [ClipFile],
        totalBytes: Int64,
        freeBytes: Int64,
        maxBytes: Int64,
        minFreeBytes: Int64,
        protecting: Set<URL>
    ) -> [URL]

    /// True if, ignoring deletion, current usage already violates a limit.
    static func overLimit(totalBytes: Int64, freeBytes: Int64,
                          maxBytes: Int64, minFreeBytes: Int64) -> Bool

    static func gbToBytes(_ gb: Double) -> Int64   // decimal GB (1e9)
}
```

Selection sorts candidates oldest-first, accumulates freed bytes, and stops once
both constraints are satisfied (or candidates are exhausted — best effort).

### 1.4 FileStore additions

- `folderUsage() -> (count: Int, totalBytes: Int64)` — enumerate `.mov`, sum sizes.
- `volumeFreeBytes() -> Int64` — via `URLResourceValues.volumeAvailableCapacityForImportantUsage`
  on the current folder; `0` on failure.
- `clipFiles() -> [ClipFile]` — `.mov` with size + modification date.
- `enforce(maxBytes:minFreeBytes:protecting:) -> Bool` — applies `clipsToDelete`
  and removes the chosen files; returns whether usage is within limits afterward.

### 1.5 RecordingController integration

`RecordingController` gains an injected closure/delegate to the storage check so
it stays decoupled from `FileStore` specifics:

```swift
// Returns true if a new clip may be opened now.
var storageGate: ((_ protecting: Set<URL>) -> StorageDecision)?
enum StorageDecision { case ok, stop }
```

- Before `openWriter` (on `.startClip` and `.rotate`), call `storageGate`,
  passing `protecting` = the set of in-flight clip URLs (the writer about to open
  has no file yet; on `.rotate` the just-closed clip may still be finalizing
  asynchronously, so the controller tracks and protects its URL until
  `finishWriting` completes).
  - `.loop`: the gate frees space (deletes oldest, never a protected URL) then
    returns `.ok` (best effort — always proceeds).
  - `.stop` when over limit: gate returns `.stop`; the controller does **not**
    open a writer and invokes `onStorageStop`. (On `.rotate` the previous clip is
    already finalized by `finishWriter` before the gate is consulted.)
- `onStorageStop: (() -> Void)?` → AppDelegate calls `stopMonitoring()` (which
  calls `recorder.stop()`, resetting the FSM to idle and stopping the camera) and
  shows a "recording stopped — disk limit reached" status in the menu. Routing
  teardown through `stopMonitoring` keeps the FSM and writer state consistent even
  though `fsm.step` had already transitioned to `.recording`.

The gate is wired in `AppDelegate` using `FileStore` + current `AppSettings`.

### 1.6 UI

`SettingsView` "Storage" section gains:
- Stepper `Max storage (GB)` (0 = off), Stepper `Keep free (GB)` (0 = off).
- Picker `When limit reached`: Loop (delete oldest) / Stop & notify.
- Read-only usage line: `"<count> clips · <X> GB · <Y> GB free"` refreshed on
  appear and after recordings.

### 1.7 Tests

`StorageMathTests`: oldest-first ordering; respects `protecting`; satisfies both
size and free constraints; `0` means unconstrained; stops when nothing left to
delete; `overLimit` boundaries; `gbToBytes`.

---

## Feature 2 — Detection zones (grid mask)

### 2.1 Goal

Let the user ignore parts of the frame (a TV, a window onto a busy street) to cut
false triggers, by painting a coarse grid mask over a camera snapshot.

### 2.2 Model — `MotionMask`

- Fixed grid **16 × 9** (144 cells), matching 16:9 and mapping cleanly onto the
  320×180 analysis frame (each cell = 20×20 analysis px).
- `ignored: [Bool]` of length 144 (row-major, top-left origin in image space).
- Semantics: an *ignored* cell contributes neither to the changed-pixel count nor
  to the analyzed-pixel total, so the motion threshold remains "fraction of the
  active area".
- Persistence: compact string of `144` chars `'0'/'1'` in UserDefaults
  (`detectionMask`). Empty/absent ⇒ all-active (no masking).

```swift
struct MotionMask: Equatable {
    static let cols = 16, rows = 9, count = cols * rows
    private(set) var ignored: [Bool]            // count == 144
    var isEmpty: Bool { !ignored.contains(true) }      // nothing ignored
    var allIgnored: Bool { !ignored.contains(false) }
    init()                                       // all active
    init?(encoded: String)                       // parse "0/1"*144
    func encoded() -> String
    func cell(_ col: Int, _ row: Int) -> Bool
    mutating func toggle(_ col: Int, _ row: Int)
    mutating func clear()                         // all active
    mutating func invert()
    /// Per-analysis-pixel ignore lookup for a given analysis size.
    func pixelLookup(width: Int, height: Int) -> [Bool]   // size w*h
}
```

### 2.3 MotionDetector integration

- Detector holds an optional per-pixel ignore lookup (size 320×180) plus the
  analyzed-pixel count (non-ignored).
- New thread-safe staging like the existing tunables: `requestMask(_ MotionMask?)`
  stores it under `paramLock`; `applyPendingUpdate()` (already runs on the
  analysis queue) expands it once to the pixel lookup and caches the active-pixel
  count.
- Hot loop: skip pixels where `lookup[i]` is true; denominator = active-pixel
  count (not the full 320×180). If active count is `0` (everything ignored) →
  return `(motion: false, fraction: 0)`.
- A `nil`/empty mask means no masking (current behavior), active count = full.

### 2.4 Snapshot — `CameraManager.captureSnapshot`

```swift
func captureSnapshot(_ completion: @escaping (CGImage?) -> Void)
```

- If the session is running, attach a one-shot frame grab: a private
  `AVCaptureVideoDataOutput` delegate (or reuse the existing one) captures the
  next `CVPixelBuffer`, converts to `CGImage`, returns on the main queue, and
  detaches.
- If the session is **not** running, briefly configure + start it with the
  selected device, grab one frame, stop. Failure → `nil`.
- Used only by the zone editor; never writes to disk.

### 2.5 UI — `ZoneEditorView`

- Opened from a `SettingsView` button "Edit Detection Zones…" into its own window
  (like Settings/About), managed by `AppDelegate`.
- On appear: request a snapshot; show it scaled to a 16:9 area (placeholder dark
  panel if `nil`).
- Overlay a 16×9 grid; ignored cells get a translucent red fill + border. Tap or
  drag toggles cells (drag paints). Buttons: **Clear**, **Invert**, **Done**.
- Binds to a working `MotionMask`; on change writes the encoded string to
  `SettingsStore.detectionMask` (applied live via the existing
  `objectWillChange` → `applyLiveSettings` path, which calls
  `detector.requestMask`).

### 2.6 Settings wiring

- `SettingsStore.detectionMask: String` (`@Published`, persisted).
- `AppSettings` carries `detectionMask: String`; `applyLiveSettings`/`startMonitoring`
  build a `MotionMask(encoded:)` and call `detector.requestMask`.
- `SettingsView` "Motion" section: a button to open the editor and a caption
  showing how many cells are ignored.

### 2.7 Tests

`MotionMaskTests`: encode/decode round-trip; invalid strings → nil/empty;
`toggle`/`clear`/`invert`; `pixelLookup` maps the right pixels and size; all-active
vs all-ignored flags.
`MotionDetectorTests` (extend): with a mask ignoring the half of the frame that
changes → no motion; motion only in the active half → detected; all-ignored →
no motion.

---

## Cross-cutting

- **New files:** `Storage/StorageMath.swift`, `Motion/MotionMask.swift`,
  `UI/ZoneEditorView.swift`. **Edited:** `FileStore`, `RecordingController`,
  `MotionDetector`, `CameraManager`, `SettingsStore`, `SettingsView`,
  `AppDelegate`, localization catalogs, CHANGELOG.
- **Localization:** new UI strings added to `Localizable.xcstrings` (EN + RU).
- **Offline:** no network; snapshots are in-memory only; deletions confined to
  the clips folder.
- **Concurrency:** storage checks run at clip boundaries (not per frame); mask
  changes are staged under the detector's `paramLock` and applied on the analysis
  queue, consistent with existing tunable handling.
- **Defaults preserve current behavior:** disk limits off; empty mask.

## Implementation order

1. `StorageMath` (+tests) → `FileStore` usage/enforce → `RecordingController`
   gate + `onStorageStop` → settings + UI + AppDelegate wiring.
2. `MotionMask` (+tests) → `MotionDetector` mask support (+tests) →
   `CameraManager.captureSnapshot` → `ZoneEditorView` + settings/AppDelegate
   wiring.
3. Localization, CHANGELOG, full build/test, review.
