import XCTest
@testable import MacCam

final class MotionMathTests: XCTestCase {
    func testEndpoints() {
        XCTAssertEqual(MotionMath.motionThreshold(forSensitivity: 0), 0.08, accuracy: 1e-6)
        XCTAssertEqual(MotionMath.motionThreshold(forSensitivity: 4), 0.005, accuracy: 1e-6)
    }

    func testMonotonicDecreasing() {
        let t = (0...4).map { MotionMath.motionThreshold(forSensitivity: $0) }
        for i in 1..<t.count { XCTAssertLessThan(t[i], t[i - 1]) }
    }

    func testClampsOutOfRange() {
        XCTAssertEqual(MotionMath.motionThreshold(forSensitivity: -5), 0.08, accuracy: 1e-6)
        XCTAssertEqual(MotionMath.motionThreshold(forSensitivity: 99), 0.005, accuracy: 1e-6)
    }
}
