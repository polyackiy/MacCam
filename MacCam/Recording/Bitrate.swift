import Foundation

enum Quality: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// Pure average-bitrate selection. Anchored at 1080p and scaled linearly by
/// pixel area, so 4K automatically gets a proportionally higher bitrate.
enum Bitrate {
    static func bps(quality: Quality, width: Int, height: Int) -> Int {
        let anchor = 1920.0 * 1080.0
        let base: Double
        switch quality {
        case .low: base = 6_000_000
        case .medium: base = 9_000_000
        case .high: base = 12_000_000
        }
        let scaled = base * (Double(width * height) / anchor)
        return Int((scaled / 1000).rounded()) * 1000
    }
}
