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
                    audioDeviceID: nil, voiceTriggerEnabled: false, triggerMode: .motion, voiceSensitivity: 2, audioOnly: false,
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
            .first { $0.pathExtension == "mov" }
        let asset = AVURLAsset(url: try XCTUnwrap(clip))
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1, "audio track expected")
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 0, "no video track expected")

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
        let movs = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }) ?? []
        XCTAssertTrue(movs.isEmpty, "no clip should be produced without a trigger")
        try? FileManager.default.removeItem(at: tmp)
    }
}
