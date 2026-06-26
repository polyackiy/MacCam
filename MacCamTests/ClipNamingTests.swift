import XCTest
@testable import MacCam

final class ClipNamingTests: XCTestCase {
    func testFilenameFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = DateComponents(
            calendar: cal, year: 2026, month: 6, day: 26,
            hour: 9, minute: 5, second: 3).date!
        XCTAssertEqual(ClipNaming.filename(for: d, calendar: cal),
                       "MacCam_2026-06-26_09-05-03.mov")
    }

    func testAudioOnlyFilenameUsesM4A() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = DateComponents(
            calendar: cal, year: 2026, month: 6, day: 26,
            hour: 9, minute: 5, second: 3).date!
        XCTAssertEqual(
            ClipNaming.filename(for: d, calendar: cal, ext: ClipNaming.audioExtension),
            "MacCam_2026-06-26_09-05-03.m4a")
    }

    func testIsClipRecognizesBothContainers() {
        XCTAssertTrue(ClipNaming.isClip(URL(fileURLWithPath: "/a/clip.mov")))
        XCTAssertTrue(ClipNaming.isClip(URL(fileURLWithPath: "/a/clip.m4a")))
        XCTAssertTrue(ClipNaming.isClip(URL(fileURLWithPath: "/a/clip.MOV")))   // case-insensitive
        XCTAssertFalse(ClipNaming.isClip(URL(fileURLWithPath: "/a/notes.txt")))
        XCTAssertFalse(ClipNaming.isClip(URL(fileURLWithPath: "/a/clip.mp4")))
    }

    func testExpiredSelection() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = URL(fileURLWithPath: "/a/old.mov")
        let fresh = URL(fileURLWithPath: "/a/new.mov")
        let files = [
            (old, now.addingTimeInterval(-15 * 86400)),
            (fresh, now.addingTimeInterval(-1 * 86400)),
        ]
        XCTAssertEqual(
            ClipNaming.expired(files: files, olderThanDays: 14, now: now), [old])
    }
}
