# Settings Redesign & Scheduling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split MacCam Settings into tabs and add weekly schedules for monitoring and recording.

**Architecture:** A pure `WeeklySchedule` value type (tested) drives a `Scheduler` (timer + transitions). `AppDelegate` centralizes monitoring precedence (manual > guard/schedule) in `evaluateMonitoring()`. `RecordingController` gates clip creation on the recording schedule. The Settings window becomes a `TabView` of small per-tab views fed by a `SettingsContext`.

**Tech Stack:** Swift 5, SwiftUI (TabView/Form), Foundation (Calendar/Timer), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-26-settings-redesign-scheduling-design.md`

**Follow-up (separate, do not build here): Feature C — voice-activated recording (SoundAnalysis speech).**

**Build/test:** `xcodebuild -project MacCam.xcodeproj -scheme MacCam -configuration Debug -derivedDataPath build -destination 'platform=macOS' test` · Lint: `swiftlint --strict`

**TDD note:** `WeeklySchedule` is strict test-first. `Scheduler`, `AppDelegate`, `RecordingController`, and the SwiftUI tabs are glue verified by build + existing tests (the recording-gate behavior is covered by a `RecordingController` unit check via an injected clock).

---

## File Structure

```
MacCam/
├── System/WeeklySchedule.swift     # NEW pure: Weekday, TimeOfDay, isActive
├── System/Scheduler.swift          # NEW: timer + monitoring-window transitions, recording gate
├── App/AppDelegate.swift           # EDIT: evaluateMonitoring(), screenLocked, scheduler wiring, context
├── Recording/RecordingController.swift  # EDIT: recording-schedule gate in handle(video:)
├── UI/SettingsContext.swift        # NEW: bundle of deps for tabs
├── UI/SettingsView.swift           # EDIT: becomes TabView shell
├── UI/SettingsTabs/CameraSettingsTab.swift      # NEW
├── UI/SettingsTabs/MotionSettingsTab.swift      # NEW
├── UI/SettingsTabs/RecordingSettingsTab.swift   # NEW
├── UI/SettingsTabs/StorageSettingsTab.swift     # NEW
├── UI/SettingsTabs/AppearanceSettingsTab.swift  # NEW
├── UI/SettingsTabs/SystemSettingsTab.swift      # NEW
├── UI/SettingsTabs/ScheduleSettingsTab.swift    # NEW
├── UI/ScheduleEditor.swift         # NEW: one schedule's editor (toggle, day chips, time pickers)
├── UI/SettingsStore.swift          # EDIT: + monitoringSchedule, recordingSchedule
├── Localizable.xcstrings           # EDIT
MacCamTests/
├── WeeklyScheduleTests.swift       # NEW
└── RecordingControllerScheduleTests.swift  # NEW (gate via injected clock)
```

---

## Task 1: WeeklySchedule (pure) — TDD

**Files:** Create `MacCam/System/WeeklySchedule.swift`, `MacCamTests/WeeklyScheduleTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MacCam

