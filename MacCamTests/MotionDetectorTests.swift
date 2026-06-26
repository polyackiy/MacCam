import XCTest
import CoreVideo
@testable import MacCam

final class MotionDetectorTests: XCTestCase {
    /// Builds a 32BGRA pixel buffer whose luminance at (x, y) is `fill(x, y)`.
    private func makeBuffer(width: Int, height: Int, fill: (Int, Int) -> UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let v = fill(x, y)
                let p = y * row + x * 4
                base[p + 0] = v  // B
                base[p + 1] = v  // G
                base[p + 2] = v  // R
                base[p + 3] = 255 // A
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testNoMotionOnIdenticalFrames() {
        let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
        let a = makeBuffer(width: 640, height: 360) { _, _ in 100 }
        XCTAssertNil(d.analyze(a, pts: 0))  // first frame → nil
        let r = d.analyze(a, pts: 1)!
        XCTAssertFalse(r.motion)
        XCTAssertLessThan(r.fraction, 0.01)
    }

    func testMotionWhenHalfFrameChanges() {
        let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
        let dark = makeBuffer(width: 640, height: 360) { _, _ in 30 }
        let half = makeBuffer(width: 640, height: 360) { x, _ in x < 320 ? 30 : 220 }
        _ = d.analyze(dark, pts: 0)
        let r = d.analyze(half, pts: 1)!
        XCTAssertTrue(r.motion)
        XCTAssertGreaterThan(r.fraction, 0.3)
    }

    func testThrottleReturnsNilWithinInterval() {
        let d = MotionDetector(pixelDelta: 25, threshold: 0.02)
        let a = makeBuffer(width: 640, height: 360) { _, _ in 100 }
        _ = d.analyze(a, pts: 0)
        XCTAssertNil(d.analyze(a, pts: 0.01))  // < 1/12 s since last
    }
}
