import AppKit

/// Preferences is a stub for this milestone: it reports live stream status
/// and documents the delay, login item, and display behavior that are not
/// editable here yet. The collapse delay can still be set with `defaults`.
final class PreferencesController: NSWindowController {
    private let statusTitle = NSTextField(labelWithString: "Stream")
    private let statusBody = NSTextField(wrappingLabelWithString: "Starting…")
    private let delayValue = NSTextField(labelWithString: "")
    private var mirror: DFRMirror?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TouchBarPill Preferences"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
    }

    func attach(mirror: DFRMirror) {
        self.mirror = mirror
        refresh()
    }

    func show() {
        refresh()
        window?.center()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard let mirror else { return }
        statusTitle.stringValue = mirror.simulatorReady ? "Stream" : "Stream unavailable"
        statusBody.stringValue = mirror.statusMessage
        let delay = PillMetrics.collapseDelay
        delayValue.stringValue = String(format: "%.2f seconds", delay)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        // AppKit's layoutMarginsGuide is read-only; NSView has no layoutMargins setter.
        let inset = NSLayoutGuide()
        content.addLayoutGuide(inset)
        NSLayoutConstraint.activate([
            inset.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            inset.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            inset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            inset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        let heading = NSTextField(labelWithString: "TouchBarPill")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)

        let intro = NSTextField(wrappingLabelWithString: "A thin pill at the top of the screen. Hover it to expand the live adaptive Touch Bar, then move away and it collapses.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 440

        statusTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        statusBody.font = .systemFont(ofSize: 12)
        statusBody.textColor = .secondaryLabelColor
        statusBody.maximumNumberOfLines = 4
        statusBody.preferredMaxLayoutWidth = 440

        let delayLabel = NSTextField(labelWithString: "Collapse delay")
        delayLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        delayValue.font = .systemFont(ofSize: 12)
        delayValue.textColor = .secondaryLabelColor
        let delayNote = NSTextField(wrappingLabelWithString: "Fixed for this version. Change it without rebuilding: defaults write com.touchbarpill.TouchBarPill CollapseDelay -float 0.5")
        delayNote.font = .systemFont(ofSize: 11)
        delayNote.textColor = .tertiaryLabelColor
        delayNote.preferredMaxLayoutWidth = 440

        let loginLabel = NSTextField(labelWithString: "Open at login")
        loginLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let loginNote = NSTextField(wrappingLabelWithString: "Not in this version. Add TouchBarPill.app under System Settings → General → Login Items.")
        loginNote.font = .systemFont(ofSize: 11)
        loginNote.textColor = .tertiaryLabelColor
        loginNote.preferredMaxLayoutWidth = 440

        let displayLabel = NSTextField(labelWithString: "Display")
        displayLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let displayNote = NSTextField(wrappingLabelWithString: "While collapsed, the pill follows the screen under the pointer. There is no pin-to-display control yet.")
        displayNote.font = .systemFont(ofSize: 11)
        displayNote.textColor = .tertiaryLabelColor
        displayNote.preferredMaxLayoutWidth = 440

        let copy = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        copy.bezelStyle = .rounded

        let views = [heading, intro, statusTitle, statusBody, delayLabel, delayValue, delayNote, loginLabel, loginNote, displayLabel, displayNote, copy]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            intro.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            intro.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            intro.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            statusTitle.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 16),
            statusTitle.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            statusTitle.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            statusBody.topAnchor.constraint(equalTo: statusTitle.bottomAnchor, constant: 2),
            statusBody.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            statusBody.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            delayLabel.topAnchor.constraint(equalTo: statusBody.bottomAnchor, constant: 14),
            delayLabel.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            delayValue.centerYAnchor.constraint(equalTo: delayLabel.centerYAnchor),
            delayValue.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            delayNote.topAnchor.constraint(equalTo: delayLabel.bottomAnchor, constant: 2),
            delayNote.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            delayNote.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            loginLabel.topAnchor.constraint(equalTo: delayNote.bottomAnchor, constant: 12),
            loginLabel.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            loginLabel.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            loginNote.topAnchor.constraint(equalTo: loginLabel.bottomAnchor, constant: 2),
            loginNote.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            loginNote.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            displayLabel.topAnchor.constraint(equalTo: loginNote.bottomAnchor, constant: 12),
            displayLabel.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            displayLabel.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            displayNote.topAnchor.constraint(equalTo: displayLabel.bottomAnchor, constant: 2),
            displayNote.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
            displayNote.trailingAnchor.constraint(equalTo: inset.trailingAnchor),

            copy.topAnchor.constraint(equalTo: displayNote.bottomAnchor, constant: 16),
            copy.leadingAnchor.constraint(equalTo: inset.leadingAnchor),
        ])
    }

    @objc private func copyDiagnostics() {
        guard let mirror else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppDelegate.diagnosticsText(mirror: mirror), forType: .string)
    }
}