final class WeeklyScheduleTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    // 2026-06-22 is a Monday.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        DateComponents(calendar: cal, year: y, month: mo, day: d, hour: h, minute: mi).date!
    }

    func testDisabledAlwaysFalse() {
        var s = WeeklySchedule(); s.enabled = false
        XCTAssertFalse(s.isActive(at: date(2026, 6, 22, 23, 0), calendar: cal))
    }

    func testSameDayWindowInside() {
        var s = WeeklySchedule(enabled: true, days: [.mon],
                               start: TimeOfDay(minutes: 9 * 60), end: TimeOfDay(minutes: 18 * 60))
        XCTAssertTrue(s.isActive(at: date(2026, 6, 22, 10, 0), calendar: cal))  // Mon 10:00
        XCTAssertFalse(s.isActive(at: date(2026, 6, 22, 18, 0), calendar: cal)) // end exclusive
        XCTAssertTrue(s.isActive(at: date(2026, 6, 22, 9, 0), calendar: cal))   // start inclusive
        XCTAssertFalse(s.isActive(at: date(2026, 6, 23, 10, 0), calendar: cal)) // Tue not selected
    }

    func testOvernightEveningAndMorning() {
        // Mon 22:00 → 07:00. Active Mon-evening and Tue-morning (the previous day owns the morning).
        var s = WeeklySchedule(enabled: true, days: [.mon],
                               start: TimeOfDay(minutes: 22 * 60), end: TimeOfDay(minutes: 7 * 60))
        XCTAssertTrue(s.isActive(at: date(2026, 6, 22, 23, 0), calendar: cal))  // Mon 23:00 evening
        XCTAssertTrue(s.isActive(at: date(2026, 6, 23, 6, 0), calendar: cal))   // Tue 06:00 morning (Mon window)
        XCTAssertFalse(s.isActive(at: date(2026, 6, 23, 7, 0), calendar: cal))  // Tue 07:00 end exclusive
        XCTAssertFalse(s.isActive(at: date(2026, 6, 22, 21, 0), calendar: cal)) // Mon 21:00 before start
        XCTAssertFalse(s.isActive(at: date(2026, 6, 24, 6, 0), calendar: cal))  // Wed 06:00 (Tue not selected)
    }

    func testEmptyWindowWhenStartEqualsEnd() {
        var s = WeeklySchedule(enabled: true, days: Set(Weekday.allCases),
                               start: TimeOfDay(minutes: 600), end: TimeOfDay(minutes: 600))
        XCTAssertFalse(s.isActive(at: date(2026, 6, 22, 10, 0), calendar: cal))
    }

    func testCodableRoundTrip() throws {
        let s = WeeklySchedule(enabled: true, days: [.fri, .sat],
                               start: TimeOfDay(minutes: 90), end: TimeOfDay(minutes: 120))
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(WeeklySchedule.self, from: data), s)
    }
}
```

- [ ] **Step 2: Run → FAIL** (types undefined).
- [ ] **Step 3: Implement**

```swift
import Foundation

enum Weekday: Int, CaseIterable, Codable {
    case sun = 1, mon, tue, wed, thu, fri, sat

    var previous: Weekday { Weekday(rawValue: rawValue == 1 ? 7 : rawValue - 1)! }
}

struct TimeOfDay: Codable, Equatable {
    var minutes: Int
    init(minutes: Int) { self.minutes = min(1439, max(0, minutes)) }
    var hour: Int { minutes / 60 }
    var minute: Int { minutes % 60 }
}

struct WeeklySchedule: Codable, Equatable {
    var enabled: Bool
    var days: Set<Weekday>
    var start: TimeOfDay
    var end: TimeOfDay

    init(enabled: Bool = false,
         days: Set<Weekday> = Set(Weekday.allCases),
         start: TimeOfDay = TimeOfDay(minutes: 22 * 60),
         end: TimeOfDay = TimeOfDay(minutes: 7 * 60)) {
        self.enabled = enabled
        self.days = days
        self.start = start
        self.end = end
    }

    func isActive(at date: Date, calendar: Calendar) -> Bool {
        guard enabled, start.minutes != end.minutes else { return false }
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wdRaw = comps.weekday, let wd = Weekday(rawValue: wdRaw) else { return false }
        let m = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        if start.minutes < end.minutes {
            return days.contains(wd) && m >= start.minutes && m < end.minutes
        }
        // Overnight: evening part belongs to today's window; morning part to the previous day's.
        if days.contains(wd) && m >= start.minutes { return true }
        if days.contains(wd.previous) && m < end.minutes { return true }
        return false
    }
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat: WeeklySchedule pure model`.

---

## Task 2: SettingsStore schedule fields

**Files:** Modify `MacCam/UI/SettingsStore.swift` (glue; build-verified).

- [ ] **Step 1:** Add two `@Published` schedules persisted as JSON strings. Add to `AppSettings`, `snapshot()`, keys, and init. Add a private helper:

```swift
// In SettingsStore, near other Key entries:
static let monitoringSchedule = "monitoringSchedule"
static let recordingSchedule = "recordingSchedule"
```

```swift
// Published properties (encode on write):
@Published var monitoringSchedule: WeeklySchedule {
    didSet { defaults.set(Self.encode(monitoringSchedule), forKey: Key.monitoringSchedule) }
}
@Published var recordingSchedule: WeeklySchedule {
    didSet { defaults.set(Self.encode(recordingSchedule), forKey: Key.recordingSchedule) }
}

private static func encode(_ s: WeeklySchedule) -> String {
    (try? String(data: JSONEncoder().encode(s), encoding: .utf8) ?? nil) ?? "" ?? ""
}
private static func decode(_ string: String?) -> WeeklySchedule {
    guard let string, let data = string.data(using: .utf8),
          let s = try? JSONDecoder().decode(WeeklySchedule.self, from: data) else { return WeeklySchedule() }
    return s
}
```

Replace the brittle `encode` above with this exact, compiling version:

```swift
private static func encode(_ schedule: WeeklySchedule) -> String {
    guard let data = try? JSONEncoder().encode(schedule),
          let string = String(data: data, encoding: .utf8) else { return "" }
    return string
}
```

- [ ] **Step 2:** In `init`, read them: `monitoringSchedule = Self.decode(defaults.string(forKey: Key.monitoringSchedule))` and the same for recording. Add both to the `AppSettings` struct and to `snapshot()`.
- [ ] **Step 3: Build** → `BUILD SUCCEEDED`.
- [ ] **Step 4: Commit** `feat: persist monitoring/recording schedules`.

---

## Task 3: Scheduler

**Files:** Create `MacCam/System/Scheduler.swift` (glue around the tested model).

- [ ] **Step 1:** Implement:

```swift
import Foundation

/// Evaluates the monitoring window on a timer and exposes the recording gate.
/// All callbacks fire on the main queue.
final class Scheduler {
    var onMonitoringWindowChange: ((Bool) -> Void)?

