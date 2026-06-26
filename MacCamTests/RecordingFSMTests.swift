import XCTest
@testable import MacCam

final class RecordingFSMTests: XCTestCase {
    func testStartOnMotion() {
        var f = RecordingFSM()
        XCTAssertEqual(f.step(motion: true, now: 0), .startClip)
        XCTAssertEqual(f.state, .recording)
    }

    func testStaysRecordingDuringCooldown() {
        var f = RecordingFSM()
        _ = f.step(motion: true, now: 0)
        XCTAssertEqual(f.step(motion: false, now: 3), .appendOnly)  // < 5s cooldown
    }

    func testFinishAfterCooldownPastMinClip() {
        var f = RecordingFSM()
        _ = f.step(motion: true, now: 0)
        XCTAssertEqual(f.step(motion: false, now: 11), .finishAndIdle)
        XCTAssertEqual(f.state, .idle)
    }

    func testRotateAtMaxClip() {
        var f = RecordingFSM()
        _ = f.step(motion: true, now: 0)
        XCTAssertEqual(f.step(motion: true, now: 60), .rotate)
        XCTAssertEqual(f.state, .recording)
    }

    func testNoFinishBeforeMinClipEvenIfQuiet() {
        var f = RecordingFSM(minClip: 5, maxClip: 60, cooldown: 1)
        _ = f.step(motion: true, now: 0)
        XCTAssertEqual(f.step(motion: false, now: 2), .appendOnly)  // quiet but clip < minClip
    }

    func testIdleStaysIdleWithoutMotion() {
        var f = RecordingFSM()
        XCTAssertEqual(f.step(motion: false, now: 0), RecAction.none)
        XCTAssertEqual(f.state, .idle)
    }
}
