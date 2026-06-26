import XCTest
@testable import MacCam

final class BitrateTests: XCTestCase {
    func test1080p() {
        XCTAssertEqual(Bitrate.bps(quality: .low, width: 1920, height: 1080), 6_000_000)
        XCTAssertEqual(Bitrate.bps(quality: .medium, width: 1920, height: 1080), 9_000_000)
        XCTAssertEqual(Bitrate.bps(quality: .high, width: 1920, height: 1080), 12_000_000)
    }

    func test4kScalesUp() {
        XCTAssertGreaterThan(
            Bitrate.bps(quality: .medium, width: 3840, height: 2160),
            Bitrate.bps(quality: .medium, width: 1920, height: 1080))
    }
}
