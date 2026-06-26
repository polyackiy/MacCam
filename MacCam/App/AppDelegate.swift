import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let fileStore = FileStore()
    private(set) var camera: CameraManager!
    private var detector: MotionDetector!
    private var recorder: RecordingController!
    private var captureDelegate: CaptureDelegate!
    private let menuBar = MenuBarController()
    private let lockMonitor = LockMonitor()

    private var monitoring = false
    private var manualOverride = false
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let snap = settings.snapshot()
        camera = CameraManager(settings: snap)
        detector = MotionDetector(pixelDelta: snap.pixelDelta, threshold: snap.motionThreshold)
        recorder = RecordingController(fileStore: fileStore, settings: snap)
        captureDelegate = CaptureDelegate(detector: detector, recorder: recorder)

        recorder.onStateChange = { [weak self] _, _ in self?.updateMenu() }
        wireMenu()
        wireGuard()
        menuBar.setLaunchAtLogin(LaunchAtLogin.isEnabled)
        lockMonitor.start()

        requestAccess()
        updateMenu()
        NSLog("MacCam launched")
    }

    // MARK: Wiring

    private func wireMenu() {
        menuBar.onToggleMonitoring = { [weak self] in
            guard let self else { return }
            if self.monitoring { self.stopMonitoring() } else { self.startMonitoring(manual: true) }
        }
        menuBar.onOpenFolder = { [weak self] in self?.fileStore.openInFinder() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBar.onToggleLaunchAtLogin = { [weak self] in
            guard let self else { return }
            let new = !LaunchAtLogin.isEnabled
            LaunchAtLogin.setEnabled(new)
            self.settings.launchAtLogin = LaunchAtLogin.isEnabled
            self.menuBar.setLaunchAtLogin(LaunchAtLogin.isEnabled)
        }
        menuBar.onQuit = { [weak self] in
            self?.stopMonitoring()
            NSApp.terminate(nil)
        }
    }

    private func wireGuard() {
        lockMonitor.onLock = { [weak self] in
            guard let self, self.settings.guardMode, !self.monitoring else { return }
            self.startMonitoring(manual: false)
        }
        lockMonitor.onUnlock = { [weak self] in
            guard let self, self.monitoring, !self.manualOverride else { return }
            self.stopMonitoring()
        }
    }

    // MARK: Monitoring control

    private func startMonitoring(manual: Bool) {
        if manual { manualOverride = true }
        let snap = settings.snapshot()
        applyToDetector(snap)
        recorder.updateSettings(snap)
        camera.configure(settings: snap, delegate: captureDelegate)
        camera.start()
        monitoring = true
        if snap.autoCleanup { fileStore.runCleanup(olderThanDays: snap.cleanupDays) }
        updateMenu()
    }

    private func stopMonitoring() {
        manualOverride = false
        camera.stop()
        recorder.stop()
        monitoring = false
        updateMenu()
    }

    private func reconfigureIfMonitoring() {
        guard monitoring else { return }
        let snap = settings.snapshot()
        applyToDetector(snap)
        recorder.updateSettings(snap)
        camera.configure(settings: snap, delegate: captureDelegate)
    }

    private func applyToDetector(_ snap: AppSettings) {
        detector.pixelDelta = snap.pixelDelta
        detector.threshold = snap.motionThreshold
        detector.reset()
    }

    private func updateMenu() {
        DispatchQueue.main.async {
            if !self.monitoring {
                self.menuBar.setState(.off, statusText: "Idle")
            } else if self.recorder.isRecording {
                self.menuBar.setState(.recording, statusText: "Recording…")
            } else {
                let last = self.recorder.lastClipName.map { "Last clip: \($0)" } ?? "Monitoring"
                self.menuBar.setState(.monitoring, statusText: last)
            }
        }
    }

    // MARK: Settings window

    private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings,
                camera: camera,
                fileStore: fileStore,
                onReconfigure: { [weak self] in self?.reconfigureIfMonitoring() },
                onLaunchAtLoginChange: { [weak self] enabled in
                    LaunchAtLogin.setEnabled(enabled)
                    self?.settings.launchAtLogin = LaunchAtLogin.isEnabled
                    self?.menuBar.setLaunchAtLogin(LaunchAtLogin.isEnabled)
                })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "MacCam Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: Permissions

    private func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            if !granted { DispatchQueue.main.async { self?.showAccessDenied(.video) } }
        }
        if settings.audioEnabled {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    private func showAccessDenied(_ media: AVMediaType) {
        let alert = NSAlert()
        alert.messageText = "Camera access denied"
        alert.informativeText = "MacCam needs camera access to monitor for motion. "
            + "Enable it in System Settings → Privacy & Security → Camera."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
