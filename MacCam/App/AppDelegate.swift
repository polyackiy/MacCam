import AppKit
import AVFoundation
import SwiftUI
import Combine

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
    private var stoppedStatus: String?   // sticky menu reason shown while idle
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var zoneWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let snap = settings.snapshot()
        camera = CameraManager(settings: snap)
        detector = MotionDetector(pixelDelta: snap.pixelDelta, threshold: snap.motionThreshold)
        recorder = RecordingController(fileStore: fileStore, settings: snap)
        captureDelegate = CaptureDelegate(detector: detector, recorder: recorder)

        recorder.onStateChange = { [weak self] _, _ in self?.updateMenu() }
        wireStorageGate()
        wireMenu()
        wireGuard()
        menuBar.setLaunchAtLogin(LaunchAtLogin.isEnabled)
        updateMenuBarAppearance()
        lockMonitor.start()

        // Apply detector/recorder-affecting settings live while monitoring,
        // without rebuilding the capture session (camera/FPS/audio changes go
        // through reconfigureIfMonitoring instead). objectWillChange fires
        // *before* the @Published value is written, so the async hop is
        // load-bearing: it defers the read until after the (main-thread)
        // mutation completes, giving us the new value.
        settings.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async {
                    self?.applyLiveSettings()
                    self?.updateMenuBarAppearance()
                }
            }
            .store(in: &cancellables)

        requestAccess()
        updateMenu()
        Log.app.info("MacCam launched")
    }

    // MARK: Wiring

    private func wireMenu() {
        menuBar.onToggleMonitoring = { [weak self] in
            guard let self else { return }
            if self.monitoring { self.stopMonitoring() } else { self.startMonitoring(manual: true) }
        }
        menuBar.onOpenFolder = { [weak self] in self?.fileStore.openInFinder() }
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBar.onAbout = { [weak self] in self?.openAbout() }
        menuBar.onToggleLaunchAtLogin = { [weak self] in
            self?.setLaunchAtLogin(!LaunchAtLogin.isEnabled)
        }
        menuBar.onQuit = { [weak self] in
            self?.stopMonitoring()
            NSApp.terminate(nil)
        }
    }

    private func wireStorageGate() {
        // Disk-limit values reach the recorder via updateSettings (the recorder
        // enforces them off the capture queue). Here we only react to a stop.
        recorder.onStorageStop = { [weak self] in
            guard let self else { return }
            self.stopMonitoring()
            // Sticky reason survives later updateMenu calls (e.g. a late
            // finishWriting completion) until the next manual start.
            self.stoppedStatus = loc("Stopped: disk limit reached")
            self.updateMenu()
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
        stoppedStatus = nil
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
        stoppedStatus = nil
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

    /// Push current settings into the detector and recorder without touching
    /// the capture session. Cheap; safe to call on every settings edit.
    private func applyLiveSettings() {
        guard monitoring else { return }
        let snap = settings.snapshot()
        applyToDetector(snap)
        recorder.updateSettings(snap)
    }

    private func applyToDetector(_ snap: AppSettings) {
        // Staged and applied on the capture queue to avoid racing analyze().
        detector.requestUpdate(pixelDelta: snap.pixelDelta, threshold: snap.motionThreshold)
        detector.requestMask(MotionMask(encoded: snap.detectionMask))
    }

    private func updateMenuBarAppearance() {
        menuBar.setAppearance(style: settings.menuBarStyle,
                              discreetSymbol: settings.discreetIcon.symbolName)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
        let actual = LaunchAtLogin.isEnabled
        settings.launchAtLogin = actual
        menuBar.setLaunchAtLogin(actual)
    }

    private func updateMenu() {
        DispatchQueue.main.async {
            if !self.monitoring {
                self.menuBar.setState(.off, statusText: self.stoppedStatus ?? loc("Idle"))
            } else if self.recorder.isRecording {
                self.menuBar.setState(.recording, statusText: loc("Recording…"))
            } else {
                let last = self.recorder.lastClipName.map { loc("Last clip: %@", $0) } ?? loc("Monitoring")
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
                onLaunchAtLoginChange: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
                onEditZones: { [weak self] in self?.openZoneEditor() })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = loc("MacCam Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openAbout() {
        if aboutWindow == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: hosting)
            window.title = loc("About MacCam")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            aboutWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    private func openZoneEditor() {
        // Recreate each time so the editor reloads a fresh snapshot and the
        // current mask (onAppear re-runs on a new view).
        zoneWindow?.close()
        let view = ZoneEditorView(settings: settings, camera: camera)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = loc("Detection Zones")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        zoneWindow = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
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
        alert.messageText = loc("Camera access denied")
        alert.informativeText = loc("MacCam needs camera access to monitor for motion. "
            + "Enable it in System Settings → Privacy & Security → Camera.")
        alert.addButton(withTitle: loc("Open System Settings"))
        alert.addButton(withTitle: loc("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