    private var monitoring = WeeklySchedule()
    private var recording = WeeklySchedule()
    private var calendar = Calendar.current
    private let now: () -> Date
    private var timer: Timer?
    private var lastActive = false

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func update(monitoring: WeeklySchedule, recording: WeeklySchedule) {
        self.monitoring = monitoring
        self.recording = recording
        evaluate()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.evaluate() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func isMonitoringWindowActive(at date: Date = Date()) -> Bool {
        monitoring.isActive(at: date, calendar: calendar)
    }

    func isRecordingAllowed(at date: Date = Date()) -> Bool {
        guard recording.enabled else { return true }
        return recording.isActive(at: date, calendar: calendar)
    }

    private func evaluate() {
        let active = isMonitoringWindowActive(at: now())
        guard active != lastActive else { return }
        lastActive = active
        DispatchQueue.main.async { [weak self] in self?.onMonitoringWindowChange?(active) }
    }
}
```

- [ ] **Step 2: Build** → `BUILD SUCCEEDED`.
- [ ] **Step 3: Commit** `feat: Scheduler timer and recording gate`.

---

## Task 4: RecordingController recording-schedule gate — TDD

**Files:** Modify `MacCam/Recording/RecordingController.swift`, create `MacCamTests/RecordingControllerScheduleTests.swift`

The controller already takes `AppSettings` via `updateSettings`. Add a recording
gate driven by the snapshot's `recordingSchedule`, evaluated against an injectable
clock so it's unit-testable.

- [ ] **Step 1: Write failing test** — feed a video frame with motion while the
  recording schedule is inactive, assert no clip starts; then active, assert it
  starts.

```swift
import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import MacCam

final class RecordingControllerScheduleTests: XCTestCase {
    private func pixelSample(pts: CMTime) -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pb!, formatDescriptionOut: &fmt)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb!,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt!,
            sampleTiming: &timing, sampleBufferOut: &sb)
        return sb!
    }

    private func settings(_ schedule: WeeklySchedule) -> AppSettings {
        AppSettings(cameraID: nil, targetFPS: 30, sensitivity: 2, pixelDelta: 25,
            postMotionCooldown: 5, minClipLength: 1, maxClipLength: 60, preRollEnabled: false,
            preRoll: 3, audioEnabled: false, audioDeviceID: nil, codec: .hevc, quality: .medium,
            autoCleanup: false, cleanupDays: 14, guardMode: false, maxStorageGB: 0,
            minFreeSpaceGB: 0, diskLimitPolicy: .loop, detectionMask: "",
            monitoringSchedule: WeeklySchedule(), recordingSchedule: schedule)
    }

    func testDisabledScheduleRecordsOnMotion() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Sched-\(ProcessInfo.processInfo.globallyUniqueString)")
        let fs = FileStore(defaults: .standard, defaultOverride: tmp)
        let rc = RecordingController(fileStore: fs, settings: settings(WeeklySchedule()))
        rc.clock = { Date(timeIntervalSince1970: 0) }
        rc.handle(video: pixelSample(pts: CMTime(value: 0, timescale: 30)), motion: true)
        XCTAssertTrue(rc.isRecording)
        rc.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    func testInactiveScheduleSuppressesRecording() {
        // Schedule active only Sunday 00:00–00:30; clock is epoch 0 = Thursday 1970-01-01.
        var sched = WeeklySchedule(enabled: true, days: [.sun],
            start: TimeOfDay(minutes: 0), end: TimeOfDay(minutes: 30))
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Sched-\(ProcessInfo.processInfo.globallyUniqueString)")
        let fs = FileStore(defaults: .standard, defaultOverride: tmp)
        let rc = RecordingController(fileStore: fs, settings: settings(sched))
        rc.clock = { Date(timeIntervalSince1970: 0) }   // Thursday → not in window
        rc.handle(video: pixelSample(pts: CMTime(value: 0, timescale: 30)), motion: true)
        XCTAssertFalse(rc.isRecording)
        rc.stop()
        try? FileManager.default.removeItem(at: tmp)
    }
}
```

- [ ] **Step 2: Run → FAIL** (`clock` undefined / motion not gated).
- [ ] **Step 3: Implement.** In `RecordingController` add an injectable clock and store the schedule from the snapshot; gate motion in `handle(video:)`.

```swift
// Near other stored state:
var clock: () -> Date = Date.init
private var recordingSchedule = WeeklySchedule()
private var scheduleCalendar = Calendar.current
```

In `applyDiskLimits(_:)` (already called from init/updateSettings) — or add a
sibling call — capture the schedule:

```swift
// Add inside updateSettings(_:) and init, right after applyDiskLimits(s):
recordingSchedule = s.recordingSchedule
```

In `handle(video:motion:)`, replace the first use of `motion` with a gated value
at the very top of the method body (after computing `now`/locking is fine; do it
before `fsm.step`):

```swift
let allowed = !recordingSchedule.enabled
    || recordingSchedule.isActive(at: clock(), calendar: scheduleCalendar)
