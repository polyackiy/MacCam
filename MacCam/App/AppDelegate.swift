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
    private let voiceDetector = VoiceDetector()
    private let menuBar = MenuBarController()
    private let lockMonitor = LockMonitor()
    private let scheduler = Scheduler()

    private var monitoring = false
    private var manualOverride = false
    private var screenLocked = false
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
        captureDelegate = CaptureDelegate(detector: detector, recorder: recorder, voiceDetector: voiceDetector)

        recorder.onStateChange = { [weak self] _, _ in self?.updateMenu() }
        wireStorageGate()
        wireMenu()
        wireGuard()
        menuBar.setLaunchAtLogin(LaunchAtLogin.isEnabled)
        updateMenuBarAppearance()
        lockMonitor.start()

        scheduler.onMonitoringWindowChange = { [weak self] _ in self?.evaluateMonitoring() }
        scheduler.update(monitoring: snap.monitoringSchedule, recording: snap.recordingSchedule)
        scheduler.start()

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
            if self.monitoring {
                self.stopMonitoring()
            } else {
                // Ensure microphone access is requested via a user action (so the
                // TCC prompt actually appears) before configuring audio capture.
                self.ensureAudioAuthorized { self.startMonitoring(manual: true) }
            }
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
            guard let self else { return }
            self.screenLocked = true
            self.evaluateMonitoring()
        }
        lockMonitor.onUnlock = { [weak self] in
            guard let self else { return }
            self.screenLocked = false
            self.evaluateMonitoring()
        }
    }

    /// Auto-monitoring sources are guard mode and the monitoring schedule; a
    /// manual Start overrides both and runs until manual Stop. Acts only on a
    /// state change, so it is safe to call repeatedly.
    private func evaluateMonitoring() {
        if manualOverride { return }
        let guardActive = settings.guardMode && screenLocked
        let shouldMonitor = guardActive || scheduler.isMonitoringWindowActive()
        if shouldMonitor && !monitoring {
            startMonitoring(manual: false)
        } else if !shouldMonitor && monitoring {
            stopMonitoring()
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
        voiceDetector.reset()
        monitoring = false
        updateMenu()
        // No re-arm here: a manual Stop pauses until the next auto trigger (a
        // schedule-window transition or screen lock), so the button always works.
    }

    private func reconfigureIfMonitoring() {
        guard monitoring else { return }
        let snap = settings.snapshot()
        // Finalize any in-progress clip before the capture session changes. A
        // reconfigure can change which media flows (audio-only ⇄ video) or the
        // video dimensions; an already-open writer is built for the old set, so
        // continuing it would drop frames or splice mismatched tracks. Closing it
        // here makes the next clip open cleanly with the new configuration.
        recorder.stop()
        applyToDetector(snap)
        recorder.updateSettings(snap)
        camera.configure(settings: snap, delegate: captureDelegate)
    }

    /// Push current settings into the detector/recorder (when monitoring) and the
    /// scheduler (always), then re-evaluate auto-monitoring. Cheap; safe to call
    /// on every settings edit.
    private func applyLiveSettings() {
        let snap = settings.snapshot()
        scheduler.update(monitoring: snap.monitoringSchedule, recording: snap.recordingSchedule)
        if monitoring {
            applyToDetector(snap)
            recorder.updateSettings(snap)
        }
        evaluateMonitoring()
    }

    private func applyToDetector(_ snap: AppSettings) {
        // Staged and applied on the capture queue to avoid racing analyze().
        detector.requestUpdate(pixelDelta: snap.pixelDelta, threshold: snap.motionThreshold)
        detector.requestMask(MotionMask(encoded: snap.detectionMask))
        voiceDetector.requestUpdate(
            enabled: snap.triggerMode.usesVoice && snap.audioEnabled,
            threshold: VoiceMath.confidenceThreshold(forSensitivity: snap.voiceSensitivity))
        captureDelegate.setTriggerMode(snap.triggerMode)
        captureDelegate.setAudioOnly(snap.effectiveAudioOnly)
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
            let context = SettingsContext(
                settings: settings,
                camera: camera,
                fileStore: fileStore,
                onReconfigure: { [weak self] in self?.reconfigureIfMonitoring() },
                onLaunchAtLoginChange: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
                onEditZones: { [weak self] in self?.openZoneEditor() },
                onRequestAudioAccess: { [weak self] in self?.requestAudioAccessIfNeeded() })
            let hosting = NSHostingController(rootView: SettingsView(context: context))
            let window = NSWindow(contentViewController: hosting)
            window.title = loc("MacCam Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
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
        // Guard mode can't prompt on a locked screen, so resolve microphone
        // access ahead of time when it's configured to run unattended.
        if settings.guardMode, settings.audioEnabled,
           AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    /// If audio is enabled, make sure microphone access has been requested before
    /// continuing. Activates the app so the system prompt is visible (this app is
    /// a menu-bar accessory). Proceeds regardless of the result — video still
    /// records if the user declines.
    private func ensureAudioAuthorized(_ then: @escaping () -> Void) {
        guard settings.audioEnabled else { then(); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async(execute: then)
            }
        case .denied, .restricted:
            showAccessDenied(.audio)   // audio enabled but blocked — tell the user why
            then()
        default:  // .authorized
            then()
        }
    }

    /// Called when the user turns "Record audio" on in Settings, so the
    /// microphone prompt appears at the moment of intent (app is active).
    func requestAudioAccessIfNeeded() {
        ensureAudioAuthorized {}
    }

    private func showAccessDenied(_ media: AVMediaType) {
        let isAudio = media == .audio
        let alert = NSAlert()
        alert.messageText = isAudio ? loc("Microphone access denied") : loc("Camera access denied")
        alert.informativeText = isAudio
            ? loc("MacCam needs microphone access to record audio. "
                + "Enable it in System Settings → Privacy & Security → Microphone.")
            : loc("MacCam needs camera access to monitor for motion. "
                + "Enable it in System Settings → Privacy & Security → Camera.")
        alert.addButton(withTitle: loc("Open System Settings"))
        alert.addButton(withTitle: loc("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let pane = isAudio ? "Privacy_Microphone" : "Privacy_Camera"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
