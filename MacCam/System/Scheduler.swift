import Foundation

/// Evaluates the monitoring window on a timer and exposes the recording gate.
/// All callbacks fire on the main queue.
final class Scheduler {
    var onMonitoringWindowChange: ((Bool) -> Void)?

    private var monitoring = WeeklySchedule()
    private var recording = WeeklySchedule()
    private let calendar = Calendar.current
    private let now: () -> Date
    private var timer: Timer?
    private var lastActive = false

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func update(monitoring: WeeklySchedule, recording: WeeklySchedule) {
        self.monitoring = monitoring
        self.recording = recording
        evaluate()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.evaluate() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func isMonitoringWindowActive(at date: Date = Date()) -> Bool {
        monitoring.isActive(at: date, calendar: calendar)
    }

    func isRecordingAllowed(at date: Date = Date()) -> Bool {
        guard recording.enabled else { return true }
        return recording.isActive(at: date, calendar: calendar)
    }

    private func evaluate() {
        let active = isMonitoringWindowActive(at: now())
        guard active != lastActive else { return }
        lastActive = active
        DispatchQueue.main.async { [weak self] in self?.onMonitoringWindowChange?(active) }
    }
}