let effectiveMotion = motion && allowed
```
Then use `effectiveMotion` in `fsm.step(motion: effectiveMotion, now: now)` and in
the pre-roll push guard `if fsm.state == .idle && settings.preRollEnabled` (push is
unaffected; only the FSM input changes).

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat: recording-schedule gate in RecordingController`.

---

## Task 5: AppDelegate — scheduler wiring + evaluateMonitoring

**Files:** Modify `MacCam/App/AppDelegate.swift` (glue).

- [ ] **Step 1:** Add state + scheduler. Near the other properties:

```swift
private let scheduler = Scheduler()
private var screenLocked = false
```

- [ ] **Step 2:** In `applicationDidFinishLaunching`, after constructing the
  recorder and before `lockMonitor.start()`, wire the scheduler:

```swift
scheduler.onMonitoringWindowChange = { [weak self] _ in self?.evaluateMonitoring() }
let snap0 = settings.snapshot()
scheduler.update(monitoring: snap0.monitoringSchedule, recording: snap0.recordingSchedule)
scheduler.start()
```

- [ ] **Step 3:** Replace the guard wiring so lock/unlock set `screenLocked` and
  re-evaluate, instead of starting/stopping directly:

```swift
private func wireGuard() {
    lockMonitor.onLock = { [weak self] in
        guard let self else { return }
        self.screenLocked = true
        self.evaluateMonitoring()
    }
    lockMonitor.onUnlock = { [weak self] in
        guard let self else { return }
        self.screenLocked = false
        self.evaluateMonitoring()
    }
}
```

- [ ] **Step 4:** Add the central evaluator and use it on manual Stop:

```swift
/// Auto-monitoring sources (guard + schedule). Manual Start overrides both.
private func evaluateMonitoring() {
    if manualOverride { return }
    let guardActive = settings.guardMode && screenLocked
    let scheduleActive = scheduler.isMonitoringWindowActive()
    let shouldMonitor = guardActive || scheduleActive
    if shouldMonitor && !monitoring {
        startMonitoring(manual: false)
    } else if !shouldMonitor && monitoring {
        stopMonitoring()
    }
}
```

In `stopMonitoring()`, after `monitoring = false` and clearing `manualOverride`,
call `evaluateMonitoring()` so an active guard/schedule can immediately re-arm:

```swift
// at the end of stopMonitoring():
evaluateMonitoring()
```
(Guard against recursion: `evaluateMonitoring` only acts on a state change, and
`stopMonitoring` already set `monitoring = false`, so re-arm starts at most once.)

