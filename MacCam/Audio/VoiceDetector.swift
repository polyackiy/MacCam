import Foundation
import AVFoundation
import SoundAnalysis

/// Detects human speech in the mic stream with on-device SoundAnalysis and
/// exposes a thread-safe "voice active" flag. Fed audio buffers on the capture
/// audio queue; the SoundAnalysis observer updates activity under a lock.
final class VoiceDetector: NSObject, SNResultsObserving {
    let holdSeconds: TimeInterval = 2.0

    private let lock = NSLock()
    private var enabled = false
    private var threshold = 0.6
    private var activity = VoiceActivity()

    private var analyzer: SNAudioStreamAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var framePosition: AVAudioFramePosition = 0

    /// Thread-safe staging (called from the main queue on settings changes).
    /// Clearing the staged enable also clears any pending activity, so disabling
    /// the trigger stops firing immediately (no ~holdSeconds tail).
    func requestUpdate(enabled: Bool, threshold: Double) {
        lock.lock()
        self.enabled = enabled
        self.threshold = threshold
        if !enabled { activity.reset() }
        lock.unlock()
    }

    func isActive(at date: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activity.isActive(at: date, hold: holdSeconds)
    }

    func reset() {
        lock.lock()
        activity.reset()
        analyzer = nil
        analyzerFormat = nil
        framePosition = 0
        lock.unlock()
    }

    /// Called on the capture audio queue for each audio sample buffer.
    func analyze(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); let on = enabled; lock.unlock()
        guard on, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        lock.lock()
        // Rebuild the analyzer if absent or if the audio format changed mid-stream
        // (e.g. the user switched microphone), so it never receives mismatched
        // buffers and silently stops classifying.
        if analyzer == nil || analyzerFormat.map({ !$0.isEqual(pcm.format) }) ?? true {
            setupAnalyzerLocked(format: pcm.format)
        }
        let analyzer = self.analyzer
        let position = framePosition
        framePosition += AVAudioFramePosition(pcm.frameLength)
        lock.unlock()

        // Not under the lock: the observer may be invoked synchronously here and
        // it also takes the lock.
        analyzer?.analyze(pcm, atAudioFramePosition: position)
    }

    private func setupAnalyzerLocked(format: AVAudioFormat) {
        let analyzer = SNAudioStreamAnalyzer(format: format)
        if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            try? analyzer.add(request, withObserver: self)
        }
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.framePosition = 0
    }

    // MARK: SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let speech = result.classification(forIdentifier: "speech") else { return }
        lock.lock()
        if Double(speech.confidence) >= threshold { activity.noteSpeech(at: Date()) }
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        Log.capture.error("Voice analysis failed: \(error.localizedDescription, privacy: .public)")
        lock.lock()
        analyzer = nil   // force a rebuild on the next buffer
        analyzerFormat = nil
        lock.unlock()
    }

    func requestDidComplete(_ request: SNRequest) {}

    // MARK: Buffer conversion

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
