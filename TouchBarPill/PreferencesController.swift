import AppKit

/// Preferences for the stream, collapse delay, login item, display, position,
/// pin, discreet mode, focus goal, notch chrome, and fullscreen hit zone.
final class PreferencesController: NSWindowController {
    private let statusTitle = NSTextField(labelWithString: L("Stream"))
    private let statusBody = NSTextField(wrappingLabelWithString: L("Starting…"))
    private let delayValue = NSTextField(labelWithString: "")
    private let loginSwitch = NSSwitch()
    private let loginNote = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: L("Open Login Items Settings"), target: nil, action: nil)
    private let displayPopup = NSPopUpButton()
    private let displayNote = NSTextField(wrappingLabelWithString: "")
    private let positionPopup = NSPopUpButton()
    private let pinSwitch = NSSwitch()
    private let discreetSwitch = NSSwitch()
    private let opacitySlider = NSSlider()
    private let opacityReadout = NSTextField(labelWithString: "")
    private let focusGoalPopup = NSPopUpButton()
    private let resetFocusButton = NSButton(title: L("Reset Focus"), target: nil, action: nil)
    private let themePopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let hitZonePopup = NSPopUpButton()
    private var mirror: DFRMirror?
    private var suppressUI = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("TouchBarPill Preferences")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(placementChanged),
            name: PillPlacement.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusChanged),
            name: FocusSession.didChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func attach(mirror: DFRMirror) {
        self.mirror = mirror
        refresh()
    }

    func show() {
        refresh()
        refreshLogin()
        window?.center()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        reloadPlacementControls()
        guard let mirror else { return }
        statusTitle.stringValue = mirror.simulatorReady ? L("Stream") : L("Stream unavailable")
        statusBody.stringValue = mirror.statusMessage
        delayValue.stringValue = String(format: L("%.2f seconds"), PillMetrics.collapseDelay)
        if window?.isVisible == true {
            refreshLogin()
        }
    }

    func refreshLogin() {
        loginSwitch.state = LaunchAtLogin.isOn ? .on : .off
        loginSwitch.isEnabled = LaunchAtLogin.isSupported
        loginNote.stringValue = LaunchAtLogin.note()
        loginSettingsButton.isHidden = !LaunchAtLogin.needsSettingsButton
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        content.addSubview(scroll)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
        ])

        let heading = NSTextField(labelWithString: "TouchBarPill")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)

        let intro = note(L("A black notch attaches to the edge you choose — top center by default, or bottom, left mid, or right mid. Drag it along that edge. Hover to open the Touch Bar. Click the collapsed notch to start or pause Focus. Scroll to change volume; double-click to mute. The expanded strip follows the same edge. Move away and it folds back, unless it is pinned."))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        statusTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        statusBody.font = .systemFont(ofSize: 12)
        statusBody.textColor = .secondaryLabelColor
        statusBody.maximumNumberOfLines = 4
        statusBody.preferredMaxLayoutWidth = 440

        let delayLabel = sectionLabel(L("Collapse delay"))
        delayValue.font = .systemFont(ofSize: 12)
        delayValue.textColor = .secondaryLabelColor
        let delayNote = note(L("Fixed for this version. Change it without rebuilding: defaults write com.touchbarpill.TouchBarPill CollapseDelay -float 0.5"))

        let loginLabel = sectionLabel(L("Open at login"))
        loginSwitch.target = self
        loginSwitch.action = #selector(loginSwitchChanged(_:))
        loginSwitch.setAccessibilityLabel(L("Open at login"))
        loginNote.font = .systemFont(ofSize: 11)
        loginNote.textColor = .tertiaryLabelColor
        loginNote.preferredMaxLayoutWidth = 440
        loginNote.maximumNumberOfLines = 4
        loginSettingsButton.bezelStyle = .rounded
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginSettings(_:))
        loginSettingsButton.isHidden = true

        let displayLabel = sectionLabel(L("Display"))
        displayPopup.target = self
        displayPopup.action = #selector(displayChanged(_:))
        displayPopup.setAccessibilityLabel(L("Display"))
        displayNote.font = .systemFont(ofSize: 11)
        displayNote.textColor = .tertiaryLabelColor
        displayNote.preferredMaxLayoutWidth = 440
        displayNote.maximumNumberOfLines = 3

        let positionLabel = sectionLabel(L("Position"))
        positionPopup.target = self
        positionPopup.action = #selector(positionChanged(_:))
        positionPopup.setAccessibilityLabel(L("Position"))
        let positionNote = note(L("Drag the collapsed notch along its attached edge. Top center, Bottom center, Left mid, and Right mid park it on that display. The expanded strip follows the same edge and stays on screen."))

        let pinLabel = sectionLabel(L("Pin expanded"))
        pinSwitch.target = self
        pinSwitch.action = #selector(pinChanged(_:))
        pinSwitch.setAccessibilityLabel(L("Pin expanded"))
        let pinNote = note(L("When on, the strip stays open until you unpin it. Leave with the pointer and it stays. Unpin from this switch, the status menu, right-click → Unpin on the strip, or the soft pushpin that appears while hovering a pinned strip."))

        let discreetLabel = sectionLabel(L("Discreet mode"))
        discreetSwitch.target = self
        discreetSwitch.action = #selector(discreetChanged(_:))
        discreetSwitch.setAccessibilityLabel(L("Discreet mode"))
        let discreetNote = note(L("When the tab is collapsed and idle, it fades. Hover or expand brings it back to full opacity. On by default."))

        let focusLabel = sectionLabel(L("Focus Goal"))
        focusGoalPopup.target = self
        focusGoalPopup.action = #selector(focusGoalChanged(_:))
        focusGoalPopup.setAccessibilityLabel(L("Focus Goal"))
        resetFocusButton.bezelStyle = .rounded
        resetFocusButton.target = self
        resetFocusButton.action = #selector(resetFocus(_:))
        let focusNote = note(L("Click the collapsed notch to start or pause a focus timer. Goal Off means no done state. 25 or 50 minutes show Done gently on the notch. Default goal is Off."))

        let themeLabel = sectionLabel(L("Notch theme"))
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        themePopup.setAccessibilityLabel(L("Notch theme"))
        let themeNote = note(L("Collapsed notch chrome only. Black, Graphite, or Soft accent (deep blue). The Touch Bar stream is unchanged."))

        let sizeLabel = sectionLabel(L("Notch size"))
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged(_:))
        sizePopup.setAccessibilityLabel(L("Notch size"))
        let sizeNote = note(L("S is smaller; M matches the previous size. Label and silhouette scale together."))

        let hitZoneLabel = sectionLabel(L("Hit zone"))
        hitZonePopup.target = self
        hitZonePopup.action = #selector(hitZoneChanged(_:))
        hitZonePopup.setAccessibilityLabel(L("Hit zone"))
        let hitZoneNote = note(L("Fullscreen edge target width. Narrow / Normal / Wide. Normal is a bit wider than the visual tab so the near-invisible hit area is easier to find."))

        let opacityLabel = sectionLabel(L("Idle opacity"))
        opacitySlider.minValue = 0.35
        opacitySlider.maxValue = 0.75
        opacitySlider.doubleValue = PillPlacement.defaultOpacity
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.setAccessibilityLabel(L("Idle opacity"))
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        opacityReadout.font = .systemFont(ofSize: 12)
        opacityReadout.textColor = .secondaryLabelColor
        opacityReadout.alignment = .right
        opacityReadout.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let copy = NSButton(title: L("Copy Diagnostics"), target: self, action: #selector(copyDiagnostics))
        copy.bezelStyle = .rounded

        let rows = [
            labeledRow(delayLabel, delayValue),
            labeledRow(loginLabel, loginSwitch),
            labeledRow(displayLabel, displayPopup),
            labeledRow(positionLabel, positionPopup),
            labeledRow(pinLabel, pinSwitch),
            labeledRow(discreetLabel, discreetSwitch),
            labeledRow(opacityLabel, opacityCluster()),
            labeledRow(focusLabel, focusGoalPopup),
            labeledRow(themeLabel, themePopup),
            labeledRow(sizeLabel, sizePopup),
            labeledRow(hitZoneLabel, hitZonePopup),
        ]
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(statusTitle)
        stack.addArrangedSubview(statusBody)
        stack.addArrangedSubview(rows[0])
        stack.addArrangedSubview(delayNote)
        stack.addArrangedSubview(rows[1])
        stack.addArrangedSubview(loginNote)
        stack.addArrangedSubview(loginSettingsButton)
        stack.addArrangedSubview(rows[2])
        stack.addArrangedSubview(displayNote)
        stack.addArrangedSubview(rows[3])
        stack.addArrangedSubview(positionNote)
        stack.addArrangedSubview(rows[4])
        stack.addArrangedSubview(pinNote)
        stack.addArrangedSubview(rows[5])
        stack.addArrangedSubview(discreetNote)
        stack.addArrangedSubview(rows[6])
        stack.addArrangedSubview(rows[7])
        stack.addArrangedSubview(focusNote)
        stack.addArrangedSubview(resetFocusButton)
        stack.addArrangedSubview(rows[8])
        stack.addArrangedSubview(themeNote)
        stack.addArrangedSubview(rows[9])
        stack.addArrangedSubview(sizeNote)
        stack.addArrangedSubview(rows[10])
        stack.addArrangedSubview(hitZoneNote)
        stack.addArrangedSubview(copy)
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        for view in [intro, statusBody, delayNote, loginNote, displayNote, positionNote, pinNote, discreetNote, focusNote, themeNote, sizeNote, hitZoneNote] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        reloadPlacementControls()
    }

    private func opacityCluster() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(opacitySlider)
        row.addArrangedSubview(opacityReadout)
        return row
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .tertiaryLabelColor
        field.preferredMaxLayoutWidth = 440
        field.maximumNumberOfLines = 4
        return field
    }

    private func labeledRow(_ label: NSView, _ control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        return row
    }

    @objc private func placementChanged() {
        reloadPlacementControls()
    }

    @objc private func focusChanged() {
        reloadFocusControls()
    }

    private func reloadPlacementControls() {
        suppressUI = true
        defer { suppressUI = false }

        displayPopup.removeAllItems()
        let resolvedID = DisplayList.resolved().map { DisplayList.id(of: $0) }
        for entry in DisplayList.entries() {
            let ident = DisplayList.id(of: entry.screen)
            displayPopup.addItem(withTitle: entry.title)
            displayPopup.lastItem?.tag = Int(ident)
        }
        if let resolvedID {
            displayPopup.selectItem(withTag: Int(resolvedID))
        }
        if PillPlacement.preferredDisplayIsConnected {
            displayNote.stringValue = L("The notch and the expanded strip use the edge you choose on this display. If you unplug it, TouchBarPill uses the built-in display, or the main display, until it returns.")
        } else {
            displayNote.stringValue = L("That display is unplugged. Showing the built-in display, or the main display, until it is back. The choice is remembered.")
        }

        positionPopup.removeAllItems()
        let edges: [(String, PillEdge, Int)] = [
            (L("Top center"), .topCenter, 0),
            (L("Bottom center"), .bottomCenter, 1),
            (L("Left mid"), .leftMid, 2),
            (L("Right mid"), .rightMid, 3),
        ]
        for (title, _, tag) in edges {
            positionPopup.addItem(withTitle: title)
            positionPopup.lastItem?.tag = tag
        }
        if PillPlacement.isPurePreset {
            switch PillPlacement.edge {
            case .topCenter: positionPopup.selectItem(withTag: 0)
            case .bottomCenter: positionPopup.selectItem(withTag: 1)
            case .leftMid: positionPopup.selectItem(withTag: 2)
            case .rightMid: positionPopup.selectItem(withTag: 3)
            }
        } else {
            positionPopup.addItem(withTitle: L("Custom"))
            positionPopup.lastItem?.tag = -1
            positionPopup.selectItem(withTag: -1)
        }

        pinSwitch.state = PillPlacement.pinExpanded ? .on : .off
        discreetSwitch.state = PillPlacement.discreetMode ? .on : .off
        opacitySlider.isEnabled = PillPlacement.discreetMode
        opacitySlider.doubleValue = Double(PillPlacement.discreetOpacity)
        opacityReadout.stringValue = "\(Int((PillPlacement.discreetOpacity * 100).rounded()))%"

        themePopup.removeAllItems()
        for (index, theme) in NotchTheme.allCases.enumerated() {
            themePopup.addItem(withTitle: theme.menuTitle)
            themePopup.lastItem?.tag = index
        }
        themePopup.selectItem(withTag: NotchTheme.allCases.firstIndex(of: PillPlacement.theme) ?? 0)

        sizePopup.removeAllItems()
        for (index, size) in NotchSize.allCases.enumerated() {
            sizePopup.addItem(withTitle: size.menuTitle)
            sizePopup.lastItem?.tag = index
        }
        sizePopup.selectItem(withTag: NotchSize.allCases.firstIndex(of: PillPlacement.size) ?? 1)

        hitZonePopup.removeAllItems()
        for (index, zone) in HitZoneWidth.allCases.enumerated() {
            hitZonePopup.addItem(withTitle: zone.menuTitle)
            hitZonePopup.lastItem?.tag = index
        }
        hitZonePopup.selectItem(withTag: HitZoneWidth.allCases.firstIndex(of: PillPlacement.hitZone) ?? 1)

        reloadFocusControls()
    }

    private func reloadFocusControls() {
        let was = suppressUI
        suppressUI = true
        defer { suppressUI = was }

        focusGoalPopup.removeAllItems()
        let current = FocusSession.shared.goal
        for goal in FocusGoal.allCases {
            focusGoalPopup.addItem(withTitle: goal.shortTitle)
            focusGoalPopup.lastItem?.tag = goal.rawValue
        }
        focusGoalPopup.selectItem(withTag: current.rawValue)
        resetFocusButton.isEnabled = FocusSession.shared.phase != .idle
    }

    @objc private func loginSwitchChanged(_ sender: NSSwitch) {
        let outcome = LaunchAtLogin.setEnabled(sender.state == .on)
        refresh()
        if outcome == .needsSettings {
            LaunchAtLogin.presentHelp()
        }
    }

    @objc private func openLoginSettings(_ sender: NSButton) {
        LaunchAtLogin.openSettings()
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        guard !suppressUI, let item = sender.selectedItem, item.tag > 0 else { return }
        PillPlacement.preferredDisplayID = CGDirectDisplayID(item.tag)
        PillPlacement.postChange()
    }

    @objc private func positionChanged(_ sender: NSPopUpButton) {
        guard !suppressUI, let item = sender.selectedItem, item.tag >= 0 else { return }
        let edge: PillEdge
        switch item.tag {
        case 1: edge = .bottomCenter
        case 2: edge = .leftMid
        case 3: edge = .rightMid
        default: edge = .topCenter
        }
        PillPlacement.storeEdge(edge)
        PillPlacement.postChange()
    }

    @objc private func pinChanged(_ sender: NSSwitch) {
        guard !suppressUI else { return }
        PillPlacement.pinExpanded = sender.state == .on
        PillPlacement.postChange()
    }

    @objc private func discreetChanged(_ sender: NSSwitch) {
        guard !suppressUI else { return }
        PillPlacement.discreetMode = sender.state == .on
        PillPlacement.postChange()
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        guard !suppressUI else { return }
        PillPlacement.discreetOpacity = CGFloat(sender.doubleValue)
        opacityReadout.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
        PillPlacement.postChange()
    }

    @objc private func focusGoalChanged(_ sender: NSPopUpButton) {
        guard !suppressUI, let item = sender.selectedItem else { return }
        FocusSession.shared.goal = FocusGoal(rawValue: item.tag) ?? .off
    }

    @objc private func resetFocus(_ sender: NSButton) {
        FocusSession.shared.reset()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard !suppressUI, let item = sender.selectedItem,
              NotchTheme.allCases.indices.contains(item.tag) else { return }
        PillPlacement.theme = NotchTheme.allCases[item.tag]
        PillPlacement.postChange()
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        guard !suppressUI, let item = sender.selectedItem,
              NotchSize.allCases.indices.contains(item.tag) else { return }
        PillPlacement.size = NotchSize.allCases[item.tag]
        PillPlacement.postChange()
    }

    @objc private func hitZoneChanged(_ sender: NSPopUpButton) {
        guard !suppressUI, let item = sender.selectedItem,
              HitZoneWidth.allCases.indices.contains(item.tag) else { return }
        PillPlacement.hitZone = HitZoneWidth.allCases[item.tag]
        PillPlacement.postChange()
    }

    @objc private func copyDiagnostics() {
        guard let mirror else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppDelegate.diagnosticsText(mirror: mirror), forType: .string)
    }
}
