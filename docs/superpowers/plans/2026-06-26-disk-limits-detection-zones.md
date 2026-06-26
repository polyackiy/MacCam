# Disk Limits & Detection Zones Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add disk-space limits (loop/stop) and ignore-zone motion masking to MacCam, fully offline.

**Architecture:** Two independent features. Pure logic (storage deletion selection, mask encoding/expansion) goes into testable seams (`StorageMath`, `MotionMask`); the recording controller consults a storage gate at clip boundaries; the motion detector applies a thread-staged ignore mask on its analysis queue; a snapshot-backed grid editor edits the mask.

**Tech Stack:** Swift 5.x, AVFoundation, vImage/Accelerate, SwiftUI + AppKit, XCTest. Build/test via `make test`; lint via `swiftlint --strict`.

**Spec:** `docs/superpowers/specs/2026-06-26-disk-limits-detection-zones-design.md`

**Build/test commands:**
- Test: `xcodebuild -project MacCam.xcodeproj -scheme MacCam -configuration Debug -derivedDataPath build -destination 'platform=macOS' test`
- Lint: `swiftlint --strict`

**TDD note:** Pure seams (`StorageMath`, `MotionMask`) and the masked `MotionDetector` are strict test-first. AVFoundation/AppKit glue (`FileStore` enumeration, `RecordingController` gate wiring, `CameraManager.captureSnapshot`, `ZoneEditorView`, settings) is implemented then verified by build + existing integration tests.

---

## File Structure

```
MacCam/
├── Storage/StorageMath.swift          # NEW pure: clipsToDelete / overLimit / gbToBytes
├── Storage/FileStore.swift            # EDIT: usage, free space, enforce
├── Recording/RecordingController.swift# EDIT: storage gate + onStorageStop, protected URLs
├── Motion/MotionMask.swift            # NEW pure: 16x9 mask encode/expand
├── Motion/MotionDetector.swift        # EDIT: thread-staged mask, masked analyze
├── Capture/CameraManager.swift        # EDIT: captureSnapshot(_:)
├── UI/ZoneEditorView.swift            # NEW: snapshot + grid editor
├── UI/SettingsStore.swift             # EDIT: disk + mask settings
├── UI/SettingsView.swift              # EDIT: Storage section + zone editor button
├── App/AppDelegate.swift              # EDIT: gate wiring, onStorageStop, zone window
├── Localizable.xcstrings              # EDIT: new EN/RU strings
MacCamTests/
├── StorageMathTests.swift             # NEW
├── MotionMaskTests.swift              # NEW
└── MotionDetectorTests.swift          # EDIT: masked cases
```

---

## Task 1: StorageMath (pure) — TDD

