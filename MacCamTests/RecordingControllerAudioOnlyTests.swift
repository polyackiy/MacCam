import XCTest
import AVFoundation
import CoreMedia
@testable import MacCam

/// Drives RecordingController through the audio-only path (no video frames) and
/// asserts the produced clip has exactly one audio track and no video track.
final class RecordingControllerAudioOnlyTests: XCTestCase {
    private let sampleRate: Double = 44_100

    private func settings() -> AppSettings {
        AppSettings(cameraID: nil, targetFPS: 30, sensitivity: 2, pixelDelta: 25,
                    postMotionCooldown: 1, minClipLength: 1, maxClipLength: 60,
                    preRollEnabled: false, preRoll: 3, audioEnabled: true,
                    audioDeviceID: nil, triggerMode: .motion, voiceSensitivity: 2, audioOnly: false,
                    codec: .hevc, quality: .medium, autoCleanup: false,
                    cleanupDays: 14, guardMode: false,
                    monitoringSchedule: WeeklySchedule(), recordingSchedule: WeeklySchedule(),
                    maxStorageGB: 0, minFreeSpaceGB: 0,
                    diskLimitPolicy: .loop, detectionMask: "")
    }

    private func makeAudioSample(pts: CMTime, frames: Int) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let byteCount = frames * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                           blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                           flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                             sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: [2], sampleBufferOut: &sample)
        return sample!
    }

    private func makeStore() -> (RecordingController, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacCamAudioOnly-\(ProcessInfo.processInfo.globallyUniqueString)")
        let fileStore = FileStore(defaults: UserDefaults.standard, defaultOverride: tmp)
        return (RecordingController(fileStore: fileStore, settings: settings()), tmp)
    }

    private func makeFloat32AudioSample(pts: CMTime, frames: Int) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let byteCount = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                           blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                           flags: 0, blockBufferOut: &block)
        var samples = (0..<frames).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
        samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                             sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 1, sampleSizeArray: [4], sampleBufferOut: &sample)
        return sample!
    }

    /// Float32 audio with voice enhancement on (the default) must still produce a
    /// valid, encodable audio track — i.e. the freshly-wrapped sample buffer the
    /// enhancer returns is accepted by AVAssetWriter.
    func testAudioOnlyFloat32WithEnhancementProducesAudioTrack() throws {
        let (rc, tmp) = makeStore()
        let clipWritten = expectation(description: "clip finalized")
        clipWritten.assertForOverFulfill = false
        rc.onStateChange = { _, name in if name != nil { clipWritten.fulfill() } }

        let framesPerAudio = 1024
        var audioPTS = CMTime.zero
        for i in 0..<260 {
            rc.handle(audioOnly: makeFloat32AudioSample(pts: audioPTS, frames: framesPerAudio),
                      trigger: i < 130)
            audioPTS = CMTimeAdd(audioPTS, CMTime(value: CMTimeValue(framesPerAudio), timescale: Int32(sampleRate)))
        }
        wait(for: [clipWritten], timeout: 10)

        let clip = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "m4a" }
        let asset = AVURLAsset(url: try XCTUnwrap(clip))
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1,
                       "enhanced Float32 audio must produce a valid audio track")
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 0)
        try? FileManager.default.removeItem(at: tmp)
    }

    func testAudioOnlyClipHasAudioTrackAndNoVideoTrack() throws {
        let (rc, tmp) = makeStore()
        let clipWritten = expectation(description: "clip finalized")
        clipWritten.assertForOverFulfill = false
        rc.onStateChange = { _, name in if name != nil { clipWritten.fulfill() } }

        let framesPerAudio = 1024
        var audioPTS = CMTime.zero
        // ~6s of audio: trigger true for the first half, false for the second so
        // the clip starts, satisfies minClip, then finalizes after cooldown.
        for i in 0..<260 {
            rc.handle(audioOnly: makeAudioSample(pts: audioPTS, frames: framesPerAudio),
                      trigger: i < 130)
            audioPTS = CMTimeAdd(audioPTS, CMTime(value: CMTimeValue(framesPerAudio), timescale: Int32(sampleRate)))
        }

        wait(for: [clipWritten], timeout: 10)

        let clip = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "m4a" }
        let asset = AVURLAsset(url: try XCTUnwrap(clip))
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1, "audio track expected")
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 0, "no video track expected")

        try? FileManager.default.removeItem(at: tmp)
    }

    func testAudioOnlyRotatesIntoMultipleClips() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacCamAudioOnlyRot-\(ProcessInfo.processInfo.globallyUniqueString)")
        let fileStore = FileStore(defaults: UserDefaults.standard, defaultOverride: tmp)
        var s = settings()
        s.maxClipLength = 2   // force rotation on a short PTS window
        let rc = RecordingController(fileStore: fileStore, settings: s)
        // Advance the injected clock a minute per call so each rotated clip gets a
        // distinct second-granularity filename (clock() is only consulted when a
        // writer opens, since the recording schedule is disabled).
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var tick = 0
        rc.clock = { defer { tick += 1 }; return base.addingTimeInterval(Double(tick) * 60) }

        // Exactly two finalizations: one rotation (at PTS ≥ 2s) + the closing
        // stop(). Waiting for both guarantees every clip's finishWriting has
        // completed before we enumerate, so no half-written file is inspected.
        let twoClips = expectation(description: "two clips finalized")
        twoClips.expectedFulfillmentCount = 2
        twoClips.assertForOverFulfill = false
        rc.onStateChange = { _, name in if name != nil { twoClips.fulfill() } }

        let framesPerAudio = 1024
        var audioPTS = CMTime.zero
        // ~3.25s of PTS with sustained trigger → one rotation at 2s (stays below
        // the second rotation at 4s), so exactly two clips form.
        for _ in 0..<140 {
            rc.handle(audioOnly: makeAudioSample(pts: audioPTS, frames: framesPerAudio), trigger: true)
            audioPTS = CMTimeAdd(audioPTS, CMTime(value: CMTimeValue(framesPerAudio), timescale: Int32(sampleRate)))
        }
        rc.stop()   // finalize the last open clip

        wait(for: [twoClips], timeout: 10)

        let clips = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m4a" }
        XCTAssertGreaterThanOrEqual(clips.count, 2, "rotation should produce multiple clips")
        for url in clips {
            let asset = AVURLAsset(url: url)
            XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1, "each clip has one audio track")
            XCTAssertEqual(asset.tracks(withMediaType: .video).count, 0, "no video track in audio-only clips")
        }

        try? FileManager.default.removeItem(at: tmp)
    }

    func testNoTriggerProducesNoClip() throws {
        let (rc, tmp) = makeStore()
        let framesPerAudio = 1024
        var audioPTS = CMTime.zero
        for _ in 0..<100 {
            rc.handle(audioOnly: makeAudioSample(pts: audioPTS, frames: framesPerAudio), trigger: false)
            audioPTS = CMTimeAdd(audioPTS, CMTime(value: CMTimeValue(framesPerAudio), timescale: Int32(sampleRate)))
        }
        let clips = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { ClipNaming.isClip($0) }) ?? []
        XCTAssertTrue(clips.isEmpty, "no clip should be produced without a trigger")
        try? FileManager.default.removeItem(at: tmp)
    }
}
