import Foundation

/// Maps the 0...4 voice sensitivity dial to the confidence required from the
/// speech classifier. Higher sensitivity ⇒ lower threshold (triggers more
/// easily). Linear between 0.9 (s=0) and 0.35 (s=4).
enum VoiceMath {
    static let highConfidence = 0.9
    static let lowConfidence = 0.35

    static func confidenceThreshold(forSensitivity s: Int) -> Double {
        let c = Double(min(4, max(0, s)))
        return highConfidence + (lowConfidence - highConfidence) * (c / 4.0)
    }
}
