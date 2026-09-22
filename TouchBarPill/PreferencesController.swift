import AppKit

/// Preferences for the stream, collapse delay, login item, display, position,
/// pin, and discreet mode. The collapse delay itself is still a defaults key.
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
    private var mirror: DFRMirror?
    private var suppressUI = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
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

        let intro = note(L("A black tab sits flush with the top of the display you choose. Drag it along that edge, or pick Left, Center, or Right. Hover to open the Touch Bar. The expanded strip stays centered on that display. Move away and it folds back, unless it is pinned."))
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
        let positionNote = note(L("Drag the collapsed tab along the top edge. Left, Center, and Right park it on that display. The expanded strip stays top-centered on the same display, not under the tab."))

        let pinLabel = sectionLabel(L("Pin expanded"))
        pinSwitch.target = self
        pinSwitch.action = #selector(pinChanged(_:))
        pinSwitch.setAccessibilityLabel(L("Pin expanded"))
        let pinNote = note(L("When on, the strip stays open until you turn this off. Leaving with the pointer does not collapse it."))

        let discreetLabel = sectionLabel(L("Discreet mode"))
        discreetSwitch.target = self
        discreetSwitch.action = #selector(discreetChanged(_:))
        discreetSwitch.setAccessibilityLabel(L("Discreet mode"))
        let discreetNote = note(L("When the tab is collapsed and idle, it fades. Hover or expand brings it back to full opacity. On by default."))

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
        stack.addArrangedSubview(copy)
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        for view in [intro, statusBody, delayNote, loginNote, displayNote, positionNote, pinNote, discreetNote] {
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
            displayNote.stringValue = L("The tab and the expanded strip use the top edge of this display. If you unplug it, TouchBarPill uses the built-in display, or the main display, until it returns.")
        } else {
            displayNote.stringValue = L("That display is unplugged. Showing the built-in display, or the main display, until it is back. The choice is remembered.")
        }

        positionPopup.removeAllItems()
        positionPopup.addItem(withTitle: L("Left"))
        positionPopup.lastItem?.tag = 0
        positionPopup.addItem(withTitle: L("Center"))
        positionPopup.lastItem?.tag = 1
        positionPopup.addItem(withTitle: L("Right"))
        positionPopup.lastItem?.tag = 2
        if PillPlacement.isPurePreset {
            switch PillPlacement.anchor {
            case .leading: positionPopup.selectItem(withTag: 0)
            case .center: positionPopup.selectItem(withTag: 1)
            case .trailing: positionPopup.selectItem(withTag: 2)
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
        let anchor: PillAnchor
        switch item.tag {
        case 0: anchor = .leading
        case 2: anchor = .trailing
        default: anchor = .center
        }
        PillPlacement.storeAnchor(anchor)
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

    @objc private func copyDiagnostics() {
        guard let mirror else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppDelegate.diagnosticsText(mirror: mirror), forType: .string)
    }
}
