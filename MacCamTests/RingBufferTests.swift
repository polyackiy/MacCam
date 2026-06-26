import XCTest
@testable import MacCam

final class RingBufferTests: XCTestCase {
    func testEvictsOlderThanDuration() {
        let rb = RingBuffer<Int>(duration: 3.0)
        for i in 0...10 { rb.push(i, pts: Double(i)) }  // keep within 3s of newest (10)
        let s = rb.snapshot()
        XCTAssertEqual(s.first, 7)  // pts 7, 8, 9, 10 (10 - 7 == 3, boundary inclusive)
        XCTAssertEqual(s.last, 10)
    }

    func testOrderOldestToNewest() {
        let rb = RingBuffer<Int>(duration: 100)
        [5, 6, 7].forEach { rb.push($0, pts: Double($0)) }
        XCTAssertEqual(rb.snapshot(), [5, 6, 7])
    }

    func testClear() {
        let rb = RingBuffer<Int>(duration: 100)
        rb.push(1, pts: 1)
        rb.clear()
        XCTAssertTrue(rb.snapshot().isEmpty)
    }
}
