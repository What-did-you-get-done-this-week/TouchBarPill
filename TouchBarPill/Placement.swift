import AppKit
import CoreGraphics

/// Where the collapsed notch sits along the chosen display.
/// `leading` is the left edge, `trailing` the right edge. An offset, in
/// points, shifts it from that anchor. A free drag is stored as `center`
/// plus the distance from the display's midpoint.
enum PillAnchor: String {
    case leading
    case center
    case trailing
}

/// Persisted placement, pin, and discreet-mode settings.
/// Launch never writes these. Missing keys mean: center, not pinned,
/// discreet mode on at 52% opacity.
enum PillPlacement {
    static let didChange = Notification.Name("PillPlacementDidChange")

    static let displayIDKey = "PreferredDisplayID"
    static let anchorKey = "PillAnchor"
    static let offsetKey = "PillOffset"
    static let pinKey = "PinExpanded"
    static let discreetKey = "DiscreetMode"
    static let opacityKey = "DiscreetOpacity"
    static let idleDelayKey = "DiscreetIdleDelay"

    static let defaultOpacity = 0.52

    static func postChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static var anchor: PillAnchor {
        get {
            let raw = UserDefaults.standard.string(forKey: anchorKey) ?? PillAnchor.center.rawValue
            return PillAnchor(rawValue: raw) ?? .center
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: anchorKey) }
    }

    /// Points added after the anchor. Zero is a pure Left / Center / Right slot.
    static var offset: CGFloat {
        get {
            guard UserDefaults.standard.object(forKey: offsetKey) != nil else { return 0 }
            return CGFloat(UserDefaults.standard.double(forKey: offsetKey))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: offsetKey) }
    }

    static var isPurePreset: Bool { abs(offset) < 0.5 }

    /// Nil until the user picks a display. A missing or unplugged id falls back.
    static var preferredDisplayID: CGDirectDisplayID? {
        get {
            guard UserDefaults.standard.object(forKey: displayIDKey) != nil else { return nil }
            let value = UserDefaults.standard.integer(forKey: displayIDKey)
            guard value > 0 else { return nil }
            return CGDirectDisplayID(value)
        }
        set {
            if let newValue, newValue != 0 {
                UserDefaults.standard.set(Int(newValue), forKey: displayIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: displayIDKey)
            }
        }
    }

    static var preferredDisplayIsConnected: Bool {
        guard let saved = preferredDisplayID else { return true }
        return NSScreen.screens.contains { DisplayList.id(of: $0) == saved }
    }

    static var pinExpanded: Bool {
        get { UserDefaults.standard.bool(forKey: pinKey) }
        set { UserDefaults.standard.set(newValue, forKey: pinKey) }
    }

    /// Default ON when the key has never been written.
    static var discreetMode: Bool {
        get {
            guard UserDefaults.standard.object(forKey: discreetKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: discreetKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: discreetKey) }
    }

    /// Clamped to 0.35...0.75. Default 0.52.
    static var discreetOpacity: CGFloat {
        get {
            guard let raw = UserDefaults.standard.object(forKey: opacityKey) as? Double else {
                return CGFloat(defaultOpacity)
            }
            return CGFloat(min(max(raw, 0.35), 0.75))
        }
        set {
            let clamped = min(max(Double(newValue), 0.35), 0.75)
            UserDefaults.standard.set(clamped, forKey: opacityKey)
        }
    }

    /// How long the collapsed notch stays at full opacity before it fades.
    /// `defaults write com.touchbarpill.TouchBarPill DiscreetIdleDelay -float 1.2`
    static var idleDelay: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: idleDelayKey)
        guard raw > 0 else { return 1.2 }
        return min(max(raw, 0.3), 8)
    }

    static func storeAnchor(_ anchor: PillAnchor) {
        self.anchor = anchor
        offset = 0
    }
}

enum DisplayList {
    static func id(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let number = screen.deviceDescription[key] as? NSNumber
        return CGDirectDisplayID(number?.uint32Value ?? 0)
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        let ident = id(of: screen)
        guard ident != 0 else { return false }
        return CGDisplayIsBuiltin(ident) != 0
    }

    struct Entry {
        let screen: NSScreen
        let title: String
    }

    /// Names from the system. Empty or unknown names become "Built-in" or "Display N".
    /// Duplicate names get a numeric suffix.
    static func entries() -> [Entry] {
        let screens = NSScreen.screens
        let raw: [String] = screens.enumerated().map { index, screen in
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name == "Unknown" || name == "Unknown Display" {
                if isBuiltIn(screen) { return L("Built-in") }
                return String(format: L("Display %d"), index + 1)
            }
            return name
        }
        var counts: [String: Int] = [:]
        for name in raw { counts[name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return zip(screens, raw).map { screen, name in
            guard counts[name, default: 0] > 1 else { return Entry(screen: screen, title: name) }
            seen[name, default: 0] += 1
            return Entry(screen: screen, title: "\(name) (\(seen[name]!))")
        }
    }

    /// The saved display, or the built-in display, or the main display.
    static func resolved() -> NSScreen? {
        if let saved = PillPlacement.preferredDisplayID,
           let match = NSScreen.screens.first(where: { id(of: $0) == saved }) {
            return match
        }
        return NSScreen.screens.first(where: isBuiltIn) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func clamp(_ x: CGFloat, width: CGFloat, on screen: NSScreen) -> CGFloat {
        let minX = screen.frame.minX
        let maxX = screen.frame.maxX - width
        if maxX <= minX { return minX }
        return min(max(x, minX), maxX)
    }

    static func collapsedOriginX(width: CGFloat, on screen: NSScreen) -> CGFloat {
        let frame = screen.frame
        let x: CGFloat
        switch PillPlacement.anchor {
        case .leading:
            x = frame.minX + PillPlacement.offset
        case .trailing:
            x = frame.maxX - width - PillPlacement.offset
        case .center:
            x = frame.midX - width / 2 + PillPlacement.offset
        }
        return clamp(x, width: width, on: screen)
    }

    /// Remember a dragged X as center + offset so it survives a resolution change
    /// better than a raw global coordinate, and still clamps onto the display.
    static func storeFreeX(_ x: CGFloat, width: CGFloat, on screen: NSScreen) {
        let clamped = clamp(x, width: width, on: screen)
        let center = clamped + width / 2
        PillPlacement.anchor = .center
        PillPlacement.offset = center - screen.frame.midX
    }
}
