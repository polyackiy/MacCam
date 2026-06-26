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
        let files = [f("old", 5, 1), f("mid", 5, 2), f("new", 5, 3)]
        let del = StorageMath.clipsToDelete(
            files: files, totalBytes: 15, freeBytes: 100,
            maxBytes: 8, minFreeBytes: 0, protecting: [])
        XCTAssertEqual(del.map { $0.lastPathComponent }, ["old", "mid"])
    }

    func testDeletesUntilFreeFloorMet() {
        let files = [f("old", 10, 1), f("new", 10, 2)]
        let del = StorageMath.clipsToDelete(
            files: files, totalBytes: 20, freeBytes: 5,
            maxBytes: 0, minFreeBytes: 12, protecting: [])
        XCTAssertEqual(del.map { $0.lastPathComponent }, ["old"])
    }

    func testNeverDeletesProtected() {
        let files = [f("old", 10, 1), f("new", 10, 2)]
        let protectedURL = URL(fileURLWithPath: "/c/old")
        let del = StorageMath.clipsToDelete(
            files: files, totalBytes: 20, freeBytes: 0,
            maxBytes: 5, minFreeBytes: 0, protecting: [protectedURL])
        XCTAssertEqual(del.map { $0.lastPathComponent }, ["new"])
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
