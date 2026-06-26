import XCTest
@testable import MacCam

final class VoiceMathTests: XCTestCase {
    func testEndpoints() {
        XCTAssertEqual(VoiceMath.confidenceThreshold(forSensitivity: 0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(VoiceMath.confidenceThreshold(forSensitivity: 4), 0.35, accuracy: 1e-9)
    }

    func testMonotonicDecreasing() {
        let t = (0...4).map { VoiceMath.confidenceThreshold(forSensitivity: $0) }
        for i in 1..<t.count { XCTAssertLessThan(t[i], t[i - 1]) }
    }

    func testClampsOutOfRange() {
        XCTAssertEqual(VoiceMath.confidenceThreshold(forSensitivity: -3), 0.9, accuracy: 1e-9)
        XCTAssertEqual(VoiceMath.confidenceThreshold(forSensitivity: 99), 0.35, accuracy: 1e-9)
    }
}
