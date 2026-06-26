import Foundation

/// Pure helpers for clip filenames and retention selection.
enum ClipNaming {
    /// `MacCam_YYYY-MM-DD_HH-mm-ss.mov` using the supplied calendar/timezone.
    static func filename(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        func p2(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let y = String(format: "%04d", c.year ?? 0)
        return "MacCam_\(y)-\(p2(c.month))-\(p2(c.day))_\(p2(c.hour))-\(p2(c.minute))-\(p2(c.second)).mov"
    }

    /// URLs whose modification date is older than `olderThanDays` relative to `now`.
    static func expired(files: [(url: URL, modified: Date)], olderThanDays: Int, now: Date) -> [URL] {
        let cutoff = Double(olderThanDays) * 86400.0
        return files
            .filter { now.timeIntervalSince($0.modified) > cutoff }
            .map { $0.url }
    }
}
