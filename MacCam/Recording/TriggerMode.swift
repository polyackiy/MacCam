import Foundation

/// What starts a recording clip. Replaces the old standalone "voice trigger"
/// boolean with an explicit choice. `Continuous` records whenever monitoring is
/// active; `Voice` and `Motion+Voice` require audio recording to be enabled.
/// `allowsAudioOnly` marks the modes that can record without a camera (the
/// camera is only needed when motion is a trigger source).
enum TriggerMode: String, CaseIterable, Identifiable {
    case continuous, motion, voice, motionAndVoice

    var id: String { rawValue }

    var usesMotion: Bool { self == .motion || self == .motionAndVoice }
    var usesVoice: Bool { self == .voice || self == .motionAndVoice }
    var isContinuous: Bool { self == .continuous }
    var allowsAudioOnly: Bool { self == .continuous || self == .voice }

    var label: String {
        switch self {
        case .continuous: return "Continuous"
        case .motion: return "Motion"
        case .voice: return "Voice"
        case .motionAndVoice: return "Motion + Voice"
        }
    }
}