**Files:** Create `MacCam/Storage/StorageMath.swift`, `MacCamTests/StorageMathTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import MacCam

final class StorageMathTests: XCTestCase {
    private func f(_ name: String, _ size: Int64, _ day: Int) -> ClipFile {
        ClipFile(url: URL(fileURLWithPath: "/c/\(name)"),
                 size: size,
                 modified: Date(timeIntervalSince1970: Double(day) * 86400))
    }

    func testGbToBytes() {
        XCTAssertEqual(StorageMath.gbToBytes(2), 2_000_000_000)
        XCTAssertEqual(StorageMath.gbToBytes(0), 0)
    }

    func testDeletesOldestUntilUnderSizeCap() {
        let files = [f("old", 5, 1), f("mid", 5, 2), f("new", 5, 3)] // total 15
        let del = StorageMath.clipsToDelete(
            files: files, totalBytes: 15, freeBytes: 100,
            maxBytes: 8, minFreeBytes: 0, protecting: [])
        XCTAssertEqual(del.map { $0.lastPathComponent }, ["old", "mid"]) // 15->10->5 <= 8
    }

    func testDeletesUntilFreeFloorMet() {
        let files = [f("old", 10, 1), f("new", 10, 2)]
        let del = StorageMath.clipsToDelete(
            files: files, totalBytes: 20, freeBytes: 5,
            maxBytes: 0, minFreeBytes: 12, protecting: []) // need free>=12: delete old -> free 15
        XCTAssertEqual(del.map { $0.lastPathComponent }, ["old"])
    }

    func testNeverDeletesProtected() {
        let files = [f("old", 10, 1), f("new", 10, 2)]
        let protectedURL = URL(fileURLWithPath: "/c/old")
        let del = StorageMath.clipsToDelete(
            files: files, totalBytes: 20, freeBytes: 0,
            maxBytes: 5, minFreeBytes: 0, protecting: [protectedURL])
        XCTAssertEqual(del.map { $0.lastPathComponent }, ["new"]) // old protected, only new deletable
    }

    func testZeroLimitsMeanNoDeletion() {
        let files = [f("a", 10, 1)]
        XCTAssertTrue(StorageMath.clipsToDelete(
            files: files, totalBytes: 10, freeBytes: 1,
            maxBytes: 0, minFreeBytes: 0, protecting: []).isEmpty)
    }

    func testOverLimit() {
        XCTAssertTrue(StorageMath.overLimit(totalBytes: 10, freeBytes: 100, maxBytes: 8, minFreeBytes: 0))
        XCTAssertTrue(StorageMath.overLimit(totalBytes: 1, freeBytes: 3, maxBytes: 0, minFreeBytes: 5))
        XCTAssertFalse(StorageMath.overLimit(totalBytes: 1, freeBytes: 100, maxBytes: 0, minFreeBytes: 0))
    }
}
```

- [ ] **Step 2: Run → FAIL** (`StorageMath` undefined).
- [ ] **Step 3: Implement**

```swift
import Foundation

struct ClipFile: Equatable {
    let url: URL
    let size: Int64
    let modified: Date
}

enum StorageMath {
    static func gbToBytes(_ gb: Double) -> Int64 { Int64((gb * 1_000_000_000).rounded()) }

    static func overLimit(totalBytes: Int64, freeBytes: Int64,
                          maxBytes: Int64, minFreeBytes: Int64) -> Bool {
        (maxBytes > 0 && totalBytes > maxBytes) || (minFreeBytes > 0 && freeBytes < minFreeBytes)
    }

    static func clipsToDelete(
        files: [ClipFile], totalBytes: Int64, freeBytes: Int64,
        maxBytes: Int64, minFreeBytes: Int64, protecting: Set<URL>
    ) -> [URL] {
        guard maxBytes > 0 || minFreeBytes > 0 else { return [] }
        var total = totalBytes, free = freeBytes
        var result: [URL] = []
        let candidates = files
            .filter { !protecting.contains($0.url) }
            .sorted { $0.modified < $1.modified } // oldest first
        for clip in candidates {
            if !overLimit(totalBytes: total, freeBytes: free, maxBytes: maxBytes, minFreeBytes: minFreeBytes) {
                break
            }
            result.append(clip.url)
            total -= clip.size
            free += clip.size
        }
        return result
    }
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat: StorageMath pure deletion selection`.

---

## Task 2: FileStore usage / free space / enforce

**Files:** Modify `MacCam/Storage/FileStore.swift` (glue; verified by build).

- [ ] **Step 1:** Add `clipFiles()`:

```swift
func clipFiles() -> [ClipFile] {
    let folder = currentFolder()
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    guard let items = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
    return items.filter { $0.pathExtension.lowercased() == "mov" }.compactMap { url in
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let date = v?.contentModificationDate, let size = v?.fileSize else { return nil }
        return ClipFile(url: url, size: Int64(size), modified: date)
    }
}
```

- [ ] **Step 2:** Add usage + free space:

```swift
func folderUsage() -> (count: Int, totalBytes: Int64) {
    let files = clipFiles()
    return (files.count, files.reduce(0) { $0 + $1.size })
}

func volumeFreeBytes() -> Int64 {
    let url = currentFolder()
    let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return Int64(v?.volumeAvailableCapacityForImportantUsage ?? 0)
}
```

