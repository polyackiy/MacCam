import Foundation

enum RecState: Equatable {
    case idle
    case recording
}

enum RecAction: Equatable {
    case none           // idle, nothing to do
    case startClip      // open a new writer and begin recording
    case appendOnly     // keep appending the current clip
    case finishAndIdle  // close the clip, go back to idle
    case rotate         // close current clip and immediately open the next
}

/// Pure recording state machine. Time is injected (seconds, monotonic source
/// timestamps), so no timers or threads are involved and transitions are fully
/// testable.
struct RecordingFSM {
    var minClip: Double
    var maxClip: Double
    var cooldown: Double

    private(set) var state: RecState = .idle
    private var clipStart: Double = 0
    private var lastMotion: Double = 0

    init(minClip: Double = 5, maxClip: Double = 60, cooldown: Double = 5) {
        self.minClip = minClip
        self.maxClip = maxClip
        self.cooldown = cooldown
    }

    mutating func step(motion: Bool, now: Double) -> RecAction {
        switch state {
        case .idle:
            guard motion else { return .none }
            state = .recording
            clipStart = now
            lastMotion = now
            return .startClip

        case .recording:
            if motion { lastMotion = now }

            if now - clipStart >= maxClip {
                clipStart = now
                return .rotate
            }

            let quietLongEnough = now - lastMotion >= cooldown
            let clipLongEnough = now - clipStart >= minClip
            if quietLongEnough && clipLongEnough {
                state = .idle
                return .finishAndIdle
            }
            return .appendOnly
        }
    }
}
