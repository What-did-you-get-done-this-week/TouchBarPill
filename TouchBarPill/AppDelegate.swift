import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var showItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var pinItem: NSMenuItem!
    private var statusMenu: NSMenu!
    private var displayItem: NSMenuItem!
    private var positionItem: NSMenuItem!
    private let displayMenu = NSMenu()
    private let positionMenu = NSMenu()
    private let themeMenu = NSMenu()
    private let sizeMenu = NSMenu()
    private var resetFocusItem: NSMenuItem!
    private var didTeardown = false
    private var mirror: DFRMirror!
    private var pill: PillPanelController!
    /// Created on first use, which is during launch — not before NSApp.run.
    private lazy var preferences = PreferencesController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        mirror = DFRMirror()
        pill = PillPanelController(mirror: mirror)
        // Never register a login item here. The old default-on path called
        // SMAppService at launch and macOS answered with an admin password sheet.
        LaunchAtLogin.forgetLegacyPreference()
        preferences.attach(mirror: mirror)

        mirror.stateHandler = { [weak self] in
            self?.mirrorChanged()
        }
        mirror.start()
        FullscreenWatcher.shared.start()

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
        loginItem.state = LaunchAtLogin.isOn ? .on : .off
        pinItem.state = PillPlacement.pinExpanded ? .on : .off
        resetFocusItem.isEnabled = FocusSession.shared.phase != .idle
        syncDisplayItem()
        rebuildDisplayMenu()
        rebuildPositionMenu()
        rebuildThemeMenu()
        rebuildSizeMenu()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = L("TouchBarPill — click to quit")

        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu

        showItem = NSMenuItem(title: L("Hide Touch Bar"), action: #selector(togglePill), keyEquivalent: "h")
        showItem.keyEquivalentModifierMask = [.command, .shift]
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        displayItem = NSMenuItem(title: L("Display"), action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        displayItem.target = self

        positionItem = NSMenuItem(title: L("Position"), action: nil, keyEquivalent: "")
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        pinItem = NSMenuItem(title: L("Pin expanded"), action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        let themeItem = NSMenuItem(title: L("Notch theme"), action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        let sizeItem = NSMenuItem(title: L("Notch size"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())

        resetFocusItem = NSMenuItem(title: L("Reset Focus"), action: #selector(resetFocus), keyEquivalent: "")
        resetFocusItem.target = self
        menu.addItem(resetFocusItem)

        menu.addItem(.separator())

        let preferencesItem = NSMenuItem(title: L("Preferences…"), action: #selector(showPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        loginItem = NSMenuItem(title: L("Open at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = .off
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
        FullscreenWatcher.shared.stop()
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

    @objc private func showPreferences(_ sender: Any?) {
        preferences.show()
    }

    @objc private func togglePin() {
        PillPlacement.pinExpanded.toggle()
        PillPlacement.postChange()
    }

    @objc private func resetFocus() {
        FocusSession.shared.reset()
    }

    @objc private func chooseTheme(_ sender: NSMenuItem) {
        guard NotchTheme.allCases.indices.contains(sender.tag) else { return }
        PillPlacement.theme = NotchTheme.allCases[sender.tag]
        PillPlacement.postChange()
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard NotchSize.allCases.indices.contains(sender.tag) else { return }
        PillPlacement.size = NotchSize.allCases[sender.tag]
        PillPlacement.postChange()
    }

    @objc private func chooseDisplay(_ sender: NSMenuItem) {
        let ident = CGDirectDisplayID(sender.tag)
        guard ident != 0 else { return }
        PillPlacement.preferredDisplayID = ident
        PillPlacement.postChange()
    }

    @objc private func chooseEdge(_ sender: NSMenuItem) {
        let edge: PillEdge
        switch sender.tag {
        case 1: edge = .bottomCenter
        case 2: edge = .leftMid
        case 3: edge = .rightMid
        default: edge = .topCenter
        }
        PillPlacement.storeEdge(edge)
        PillPlacement.postChange()
    }

    /// Display exists only when more than one screen is attached.
    private func syncDisplayItem() {
        let show = NSScreen.screens.count > 1
        let listed = displayItem.menu != nil
        if show && !listed {
            let index = statusMenu.index(of: positionItem)
            statusMenu.insertItem(displayItem, at: max(0, index))
        } else if !show && listed {
            statusMenu.removeItem(displayItem)
        }
    }

    private func rebuildDisplayMenu() {
        guard NSScreen.screens.count > 1 else {
            displayMenu.removeAllItems()
            return
        }
        displayMenu.removeAllItems()
        let resolvedID = DisplayList.resolved().map { DisplayList.id(of: $0) }
        for entry in DisplayList.entries() {
            let ident = DisplayList.id(of: entry.screen)
            let item = NSMenuItem(title: entry.title, action: #selector(chooseDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(ident)
            item.state = ident == resolvedID ? .on : .off
            displayMenu.addItem(item)
        }
        if displayMenu.items.isEmpty {
            let empty = NSMenuItem(title: L("No displays"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            displayMenu.addItem(empty)
        }
    }

    private func rebuildPositionMenu() {
        positionMenu.removeAllItems()
        let specs: [(String, PillEdge, Int)] = [
            (L("Top center"), .topCenter, 0),
            (L("Bottom center"), .bottomCenter, 1),
            (L("Left mid"), .leftMid, 2),
            (L("Right mid"), .rightMid, 3),
        ]
        for (title, edge, tag) in specs {
            let item = NSMenuItem(title: title, action: #selector(chooseEdge(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            let selected = PillPlacement.edge == edge && PillPlacement.isPurePreset
            item.state = selected ? .on : .off
            positionMenu.addItem(item)
        }
    }

    private func rebuildThemeMenu() {
        themeMenu.removeAllItems()
        let current = PillPlacement.theme
        for (index, theme) in NotchTheme.allCases.enumerated() {
            let item = NSMenuItem(title: theme.menuTitle, action: #selector(chooseTheme(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = theme == current ? .on : .off
            themeMenu.addItem(item)
        }
    }

    private func rebuildSizeMenu() {
        sizeMenu.removeAllItems()
        let current = PillPlacement.size
        for (index, size) in NotchSize.allCases.enumerated() {
            let item = NSMenuItem(title: size.menuTitle, action: #selector(chooseSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = size == current ? .on : .off
            sizeMenu.addItem(item)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let outcome = LaunchAtLogin.setEnabled(!LaunchAtLogin.isOn)
        loginItem.state = LaunchAtLogin.isOn ? .on : .off
        loginItem.title = LaunchAtLogin.menuTitle()
        preferences.refresh()
        if outcome == .needsSettings {
            LaunchAtLogin.presentHelp()
        }
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

        let resolved = DisplayList.resolved()
        let resolvedID = resolved.map { Int(DisplayList.id(of: $0)) } ?? 0
        let resolvedName = resolved?.localizedName ?? L("none")
        let saved = PillPlacement.preferredDisplayID.map { String(Int($0)) } ?? "auto"
        let fallback = PillPlacement.preferredDisplayIsConnected ? "no" : "yes"

        return """
        TouchBarPill \(version) (\(build))
        \(ProcessInfo.processInfo.operatingSystemVersionString)
        CollapseDelay: \(PillMetrics.collapseDelay)
        PillHidden: \(UserDefaults.standard.bool(forKey: "PillHidden"))
        PreferredDisplayID: \(saved)
        ResolvedDisplay: \(resolvedName) id=\(resolvedID) fallback=\(fallback)
        Edge: \(PillPlacement.edge.rawValue) offset \(String(format: "%.1f", Double(PillPlacement.offset)))
        PinExpanded: \(PillPlacement.pinExpanded)
        DiscreetMode: always-on opacity \(String(format: "%.2f", Double(PillPlacement.discreetOpacity))) idle \(String(format: "%.2f", PillPlacement.idleDelay))
        NotchTheme: \(PillPlacement.theme.rawValue) size \(PillPlacement.size.rawValue) hitZone \(PillPlacement.hitZone.rawValue)
        RevealDelay: \(String(format: "%.2f", PillPlacement.revealDelay)) FullscreenHideDelay: \(String(format: "%.2f", PillPlacement.fullscreenHideDelay))
        Focus: phase \(String(describing: FocusSession.shared.phase)) elapsed \(String(format: "%.0f", FocusSession.shared.displayElapsed))s
        Fullscreen: \(FullscreenWatcher.shared.isFullscreen ? "yes" : "no")
        ExpandedPlacement: follows \(PillPlacement.edge.rawValue) on the chosen display
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
