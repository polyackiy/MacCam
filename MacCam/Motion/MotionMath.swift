import Foundation

/// Pure mapping from the SP-Cam-style sensitivity dial (0...4) to the fraction
/// of changed pixels required to declare motion. Higher sensitivity → lower
/// threshold. Interpolated logarithmically between 8% (coarse) and 0.5% (fine).
enum MotionMath {
    static let coarseThreshold = 0.08   // sensitivity 0
    static let fineThreshold = 0.005    // sensitivity 4

    static func motionThreshold(forSensitivity s: Int) -> Double {
        let c = Double(min(4, max(0, s)))
        let hi = log(coarseThreshold)
        let lo = log(fineThreshold)
        return exp(hi + (lo - hi) * (c / 4.0))
    }
}
