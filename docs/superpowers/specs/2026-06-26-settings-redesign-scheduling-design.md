# MacCam — Settings redesign & Scheduling. Design / spec

**Date:** 2026-06-26
**Status:** approved for implementation
**Depends on:** MacCam main (capture → motion → record, disk limits, zones, audio)

Two coupled pieces in one spec: **A** a tabbed Settings redesign and **B**
weekly schedules for monitoring and recording. Both stay fully offline.

> **Follow-up (NOT in this spec): Feature C — voice-activated recording** via
> Apple SoundAnalysis (`SNClassifySoundRequest`, on-device `speech` label) as an
> additional trigger alongside motion. To be brainstormed/spec'd/built after this
> work merges. The user explicitly asked not to forget it.

---

## Feature A — Tabbed Settings

### A.1 Goal

The single large `SettingsView` Form has outgrown one screen. Split it into a
macOS `TabView` with standard preference tabs (like System Settings), each a
small focused view. This also makes room for the new Schedule tab.

### A.2 Tabs

| Tab | SF Symbol | Contents |
|---|---|---|
| Camera | `camera` | camera picker, resolution, target FPS |
| Motion | `figure.walk` | sensitivity slider, "Edit Detection Zones…" |
| Recording | `record.circle` | min/max clip, cooldown, pre-roll, record audio + microphone picker, codec, quality |
| Schedule | `calendar` | monitoring schedule + recording schedule (Feature B) |
| Storage | `internaldrive` | folder, usage, disk limits, auto-cleanup |
| Appearance | `eye` | menu-bar icon style, discreet icon |
| System | `gearshape` | guard mode, launch at login |

### A.3 Structure

- Root view `SettingsView` becomes a `TabView` composing one view per tab:
  `CameraSettingsTab`, `MotionSettingsTab`, `RecordingSettingsTab`,
  `ScheduleSettingsTab`, `StorageSettingsTab`, `AppearanceSettingsTab`,
  `SystemSettingsTab` (new files under `UI/SettingsTabs/`). Each is a `Form`
  with `.formStyle(.grouped)`.
- Shared dependencies are bundled in a lightweight value `SettingsContext` so
  each tab takes one parameter instead of many:

```swift
struct SettingsContext {
    let settings: SettingsStore          // ObservableObject
    let camera: CameraManager            // ObservableObject (resolution, device lists)
    let fileStore: FileStore
    let onReconfigure: () -> Void
    let onLaunchAtLoginChange: (Bool) -> Void
    let onEditZones: () -> Void
    let onRequestAudioAccess: () -> Void
}
```

  `SettingsStore`/`CameraManager` stay `@ObservedObject` inside each tab (passed
  through the context); the closures are plain values.
- The window stays an `AppDelegate`-managed `NSWindow` hosting
  `SettingsView(context:)`. Window size: fixed width ~480, height ~560 (tabs
  keep each pane short).

### A.4 No behavior change

All existing controls keep their bindings and side effects (e.g. camera/FPS/audio
changes still call `onReconfigure`; audio-on still calls `onRequestAudioAccess`).
This is a structural refactor plus the new Schedule tab.

---

## Feature B — Weekly schedules

### B.1 Goal

Automatically run **monitoring** and/or gate **recording** within weekly time
windows (e.g. "monitor Mon–Fri 22:00–07:00"). Two independent schedules.

### B.2 Pure model — `WeeklySchedule`

```swift
enum Weekday: Int, CaseIterable, Codable {   // 1 = Sunday … 7 = Saturday (Calendar order)
    case sun = 1, mon, tue, wed, thu, fri, sat
}

struct TimeOfDay: Codable, Equatable {       // minutes since midnight, 0...1439
    var minutes: Int
}

struct WeeklySchedule: Codable, Equatable {
    var enabled: Bool = false
    var days: Set<Weekday> = Set(Weekday.allCases)
    var start: TimeOfDay = TimeOfDay(minutes: 22 * 60)   // 22:00
    var end: TimeOfDay = TimeOfDay(minutes: 7 * 60)      // 07:00

    /// True if `enabled` and `date` falls inside the window. Overnight windows
    /// (start > end) wrap past midnight; a window's "day" is the day it STARTS.
    func isActive(at date: Date, calendar: Calendar) -> Bool
}
```

**`isActive` rules:**
- `enabled == false` → always `false`.
- Let `wd` = weekday of `date`, `m` = minutes-since-midnight of `date`.
- **Same-day window** (`start <= end`): active if `days.contains(wd)` and
  `start.minutes <= m < end.minutes`.
