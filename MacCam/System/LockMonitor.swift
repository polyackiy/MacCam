import Foundation

/// Observes screen lock/unlock via `DistributedNotificationCenter` to drive the
/// optional guard mode.
final class LockMonitor {
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?

    private let center = DistributedNotificationCenter.default()
    private var observing = false

    func start() {
        guard !observing else { return }
        observing = true
        center.addObserver(self, selector: #selector(locked),
                           name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(unlocked),
                           name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    func stop() {
        guard observing else { return }
        observing = false
        center.removeObserver(self)
    }

    @objc private func locked() { onLock?() }
    @objc private func unlocked() { onUnlock?() }
}
