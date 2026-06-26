# MacCam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native macOS menu-bar app that records motion-triggered video clips from the Mac camera, fully offline.

**Architecture:** Single `AVCaptureSession` feeds a delegate that runs vImage motion detection (downscaled, throttled) and a recording FSM driving `AVAssetWriter`. Pure logic (sensitivity/bitrate mapping, format selection, motion diff, ring buffer, FSM transitions, file naming/cleanup) is isolated into testable seams covered by an XCTest target; AVFoundation/AppKit glue is verified by build + run.

**Tech Stack:** Swift 5.9, SwiftUI + AppKit (`NSStatusItem`), AVFoundation, Accelerate/vImage, ServiceManagement (`SMAppService`). Hand-written `MacCam.xcodeproj` (app target + unit-test target), App Sandbox, no third-party deps.

**Spec:** `docs/superpowers/specs/2026-06-26-maccam-security-camera-design.md`

**TDD note:** Tasks with a pure-logic seam follow strict test-first (write failing test → run → implement → pass → commit). Glue tasks (capture session, asset writer I/O, status item, SwiftUI) have no unit test; they are implemented then verified via `xcodebuild build` and a manual run step, and committed.

**Build/test commands:**
- Build: `xcodebuild -project MacCam.xcodeproj -scheme MacCam -configuration Debug -destination 'platform=macOS' build`
- Test: `xcodebuild -project MacCam.xcodeproj -scheme MacCam -destination 'platform=macOS' test`

---

## File Structure

```
MacCam/
├── MacCam.xcodeproj/project.pbxproj
├── MacCam/
│   ├── App/MacCamApp.swift            # @main, NSApplicationDelegateAdaptor
│   ├── App/AppDelegate.swift          # lifecycle, permissions, wiring, .accessory
│   ├── Capture/CameraManager.swift    # AVCaptureSession config, start/stop, disconnect
│   ├── Capture/FormatSelector.swift   # PURE: pick max-area format with fps>=24
│   ├── Capture/CaptureDelegate.swift  # sample buffer delegate → motion + recording
│   ├── Motion/MotionDetector.swift    # vImage downscale+grayscale+diff
│   ├── Motion/MotionMath.swift        # PURE: sensitivity→threshold mapping
│   ├── Motion/RingBuffer.swift        # pre-roll frame buffer
│   ├── Recording/RecordingController.swift  # AVAssetWriter glue + FSM driver
│   ├── Recording/RecordingFSM.swift   # PURE: state transition decisions
│   ├── Recording/Bitrate.swift        # PURE: quality+resolution→bitrate
│   ├── Storage/FileStore.swift        # folder, bookmark, naming, cleanup
│   ├── Storage/ClipNaming.swift       # PURE: timestamp→filename, cleanup selection
│   ├── System/LockMonitor.swift       # screen lock/unlock → guard
│   ├── System/LaunchAtLogin.swift     # SMAppService
│   ├── UI/MenuBarController.swift      # NSStatusItem + menu + icon states
│   ├── UI/SettingsView.swift          # SwiftUI settings
│   ├── UI/SettingsStore.swift         # UserDefaults @Published + Settings snapshot
│   ├── Assets.xcassets
│   ├── Info.plist
│   └── MacCam.entitlements
├── MacCamTests/
│   ├── MotionMathTests.swift
│   ├── BitrateTests.swift
│   ├── FormatSelectorTests.swift
│   ├── RingBufferTests.swift
│   ├── RecordingFSMTests.swift
│   ├── ClipNamingTests.swift
│   └── MotionDetectorTests.swift
└── README.md
```

---

## Task 0: Project scaffold (agent app builds & runs)

**Files:**
- Create: `MacCam.xcodeproj/project.pbxproj`
- Create: `MacCam/App/MacCamApp.swift`, `MacCam/App/AppDelegate.swift`
- Create: `MacCam/Info.plist`, `MacCam/MacCam.entitlements`
- Create: `MacCam/Assets.xcassets/` (AppIcon + status icons placeholders)
- Create: `MacCamTests/Smoke.swift` (one trivial passing test to validate the test target)