- [ ] **Step 3:** Add enforce:

```swift
@discardableResult
func enforce(maxBytes: Int64, minFreeBytes: Int64, protecting: Set<URL>) -> Bool {
    let files = clipFiles()
    let total = files.reduce(0) { $0 + $1.size }
    let free = volumeFreeBytes()
    let toDelete = StorageMath.clipsToDelete(
        files: files, totalBytes: total, freeBytes: free,
        maxBytes: maxBytes, minFreeBytes: minFreeBytes, protecting: protecting)
    for url in toDelete { try? FileManager.default.removeItem(at: url) }
    let newTotal = total - toDelete.reduce(0) { acc, url in
        acc + (files.first { $0.url == url }?.size ?? 0) }
    let newFree = free + (total - newTotal)
    return !StorageMath.overLimit(totalBytes: newTotal, freeBytes: newFree,
                                  maxBytes: maxBytes, minFreeBytes: minFreeBytes)
}
```

- [ ] **Step 4: Build** → `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `feat: FileStore disk usage and enforcement`.

---

## Task 3: RecordingController storage gate

**Files:** Modify `MacCam/Recording/RecordingController.swift` (glue).

- [ ] **Step 1:** Add types + hooks near the top of the class:

```swift
enum StorageDecision { case ok, stop }
var storageGate: ((_ protecting: Set<URL>) -> StorageDecision)?
var onStorageStop: (() -> Void)?
private var finalizingURLs: Set<URL> = []
```

- [ ] **Step 2:** Add a helper that gates opening and returns whether to proceed. Place above `openWriter`:

```swift
/// Returns true if a new clip may be opened. On .stop, fires onStorageStop.
private func storageAllowsNewClip() -> Bool {
    guard let gate = storageGate else { return true }
    let protectedURLs = finalizingURLs.union(currentURL.map { [$0] } ?? [])
    if gate(protectedURLs) == .stop {
        DispatchQueue.main.async { [weak self] in self?.onStorageStop?() }
        return false
    }
    return true
}
```

- [ ] **Step 3:** Track the current writer URL. In the class add `private var currentURL: URL?`, set it in `openWriter` right after computing `url` (`currentURL = url`), and in `finishWriter` move it into `finalizingURLs` for the duration of finalization:

```swift
// inside finishWriter(), before w.finishWriting:
if let u = currentURL { finalizingURLs.insert(u) }
let finishedURL = currentURL
// inside the finishWriting completion closure, after lock:
if let fu = finishedURL { self.finalizingURLs.remove(fu) }
// and set currentURL = nil in the synchronous reset block
```

- [ ] **Step 4:** Gate the two open sites in `handle(video:motion:)`:

```swift
case .startClip:
    guard storageAllowsNewClip() else { break }
    // ... existing pre-roll / open logic ...

case .rotate:
    finishWriter()
    guard storageAllowsNewClip() else { break }
    openWriter(dimensionsFrom: sampleBuffer, startPTS: pts)
    appendVideo(sampleBuffer)
