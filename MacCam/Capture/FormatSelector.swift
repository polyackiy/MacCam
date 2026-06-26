import Foundation

/// Minimal description of a capture format, so the selection logic can be unit
/// tested without constructing real `AVCaptureDevice.Format` objects.
protocol FormatInfo {
    var width: Int { get }
    var height: Int { get }
    var maxFPS: Double { get }
}

/// Pure max-resolution selection: among formats meeting the minimum FPS, pick
/// the one with the largest pixel area. If none meet the FPS floor, fall back
/// to the largest area overall so we still capture something.
enum FormatSelector {
    static func pick<F: FormatInfo>(from formats: [F], minFPS: Double) -> F? {
        let ok = formats.filter { $0.maxFPS >= minFPS }
        let pool = ok.isEmpty ? formats : ok
        return pool.max { ($0.width * $0.height) < ($1.width * $1.height) }
    }
}
