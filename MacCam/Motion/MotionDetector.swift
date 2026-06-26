import Foundation
import CoreVideo
import Accelerate

/// Fast motion detector: downscales each frame to 320×180 grayscale, compares
/// it against the previous frame's grayscale via an absolute difference, and
/// reports the fraction of pixels that changed by more than `pixelDelta`.
/// Analysis is throttled by presentation timestamp (~12 Hz) to save CPU.
final class MotionDetector {
    static let analyzeWidth = 320
    static let analyzeHeight = 180
    private static let throttleInterval = 1.0 / 12.0

    private(set) var pixelDelta: Int
    private(set) var threshold: Double

    // Tunables are mutated only on the analysis queue (inside `analyze`). Other
    // threads request changes via `requestUpdate`, staged here under a lock and
    // picked up at the start of the next `analyze` — so there is no data race on
    // the detector's mutable state.
    private let paramLock = NSLock()
    private var pendingPixelDelta: Int?
    private var pendingThreshold: Double?
    private var pendingMask: MotionMask??   // outer = "has pending", inner = value (nil = no mask)

    private let count = analyzeWidth * analyzeHeight
    private var scaledBGRA: UnsafeMutableRawPointer
    private var currentGray: UnsafeMutablePointer<UInt8>
    private var previousGray: UnsafeMutablePointer<UInt8>
    private var ignoreLookup: [Bool]?       // size `count`, true = ignore this pixel
    private var activeCount: Int
    private var hasPrevious = false
    private var lastPTS: Double = -.infinity

    init(pixelDelta: Int, threshold: Double) {
        self.pixelDelta = pixelDelta
        self.threshold = threshold
        activeCount = Self.analyzeWidth * Self.analyzeHeight
        scaledBGRA = .allocate(byteCount: count * 4, alignment: 16)
        currentGray = .allocate(capacity: count)
        previousGray = .allocate(capacity: count)
    }

    deinit {
        scaledBGRA.deallocate()
        currentGray.deallocate()
        previousGray.deallocate()
    }

    /// Thread-safe: stage new tunables to be applied on the analysis queue at
    /// the next frame. Safe to call from any thread (e.g. the main queue when
    /// settings change live).
    func requestUpdate(pixelDelta: Int, threshold: Double) {
        paramLock.lock()
        pendingPixelDelta = pixelDelta
        pendingThreshold = threshold
        paramLock.unlock()
    }

    /// Thread-safe: stage a new ignore mask (or `nil`/empty for no masking),
    /// applied on the analysis queue at the next frame.
    func requestMask(_ mask: MotionMask?) {
        paramLock.lock()
        pendingMask = .some(mask)
        paramLock.unlock()
    }

    /// Pick up any staged tunables. Runs on the analysis queue. Changing the
    /// threshold/pixel delta does not invalidate the stored reference frame, so
    /// no reset is needed (and no frame is dropped on a settings change).
    private func applyPendingUpdate() {
        paramLock.lock()
        if let pd = pendingPixelDelta { pixelDelta = pd; pendingPixelDelta = nil }
        if let th = pendingThreshold { threshold = th; pendingThreshold = nil }
        if let boxed = pendingMask {
            pendingMask = nil
            if let mask = boxed, !mask.isEmpty {
                let lookup = mask.pixelLookup(width: Self.analyzeWidth, height: Self.analyzeHeight)
                ignoreLookup = lookup
                activeCount = lookup.lazy.filter { !$0 }.count
            } else {
                ignoreLookup = nil
                activeCount = count
            }
        }
        paramLock.unlock()
    }

    /// Returns nil for the first frame and for throttled frames; otherwise the
    /// motion verdict and the changed-pixel fraction.
    func analyze(_ pixelBuffer: CVPixelBuffer, pts: Double) -> (motion: Bool, fraction: Double)? {
        applyPendingUpdate()
        if hasPrevious, pts - lastPTS < Self.throttleInterval { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let srcRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var src = vImage_Buffer(data: base, height: vImagePixelCount(srcH),
                                width: vImagePixelCount(srcW), rowBytes: srcRow)
        var scaled = vImage_Buffer(data: scaledBGRA, height: vImagePixelCount(Self.analyzeHeight),
                                   width: vImagePixelCount(Self.analyzeWidth), rowBytes: Self.analyzeWidth * 4)
        guard vImageScale_ARGB8888(&src, &scaled, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }

        // BGRA → luminance (Planar8): 0.114B + 0.587G + 0.299R, divisor 256.
        var gray = vImage_Buffer(data: currentGray, height: vImagePixelCount(Self.analyzeHeight),
                                 width: vImagePixelCount(Self.analyzeWidth), rowBytes: Self.analyzeWidth)
        let matrix: [Int16] = [29, 150, 77, 0]  // B, G, R, A in memory order
        guard vImageMatrixMultiply_ARGB8888ToPlanar8(&scaled, &gray, matrix, 256, nil, 0,
                                                      vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }

        defer {
            // Current frame becomes the reference for next time.
            memcpy(previousGray, currentGray, count)
            hasPrevious = true
            lastPTS = pts
        }

        guard hasPrevious else { return nil }  // first frame: just store, no verdict

        let thresh = min(255, max(0, pixelDelta))
        var changed = 0
        if let ignore = ignoreLookup {
            guard activeCount > 0 else { return (false, 0) }
            for i in 0..<count where !ignore[i]
                && abs(Int(currentGray[i]) - Int(previousGray[i])) > thresh {
                changed += 1
            }
            let fraction = Double(changed) / Double(activeCount)
            return (fraction > threshold, fraction)
        } else {
            for i in 0..<count where abs(Int(currentGray[i]) - Int(previousGray[i])) > thresh {
                changed += 1
            }
            let fraction = Double(changed) / Double(count)
            return (fraction > threshold, fraction)
        }
    }
}
