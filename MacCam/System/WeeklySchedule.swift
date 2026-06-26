import Foundation

enum Weekday: Int, CaseIterable, Codable {
    case sun = 1, mon, tue, wed, thu, fri, sat

    var previous: Weekday { Weekday(rawValue: rawValue == 1 ? 7 : rawValue - 1)! }
}

/// Minutes since midnight, clamped to a valid day (0...1439).
struct TimeOfDay: Codable, Equatable {
    var minutes: Int
    init(minutes: Int) { self.minutes = min(1439, max(0, minutes)) }
    var hour: Int { minutes / 60 }
    var minute: Int { minutes % 60 }
}

/// A weekly time window: active on selected weekdays between `start` and `end`.
/// Overnight windows (start > end) wrap past midnight; a window is owned by the
/// day it starts, so the morning portion belongs to the previous day's window.
struct WeeklySchedule: Codable, Equatable {
    var enabled: Bool
    var days: Set<Weekday>
    var start: TimeOfDay
    var end: TimeOfDay

    init(enabled: Bool = false,
         days: Set<Weekday> = Set(Weekday.allCases),
         start: TimeOfDay = TimeOfDay(minutes: 22 * 60),
         end: TimeOfDay = TimeOfDay(minutes: 7 * 60)) {
        self.enabled = enabled
        self.days = days
        self.start = start
        self.end = end
    }

    func isActive(at date: Date, calendar: Calendar) -> Bool {
        guard enabled, start.minutes != end.minutes else { return false }
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wdRaw = comps.weekday, let wd = Weekday(rawValue: wdRaw) else { return false }
        let m = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

        if start.minutes < end.minutes {
            return days.contains(wd) && m >= start.minutes && m < end.minutes
        }
        // Overnight: evening part belongs to today; morning part to the previous day.
        if days.contains(wd) && m >= start.minutes { return true }
        if days.contains(wd.previous) && m < end.minutes { return true }
        return false
    }
}