- [ ] **Step 5:** In `applyLiveSettings()`, push schedules to the scheduler and
  re-evaluate (so editing a schedule applies immediately):

```swift
// inside applyLiveSettings(), after recorder.updateSettings(snap):
scheduler.update(monitoring: snap.monitoringSchedule, recording: snap.recordingSchedule)
evaluateMonitoring()
```
Note `applyLiveSettings()` currently `guard monitoring else { return }` early —
change it so the scheduler update runs regardless of `monitoring`:

```swift
private func applyLiveSettings() {
    let snap = settings.snapshot()
    scheduler.update(monitoring: snap.monitoringSchedule, recording: snap.recordingSchedule)
    if monitoring {
        applyToDetector(snap)
        recorder.updateSettings(snap)
    }
    evaluateMonitoring()
}
```

- [ ] **Step 6: Build + test** → `BUILD SUCCEEDED`, all prior tests pass.
- [ ] **Step 7: Commit** `feat: schedule-driven monitoring with manual precedence`.

---

## Task 6: SettingsContext + TabView shell

**Files:** Create `MacCam/UI/SettingsContext.swift`; rewrite `MacCam/UI/SettingsView.swift` as the TabView shell. (Glue; build-verified.)

- [ ] **Step 1:** Create `SettingsContext.swift`:

```swift
import Foundation

struct SettingsContext {
    let settings: SettingsStore
    let camera: CameraManager
    let fileStore: FileStore
    let onReconfigure: () -> Void
    let onLaunchAtLoginChange: (Bool) -> Void
    let onEditZones: () -> Void
    let onRequestAudioAccess: () -> Void
}
```

- [ ] **Step 2:** Rewrite `SettingsView` as a `TabView` (keep `@ObservedObject`
  refs so SwiftUI observes changes):

```swift
import SwiftUI

struct SettingsView: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var camera: CameraManager

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
        self.camera = context.camera
    }

    var body: some View {
        TabView {
            CameraSettingsTab(context: context)
                .tabItem { Label("Camera", systemImage: "camera") }
            MotionSettingsTab(context: context)
                .tabItem { Label("Motion", systemImage: "figure.walk") }
            RecordingSettingsTab(context: context)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            ScheduleSettingsTab(context: context)
                .tabItem { Label("Schedule", systemImage: "calendar") }
            StorageSettingsTab(context: context)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            AppearanceSettingsTab(context: context)
                .tabItem { Label("Appearance", systemImage: "eye") }
            SystemSettingsTab(context: context)
                .tabItem { Label("System", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 560)
    }
}
```

- [ ] **Step 3:** Update `AppDelegate.openSettings()` to build a `SettingsContext`
  and pass it: `SettingsView(context: SettingsContext(settings: settings, camera: camera, fileStore: fileStore, onReconfigure: { [weak self] in self?.reconfigureIfMonitoring() }, onLaunchAtLoginChange: { [weak self] e in self?.setLaunchAtLogin(e) }, onEditZones: { [weak self] in self?.openZoneEditor() }, onRequestAudioAccess: { [weak self] in self?.requestAudioAccessIfNeeded() }))`.
