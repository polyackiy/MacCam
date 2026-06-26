import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import MacCam

/// End-to-end check of the real AVAssetWriter recording path: feed synthetic
/// frames through RecordingController and assert a valid, playable HEVC .mov is
/// produced on disk. No camera required.
final class RecordingIntegrationTests: XCTestCase {
    private let width = 1280, height = 720

    private func makeSettings() -> AppSettings {
        AppSettings(cameraID: nil, targetFPS: 30, sensitivity: 2, pixelDelta: 25,
                    postMotionCooldown: 1, minClipLength: 1, maxClipLength: 60,
                    preRollEnabled: false, preRoll: 3, audioEnabled: false,
                    audioDeviceID: nil, codec: .hevc, quality: .medium, autoCleanup: false,
                    cleanupDays: 14, guardMode: false,
                    maxStorageGB: 0, minFreeSpaceGB: 0,
                    diskLimitPolicy: .loop, detectionMask: "")
    }

    private func makeVideoSample(pts: CMTime) -> CMSampleBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(truncatingIfNeeded: Int(pts.value) * 40), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: buffer, formatDescriptionOut: &fmt)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                           dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                           formatDescription: fmt!, sampleTiming: &timing,
                                           sampleBufferOut: &sample)
        return sample!
    }

    func testProducesPlayableHEVCClip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacCamITest-\(ProcessInfo.processInfo.globallyUniqueString)")
        let fileStore = FileStore(defaults: UserDefaults.standard, defaultOverride: tmp)
        let rc = RecordingController(fileStore: fileStore, settings: makeSettings())

        let clipWritten = expectation(description: "clip finalized")
        clipWritten.assertForOverFulfill = false
        rc.onStateChange = { _, name in if name != nil { clipWritten.fulfill() } }

        // 0.0–0.97s: motion present (starts and grows the clip).
        for i in 0..<30 {
            rc.handle(video: makeVideoSample(pts: CMTime(value: CMTimeValue(i), timescale: 30)), motion: true)
        }
        // 1.0–2.2s: quiet, until cooldown + min-clip elapse and the clip finalizes.
        for i in 30..<67 {
            rc.handle(video: makeVideoSample(pts: CMTime(value: CMTimeValue(i), timescale: 30)), motion: false)
        }

        wait(for: [clipWritten], timeout: 10)

        let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" }
        XCTAssertEqual(files.count, 1, "exactly one clip expected")
        let clip = files[0]
        XCTAssertTrue(clip.lastPathComponent.hasPrefix("MacCam_"))

        let asset = AVURLAsset(url: clip)
        let videoTracks = asset.tracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1, "one video track expected")

        let track = videoTracks[0]
        XCTAssertEqual(Int(track.naturalSize.width), width)
        XCTAssertEqual(Int(track.naturalSize.height), height)

        let desc = track.formatDescriptions.first as! CMFormatDescription
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(desc), kCMVideoCodecType_HEVC,
                       "codec should be HEVC")

        try? FileManager.default.removeItem(at: tmp)
    }
}
