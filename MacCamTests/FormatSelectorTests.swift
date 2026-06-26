import XCTest
@testable import MacCam

private struct Fmt: FormatInfo {
    let width: Int
    let height: Int
    let maxFPS: Double
}

final class FormatSelectorTests: XCTestCase {
    func testPicksMaxAreaWithAcceptableFPS() {
        let fmts = [
            Fmt(width: 1280, height: 720, maxFPS: 60),
            Fmt(width: 1920, height: 1080, maxFPS: 30),
            Fmt(width: 3840, height: 2160, maxFPS: 15),  // 15 < 24 → excluded
        ]
        let best = FormatSelector.pick(from: fmts, minFPS: 24)!
        XCTAssertEqual(best.width, 1920)
        XCTAssertEqual(best.height, 1080)
    }

    func testFallsBackToMaxAreaIfNoneMeetFPS() {
        let fmts = [
            Fmt(width: 640, height: 480, maxFPS: 10),
            Fmt(width: 1920, height: 1080, maxFPS: 12),
        ]
        let best = FormatSelector.pick(from: fmts, minFPS: 24)!
        XCTAssertEqual(best.width, 1920)
    }

    func testEmpty() {
        XCTAssertNil(FormatSelector.pick(from: [Fmt](), minFPS: 24))
    }
}