```

- [ ] **Step 5: Build** → `BUILD SUCCEEDED`.
- [ ] **Step 6: Commit** `feat: recording controller storage gate`.

---

## Task 4: Disk settings + AppDelegate wiring + Settings UI

**Files:** Modify `SettingsStore.swift`, `App/AppDelegate.swift`, `UI/SettingsView.swift` (glue).

- [ ] **Step 1:** In `SettingsStore.swift` add the enum + properties:

```swift
enum DiskLimitPolicy: String, CaseIterable, Identifiable {
    case loop, stop
    var id: String { rawValue }
    var label: String { self == .loop ? "Loop (delete oldest)" : "Stop & notify" }
}
```
Add `@Published var maxStorageGB: Double`, `minFreeSpaceGB: Double`, `diskLimitPolicy: DiskLimitPolicy`, with UserDefaults keys `maxStorageGB`/`minFreeSpaceGB`/`diskLimitPolicy`, registered defaults `0.0`, `0.0`, `DiskLimitPolicy.loop.rawValue`, init reads, and add them to `AppSettings` + `snapshot()`.

- [ ] **Step 2:** In `AppDelegate`, wire the gate after constructing `recorder` in `applicationDidFinishLaunching`:

```swift
recorder.storageGate = { [weak self] protectedURLs in
    guard let self else { return .ok }
    let snap = self.settings.snapshot()
    let maxB = StorageMath.gbToBytes(snap.maxStorageGB)
    let minFree = StorageMath.gbToBytes(snap.minFreeSpaceGB)
    if maxB == 0 && minFree == 0 { return .ok }
    if snap.diskLimitPolicy == .loop {
        self.fileStore.enforce(maxBytes: maxB, minFreeBytes: minFree, protecting: protectedURLs)
        return .ok
    } else {
        let total = self.fileStore.folderUsage().totalBytes
        let free = self.fileStore.volumeFreeBytes()
        return StorageMath.overLimit(totalBytes: total, freeBytes: free,
                                     maxBytes: maxB, minFreeBytes: minFree) ? .stop : .ok
    }
}
recorder.onStorageStop = { [weak self] in
    self?.stopMonitoring()
    self?.menuBar.setState(.off, statusText: loc("Stopped: disk limit reached"))
}
```

- [ ] **Step 3:** In `SettingsView` "Storage" section add controls bound to the new settings:

```swift
Stepper("Max storage: \(Int(settings.maxStorageGB)) GB (0 = off)",
        value: $settings.maxStorageGB, in: 0...2000, step: 5)
Stepper("Keep free: \(Int(settings.minFreeSpaceGB)) GB (0 = off)",
        value: $settings.minFreeSpaceGB, in: 0...2000, step: 5)
Picker("When limit reached", selection: $settings.diskLimitPolicy) {
    ForEach(DiskLimitPolicy.allCases) { Text($0.label).tag($0) }
}
LabeledContent("Usage", value: usageText)
```
Add `@State private var usageText = "—"` and compute on `.onAppear`:
```swift
let u = fileStore.folderUsage()
let freeGB = Double(fileStore.volumeFreeBytes()) / 1_000_000_000
let usedGB = Double(u.totalBytes) / 1_000_000_000
usageText = String(format: "%d clips · %.1f GB · %.1f GB free", u.count, usedGB, freeGB)
```

- [ ] **Step 4: Build + test** → `BUILD SUCCEEDED`, 27 prior tests pass.
- [ ] **Step 5: Commit** `feat: disk limit settings, gate wiring, storage UI`.

---

## Task 5: MotionMask (pure) — TDD

**Files:** Create `MacCam/Motion/MotionMask.swift`, `MacCamTests/MotionMaskTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import MacCam

final class MotionMaskTests: XCTestCase {
    func testDefaultIsEmptyActive() {
        let m = MotionMask()
        XCTAssertTrue(m.isEmpty)        // nothing ignored
        XCTAssertFalse(m.allIgnored)
        XCTAssertEqual(m.encoded().count, MotionMask.count)
        XCTAssertEqual(Set(m.encoded()), ["0"])
    }

    func testToggleAndEncodeRoundTrip() {
        var m = MotionMask()
        m.toggle(0, 0)
        m.toggle(15, 8)
        XCTAssertTrue(m.cell(0, 0))
        XCTAssertTrue(m.cell(15, 8))
        XCTAssertFalse(m.isEmpty)
        let decoded = MotionMask(encoded: m.encoded())
        XCTAssertEqual(decoded, m)
    }

    func testInvalidEncodedReturnsNil() {
        XCTAssertNil(MotionMask(encoded: "001"))         // wrong length
        XCTAssertNil(MotionMask(encoded: String(repeating: "2", count: 144)))
    }

    func testClearAndInvert() {
        var m = MotionMask()
        m.invert()
        XCTAssertTrue(m.allIgnored)
        m.clear()
        XCTAssertTrue(m.isEmpty)
    }

