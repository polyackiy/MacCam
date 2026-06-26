import XCTest
@testable import MacCam

final class VoiceActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testInactiveBeforeAnySpeech() {
        let a = VoiceActivity()
        XCTAssertFalse(a.isActive(at: t0, hold: 2))
    }

    func testActiveWithinHold() {
        var a = VoiceActivity()
        a.noteSpeech(at: t0)
        XCTAssertTrue(a.isActive(at: t0.addingTimeInterval(1.5), hold: 2))
    }

    func testInactivePastHold() {
        var a = VoiceActivity()
        a.noteSpeech(at: t0)
        XCTAssertFalse(a.isActive(at: t0.addingTimeInterval(2.0), hold: 2))
    }

    func testRefreshExtendsWindow() {
        var a = VoiceActivity()
        a.noteSpeech(at: t0)
        a.noteSpeech(at: t0.addingTimeInterval(1.5))
        XCTAssertTrue(a.isActive(at: t0.addingTimeInterval(3.0), hold: 2))
    }

    func testReset() {
        var a = VoiceActivity()
        a.noteSpeech(at: t0)
        a.reset()
        XCTAssertFalse(a.isActive(at: t0, hold: 2))
    }
}
