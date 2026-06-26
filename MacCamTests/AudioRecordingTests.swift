import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import MacCam

/// Feeds synthetic video + audio through RecordingController with audio enabled
/// and asserts the produced clip actually contains an audio track. Reproduces
/// the "audio not recorded" bug at the RecordingController layer (no camera).
final class AudioRecordingTests: XCTestCase {
    private let width = 1280, height = 720
    private let sampleRate: Double = 44_100

    private func settings() -> AppSettings {
        AppSettings(cameraID: nil, targetFPS: 30, sensitivity: 2, pixelDelta: 25,
                    postMotionCooldown: 1, minClipLength: 1, maxClipLength: 60,
                    preRollEnabled: false, preRoll: 3, audioEnabled: true,
                    audioDeviceID: nil, triggerMode: .motion, voiceSensitivity: 2, audioOnly: false, codec: .hevc, quality: .medium, autoCleanup: false,
                    cleanupDays: 14, guardMode: false,
                    monitoringSchedule: WeeklySchedule(), recordingSchedule: WeeklySchedule(),
                    maxStorageGB: 0, minFreeSpaceGB: 0,
                    diskLimitPolicy: .loop, detectionMask: "")
    }

    private func makeVideoSample(pts: CMTime) -> CMSampleBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pb!, formatDescriptionOut: &fmt)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb!,
                                           dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                           formatDescription: fmt!, sampleTiming: &timing,
                                           sampleBufferOut: &sample)
        return sample!
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

    func testClipContainsAudioTrack() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacCamAudio-\(ProcessInfo.processInfo.globallyUniqueString)")
        let fileStore = FileStore(defaults: UserDefaults.standard, defaultOverride: tmp)
        let rc = RecordingController(fileStore: fileStore, settings: settings())

        let clipWritten = expectation(description: "clip finalized")
        clipWritten.assertForOverFulfill = false
        rc.onStateChange = { _, name in if name != nil { clipWritten.fulfill() } }

        let framesPerAudio = 1024
        var audioPTS = CMTime.zero
        for i in 0..<67 {
            let vpts = CMTime(value: CMTimeValue(i), timescale: 30)
            rc.handle(video: makeVideoSample(pts: vpts), motion: i < 30)
            // Interleave ~2 audio buffers per video frame to cover the timeline.
            for _ in 0..<2 {
                rc.handle(audio: makeAudioSample(pts: audioPTS, frames: framesPerAudio))
                audioPTS = CMTimeAdd(audioPTS, CMTime(value: CMTimeValue(framesPerAudio), timescale: Int32(sampleRate)))
            }
        }

        wait(for: [clipWritten], timeout: 10)

        let clip = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "mov" }
        let asset = AVURLAsset(url: try XCTUnwrap(clip))
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 1, "video track expected")
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1, "audio track expected")

        try? FileManager.default.removeItem(at: tmp)
    }
}