    func testPixelLookupMapsCells() {
        var m = MotionMask()
        m.toggle(0, 0)                      // ignore top-left cell
        let lookup = m.pixelLookup(width: 16, height: 9)  // 1px per cell
        XCTAssertTrue(lookup[0])            // (0,0) ignored
        XCTAssertFalse(lookup[1])           // (1,0) active
        XCTAssertEqual(lookup.count, 16 * 9)
    }
}
```

- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement**

```swift
import Foundation

struct MotionMask: Equatable {
    static let cols = 16
    static let rows = 9
    static let count = cols * rows

    private(set) var ignored: [Bool]

    init() { ignored = Array(repeating: false, count: Self.count) }

    init?(encoded: String) {
        guard encoded.count == Self.count else { return nil }
        var arr = [Bool]()
        arr.reserveCapacity(Self.count)
        for ch in encoded {
            switch ch {
            case "0": arr.append(false)
            case "1": arr.append(true)
            default: return nil
            }
        }
        ignored = arr
    }

    var isEmpty: Bool { !ignored.contains(true) }
    var allIgnored: Bool { !ignored.contains(false) }
    var ignoredCount: Int { ignored.lazy.filter { $0 }.count }

    private func index(_ col: Int, _ row: Int) -> Int { row * Self.cols + col }
    func cell(_ col: Int, _ row: Int) -> Bool { ignored[index(col, row)] }
    mutating func toggle(_ col: Int, _ row: Int) { ignored[index(col, row)].toggle() }
    mutating func set(_ col: Int, _ row: Int, _ value: Bool) { ignored[index(col, row)] = value }
    mutating func clear() { ignored = Array(repeating: false, count: Self.count) }
    mutating func invert() { ignored = ignored.map { !$0 } }

    func encoded() -> String { String(ignored.map { $0 ? "1" : "0" }) }