- [ ] **Step 4: Build** (will fail until tab files exist — that's Task 7). Skip running until Task 7.

---

## Task 7: Per-tab views (move existing controls)

**Files:** Create the seven tab files under `MacCam/UI/SettingsTabs/`. Move the
existing `SettingsView` sections verbatim into the matching tab (same bindings,
same side effects). (Glue; build + run verified.)

- [ ] **Step 1:** `CameraSettingsTab.swift` — the current "Camera" `Section`
  contents (camera Picker → `settings.cameraID` + `onReconfigure`, resolution
  `LabeledContent`, Target FPS Picker), wrapped in a `Form { Section("Camera") {...} }`
  with `@ObservedObject var settings` and `@ObservedObject var camera` taken from
  `context`, plus the `cameras` `@State` + `.onAppear` loader. Use this skeleton
  for every tab:

```swift
import SwiftUI
import AppKit

struct CameraSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var camera: CameraManager
    @State private var cameras: [(id: String, name: String)] = []

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
        self.camera = context.camera
    }

    var body: some View {
        Form {
            Picker("Camera", selection: Binding(
                get: { settings.cameraID ?? cameras.first?.id ?? "" },
                set: { settings.cameraID = $0; context.onReconfigure() })) {
                ForEach(cameras, id: \.id) { Text($0.name).tag($0.id) }
            }
            LabeledContent("Resolution", value: camera.formatDescription)
            Picker("Target FPS", selection: Binding(
                get: { settings.targetFPS },
                set: { settings.targetFPS = $0; context.onReconfigure() })) {
                Text("15").tag(15); Text("24").tag(24); Text("30").tag(30)
            }
        }
        .formStyle(.grouped)
        .onAppear { cameras = camera.availableCameras().map { ($0.uniqueID, $0.localizedName) } }
    }
}
```

- [ ] **Step 2:** `MotionSettingsTab.swift` — the "Motion" section (sensitivity
  slider; "Edit Detection Zones…" button → `context.onEditZones()`; the
  "N zone cells ignored" caption via `MotionMask(encoded:)`).
- [ ] **Step 3:** `RecordingSettingsTab.swift` — the "Recording" section
  (min/max clip steppers, cooldown stepper, pre-roll toggle+stepper, Record audio
  toggle → `settings.audioEnabled` + `context.onReconfigure()` + `if $0 { context.onRequestAudioAccess() }`,
  Microphone picker when `audioEnabled` with `microphones` `@State` loaded from
  `camera.availableMicrophones()`, Codec picker, Quality picker).
- [ ] **Step 4:** `StorageSettingsTab.swift` — the "Storage" section (Folder
  `LabeledContent`, "Choose Folder…" button + `chooseFolder()` using `NSOpenPanel`
  and `context.fileStore.setFolder`, Usage `LabeledContent` + `refreshUsage()`,
  auto-cleanup toggle+stepper, max-storage stepper, keep-free stepper, policy
  Picker).
- [ ] **Step 5:** `AppearanceSettingsTab.swift` — the "Appearance & Privacy"
  section (menu-bar style Picker; discreet-icon Picker + caption when discreet).
- [ ] **Step 6:** `SystemSettingsTab.swift` — the "System" section (guard-mode
  toggle bound to `settings.guardMode`; launch-at-login toggle →
  `context.onLaunchAtLoginChange`).
- [ ] **Step 7:** `ScheduleSettingsTab.swift` — placeholder body for now
  (filled by Task 8): `Form { Text("Schedule") }.formStyle(.grouped)`.
- [ ] **Step 8: Build + test** → `BUILD SUCCEEDED`, all tests pass.
- [ ] **Step 9: Manual run** — open Settings, confirm all seven tabs render and
  every control still works (camera switch, audio toggle prompts, folder picker).
- [ ] **Step 10: Commit** `refactor: split Settings into tabs via SettingsContext`.

---

## Task 8: ScheduleEditor + ScheduleSettingsTab

**Files:** Create `MacCam/UI/ScheduleEditor.swift`; fill `ScheduleSettingsTab.swift`. (Glue; run-verified.)

- [ ] **Step 1:** `ScheduleEditor.swift` — one schedule's editor bound to a
  `Binding<WeeklySchedule>`:

```swift
import SwiftUI

struct ScheduleEditor: View {
    let title: LocalizedStringKey
    @Binding var schedule: WeeklySchedule
    var onChange: () -> Void

    private let order: [(Weekday, String)] = [
        (.mon, "Mon"), (.tue, "Tue"), (.wed, "Wed"), (.thu, "Thu"),
        (.fri, "Fri"), (.sat, "Sat"), (.sun, "Sun")]

    var body: some View {
        Section(title) {
            Toggle("Enabled", isOn: Binding(
                get: { schedule.enabled },
                set: { schedule.enabled = $0; onChange() }))
            if schedule.enabled {
                HStack(spacing: 4) {
                    ForEach(order, id: \.0) { day, label in
                        let on = schedule.days.contains(day)
                        Button(label) {
                            if on { schedule.days.remove(day) } else { schedule.days.insert(day) }
                            onChange()
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .gray)
                    }
                }
                DatePicker("Start", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                Text("Overnight windows (start after end) span midnight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<WeeklySchedule, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: {
                let tod = schedule[keyPath: keyPath]
                return Calendar.current.date(from: DateComponents(hour: tod.hour, minute: tod.minute)) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                schedule[keyPath: keyPath] = TimeOfDay(minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
                onChange()
            })
    }
}
```

- [ ] **Step 2:** Fill `ScheduleSettingsTab.swift`:

```swift
import SwiftUI

struct ScheduleSettingsTab: View {
    let context: SettingsContext
    @ObservedObject private var settings: SettingsStore

    init(context: SettingsContext) {
        self.context = context
        self.settings = context.settings
    }

    var body: some View {
        Form {
            ScheduleEditor(title: "Monitoring schedule",
                           schedule: $settings.monitoringSchedule,
                           onChange: context.onReconfigure)
            ScheduleEditor(title: "Recording schedule",
                           schedule: $settings.recordingSchedule,
                           onChange: context.onReconfigure)
        }
        .formStyle(.grouped)
    }
}
```

(`context.onReconfigure` → `reconfigureIfMonitoring`, but schedule changes also
flow through `applyLiveSettings` via `objectWillChange`, which is what pushes them
to the `Scheduler`. `onReconfigure` is harmless here; the live path does the work.)

- [ ] **Step 3: Build + test** → `BUILD SUCCEEDED`, all tests pass.
- [ ] **Step 4: Manual run** — set a monitoring schedule window covering "now",
  confirm monitoring auto-starts; set a recording schedule excluding "now",
  confirm motion does not record while monitoring runs.
- [ ] **Step 5: Commit** `feat: schedule editor UI`.

---

## Task 9: Localization + CHANGELOG + final verification

**Files:** Modify `MacCam/Localizable.xcstrings`, `CHANGELOG.md`.

- [ ] **Step 1:** Add EN→RU for new user-facing strings: tab labels
  `"Camera"`(exists), `"Motion"`(exists), `"Recording"`(exists), `"Schedule"`→"Расписание",
  `"Storage"`(exists), `"Appearance"`→"Внешний вид", `"System"`(exists);
  `"Microphone"`(exists); `"Monitoring schedule"`→"Расписание наблюдения",
  `"Recording schedule"`→"Расписание записи", `"Enabled"`→"Включено",
  `"Start"`→"Начало", `"End"`→"Конец",
  `"Overnight windows (start after end) span midnight."`→"Ночные окна (начало позже конца) переходят через полночь.",
  and weekday labels `"Mon"`→"Пн" … `"Sun"`→"Вс". Use the existing entry format.
- [ ] **Step 2:** `CHANGELOG.md` Unreleased → Added: "Tabbed Settings window."
  and "Weekly schedules for monitoring (auto start/stop) and recording (gate
  clips to time windows), with manual-start priority."
