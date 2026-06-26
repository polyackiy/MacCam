import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import MacCam

final class RecordingControllerScheduleTests: XCTestCase {
    private func pixelSample(pts: CMTime) -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pb!, formatDescriptionOut: &fmt)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb!,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt!,
            sampleTiming: &timing, sampleBufferOut: &sb)
        return sb!
    }

    private func settings(_ schedule: WeeklySchedule) -> AppSettings {
        AppSettings(cameraID: nil, targetFPS: 30, sensitivity: 2, pixelDelta: 25,
            postMotionCooldown: 5, minClipLength: 1, maxClipLength: 60, preRollEnabled: false,
            preRoll: 3, audioEnabled: false, audioDeviceID: nil, codec: .hevc, quality: .medium,
            autoCleanup: false, cleanupDays: 14, guardMode: false,
            monitoringSchedule: WeeklySchedule(), recordingSchedule: schedule,
            maxStorageGB: 0, minFreeSpaceGB: 0, diskLimitPolicy: .loop, detectionMask: "")
    }

    private func makeController(_ schedule: WeeklySchedule) -> (RecordingController, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Sched-\(ProcessInfo.processInfo.globallyUniqueString)")
        let fs = FileStore(defaults: .standard, defaultOverride: tmp)
        let rc = RecordingController(fileStore: fs, settings: settings(schedule))
        return (rc, tmp)
    }

    func testDisabledScheduleRecordsOnMotion() {
        let (rc, tmp) = makeController(WeeklySchedule())   // disabled ⇒ always allowed
        rc.clock = { Date(timeIntervalSince1970: 0) }
        rc.handle(video: pixelSample(pts: CMTime(value: 0, timescale: 30)), motion: true)
        XCTAssertTrue(rc.isRecording)
        rc.stop()
        try? FileManager.default.removeItem(at: tmp)
    }

    func testInactiveScheduleSuppressesRecording() {
        // Active only Sunday 00:00–00:30; epoch 0 is Thursday 1970-01-01 → not in window.
        let sched = WeeklySchedule(enabled: true, days: [.sun],
            start: TimeOfDay(minutes: 0), end: TimeOfDay(minutes: 30))
        let (rc, tmp) = makeController(sched)
        rc.clock = { Date(timeIntervalSince1970: 0) }
        rc.handle(video: pixelSample(pts: CMTime(value: 0, timescale: 30)), motion: true)
        XCTAssertFalse(rc.isRecording)
        rc.stop()
        try? FileManager.default.removeItem(at: tmp)
    }
}
