import AppKit
import ServiceManagement

/// Login item for this app. Default is on. macOS 13 and later use `SMAppService`;
/// earlier systems keep the preference but cannot register an item from here.
enum LaunchAtLogin {
    static let defaultsKey = "LaunchAtLogin"

    enum Gate: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unsupported
    }

    /// What the user last chose. Missing key means on.
    static var userWantsEnabled: Bool {
        guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
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

    /// Apply the saved choice, or turn the login item on the first time.
    static func syncOnLaunch() {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: defaultsKey)
        }
        apply(userWantsEnabled)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        apply(enabled)
    }

    static func note() -> String {
        if let lastError, userWantsEnabled {
            return String(format: L("Could not update the login item: %@"), lastError)
        }
        switch gate {
        case .requiresApproval where userWantsEnabled:
            return L("macOS still needs approval before TouchBarPill can open at login. Allow it under System Settings → General → Login Items.")
        case .unsupported:
            return L("Opening at login requires macOS 13 or later.")
        default:
            return L("On by default. macOS may ask you to allow the login item under System Settings → General → Login Items.")
        }
    }

    static func menuTitle() -> String {
        if gate == .requiresApproval && userWantsEnabled {
            return L("Open at Login (approval needed)")
        }
        return L("Open at Login")
    }

    static func diagnosticLine() -> String {
        let choice = userWantsEnabled ? L("on") : L("off")
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

    private static func apply(_ enabled: Bool) {
        lastError = nil
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                switch service.status {
                case .enabled, .requiresApproval:
                    break
                default:
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
