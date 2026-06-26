import Foundation

/// Keeps "voice active" true for `hold` seconds after the last detected speech,
/// smoothing the gaps between the analyzer's ~1 s windows.
struct VoiceActivity {
    private(set) var lastSpeech: Date?

    mutating func noteSpeech(at date: Date) { lastSpeech = date }
    mutating func reset() { lastSpeech = nil }

    func isActive(at date: Date, hold: TimeInterval) -> Bool {
        guard let lastSpeech else { return false }
        return date.timeIntervalSince(lastSpeech) < hold
    }
}
