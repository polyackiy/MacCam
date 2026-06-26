import XCTest
@testable import MacCam

final class MotionMaskTests: XCTestCase {
    func testDefaultIsEmptyActive() {
        let m = MotionMask()
        XCTAssertTrue(m.isEmpty)
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
        XCTAssertNil(MotionMask(encoded: "001"))
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
        m.toggle(0, 0)
        let lookup = m.pixelLookup(width: 16, height: 9)
        XCTAssertTrue(lookup[0])
        XCTAssertFalse(lookup[1])
        XCTAssertEqual(lookup.count, 16 * 9)
    }
}
