import AppKit
import ServiceManagement

/// Opt-in login item. Launch never registers or unregisters anything — that
/// call is what makes macOS put up an admin password sheet (`sfltool`).
/// The checkbox starts off. `SMAppService` runs only after the user flips it.
enum LaunchAtLogin {
    enum Gate: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unsupported
    }

    /// Result of a user toggle. `.needsSettings` means we should explain the
    /// Login Items pane. Launch does not produce this.
    enum Outcome: Equatable {
        case unchanged
        case updated
        case needsSettings
    }

    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// True only when the system already has this app as a login item.
    /// A fresh install is false. Reading this does not register anything.
    static var isOn: Bool {
        switch gate {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound, .unsupported:
            return false
        }
    }

    static var gate: Gate {
        guard #available(macOS 13.0, *) else { return .unsupported }
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .notRegistered:
            return .notRegistered
        @unknown default:
            return .notRegistered
        }
    }

    private(set) static var lastError: String?

    /// Drop the previous build's stored "on" flag. Does not touch ServiceManagement.
    static func forgetLegacyPreference() {
        UserDefaults.standard.removeObject(forKey: "LaunchAtLogin")
    }

    static func setEnabled(_ enabled: Bool) -> Outcome {
        lastError = nil
        guard #available(macOS 13.0, *) else {
            if enabled {
                lastError = L("Opening at login requires macOS 13 or later.")
                return .needsSettings
            }
            return .unchanged
        }

        let service = SMAppService.mainApp
        do {
            if enabled {
                switch service.status {
                case .enabled:
                    return .unchanged
                case .requiresApproval:
                    return .needsSettings
                default:
                    try service.register()
                }
            } else {
                if service.status == .notRegistered || service.status == .notFound {
                    return .unchanged
                }
                try service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
            return .needsSettings
        }

        if enabled && gate != .enabled {
            return .needsSettings
        }
        return .updated
    }

    static func note() -> String {
        if let lastError {
            return lastError
        }
        switch gate {
        case .requiresApproval:
            return L("macOS still needs your OK before TouchBarPill can open at login. Allow it under System Settings → General → Login Items.")
        case .unsupported:
            return L("Opening at login requires macOS 13 or later.")
        case .enabled:
            return L("TouchBarPill will open when you log in. Turn this off to remove it from Login Items.")
        case .notRegistered, .notFound:
            return L("Off by default. Turn it on here or from the menu-bar icon. macOS may then ask you to allow TouchBarPill under System Settings → General → Login Items.")
        }
    }

    static var needsSettingsButton: Bool {
        if lastError != nil { return true }
        switch gate {
        case .requiresApproval, .notFound, .unsupported:
            return true
        case .enabled, .notRegistered:
            return false
        }
    }

    static func menuTitle() -> String {
        if gate == .requiresApproval {
            return L("Open at Login (approval needed)")
        }
        return L("Open at Login")
    }

    static func openSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.users") {
            NSWorkspace.shared.open(url)
        }
    }

    static func presentHelp() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Allow TouchBarPill in Login Items")
        alert.informativeText = L("Open at Login is still off. To allow it, open System Settings → General → Login Items and enable TouchBarPill.")
        alert.addButton(withTitle: L("Open Login Items Settings"))
        alert.addButton(withTitle: L("OK"))
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }

    static func diagnosticLine() -> String {
        let choice = isOn ? L("on") : L("off")
        let state: String
        switch gate {
        case .enabled:
            state = L("enabled")
        case .requiresApproval:
            state = L("needs approval")
        case .notRegistered:
            state = L("not registered")
        case .notFound:
            state = L("not found")
        case .unsupported:
            state = L("needs macOS 13")
        }
        var line = String(format: L("Launch at login: %@ (%@)"), choice, state)
        if let lastError {
            line += " — \(lastError)"
        }
        return line
    }
}