    /// Per-pixel ignore lookup for an analysis buffer of the given size.
    func pixelLookup(width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let row = min(Self.rows - 1, y * Self.rows / height)
            for x in 0..<width {
                let col = min(Self.cols - 1, x * Self.cols / width)
                out[y * width + x] = ignored[row * Self.cols + col]
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `feat: MotionMask 16x9 ignore mask`.

---

## Task 6: MotionDetector mask support — TDD

**Files:** Modify `MacCam/Motion/MotionDetector.swift`, `MacCamTests/MotionDetectorTests.swift`

- [ ] **Step 1: Add masked tests** (append to `MotionDetectorTests`):

```swift
func testMaskIgnoresChangingRegion() {
    let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
    var mask = MotionMask()
    for row in 0..<MotionMask.rows {            // ignore the RIGHT half (cols 8..15)
        for col in 8..<MotionMask.cols { mask.set(col, row, true) }
    }
    d.requestMask(mask)
    let dark = makeBuffer(width: 640, height: 360) { _, _ in 30 }
    let rightChanges = makeBuffer(width: 640, height: 360) { x, _ in x >= 320 ? 220 : 30 }
    _ = d.analyze(dark, pts: 0)
    let r = d.analyze(rightChanges, pts: 1)!
    XCTAssertFalse(r.motion)                    // all change is in the ignored half
    XCTAssertLessThan(r.fraction, 0.01)
}

func testMaskKeepsActiveRegion() {
    let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
    var mask = MotionMask()
    for row in 0..<MotionMask.rows {
        for col in 8..<MotionMask.cols { mask.set(col, row, true) } // ignore right half
    }
    d.requestMask(mask)
    let dark = makeBuffer(width: 640, height: 360) { _, _ in 30 }
    let leftChanges = makeBuffer(width: 640, height: 360) { x, _ in x < 320 ? 220 : 30 }
    _ = d.analyze(dark, pts: 0)
    let r = d.analyze(leftChanges, pts: 1)!
    XCTAssertTrue(r.motion)                     // change is in the active half
    XCTAssertGreaterThan(r.fraction, 0.3)
}

func testAllIgnoredYieldsNoMotion() {
    let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
    var mask = MotionMask(); mask.invert()      // ignore everything
    d.requestMask(mask)
    let dark = makeBuffer(width: 640, height: 360) { _, _ in 30 }
    let bright = makeBuffer(width: 640, height: 360) { _, _ in 220 }
    _ = d.analyze(dark, pts: 0)
    let r = d.analyze(bright, pts: 1)!
    XCTAssertFalse(r.motion)
    XCTAssertEqual(r.fraction, 0, accuracy: 1e-9)
}
```

- [ ] **Step 2: Run → FAIL** (`requestMask` undefined).
- [ ] **Step 3: Implement.** Add staging fields near the other pending tunables:

```swift
private var pendingMask: MotionMask??          // outer optional = "has pending", inner = value
private var ignoreLookup: [Bool]?              // size count, true = ignore
private var activeCount = analyzeWidth * analyzeHeight
```
Add the request method (any thread):

```swift
func requestMask(_ mask: MotionMask?) {
    paramLock.lock()
    pendingMask = .some(mask)
    paramLock.unlock()
}
```
Extend `applyPendingUpdate()` (runs on analysis queue) to consume it:

```swift
if let boxed = pendingMask {
    pendingMask = nil
    if let mask = boxed, !mask.isEmpty {
        let lookup = mask.pixelLookup(width: Self.analyzeWidth, height: Self.analyzeHeight)
        ignoreLookup = lookup
        activeCount = lookup.lazy.filter { !$0 }.count
    } else {
        ignoreLookup = nil
        activeCount = count
    }
}
```
(Read `pendingMask`/write `ignoreLookup` while holding `paramLock` is fine; expansion is cheap and one-shot.)

Update the counting loop in `analyze` to honor the mask:

```swift
let thresh = min(255, max(0, pixelDelta))
var changed = 0
if let ignore = ignoreLookup {
    if activeCount == 0 { return (false, 0) }
    for i in 0..<count where !ignore[i]
        && abs(Int(currentGray[i]) - Int(previousGray[i])) > thresh { changed += 1 }
    return (Double(changed) / Double(activeCount) > threshold, Double(changed) / Double(activeCount))
} else {
    for i in 0..<count where abs(Int(currentGray[i]) - Int(previousGray[i])) > thresh { changed += 1 }
    let fraction = Double(changed) / Double(count)
    return (fraction > threshold, fraction)
}
```

- [ ] **Step 4: Run → PASS** (all MotionDetector tests, masked + unmasked).
- [ ] **Step 5: Commit** `feat: motion detector ignore-zone mask`.

---

## Task 7: CameraManager.captureSnapshot

**Files:** Modify `MacCam/Capture/CameraManager.swift` (glue).

- [ ] **Step 1:** Add a one-shot snapshot helper. Add a private delegate class at file scope:

```swift
private final class SnapshotGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let completion: (CGImage?) -> Void
    private var done = false
    init(completion: @escaping (CGImage?) -> Void) { self.completion = completion }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !done, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        done = true
        let ci = CIImage(cvPixelBuffer: pb)
        let cg = CIContext().createCGImage(ci, from: ci.extent)
        DispatchQueue.main.async { self.completion(cg) }
    }
}
```

- [ ] **Step 2:** Add the method to `CameraManager`:

```swift
private var snapshotGrabber: SnapshotGrabber?
private var snapshotOutput: AVCaptureVideoDataOutput?

func captureSnapshot(_ completion: @escaping (CGImage?) -> Void) {
    sessionQueue.async {
        let wasRunning = self.session.isRunning
        if self.session.inputs.isEmpty {
            // Configure with the selected device just for the snapshot.
            self.reconfigure()
        }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        var finished = false
        let grabber = SnapshotGrabber { image in
            self.sessionQueue.async {
                if self.session.outputs.contains(out) { self.session.removeOutput(out) }
                if !wasRunning { self.session.stopRunning() }
            }
            if !finished { finished = true; completion(image) }
        }
        out.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "capture.snapshot"))
        self.snapshotGrabber = grabber
        self.snapshotOutput = out
        if self.session.canAddOutput(out) { self.session.addOutput(out) }
        if !wasRunning { self.session.startRunning() }
        // Safety timeout: if no frame arrives, return nil.
        self.sessionQueue.asyncAfter(deadline: .now() + 3) {
            if !finished {
                finished = true
                if self.session.outputs.contains(out) { self.session.removeOutput(out) }
                if !wasRunning { self.session.stopRunning() }
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
```

- [ ] **Step 3: Build** → `BUILD SUCCEEDED`.
- [ ] **Step 4: Commit** `feat: camera one-shot snapshot for zone editor`.

---

## Task 8: ZoneEditorView + settings/AppDelegate wiring

**Files:** Create `MacCam/UI/ZoneEditorView.swift`; modify `SettingsStore.swift`, `SettingsView.swift`, `App/AppDelegate.swift` (glue).

- [ ] **Step 1:** In `SettingsStore.swift` add `@Published var detectionMask: String` (key `detectionMask`, default `""`), include in `AppSettings` + `snapshot()`. In `AppDelegate.applyToDetector` add:

```swift
detector.requestMask(MotionMask(encoded: snap.detectionMask))
```
(`MotionMask(encoded:)` returns nil for `""` → no masking.)

- [ ] **Step 2:** Create `ZoneEditorView.swift`:

```swift
import SwiftUI

struct ZoneEditorView: View {
    @ObservedObject var settings: SettingsStore
    let camera: CameraManager

    @State private var mask = MotionMask()
    @State private var snapshot: CGImage?

    var body: some View {
        VStack(spacing: 12) {
            Text("Tap or drag cells to ignore (red). Motion there is not detected.")
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack {
                    if let snapshot {
                        Image(snapshot, scale: 1, label: Text("preview")).resizable()
                    } else {
                        Rectangle().fill(Color.black.opacity(0.85))
                    }
                    grid(in: geo.size)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { paint($0.location, in: geo.size) })
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)
            HStack {
                Button("Clear") { mask.clear(); persist() }
                Button("Invert") { mask.invert(); persist() }
                Spacer()
                Text("\(mask.ignoredCount) cells ignored").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520, height: 380)
        .onAppear {
            mask = MotionMask(encoded: settings.detectionMask) ?? MotionMask()
            camera.captureSnapshot { snapshot = $0 }
        }
    }

    private func grid(in size: CGSize) -> some View {
        let cw = size.width / CGFloat(MotionMask.cols)
        let ch = size.height / CGFloat(MotionMask.rows)
        return ZStack {
            ForEach(0..<MotionMask.rows, id: \.self) { row in
                ForEach(0..<MotionMask.cols, id: \.self) { col in
                    Rectangle()
                        .fill(mask.cell(col, row) ? Color.red.opacity(0.45) : Color.clear)
                        .frame(width: cw, height: ch)
                        .border(Color.white.opacity(0.25), width: 0.5)
                        .position(x: cw * (CGFloat(col) + 0.5), y: ch * (CGFloat(row) + 0.5))
                }
            }
        }
    }

    private func paint(_ point: CGPoint, in size: CGSize) {
        let col = Int(point.x / (size.width / CGFloat(MotionMask.cols)))
        let row = Int(point.y / (size.height / CGFloat(MotionMask.rows)))
        guard (0..<MotionMask.cols).contains(col), (0..<MotionMask.rows).contains(row) else { return }
        if !mask.cell(col, row) { mask.set(col, row, true); persist() }
    }

    private func persist() { settings.detectionMask = mask.encoded() }
}
```

- [ ] **Step 3:** In `SettingsView` "Motion" section add a button + caption:

```swift
Button("Edit Detection Zones…") { onEditZones() }
if let m = MotionMask(encoded: settings.detectionMask), !m.isEmpty {
    Text("\(m.ignoredCount) zone cells ignored").font(.caption).foregroundStyle(.secondary)
}
```
Add `var onEditZones: () -> Void` to `SettingsView`'s parameters and pass it from `AppDelegate.openSettings`.

- [ ] **Step 4:** In `AppDelegate` add a zone-editor window (mirroring `openAbout`):

```swift
private var zoneWindow: NSWindow?
private func openZoneEditor() {
    if zoneWindow == nil {
        let view = ZoneEditorView(settings: settings, camera: camera)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = loc("Detection Zones")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        zoneWindow = window
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    zoneWindow?.center()
    zoneWindow?.makeKeyAndOrderFront(nil)
}
```
Pass `onEditZones: { [weak self] in self?.openZoneEditor() }` when constructing `SettingsView`.

- [ ] **Step 5: Build + test** → `BUILD SUCCEEDED`, all tests pass.
- [ ] **Step 6: Commit** `feat: detection zone editor and wiring`.

---

## Task 9: Localization + CHANGELOG + final verification

**Files:** Modify `MacCam/Localizable.xcstrings`, `CHANGELOG.md`.

- [ ] **Step 1:** Add EN→RU entries to `Localizable.xcstrings` for every new user-facing string introduced above: `"When limit reached"`→"При достижении лимита", `"Usage"`→"Использование", `"Loop (delete oldest)"`→"Зациклить (удалять старейшие)", `"Stop & notify"`→"Остановить и уведомить", `"Stopped: disk limit reached"`→"Остановлено: достигнут лимит диска", `"Edit Detection Zones…"`→"Изменить зоны детекции…", `"Detection Zones"`→"Зоны детекции", `"Tap or drag cells to ignore (red). Motion there is not detected."`→"Нажимайте или ведите по ячейкам, чтобы игнорировать (красные). Движение там не учитывается.", `"Clear"`→"Очистить", `"Invert"`→"Инвертировать". (Stepper/format strings with interpolation may stay English.) Use the existing entry format:
```json
"Usage" : { "localizations" : { "ru" : { "stringUnit" : { "state" : "translated", "value" : "Использование" } } } }
```

- [ ] **Step 2:** Update `CHANGELOG.md` "Unreleased": add "Disk-space limits (size cap and free-space floor) with loop or stop policy." and "Detection zones: ignore parts of the frame via a grid mask painted over a camera snapshot."

- [ ] **Step 3: Lint** `swiftlint --strict` → 0 violations.
- [ ] **Step 4: Full test** `make test` → all tests pass (prior 27 + StorageMath + MotionMask + masked detector).
- [ ] **Step 5: Commit** `feat: localize disk limits + detection zones, changelog`.

---

## Self-Review

**Spec coverage:**
- §1.2 disk settings → Task 4. §1.3 StorageMath → Task 1. §1.4 FileStore → Task 2. §1.5 gate/onStorageStop → Task 3 + 4. §1.6 UI → Task 4. §1.7 tests → Task 1.
- §2.2 MotionMask → Task 5. §2.3 detector → Task 6. §2.4 snapshot → Task 7. §2.5 editor → Task 8. §2.6 settings wiring → Task 8. §2.7 tests → Task 5 + 6.
- Cross-cutting localization/CHANGELOG → Task 9. All covered.

**Placeholder scan:** No TBD/TODO; pure-logic tasks have full test+impl; glue tasks have concrete code and build/test verification.

**Type consistency:** `ClipFile`/`StorageMath.clipsToDelete/overLimit/gbToBytes` defined Task 1, used Tasks 2–4. `StorageDecision`/`storageGate`/`onStorageStop` Task 3, used Task 4. `DiskLimitPolicy` Task 4. `MotionMask` (cols/rows/count, `set`/`toggle`/`cell`/`clear`/`invert`/`isEmpty`/`allIgnored`/`ignoredCount`/`encoded`/`pixelLookup`) Task 5, used Tasks 6 + 8. `requestMask` Task 6, used Task 8 (`applyToDetector`). `captureSnapshot` Task 7, used Task 8. `detectionMask` setting Task 8. Consistent.
