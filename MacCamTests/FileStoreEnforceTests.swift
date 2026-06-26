import XCTest
@testable import MacCam

/// Exercises the real file-deletion path of FileStore.enforce against a temp
/// folder (the size-cap branch is deterministic; free-space depends on the host
/// volume so is not asserted here).
final class FileStoreEnforceTests: XCTestCase {
    private func writeClip(_ folder: URL, _ name: String, bytes: Int, day: Int) {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path,
                                       contents: Data(count: bytes), attributes: nil)
        let date = Date(timeIntervalSince1970: Double(day) * 86400)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testEnforceDeletesOldestUntilUnderSizeCap() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacCamEnforce-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileStore(defaults: UserDefaults.standard, defaultOverride: tmp)
        writeClip(tmp, "MacCam_old.mov", bytes: 1000, day: 1)
        writeClip(tmp, "MacCam_mid.mov", bytes: 1000, day: 2)
        writeClip(tmp, "MacCam_new.mov", bytes: 1000, day: 3)

        // Cap at 1500 bytes: must delete the two oldest (3000 -> 1000 <= 1500).
        store.enforce(maxBytes: 1500, minFreeBytes: 0, protecting: [])

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        XCTAssertEqual(remaining, ["MacCam_new.mov"])
    }

    func testEnforceRespectsProtectedURL() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacCamEnforce-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = FileStore(defaults: UserDefaults.standard, defaultOverride: tmp)
        writeClip(tmp, "MacCam_old.mov", bytes: 1000, day: 1)
        writeClip(tmp, "MacCam_new.mov", bytes: 1000, day: 2)
        let protectedURL = tmp.appendingPathComponent("MacCam_old.mov")

        // Cap forces one deletion, but the oldest is protected → newest deleted.
        store.enforce(maxBytes: 1500, minFreeBytes: 0, protecting: [protectedURL])

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        XCTAssertEqual(remaining, ["MacCam_old.mov"])
    }
}
