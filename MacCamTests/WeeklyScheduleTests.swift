import XCTest
@testable import MacCam

final class WeeklyScheduleTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // 2026-06-22 is a Monday.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        DateComponents(calendar: cal, year: y, month: mo, day: d, hour: h, minute: mi).date!
    }

    func testDisabledAlwaysFalse() {
        var s = WeeklySchedule(); s.enabled = false
        XCTAssertFalse(s.isActive(at: date(2026, 6, 22, 23, 0), calendar: cal))
    }

    func testSameDayWindowInside() {
        let s = WeeklySchedule(enabled: true, days: [.mon],
                               start: TimeOfDay(minutes: 9 * 60), end: TimeOfDay(minutes: 18 * 60))
        XCTAssertTrue(s.isActive(at: date(2026, 6, 22, 10, 0), calendar: cal))
        XCTAssertFalse(s.isActive(at: date(2026, 6, 22, 18, 0), calendar: cal))  // end exclusive
        XCTAssertTrue(s.isActive(at: date(2026, 6, 22, 9, 0), calendar: cal))    // start inclusive
        XCTAssertFalse(s.isActive(at: date(2026, 6, 23, 10, 0), calendar: cal))  // Tue not selected
    }

    func testOvernightEveningAndMorning() {
        let s = WeeklySchedule(enabled: true, days: [.mon],
                               start: TimeOfDay(minutes: 22 * 60), end: TimeOfDay(minutes: 7 * 60))
        XCTAssertTrue(s.isActive(at: date(2026, 6, 22, 23, 0), calendar: cal))   // Mon evening
        XCTAssertTrue(s.isActive(at: date(2026, 6, 23, 6, 0), calendar: cal))    // Tue morning (Mon window)
        XCTAssertFalse(s.isActive(at: date(2026, 6, 23, 7, 0), calendar: cal))   // end exclusive
        XCTAssertFalse(s.isActive(at: date(2026, 6, 22, 21, 0), calendar: cal))  // before start
        XCTAssertFalse(s.isActive(at: date(2026, 6, 24, 6, 0), calendar: cal))   // Wed (Tue not selected)
    }

    func testEmptyWindowWhenStartEqualsEnd() {
        let s = WeeklySchedule(enabled: true, days: Set(Weekday.allCases),
                               start: TimeOfDay(minutes: 600), end: TimeOfDay(minutes: 600))
        XCTAssertFalse(s.isActive(at: date(2026, 6, 22, 10, 0), calendar: cal))
    }

    func testCodableRoundTrip() throws {
        let s = WeeklySchedule(enabled: true, days: [.fri, .sat],
                               start: TimeOfDay(minutes: 90), end: TimeOfDay(minutes: 120))
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(WeeklySchedule.self, from: data), s)
    }

    func testTimeOfDayClamps() {
        XCTAssertEqual(TimeOfDay(minutes: -10).minutes, 0)
        XCTAssertEqual(TimeOfDay(minutes: 5000).minutes, 1439)
        XCTAssertEqual(TimeOfDay(minutes: 125).hour, 2)
        XCTAssertEqual(TimeOfDay(minutes: 125).minute, 5)
    }
}
