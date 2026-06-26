import AppKit

/// Menu-bar status item with state-colored icon and the app's command menu.
final class MenuBarController: NSObject {
    enum State { case off, monitoring, recording }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let toggleItem = NSMenuItem()
    private let statusLineItem = NSMenuItem()
    private let launchItem = NSMenuItem()
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var state: State = .off

    var onToggleMonitoring: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        super.init()
        buildMenu()
        setState(.off, statusText: "Idle")
    }

    private func buildMenu() {
        toggleItem.title = "Start Monitoring"
        toggleItem.target = self
        toggleItem.action = #selector(toggle)
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        statusLineItem.title = "Idle"
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        menu.addItem(.separator())

        let folder = NSMenuItem(title: "Open Clips Folder…", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        launchItem.title = "Launch at Login"
        launchItem.target = self
        launchItem.action = #selector(toggleLaunch)
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacCam", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func setState(_ state: State, statusText: String) {
        self.state = state
        toggleItem.title = (state == .off) ? "Start Monitoring" : "Stop Monitoring"
        statusLineItem.title = statusText
        blinkTimer?.invalidate()
        blinkTimer = nil

        guard let button = statusItem.button else { return }
        switch state {
        case .off:
            button.image = symbol("video.slash", color: .secondaryLabelColor)
            button.alphaValue = 1
        case .monitoring:
            button.image = symbol("video.fill", color: .systemGreen)
            button.alphaValue = 1
        case .recording:
            button.image = symbol("record.circle.fill", color: .systemRed)
            startBlinking()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchItem.state = on ? .on : .off
    }

    private func symbol(_ name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        // Tint by drawing the template in the requested color.
        guard let base = image else { return nil }
        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: base.size)
        base.draw(in: rect)
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func startBlinking() {
        blinkOn = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.blinkOn.toggle()
            button.alphaValue = self.blinkOn ? 1.0 : 0.35
        }
    }

    @objc private func toggle() { onToggleMonitoring?() }
    @objc private func openFolder() { onOpenFolder?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func toggleLaunch() { onToggleLaunchAtLogin?() }
    @objc private func quit() { onQuit?() }
}
