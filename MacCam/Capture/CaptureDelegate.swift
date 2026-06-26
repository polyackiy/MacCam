import Foundation
import AVFoundation

/// Routes capture sample buffers. The trigger source depends on `triggerMode`:
/// continuous (always), motion (vImage), voice (SoundAnalysis), or both. In
/// audio-only mode there is no video output, so audio buffers drive recording
/// directly via `handle(audioOnly:trigger:)`. `triggerMode`/`audioOnly` are set
/// from the main queue and read on the capture queues under a small lock.
final class CaptureDelegate: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    private let detector: MotionDetector
    private let recorder: RecordingController
    private let voiceDetector: VoiceDetector
    private var lastMotion = false   // read/written only on the video queue

    private let lock = NSLock()
    private var triggerMode: TriggerMode = .motion
    private var audioOnly = false

    init(detector: MotionDetector, recorder: RecordingController, voiceDetector: VoiceDetector) {
        self.detector = detector
        self.recorder = recorder
        self.voiceDetector = voiceDetector
    }

    /// Staged from the main queue on settings changes.
    func setTriggerMode(_ mode: TriggerMode) { lock.lock(); triggerMode = mode; lock.unlock() }
    func setAudioOnly(_ value: Bool) { lock.lock(); audioOnly = value; lock.unlock() }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock(); let mode = triggerMode; let audioOnly = self.audioOnly; lock.unlock()

        if output is AVCaptureAudioDataOutput {
            // Keep these paired: `analyze` is gated by `usesVoice` (so the analyzer
            // is only fed when voice is a trigger source), and `isActive()` is
            // short-circuited by `isContinuous`. `isActive()` is wall-clock based
            // (a hold window on `Date()`), while the recorder's FSM advances on
            // buffer PTS — fine for real-time capture where the two track closely.
            if mode.usesVoice { voiceDetector.analyze(sampleBuffer) }
            if audioOnly {
                let trigger = mode.isContinuous || voiceDetector.isActive()
                recorder.handle(audioOnly: sampleBuffer, trigger: trigger)
            } else {
                recorder.handle(audio: sampleBuffer)
            }
            return
        }

        // Video branch — absent in audio-only mode (no video output exists).
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let trigger: Bool
        switch mode {
        case .continuous:
            trigger = true
        case .motion:
            if let result = detector.analyze(pixelBuffer, pts: pts) { lastMotion = result.motion }
            trigger = lastMotion
        case .voice:
            trigger = voiceDetector.isActive()
        case .motionAndVoice:
            if let result = detector.analyze(pixelBuffer, pts: pts) { lastMotion = result.motion }
            trigger = lastMotion || voiceDetector.isActive()
        }
        recorder.handle(video: sampleBuffer, motion: trigger)
    }
}
