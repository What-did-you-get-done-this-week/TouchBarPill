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
    private var previewRestore: DispatchWorkItem?
    /// Click action is in flight. A trailing highlight-clear must not restore over the commit.
    private var committingMenuChoice = false
    private var didTeardown = false
    private var mirror: DFRMirror!
    private var pill: PillPanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        mirror = DFRMirror()
        pill = PillPanelController(mirror: mirror)
        // Never register a login item here. The old default-on path called
        // SMAppService at launch and macOS answered with an admin password sheet.
        LaunchAtLogin.forgetLegacyPreference()

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
        // Submenus share this delegate for hover preview. Rebuilding them
        // while they open would wipe the item under the pointer.
        guard menu === statusMenu else { return }
        showItem.title = pill.isVisible ? L("Hide Touch Bar") : L("Show Touch Bar")
        loginItem.title = LaunchAtLogin.menuTitle()
        loginItem.state = LaunchAtLogin.isOn ? .on : .off
        pinItem.state = PillPlacement.pinExpanded ? .on : .off
        syncDisplayItem()
        rebuildDisplayMenu()
        rebuildPositionMenu()
        rebuildThemeMenu()
        rebuildSizeMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === themeMenu || menu === sizeMenu || menu === positionMenu else { return }
        // The click action runs in this same turn. Restore on the next turn
        // so a commit is already written and this becomes a no-op.
        schedulePreviewRestore()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === themeMenu || menu === sizeMenu || menu === positionMenu else { return }
        guard let item, item.isEnabled, item.action != nil else {
            schedulePreviewRestore()
            return
        }
        cancelPreviewRestore()
        if menu === themeMenu {
            previewThemeItem(item)
        } else if menu === sizeMenu {
            previewSizeItem(item)
        } else {
            previewPositionItem(item)
        }
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
        positionMenu.delegate = self
        menu.addItem(positionItem)

        // Pin commits on click only. It does not preview on hover.
        pinItem = NSMenuItem(title: L("Pin Touch bar"), action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        let themeItem = NSMenuItem(title: L("Notch theme"), action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        themeMenu.delegate = self
        menu.addItem(themeItem)

        let sizeItem = NSMenuItem(title: L("Notch size"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        sizeMenu.delegate = self
        menu.addItem(sizeItem)

        menu.addItem(.separator())

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

    @objc private func togglePin() {
        PillPlacement.pinExpanded.toggle()
        PillPlacement.postChange()
    }

    @objc private func toggleCinema() {
        commitMenuChoice {
            let committed = ChromePreview.committedInvisible
            PillPlacement.cinemaMode = !committed
        }
    }

    @objc private func chooseTheme(_ sender: NSMenuItem) {
        guard NotchTheme.allCases.indices.contains(sender.tag) else { return }
        let theme = NotchTheme.allCases[sender.tag]
        commitMenuChoice {
            PillPlacement.theme = theme
            // The hover showed that color, so the commit is visible too.
            PillPlacement.cinemaMode = false
        }
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard NotchSize.allCases.indices.contains(sender.tag) else { return }
        let size = NotchSize.allCases[sender.tag]
        commitMenuChoice {
            PillPlacement.size = size
        }
    }

    @objc private func chooseDisplay(_ sender: NSMenuItem) {
        let ident = CGDirectDisplayID(sender.tag)
        guard ident != 0 else { return }
        PillPlacement.preferredDisplayID = ident
        PillPlacement.postChange()
    }

    @objc private func chooseEdge(_ sender: NSMenuItem) {
        let edge = edgeForTag(sender.tag)
        commitMenuChoice {
            PillPlacement.storeEdge(edge)
        }
    }

    /// Hover previews the color and turns Invisible off so the fill is visible.
    /// Leaving without a click restores both. Pin is not on this menu.
    private func previewThemeItem(_ item: NSMenuItem) {
        let leavingConceal = ChromePreview.invisibleAffectsConcealment
        if item.action == #selector(toggleCinema) {
            ChromePreview.theme = nil
            ChromePreview.invisible = true
        } else if NotchTheme.allCases.indices.contains(item.tag) {
            ChromePreview.theme = NotchTheme.allCases[item.tag]
            ChromePreview.invisible = false
        } else {
            schedulePreviewRestore()
            return
        }
        ChromePreview.size = nil
        ChromePreview.edge = nil
        ChromePreview.forcePresetOffset = false
        applyPreview(leavingConceal: leavingConceal)
    }

    private func previewSizeItem(_ item: NSMenuItem) {
        guard NotchSize.allCases.indices.contains(item.tag) else {
            schedulePreviewRestore()
            return
        }
        let leavingConceal = ChromePreview.invisibleAffectsConcealment
        ChromePreview.theme = nil
        ChromePreview.invisible = nil
        ChromePreview.size = NotchSize.allCases[item.tag]
        ChromePreview.edge = nil
        ChromePreview.forcePresetOffset = false
        applyPreview(leavingConceal: leavingConceal)
    }

    private func previewPositionItem(_ item: NSMenuItem) {
        guard item.action == #selector(chooseEdge(_:)) else {
            schedulePreviewRestore()
            return
        }
        let leavingConceal = ChromePreview.invisibleAffectsConcealment
        ChromePreview.theme = nil
        ChromePreview.invisible = nil
        ChromePreview.size = nil
        ChromePreview.edge = edgeForTag(item.tag)
        ChromePreview.forcePresetOffset = true
        applyPreview(leavingConceal: leavingConceal)
    }

    /// Relayout immediately. Refresh concealment only when Invisible flips,
    /// including when a size or position hover leaves a theme preview.
    private func applyPreview(leavingConceal: Bool) {
        ChromePreview.prefersInstantFrame = true
        PillPlacement.postChange()
        ChromePreview.prefersInstantFrame = false
        if leavingConceal || ChromePreview.invisibleAffectsConcealment {
            FullscreenWatcher.shared.refresh()
        }
    }

    private func edgeForTag(_ tag: Int) -> PillEdge {
        switch tag {
        case 1: return .bottomCenter
        case 2: return .leftMid
        case 3: return .rightMid
        default: return .topCenter
        }
    }

    /// Write the clicked value. The overlay is cleared first so setters store
    /// the committed choice, not the hover.
    private func commitMenuChoice(_ body: () -> Void) {
        cancelPreviewRestore()
        committingMenuChoice = true
        defer { committingMenuChoice = false }
        let hoverDroveConceal = ChromePreview.invisibleAffectsConcealment
        let cinemaBefore = ChromePreview.committedInvisible
        ChromePreview.clear()
        body()
        let cinemaAfter = ChromePreview.committedInvisible
        ChromePreview.publishCleared(concealChanged: hoverDroveConceal || cinemaBefore != cinemaAfter)
    }

    private func schedulePreviewRestore() {
        if committingMenuChoice { return }
        previewRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restorePreview()
        }
        previewRestore = work
        DispatchQueue.main.async(execute: work)
    }

    private func cancelPreviewRestore() {
        previewRestore?.cancel()
        previewRestore = nil
    }

    /// Leave without a click: put the live notch back. A commit in this turn
    /// has already cleared the overlay, so this does nothing.
    private func restorePreview() {
        previewRestore = nil
        if committingMenuChoice || !ChromePreview.isActive { return }
        let concealChanged = ChromePreview.invisibleAffectsConcealment
        ChromePreview.clear()
        ChromePreview.publishCleared(concealChanged: concealChanged)
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
        themeMenu.addItem(.separator())
        let invisible = NSMenuItem(title: L("Invisible"), action: #selector(toggleCinema), keyEquivalent: "")
        invisible.target = self
        invisible.state = PillPlacement.cinemaMode ? .on : .off
        themeMenu.addItem(invisible)
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
        MenuBarHeight: \(String(format: "%.1f", Double(MenuBarHeight.current))) (S depth matches this band; M depth \(String(format: "%.1f", Double(ZonePolicy.depth * ZonePolicy.legacySmallScale))))
        RevealDelay: \(String(format: "%.2f", PillPlacement.revealDelay)) FullscreenHideDelay: \(String(format: "%.2f", PillPlacement.fullscreenHideDelay))
        Focus: phase \(String(describing: FocusSession.shared.phase)) elapsed \(String(format: "%.0f", FocusSession.shared.displayElapsed))s label \(FocusSession.shared.notchLabel)
        Fullscreen: \(FullscreenWatcher.shared.diagnosticToken)
        Invisible: \(PillPlacement.cinemaMode ? "on" : "off")
        CinemaCoverage: \(String(format: "%.0f%%", Double(FullscreenWatcher.shared.frontCoverage * 100)))
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