- **Overnight window** (`start > end`, e.g. 22:00–07:00): active if either
  - `days.contains(wd)` and `m >= start.minutes` (evening portion, the start
    day), or
  - `days.contains(previousWeekday(wd))` and `m < end.minutes` (morning portion
    belongs to the previous day's window).
- `start == end` → empty window (never active) to avoid ambiguity.

Persisted as JSON (Codable) in a single `UserDefaults` string per schedule.

### B.3 Engine — `Scheduler`

```swift
final class Scheduler {
    var onMonitoringWindowChange: ((Bool) -> Void)?   // main queue
    func update(monitoring: WeeklySchedule, recording: WeeklySchedule)
    func start(); func stop()
    func isRecordingAllowed(at date: Date) -> Bool     // recording schedule (or true if disabled)
    func isMonitoringWindowActive(at date: Date) -> Bool
}
```

- A repeating `Timer` (every 30 s, tolerance 5 s) re-evaluates the monitoring
  window. On a transition (active↔inactive) it fires `onMonitoringWindowChange`.
- `isRecordingAllowed` returns `true` when the recording schedule is disabled,
  else `recording.isActive(now)`.
- Injected `Calendar`/clock via a `now: () -> Date` for testability of the
  transition logic (the timer itself isn't unit-tested).

### B.4 Precedence (decided: manual Start wins)

Monitoring is **on** when ANY holds:
1. **Manual Start** (`manualOverride == true`) — runs until manual Stop, ignores
   schedule and guard.
2. **Guard mode** active (screen locked) — existing behavior.
3. **Monitoring-schedule** window active.

When none hold and not under manual override → monitoring stops.

To remove ambiguity between the three auto-sources, `AppDelegate` centralizes the
decision in `evaluateMonitoring()`:
- Track `screenLocked: Bool` (set by `LockMonitor` onLock/onUnlock).
- `guardActive = settings.guardMode && screenLocked`.
- `scheduleActive = scheduler.isMonitoringWindowActive(now)` (false if the
  monitoring schedule is disabled).
- `shouldAutoMonitor = guardActive || scheduleActive`.
- If `manualOverride` → do nothing (manual wins, runs until manual Stop).
- Else if `shouldAutoMonitor && !monitoring` → `startMonitoring(manual: false)`.
- Else if `!shouldAutoMonitor && monitoring` → `stopMonitoring()`.

`evaluateMonitoring()` is called from: lock/unlock handlers, the scheduler's
`onMonitoringWindowChange`, and after a manual Stop (which clears
`manualOverride`). Manual Start remains a direct path that sets `manualOverride`
and starts. This makes the guard-vs-schedule interaction well-defined (a guard
hold during a schedule-off keeps monitoring on because `guardActive` is still
true).

**Recording gate:** `RecordingController` only opens/continues clips when the
recording schedule allows it. Implementation: the controller stores the current
`recordingSchedule` (from the settings snapshot) and, in `handle(video:motion:)`,
treats `motion` as `false` when `!recordingSchedule.isActive(now)`. Disabled
schedule ⇒ always allowed (current behavior). This pauses clip creation outside
the window without stopping monitoring.

### B.5 Settings

`SettingsStore`/`AppSettings` gain `monitoringSchedule: WeeklySchedule` and
`recordingSchedule: WeeklySchedule`, persisted as JSON strings
(`monitoringSchedule`, `recordingSchedule` keys); defaults disabled.

### B.6 UI — Schedule tab

`ScheduleSettingsTab` shows two `ScheduleEditor` blocks (Monitoring, Recording),
each:
- `Toggle("Enabled")`.
- A row of 7 day chips (Mon–Sun) toggling membership in `days`.
- Two `DatePicker(.hourAndMinute)` for start/end (bound through `TimeOfDay`).
- A caption: e.g. "Active 22:00–07:00 · overnight" and "applies on Mon, Tue…".

Editing writes back the encoded schedule to `SettingsStore`; changes apply live
via the existing `objectWillChange` → `applyLiveSettings` path (which now also
pushes the schedules to `Scheduler` and `RecordingController`).

### B.7 Tests

`WeeklyScheduleTests` (pure): same-day window in/out, overnight evening + morning
portions, day-membership filtering (incl. the previous-day rule for overnight
mornings), disabled → false, `start == end` empty, boundary minutes (inclusive
start, exclusive end). `TimeOfDay` clamping. Use a fixed `Calendar`
(gregorian/UTC) and constructed `Date`s.

---

## Cross-cutting

- **New files:** `System/WeeklySchedule.swift` (pure), `System/Scheduler.swift`,
  `UI/SettingsTabs/{Camera,Motion,Recording,Schedule,Storage,Appearance,System}SettingsTab.swift`,
  `UI/ScheduleEditor.swift`, `UI/SettingsContext.swift`.
- **Edited:** `UI/SettingsView.swift` (becomes the TabView shell), `SettingsStore`
  (+2 schedules), `AppDelegate` (scheduler wiring + precedence + context),
  `RecordingController` (recording-schedule gate), `Localizable.xcstrings`,
  `CHANGELOG.md`.
- **Concurrency:** `Scheduler` timer fires on the main queue; monitoring
  start/stop already run on main. The recording gate reads an immutable
  `WeeklySchedule` value copied into `RecordingController` under its lock
  (consistent with other live settings).
- **Offline:** no network. Schedules are local time only.
- **Defaults preserve current behavior:** both schedules disabled.

## Implementation order

1. `WeeklySchedule` (+tests) → `SettingsStore` fields.
2. `Scheduler` → `AppDelegate` precedence wiring → `RecordingController` gate.
3. Settings TabView refactor (`SettingsContext` + per-tab views) → `ScheduleEditor`
   + `ScheduleSettingsTab`.
4. Localization, CHANGELOG, full build/test/lint, review.
