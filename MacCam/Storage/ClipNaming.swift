import Foundation

/// Pure helpers for clip filenames and retention selection.
enum ClipNaming {
    /// Container extension per clip kind: `.mov` for video (HEVC/H.264 + optional
    /// audio), `.m4a` for audio-only (a single AAC track — the idiomatic audio
    /// container, so the file reads as audio, not a video with no picture).
    static let videoExtension = "mov"
    static let audioExtension = "m4a"
    /// Every extension MacCam writes — the set storage accounting/cleanup count as
    /// clips, so audio-only files are subject to disk limits and retention too.
    static let clipExtensions: Set<String> = [videoExtension, audioExtension]

    /// True if `url` is one of MacCam's clip files (by extension, case-insensitive).
    static func isClip(_ url: URL) -> Bool {
        clipExtensions.contains(url.pathExtension.lowercased())
    }

    /// `MacCam_YYYY-MM-DD_HH-mm-ss.<ext>` using the supplied calendar/timezone.
    static func filename(for date: Date, calendar: Calendar, ext: String = videoExtension) -> String {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        func p2(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let y = String(format: "%04d", c.year ?? 0)
        return "MacCam_\(y)-\(p2(c.month))-\(p2(c.day))_\(p2(c.hour))-\(p2(c.minute))-\(p2(c.second)).\(ext)"
    }

    /// URLs whose modification date is older than `olderThanDays` relative to `now`.
    static func expired(files: [(url: URL, modified: Date)], olderThanDays: Int, now: Date) -> [URL] {
        let cutoff = Double(olderThanDays) * 86400.0
        return files
            .filter { now.timeIntervalSince($0.modified) > cutoff }
            .map { $0.url }
    }
}
