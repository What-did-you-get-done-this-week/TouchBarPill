import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var showItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var didTeardown = false
    private var mirror: DFRMirror!
    private var pill: PillPanelController!
    private let preferences = PreferencesController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        mirror = DFRMirror()
        pill = PillPanelController(mirror: mirror)
        LaunchAtLogin.syncOnLaunch()
        preferences.attach(mirror: mirror)

        mirror.stateHandler = { [weak self] in
            self?.mirrorChanged()
        }
        mirror.start()

        buildStatusItem()
        if !UserDefaults.standard.bool(forKey: "PillHidden") {
            pill.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func menuWillOpen(_ menu: NSMenu) {
        showItem.title = pill.isVisible ? L("Hide Touch Bar") : L("Show Touch Bar")
        loginItem.title = LaunchAtLogin.menuTitle()
        loginItem.state = LaunchAtLogin.userWantsEnabled ? .on : .off
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = L("TouchBarPill — click to quit")

        let menu = NSMenu()
        menu.delegate = self

        showItem = NSMenuItem(title: L("Hide Touch Bar"), action: #selector(togglePill), keyEquivalent: "h")
        showItem.keyEquivalentModifierMask = [.command, .shift]
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let preferencesItem = NSMenuItem(title: L("Preferences…"), action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        loginItem = NSMenuItem(title: LaunchAtLogin.menuTitle(), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.userWantsEnabled ? .on : .off
        menu.addItem(loginItem)

        let diagnosticsItem = NSMenuItem(title: L("Copy Diagnostics"), action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("Quit TouchBarPill"), action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Left-click (and right-click) on the status item opens this menu.
        // LSUIElement hides the application menu, so this is the Quit path.
        item.menu = menu
        statusItem = item
    }

    /// Stop the Touch Bar stream and remove the status item before exit.
    private func teardown() {
        guard !didTeardown else { return }
        didTeardown = true
        pill?.hide()
        mirror?.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func mirrorChanged() {
        pill.mirrorStateChanged()
        preferences.refresh()
    }

    @objc private func togglePill() {
        if pill.isVisible {
            pill.hide()
            UserDefaults.standard.set(true, forKey: "PillHidden")
        } else {
            pill.show()
            UserDefaults.standard.set(false, forKey: "PillHidden")
        }
    }

    @objc private func showPreferences() {
        preferences.show()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.userWantsEnabled)
        preferences.refresh()
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.diagnosticsText(mirror: mirror), forType: .string)
    }

    static func diagnosticsText(mirror: DFRMirror) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let screens = NSScreen.screens.enumerated().map { index, screen in
            let notch: String
            if #available(macOS 12.0, *) {
                let auxiliaryWidth = screen.auxiliaryTopLeftArea?.width ?? 0
                notch = (auxiliaryWidth > 0 || screen.safeAreaInsets.top > 0) ? L("notch") : L("no-notch")
            } else {
                notch = L("notch-unknown")
            }
            return String(
                format: L("  [%d] %@ origin (%.0f, %.0f) size %.0f x %.0f scale %.1f %@"),
                index,
                screen.localizedName,
                screen.frame.origin.x,
                screen.frame.origin.y,
                screen.frame.width,
                screen.frame.height,
                screen.backingScaleFactor,
                notch
            )
        }.joined(separator: "\n")

        return """
        TouchBarPill \(version) (\(build))
        \(ProcessInfo.processInfo.operatingSystemVersionString)
        CollapseDelay: \(PillMetrics.collapseDelay)
        PillHidden: \(UserDefaults.standard.bool(forKey: "PillHidden"))
        \(LaunchAtLogin.diagnosticLine())
        \(mirror.diagnosticSummary())
        \(L("Screens:"))
        \(screens)
        """
    }

    private static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let capsule = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5.5, width: 15, height: 7), xRadius: 3.5, yRadius: 3.5)
            capsule.lineWidth = 1.5
            capsule.stroke()
            NSColor.black.setFill()
            for x in [4.0, 8.0, 12.0] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 7.5, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
