import Foundation
import AVFoundation

/// Routes capture sample buffers: every video frame is forwarded to the
/// recorder (so clips are smooth), while motion analysis runs throttled inside
/// the detector. The last motion verdict is reused on throttled frames.
final class CaptureDelegate: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    private let detector: MotionDetector
    private let recorder: RecordingController
    private let voiceDetector: VoiceDetector
    private var lastMotion = false

    init(detector: MotionDetector, recorder: RecordingController, voiceDetector: VoiceDetector) {
        self.detector = detector
        self.recorder = recorder
        self.voiceDetector = voiceDetector
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            recorder.handle(audio: sampleBuffer)
            voiceDetector.analyze(sampleBuffer)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if let result = detector.analyze(pixelBuffer, pts: pts) {
            lastMotion = result.motion
        }
        let trigger = lastMotion || voiceDetector.isActive()
        recorder.handle(video: sampleBuffer, motion: trigger)
    }
}
