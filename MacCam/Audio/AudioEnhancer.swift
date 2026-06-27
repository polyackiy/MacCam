import Foundation
import AVFoundation

/// A second-order (biquad) IIR filter, Direct Form I. Pure and testable.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    struct State { var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0 }

    /// RBJ cookbook high-pass coefficients (normalised by a0).
    static func highpass(cutoff: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        guard sampleRate > 0, cutoff > 0, cutoff < sampleRate / 2 else { return Biquad() }
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float((1 + cosw) / 2 / a0),
            b1: Float(-(1 + cosw) / a0),
            b2: Float((1 + cosw) / 2 / a0),
            a1: Float(-2 * cosw / a0),
            a2: Float((1 - alpha) / a0))
    }

    @inline(__always)
    func step(_ x: Float, _ s: inout State) -> Float {
        let y = b0 * x + b1 * s.x1 + b2 * s.x2 - a1 * s.y1 - a2 * s.y2
        s.x2 = s.x1; s.x1 = x
        s.y2 = s.y1; s.y1 = y
        return y
    }
}

/// In-place voice cleanup for captured Float32 LPCM: an 80 Hz high-pass to remove
/// low-frequency rumble / handling noise, plus a gentle AGC that nudges the level
/// toward a target so quiet speech is more audible. Stateful across a clip (filter
/// memory + gain envelope); call `reset()` at each clip start. Non-Float32 audio
/// is left untouched.
final class AudioEnhancer {
    private let cutoffHz = 80.0
    private let targetRMS: Float = 0.10        // ≈ -20 dBFS
    private let minGain: Float = 0.5
    private let maxGain: Float = 6.0
    private let envelopeSmoothing: Float = 0.15

    private var rate = 0.0
    private var channels = 0
    private var filter = Biquad()
    private var states: [Biquad.State] = []
    private var envelope: Float = 0
    private var gain: Float = 1

    func reset() {
        rate = 0; channels = 0; states = []; envelope = 0; gain = 1
    }

    /// Steady-state AGC gain for a given (smoothed) RMS envelope. Pure/testable.
    static func targetGain(envelope: Float, target: Float, minGain: Float, maxGain: Float) -> Float {
        guard envelope > 1e-5 else { return maxGain }
        return min(max(target / envelope, minGain), maxGain)
    }

    private func configure(rate: Double, channels: Int) {
        guard rate != self.rate || channels != self.channels else { return }
        self.rate = rate
        self.channels = channels
        filter = Biquad.highpass(cutoff: cutoffHz, sampleRate: rate)
        states = Array(repeating: Biquad.State(), count: max(channels, 1))
        envelope = 0
        gain = 1
    }

    /// Apply the high-pass + AGC in place to the Float32 samples of `sampleBuffer`.
    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return }   // Float32 LPCM only

        let channelCount = Int(asbd.mChannelsPerFrame)
        guard channelCount > 0 else { return }
        configure(rate: asbd.mSampleRate, channels: channelCount)

        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, blockBuffer != nil else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(&abl)

        // Build (pointer, stride) per channel and a common frame count.
        var lanes: [(base: UnsafeMutablePointer<Float>, stride: Int)] = []
        var frames = 0
        if buffers.count == 1 {
            // Interleaved (or mono): one buffer holds `channelCount` channels.
            guard let raw = buffers[0].mData else { return }
            let base = raw.assumingMemoryBound(to: Float.self)
            frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            for ch in 0..<channelCount { lanes.append((base + ch, channelCount)) }
        } else {
            // Non-interleaved: one buffer per channel.
            for ch in 0..<min(buffers.count, channelCount) {
                guard let raw = buffers[ch].mData else { return }
                lanes.append((raw.assumingMemoryBound(to: Float.self), 1))
            }
            frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        }
        guard frames > 0, states.count >= lanes.count else { return }

        // 1) High-pass each channel; accumulate energy for the AGC.
        var sumSquares: Float = 0
        for (ch, lane) in lanes.enumerated() {
            for i in 0..<frames {
                let p = lane.base + i * lane.stride
                let y = filter.step(p.pointee, &states[ch])
                p.pointee = y
                sumSquares += y * y
            }
        }

        // 2) Gentle AGC: smooth the RMS, ramp gain toward the target across the buffer.
        let rms = (frames * lanes.count) > 0 ? (sumSquares / Float(frames * lanes.count)).squareRoot() : 0
        envelope += envelopeSmoothing * (rms - envelope)
        let target = Self.targetGain(envelope: envelope, target: targetRMS, minGain: minGain, maxGain: maxGain)
        let startGain = gain
        let denom = Float(max(frames - 1, 1))
        for i in 0..<frames {
            let g = startGain + (target - startGain) * (Float(i) / denom)
            for lane in lanes {
                let p = lane.base + i * lane.stride
                p.pointee *= g
            }
        }
        gain = target
    }
}