- [ ] **Step 3: Lint** `swiftlint --strict` → 0 violations.
- [ ] **Step 4: Full test** `make test` → all tests pass (prior + WeeklySchedule +
  RecordingControllerSchedule).
- [ ] **Step 5: Commit** `feat: localize settings tabs + schedules, changelog`.

---

## Self-Review

**Spec coverage:**
- A.2 tabs → Tasks 6–8. A.3 SettingsContext/structure → Task 6. A.4 no-behavior-change → Task 7 (verbatim move + manual check).
- B.2 WeeklySchedule → Task 1. B.3 Scheduler → Task 3. B.4 precedence/evaluateMonitoring → Task 5. B.5 settings → Task 2. B.6 Schedule UI → Task 8. B.7 tests → Task 1 + Task 4.
- Cross-cutting localization/CHANGELOG → Task 9. All covered.

**Placeholder scan:** Removed the brittle first `encode` draft in Task 2 (replaced with the exact compiling version). Tab tasks 2–6 reference "the current X section" but each names the exact controls and bindings to move; the skeleton in Task 7 Step 1 shows the full pattern. No TBD/TODO. ScheduleSettingsTab Task 7 placeholder is explicitly replaced in Task 8.

**Type consistency:** `WeeklySchedule(enabled:days:start:end:)`, `TimeOfDay(minutes:)`, `Weekday` (+`.previous`) defined Task 1, used Tasks 2–8. `Scheduler` (`update`/`start`/`isMonitoringWindowActive`/`isRecordingAllowed`/`onMonitoringWindowChange`) Task 3, used Task 5. `RecordingController.clock` Task 4 used by tests. `SettingsContext` Task 6 used Tasks 6–8. `monitoringSchedule`/`recordingSchedule` settings Task 2 used Tasks 3/4/5/8. Consistent.
