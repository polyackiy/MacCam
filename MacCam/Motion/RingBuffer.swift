import Foundation

/// Thread-safe pre-roll buffer keeping the most recent `duration` seconds of
/// items, keyed by presentation timestamp. Generic so it can be tested without
/// real `CMSampleBuffer`s.
final class RingBuffer<T> {
    private let duration: Double
    private var items: [(pts: Double, value: T)] = []
    private let lock = NSLock()

    init(duration: Double) {
        self.duration = duration
    }

    func push(_ item: T, pts: Double) {
        lock.lock()
        defer { lock.unlock() }
        items.append((pts, item))
        let newest = pts
        while let first = items.first, newest - first.pts > duration {
            items.removeFirst()
        }
    }

    /// Oldest → newest items currently retained.
    func snapshot() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return items.map { $0.value }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
    }
}
