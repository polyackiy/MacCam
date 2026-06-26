import XCTest
@testable import MacCam

final class TriggerModeTests: XCTestCase {
    func testContinuous() {
        let m = TriggerMode.continuous
        XCTAssertFalse(m.usesMotion)
        XCTAssertFalse(m.usesVoice)
        XCTAssertTrue(m.isContinuous)
        XCTAssertTrue(m.allowsAudioOnly)
    }

    func testMotion() {
        let m = TriggerMode.motion
        XCTAssertTrue(m.usesMotion)
        XCTAssertFalse(m.usesVoice)
        XCTAssertFalse(m.isContinuous)
        XCTAssertFalse(m.allowsAudioOnly)
    }

    func testVoice() {
        let m = TriggerMode.voice
        XCTAssertFalse(m.usesMotion)
        XCTAssertTrue(m.usesVoice)
        XCTAssertFalse(m.isContinuous)
        XCTAssertTrue(m.allowsAudioOnly)
    }

    func testMotionAndVoice() {
        let m = TriggerMode.motionAndVoice
        XCTAssertTrue(m.usesMotion)
        XCTAssertTrue(m.usesVoice)
        XCTAssertFalse(m.isContinuous)
        XCTAssertFalse(m.allowsAudioOnly)
    }

    func testAllCasesAndLabels() {
        XCTAssertEqual(TriggerMode.allCases.count, 4)
        XCTAssertFalse(TriggerMode.motion.label.isEmpty)
        XCTAssertEqual(TriggerMode.continuous.id, "continuous")
    }
}