- [ ] **Step 1:** Hand-write `project.pbxproj` with two native targets: `MacCam` (com.apple.product-type.application, macOS 13.0, arm64, Swift 5.9, `GENERATE_INFOPLIST_FILE=NO` + `INFOPLIST_FILE`, `CODE_SIGN_IDENTITY=-` ad-hoc, `CODE_SIGN_ENTITLEMENTS`, `ENABLE_APP_SANDBOX` via entitlements) and `MacCamTests` (unit-test bundle, `TEST_HOST`/`BUNDLE_LOADER` → MacCam). One shared scheme `MacCam` with test action referencing `MacCamTests`.
- [ ] **Step 2:** `Info.plist` with `LSUIElement=YES`, `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `CFBundleIdentifier=com.maccam.app`, min system 13.0.
- [ ] **Step 3:** `MacCam.entitlements` with `com.apple.security.app-sandbox`, `device.camera`, `device.microphone`, `files.user-selected.read-write`. No network.
- [ ] **Step 4:** `MacCamApp.swift`: `@main struct MacCamApp: App` with `@NSApplicationDelegateAdaptor(AppDelegate.self)` and `Settings { EmptyView() }` scene (real settings window added later).
- [ ] **Step 5:** `AppDelegate.swift`: `applicationDidFinishLaunching` sets `NSApp.setActivationPolicy(.accessory)` and logs "MacCam launched".
- [ ] **Step 6:** `MacCamTests/Smoke.swift`: `func testSmoke() { XCTAssertTrue(true) }`.
- [ ] **Step 7:** Build. Run: build command above. Expected: `BUILD SUCCEEDED`.
- [ ] **Step 8:** Test. Run: test command above. Expected: `Test Suite ... passed`, `testSmoke` passes.
- [ ] **Step 9:** Manual run: launch built `.app`, confirm no Dock icon, "MacCam launched" in log.
- [ ] **Step 10:** Commit: `git add -A && git commit -m "feat: project scaffold, agent app builds and runs"`.

---

## Task 1: MotionMath (sensitivity → threshold) — PURE/TDD

**Files:** Create `MacCam/Motion/MotionMath.swift`, `MacCamTests/MotionMathTests.swift`

- [ ] **Step 1 (failing test):**
```swift
import XCTest
@testable import MacCam
final class MotionMathTests: XCTestCase {
    func testEndpoints() {
        XCTAssertEqual(MotionMath.motionThreshold(forSensitivity: 0), 0.08, accuracy: 1e-6) // coarse
        XCTAssertEqual(MotionMath.motionThreshold(forSensitivity: 4), 0.005, accuracy: 1e-6) // sensitive
    }
    func testMonotonicDecreasing() {
        let t = (0...4).map { MotionMath.motionThreshold(forSensitivity: $0) }
        for i in 1..<t.count { XCTAssertLessThan(t[i], t[i-1]) }
    }
    func testClampsOutOfRange() {
        XCTAssertEqual(MotionMath.motionThreshold(forSensitivity: -5), 0.08, accuracy: 1e-6)
        XCTAssertEqual(MotionMath.motionThreshold(forSensitivity: 99), 0.005, accuracy: 1e-6)
    }
}
```
- [ ] **Step 2:** Run test → FAIL (no MotionMath).
- [ ] **Step 3 (implement):** logarithmic interpolation between 0.08 (s=0) and 0.005 (s=4):
```swift
enum MotionMath {
    static func motionThreshold(forSensitivity s: Int) -> Double {
        let c = Double(min(4, max(0, s)))
        let hi = log(0.08), lo = log(0.005)
        return exp(hi + (lo - hi) * (c / 4.0))
    }
}
```
- [ ] **Step 4:** Run test → PASS.
- [ ] **Step 5:** Commit: `feat: motion sensitivity→threshold mapping`.

---

## Task 2: Bitrate presets — PURE/TDD

**Files:** Create `MacCam/Recording/Bitrate.swift`, `MacCamTests/BitrateTests.swift`

- [ ] **Step 1 (failing test):**
```swift
import XCTest
@testable import MacCam
final class BitrateTests: XCTestCase {
    func test1080p() {
        XCTAssertEqual(Bitrate.bps(quality: .low,    width: 1920, height: 1080), 6_000_000)
        XCTAssertEqual(Bitrate.bps(quality: .medium, width: 1920, height: 1080), 9_000_000)
        XCTAssertEqual(Bitrate.bps(quality: .high,   width: 1920, height: 1080), 12_000_000)
    }
    func test4kScalesUp() {
        XCTAssertGreaterThan(Bitrate.bps(quality: .medium, width: 3840, height: 2160),
                             Bitrate.bps(quality: .medium, width: 1920, height: 1080))
    }
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3 (implement):** base bps-per-pixel for 1080p anchor scaled linearly by area.
```swift
enum Quality: String, CaseIterable { case low, medium, high }
enum Bitrate {
    static func bps(quality: Quality, width: Int, height: Int) -> Int {
        let anchor: Double = 1920 * 1080
        let base: Double = { switch quality { case .low: 6_000_000; case .medium: 9_000_000; case .high: 12_000_000 } }()
        let scaled = base * (Double(width * height) / anchor)
        return Int((scaled / 1000).rounded()) * 1000
    }
}
```
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: bitrate presets by quality and resolution`.

---

## Task 3: FormatSelector (max-resolution pick) — PURE/TDD

**Files:** Create `MacCam/Capture/FormatSelector.swift`, `MacCamTests/FormatSelectorTests.swift`

Define a protocol seam so we can test without real `AVCaptureDevice.Format`:
```swift
protocol FormatInfo { var width: Int { get }; var height: Int { get }; var maxFPS: Double { get } }
```

- [ ] **Step 1 (failing test):**
```swift
import XCTest
@testable import MacCam
private struct Fmt: FormatInfo { let width: Int; let height: Int; let maxFPS: Double }
final class FormatSelectorTests: XCTestCase {
    func testPicksMaxAreaWithAcceptableFPS() {
        let fmts = [Fmt(width:1280,height:720,maxFPS:60),
                    Fmt(width:1920,height:1080,maxFPS:30),
                    Fmt(width:3840,height:2160,maxFPS:15)] // 15 < 24 → excluded
        let best = FormatSelector.pick(from: fmts, minFPS: 24)!
        XCTAssertEqual(best.width, 1920); XCTAssertEqual(best.height, 1080)
    }
    func testFallsBackToMaxAreaIfNoneMeetFPS() {
        let fmts = [Fmt(width:640,height:480,maxFPS:10), Fmt(width:1920,height:1080,maxFPS:12)]
        let best = FormatSelector.pick(from: fmts, minFPS: 24)!
        XCTAssertEqual(best.width, 1920)
    }
    func testEmpty() { XCTAssertNil(FormatSelector.pick(from: [Fmt](), minFPS: 24)) }
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3 (implement):**
```swift
enum FormatSelector {
    static func pick<F: FormatInfo>(from formats: [F], minFPS: Double) -> F? {
        let ok = formats.filter { $0.maxFPS >= minFPS }
        let pool = ok.isEmpty ? formats : ok
        return pool.max { ($0.width * $0.height) < ($1.width * $1.height) }
    }
}
```
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: max-resolution format selector`.

---

## Task 4: RingBuffer (pre-roll) — PURE/TDD

**Files:** Create `MacCam/Motion/RingBuffer.swift`, `MacCamTests/RingBufferTests.swift`

Generic over a timestamped element so it's testable without `CMSampleBuffer`.
```swift
final class RingBuffer<T> {
    init(duration: Double)
    func push(_ item: T, pts: Double)
    func snapshot() -> [T]   // oldest→newest, within `duration` of newest
    func clear()
}
```
- [ ] **Step 1 (failing test):**
```swift
import XCTest
@testable import MacCam
final class RingBufferTests: XCTestCase {
    func testEvictsOlderThanDuration() {
        let rb = RingBuffer<Int>(duration: 3.0)
        for i in 0...10 { rb.push(i, pts: Double(i)) } // pts 0..10, keep within 3s of newest(10)
        let s = rb.snapshot()
        XCTAssertEqual(s.first, 8); XCTAssertEqual(s.last, 10) // pts 8,9,10
    }
    func testOrderOldestToNewest() {
        let rb = RingBuffer<Int>(duration: 100)
        [5,6,7].forEach { rb.push($0, pts: Double($0)) }
        XCTAssertEqual(rb.snapshot(), [5,6,7])
    }
    func testClear() {
        let rb = RingBuffer<Int>(duration: 100); rb.push(1, pts: 1); rb.clear()
        XCTAssertTrue(rb.snapshot().isEmpty)
    }
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3 (implement):** array of `(pts, item)`, on push append then drop front while `newest.pts - front.pts > duration`. `snapshot` returns items. Internal `NSLock` for thread safety.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: ring buffer for pre-roll`.

---

## Task 5: ClipNaming + cleanup selection — PURE/TDD

**Files:** Create `MacCam/Storage/ClipNaming.swift`, `MacCamTests/ClipNamingTests.swift`

```swift
enum ClipNaming {
    static func filename(for date: Date, calendar: Calendar) -> String   // MacCam_YYYY-MM-DD_HH-mm-ss.mov
    static func expired(files: [(url: URL, modified: Date)], olderThanDays: Int, now: Date) -> [URL]
}
```
- [ ] **Step 1 (failing test):**
```swift
import XCTest
@testable import MacCam
final class ClipNamingTests: XCTestCase {
    func testFilenameFormat() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let d = DateComponents(calendar: cal, year:2026, month:6, day:26, hour:9, minute:5, second:3).date!
        XCTAssertEqual(ClipNaming.filename(for: d, calendar: cal), "MacCam_2026-06-26_09-05-03.mov")
    }
    func testExpiredSelection() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = URL(fileURLWithPath: "/a/old.mov"); let fresh = URL(fileURLWithPath: "/a/new.mov")
        let files = [(old, now.addingTimeInterval(-15*86400)), (fresh, now.addingTimeInterval(-1*86400))]
        XCTAssertEqual(ClipNaming.expired(files: files, olderThanDays: 14, now: now), [old])
    }
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3 (implement):** build string via `DateComponents` (zero-padded); `expired` filters `now - modified > days*86400`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: clip naming and expiry selection`.

---

## Task 6: RecordingFSM (transition decisions) — PURE/TDD

**Files:** Create `MacCam/Recording/RecordingFSM.swift`, `MacCamTests/RecordingFSMTests.swift`

Pure decision core, time injected (no timers/threads):
```swift
enum RecState: Equatable { case idle, recording }
enum RecAction: Equatable { case none, startClip, appendOnly, finishAndIdle, rotate }
struct RecordingFSM {
    var minClip = 5.0, maxClip = 60.0, cooldown = 5.0
    private(set) var state: RecState = .idle
    private var clipStart = 0.0, lastMotion = 0.0
    mutating func step(motion: Bool, now: Double) -> RecAction
}
```
Rules: idle+motion→startClip(state=recording, clipStart=lastMotion=now). recording: if motion → lastMotion=now; if now-clipStart>=maxClip → rotate(reset clipStart=now); else if now-lastMotion>=cooldown AND now-clipStart>=minClip → finishAndIdle; else appendOnly. idle+no motion→none.

- [ ] **Step 1 (failing test):**
```swift
import XCTest
@testable import MacCam
final class RecordingFSMTests: XCTestCase {
    func testStartOnMotion() {
        var f = RecordingFSM(); XCTAssertEqual(f.step(motion: true, now: 0), .startClip)
        XCTAssertEqual(f.state, .recording)
    }
    func testStaysRecordingDuringCooldown() {
        var f = RecordingFSM(); _ = f.step(motion: true, now: 0)
        XCTAssertEqual(f.step(motion: false, now: 3), .appendOnly) // <5s cooldown
    }
    func testFinishAfterCooldownPastMinClip() {
        var f = RecordingFSM(); _ = f.step(motion: true, now: 0)
        XCTAssertEqual(f.step(motion: false, now: 11), .finishAndIdle) // >cooldown & >minClip
        XCTAssertEqual(f.state, .idle)
    }
    func testRotateAtMaxClip() {
        var f = RecordingFSM(); _ = f.step(motion: true, now: 0)
        XCTAssertEqual(f.step(motion: true, now: 60), .rotate)
        XCTAssertEqual(f.state, .recording)
    }
    func testNoFinishBeforeMinClipEvenIfQuiet() {
        var f = RecordingFSM(minClip: 5, maxClip: 60, cooldown: 1); _ = f.step(motion: true, now: 0)
        XCTAssertEqual(f.step(motion: false, now: 2), .appendOnly) // quiet but clip<minClip
    }
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement transition rules above.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: recording state machine core`.

---

## Task 7: SettingsStore + Settings snapshot

**Files:** Create `MacCam/UI/SettingsStore.swift`. (No unit test — thin UserDefaults wrapper; covered indirectly.)

- [ ] **Step 1:** Define immutable `struct Settings` holding all params from spec §12 (camera id, targetFPS, sensitivity, pixelDelta, cooldown, minClip, maxClip, preRollEnabled, preRoll, audioEnabled, codec, quality, folderBookmark, autoCleanup, cleanupDays, guardMode, launchAtLogin).
- [ ] **Step 2:** `final class SettingsStore: ObservableObject` with `@Published` properties backed by `UserDefaults` (didSet persists). Registered defaults match spec §12.
- [ ] **Step 3:** `func snapshot() -> Settings` returns current values atomically (read on capture queue).
- [ ] **Step 4:** Build → `BUILD SUCCEEDED`.
- [ ] **Step 5:** Commit: `feat: settings store with atomic snapshot`.

---

## Task 8: MotionDetector (vImage) — TDD on synthetic buffers

**Files:** Create `MacCam/Motion/MotionDetector.swift`, `MacCamTests/MotionDetectorTests.swift`

API: `final class MotionDetector { func analyze(_ pixelBuffer: CVPixelBuffer, pts: Double) -> (motion: Bool, fraction: Double)? }` — downscale to 320×180 grayscale, abs-diff vs previous, fraction of pixels with delta>pixelDelta, throttle by pts (skip if since-last < 1/12s), returns nil on first/throttled frame. Threshold/pixelDelta read from injected closure or set properties.

- [ ] **Step 1 (failing test):** helper to build a `CVPixelBuffer` (BGRA) filled with a solid gray, and one with half the pixels bright.
```swift
import XCTest; import CoreVideo
@testable import MacCam
final class MotionDetectorTests: XCTestCase {
    func makeBuffer(width: Int, height: Int, fill: (Int,Int)->UInt8) -> CVPixelBuffer { /* create kCVPixelFormatType_32BGRA, fill luminance */ }
    func testNoMotionOnIdenticalFrames() {
        let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
        let a = makeBuffer(width: 640, height: 360) { _,_ in 100 }
        _ = d.analyze(a, pts: 0)                          // first frame → nil
        let r = d.analyze(a, pts: 1)!
        XCTAssertFalse(r.motion); XCTAssertLessThan(r.fraction, 0.01)
    }
    func testMotionWhenHalfFrameChanges() {
        let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
        let dark = makeBuffer(width: 640, height: 360) { _,_ in 30 }
        let half = makeBuffer(width: 640, height: 360) { x,_ in x < 320 ? 30 : 220 }
        _ = d.analyze(dark, pts: 0)
        let r = d.analyze(half, pts: 1)!
        XCTAssertTrue(r.motion); XCTAssertGreaterThan(r.fraction, 0.3)
    }
    func testThrottleReturnsNilWithinInterval() {
        let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
        let a = makeBuffer(width: 640, height: 360) { _,_ in 100 }
        _ = d.analyze(a, pts: 0)
        XCTAssertNil(d.analyze(a, pts: 0.01)) // <1/12s since last
    }
}
```
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement with vImage: lock base address, `vImageScale_ARGB8888`→320×180, convert to Planar8 luminance (matrix or extract), `vImageAbsoluteDifference_Planar8` vs stored previous, count pixels>pixelDelta via a pass, fraction = count/(320*180). Keep previous planar buffer. Throttle on pts.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat: vImage motion detector`.

---

## Task 9: FileStore (folder, bookmark, cleanup)

**Files:** Create `MacCam/Storage/FileStore.swift`. (Glue around tested ClipNaming; verified by build/run.)

- [ ] **Step 1:** `defaultFolder()` → `~/Movies/MacCam/`, create if missing.
- [ ] **Step 2:** `setFolder(url:)` creates security-scoped bookmark, persists to UserDefaults; `resolveFolder()` resolves bookmark with `startAccessingSecurityScopedResource`, fallback to default on failure.
- [ ] **Step 3:** `nextClipURL(now:)` uses `ClipNaming.filename`. `runCleanup(olderThanDays:)` lists folder, maps modified dates, deletes `ClipNaming.expired(...)`.
- [ ] **Step 4:** Build → `BUILD SUCCEEDED`.
- [ ] **Step 5:** Commit: `feat: file store with bookmark and cleanup`.

---

## Task 10: RecordingController (AVAssetWriter + FSM driver)

**Files:** Create `MacCam/Recording/RecordingController.swift`. (Glue; verified by build/run producing a valid clip.)

- [ ] **Step 1:** Hold `RecordingFSM`, `FileStore`, `SettingsStore` snapshot, `RingBuffer<CMSampleBuffer>`. Internal `NSLock` for video/audio append safety.
- [ ] **Step 2:** `handle(video:CMSampleBuffer, motion:Bool)`: call `fsm.step`; on `.startClip` open writer (`openWriter(firstPTS:)`), flush ring buffer if pre-roll, append; on `.appendOnly` append; on `.rotate` finish current + open next + append; on `.finishAndIdle` finish.
- [ ] **Step 3:** `handle(audio:CMSampleBuffer)`: if recording & audio input ready, append.
- [ ] **Step 4:** `openWriter(firstPTS:)`: `AVAssetWriter(.mov)`, video input with settings (codec from snapshot, W/H, `Bitrate.bps`, expected fps), optional AAC audio input, `expectsMediaDataInRealTime=true`, `startWriting`, `startSession(atSourceTime: firstPTS)`. Check `isReadyForMoreMediaData` before each append.
- [ ] **Step 5:** `finish()`: mark inputs finished, `finishWriting`, update "last clip" state, reset.
- [ ] **Step 6:** Build → `BUILD SUCCEEDED`.
- [ ] **Step 7:** Commit: `feat: recording controller with asset writer and rotation`.

---

## Task 11: CameraManager + CaptureDelegate

**Files:** Create `MacCam/Capture/CameraManager.swift`, `MacCam/Capture/CaptureDelegate.swift`. (Glue; verified by run.)

- [ ] **Step 1:** `CameraManager`: discovery `[.builtInWideAngleCamera, .external, .continuityCamera]`; default to built-in or settings-selected id. Wrap `AVCaptureDevice.Format` in `FormatInfo` adapter, call `FormatSelector.pick`, apply via `lockForConfiguration`→`activeFormat`→`activeVideoMin/MaxFrameDuration` for targetFPS→`unlock`. Do NOT set `sessionPreset` for quality.
- [ ] **Step 2:** Configure `AVCaptureVideoDataOutput` (BGRA) on queue `capture.video`, optional `AVCaptureAudioDataOutput` on `capture.audio` when `audioEnabled`. `start()/stop()`. Publish selected `WxH@fps` string.
- [ ] **Step 3:** Observe `AVCaptureSessionRuntimeError` + device disconnect; pause and retry reopen on a timer; expose status.
- [ ] **Step 4:** `CaptureDelegate`: route video buffer → RingBuffer.push (if pre-roll) → MotionDetector.analyze → RecordingController.handle(video:motion:); audio buffer → RecordingController.handle(audio:).
- [ ] **Step 5:** Build → `BUILD SUCCEEDED`.
- [ ] **Step 6:** Manual run: log prints selected device + `1920x1080 @ 30fps` on built-in cam.
- [ ] **Step 7:** Commit: `feat: camera manager and capture delegate`.

---

## Task 12: MenuBarController + status icons

**Files:** Create `MacCam/UI/MenuBarController.swift`, add status icon assets. (Glue; verified by run.)

- [ ] **Step 1:** `NSStatusItem` with SF Symbol / template images: gray (off), green (monitoring), red blinking (recording). Blink via timer toggling image while recording.
- [ ] **Step 2:** Menu: Start/Stop Monitoring (toggles CameraManager), status line ("Idle"/"Recording…"/"Last clip: NAME"), Open clips folder… (`NSWorkspace.open` folder), Settings… (open SwiftUI window), Launch at login (checkbox → LaunchAtLogin), Quit.
- [ ] **Step 3:** Subscribe to recording/monitoring state to update icon + status line.
- [ ] **Step 4:** Build → `BUILD SUCCEEDED`.
- [ ] **Step 5:** Commit: `feat: menu bar controller with state icons`.

---

## Task 13: SettingsView (SwiftUI)

**Files:** Create `MacCam/UI/SettingsView.swift`; wire `Settings` scene in `MacCamApp`. (Glue; verified by run.)

- [ ] **Step 1:** Form bound to `SettingsStore`: camera Picker (shows selected `WxH@fps`), sensitivity Slider 0–4, min/max clip steppers, cooldown stepper, pre-roll toggle+seconds, audio toggle, FPS picker (15/24/30), quality picker, folder button (`NSOpenPanel` → FileStore.setFolder), autocleanup toggle+days, launch-at-login toggle, guard-mode toggle.
- [ ] **Step 2:** Changing camera/FPS triggers `CameraManager` reconfigure (stop→configure→start) if monitoring.
- [ ] **Step 3:** Build → `BUILD SUCCEEDED`.
- [ ] **Step 4:** Commit: `feat: settings window`.

---

## Task 14: LockMonitor (guard) + LaunchAtLogin

**Files:** Create `MacCam/System/LockMonitor.swift`, `MacCam/System/LaunchAtLogin.swift`. (Glue.)

- [ ] **Step 1:** `LaunchAtLogin`: `SMAppService.mainApp.register()/unregister()`, `isEnabled` via `.status == .enabled`.
- [ ] **Step 2:** `LockMonitor`: observe `com.apple.screenIsLocked`/`com.apple.screenIsUnlocked` on `DistributedNotificationCenter`; callbacks start/stop monitoring when guardMode on. Explicit manual Start takes priority (track `manualOverride` so unlock doesn't stop a manually started session).
- [ ] **Step 3:** Build → `BUILD SUCCEEDED`.
- [ ] **Step 4:** Commit: `feat: guard mode on screen lock and launch at login`.

---

## Task 15: AppDelegate wiring + permissions + README

**Files:** Modify `MacCam/App/AppDelegate.swift`; create `README.md`. (Glue; full integration run.)

- [ ] **Step 1:** AppDelegate constructs SettingsStore, FileStore, CameraManager, MotionDetector, RecordingController, MenuBarController, LockMonitor, LaunchAtLogin; wires delegate pipeline.
- [ ] **Step 2:** Request camera (and mic if audioEnabled) access via `AVCaptureDevice.requestAccess`; on denial show alert + open `x-apple.systempreferences:com.apple.preference.security?Privacy_Camera`.
- [ ] **Step 3:** README: build/run, permissions, settings overview, offline guarantee.
- [ ] **Step 4:** Build + full test run → `BUILD SUCCEEDED`, all tests pass.
- [ ] **Step 5:** Manual end-to-end: start monitoring → wave hand → clip appears in `~/Movies/MacCam/`, plays in QuickTime, codec hevc; stop after cooldown; rotation at maxClip; low idle CPU.
- [ ] **Step 6:** Commit: `feat: wire app, permissions, README`.

---

## Self-Review

**Spec coverage:**
- §4 max format → Task 3 + 11. §4 motion → Task 8 + 1. §5 record/FSM/rotation → Task 6 + 10. §6 storage/bookmark/cleanup → Task 5 + 9. §7 monitoring/guard → Task 12 + 14. §8 menu/settings → Task 12 + 13. §9 perf (downscale/throttle/hw HEVC/idle) → Task 8 + 10/11. §10 entitlements/permissions → Task 0 + 15. §12 defaults → Task 7. §13 edge-cases (disconnect→Task 11, denial→Task 15, bookmark fallback→Task 9, writer error→Task 10). All covered.

**Placeholder scan:** No TBD/TODO; pure-logic tasks have full test+impl code; glue tasks have concrete behavior specs and build/run verification (cannot be unit-tested without hardware — acceptable and explicit).

**Type consistency:** `FormatInfo` (width/height/maxFPS) used in Task 3 & 11. `Quality` defined Task 2, used Task 7/10/13. `RecAction`/`RecState` Task 6 used Task 10. `ClipNaming.filename/expired` Task 5 used Task 9. `MotionDetector.analyze(_:pts:)->(motion,fraction)?` Task 8 used Task 11. `Settings`/`snapshot()` Task 7 used Task 10/11. Consistent.
