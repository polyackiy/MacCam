import XCTest
import AVFoundation
import CoreMedia
@testable import MacCam

final class AudioEnhancerTests: XCTestCase {
    func testProcessesFloat32BufferInPlaceAndRemovesDC() {
        let enhancer = AudioEnhancer()
        let rate = 48000.0
        var last: [Float] = []
        // Feed constant-DC Float32 buffers; the high-pass should drive the output
        // toward zero, exercising the real CMSampleBuffer/AudioBufferList glue.
        for _ in 0..<60 {
            let buffer = Self.makeFloat32Buffer(value: 0.3, frames: 1024, sampleRate: rate)
            enhancer.process(buffer)
            last = Self.readFloats(buffer)
        }
        XCTAssertFalse(last.isEmpty)
        XCTAssertTrue(last.allSatisfy { $0.isFinite }, "output must be finite")
        XCTAssertLessThan(last.map { abs($0) }.max() ?? 1, 0.05, "DC should be high-passed away")
    }

    func testLeavesInt16BufferUntouched() {
        // Non-Float32 audio must pass through unchanged (no crash, no mutation).
        let enhancer = AudioEnhancer()
        let buffer = Self.makeInt16Buffer(value: 1000, frames: 512)
        enhancer.process(buffer)
        let samples = Self.readInt16(buffer)
        XCTAssertEqual(samples.first, 1000)
        XCTAssertTrue(samples.allSatisfy { $0 == 1000 }, "Int16 must be untouched")
    }

    private static func makeFloat32Buffer(value: Float, frames: Int, sampleRate: Double) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        return makeBuffer(&asbd, bytesPerFrame: 4, frames: frames) { block, byteCount in
            var samples = [Float](repeating: value, count: frames)
            samples.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: byteCount)
            }
        }
    }

    private static func makeInt16Buffer(value: Int16, frames: Int) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        return makeBuffer(&asbd, bytesPerFrame: 2, frames: frames) { block, byteCount in
            var samples = [Int16](repeating: value, count: frames)
            samples.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: byteCount)
            }
        }
    }

    private static func makeBuffer(_ asbd: inout AudioStreamBasicDescription, bytesPerFrame: Int,
                                   frames: Int, fill: (CMBlockBuffer, Int) -> Void) -> CMSampleBuffer {
        var fmt: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                                       layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &fmt)
        let byteCount = frames * bytesPerFrame
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                           blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                           flags: 0, blockBufferOut: &block)
        fill(block!, byteCount)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(asbd.mSampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                             sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: [bytesPerFrame], sampleBufferOut: &sample)
        return sample!
    }

    private static func rawData(_ sampleBuffer: CMSampleBuffer) -> (UnsafeMutableRawPointer, Int)? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let ptr else { return nil }
        return (UnsafeMutableRawPointer(ptr), length)
    }

    private static func readFloats(_ sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let (raw, length) = rawData(sampleBuffer) else { return [] }
        let count = length / MemoryLayout<Float>.size
        let p = raw.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }

    private static func readInt16(_ sampleBuffer: CMSampleBuffer) -> [Int16] {
        guard let (raw, length) = rawData(sampleBuffer) else { return [] }
        let count = length / MemoryLayout<Int16>.size
        let p = raw.assumingMemoryBound(to: Int16.self)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }

    func testHighpassRejectsDC() {
        let hp = Biquad.highpass(cutoff: 80, sampleRate: 48000)
        var s = Biquad.State()
        var y: Float = 0
        for _ in 0..<4800 { y = hp.step(1.0, &s) }   // 0.1 s of DC
        XCTAssertLessThan(abs(y), 0.05, "high-pass should reject DC")
    }

    func testHighpassPassesHighFrequency() {
        let hp = Biquad.highpass(cutoff: 80, sampleRate: 48000)
        var s = Biquad.State()
        var tail: [Float] = []
        for i in 0..<2000 {
            let x: Float = (i % 2 == 0) ? 1 : -1   // alternating = Nyquist
            let y = hp.step(x, &s)
            if i >= 1900 { tail.append(abs(y)) }
        }
        let avg = tail.reduce(0, +) / Float(tail.count)
        XCTAssertGreaterThan(avg, 0.9, "high-pass should pass high frequencies near unity")
    }

    func testTargetGainClampsAndDirection() {
        // Quiet (low envelope) → boost, clamped at maxGain.
        XCTAssertEqual(AudioEnhancer.targetGain(envelope: 0.001, target: 0.1, minGain: 0.5, maxGain: 6),
                       6, accuracy: 0.001)
        // Loud (high envelope) → attenuate, clamped at minGain.
        XCTAssertEqual(AudioEnhancer.targetGain(envelope: 1.0, target: 0.1, minGain: 0.5, maxGain: 6),
                       0.5, accuracy: 0.001)
        // Mid → target / envelope.
        XCTAssertEqual(AudioEnhancer.targetGain(envelope: 0.05, target: 0.1, minGain: 0.5, maxGain: 6),
                       2.0, accuracy: 0.001)
    }

    func testTargetGainZeroEnvelope() {
        XCTAssertEqual(AudioEnhancer.targetGain(envelope: 0, target: 0.1, minGain: 0.5, maxGain: 6),
                       6, accuracy: 0.001)
    }
}
