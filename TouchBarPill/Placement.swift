import AppKit
import CoreGraphics

/// Which screen edge the collapsed notch attaches to.
/// Default is the top center. Side placements sit at the vertical middle.
enum PillEdge: String, CaseIterable {
    case topCenter
    case bottomCenter
    case leftMid
    case rightMid

    var attachesTop: Bool { self == .topCenter }
    var attachesBottom: Bool { self == .bottomCenter }
    var attachesLeft: Bool { self == .leftMid }
    var attachesRight: Bool { self == .rightMid }
    var isHorizontalEdge: Bool { attachesTop || attachesBottom }
    var isVerticalEdge: Bool { attachesLeft || attachesRight }
}

/// Persisted placement, pin, and discreet-mode settings.
/// Launch never writes these. Missing keys mean: top center, not pinned,
/// discreet mode on at 52% opacity.
enum PillPlacement {
    static let didChange = Notification.Name("PillPlacementDidChange")

    static let displayIDKey = "PreferredDisplayID"
    static let edgeKey = "PillEdge"
    /// Legacy horizontal-slot key from 0.3.0 (leading / center / trailing).
    static let legacyAnchorKey = "PillAnchor"
    static let offsetKey = "PillOffset"
    static let pinKey = "PinExpanded"
    static let discreetKey = "DiscreetMode"
    static let opacityKey = "DiscreetOpacity"
    static let idleDelayKey = "DiscreetIdleDelay"

    static let defaultOpacity = 0.52

    static func postChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static var edge: PillEdge {
        get {
            if let raw = UserDefaults.standard.string(forKey: edgeKey),
               let edge = PillEdge(rawValue: raw) {
                return edge
            }
            // 0.3.0 stored Left / Center / Right along the top edge only.
            // Those presets become top-center; a free drag offset is kept.
            if UserDefaults.standard.string(forKey: legacyAnchorKey) != nil {
                return .topCenter
            }
            return .topCenter
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: edgeKey) }
    }

    /// Points added after the edge’s natural mid. Zero is the pure preset.
    /// On top/bottom edges this is horizontal. On left/right it is vertical.
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

    static func storeEdge(_ edge: PillEdge) {
        self.edge = edge
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

    static func clampX(_ x: CGFloat, width: CGFloat, on screen: NSScreen) -> CGFloat {
        let minX = screen.frame.minX
        let maxX = screen.frame.maxX - width
        if maxX <= minX { return minX }
        return min(max(x, minX), maxX)
    }

    static func clampY(_ y: CGFloat, height: CGFloat, on screen: NSScreen) -> CGFloat {
        let minY = screen.frame.minY
        let maxY = screen.frame.maxY - height
        if maxY <= minY { return minY }
        return min(max(y, minY), maxY)
    }

    /// Collapsed notch size. Side edges swap width/height so the ears meet the bezel.
    static func collapsedSize(for edge: PillEdge = PillPlacement.edge) -> NSSize {
        let base = PillMetrics.collapsedSize
        if edge.isVerticalEdge {
            return NSSize(width: base.height, height: base.width)
        }
        return base
    }

    static func collapsedOrigin(size: NSSize, on screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        let offset = PillPlacement.offset
        switch PillPlacement.edge {
        case .topCenter:
            let x = clampX(frame.midX - size.width / 2 + offset, width: size.width, on: screen)
            return NSPoint(x: x, y: frame.maxY - size.height)
        case .bottomCenter:
            let x = clampX(frame.midX - size.width / 2 + offset, width: size.width, on: screen)
            return NSPoint(x: x, y: frame.minY)
        case .leftMid:
            let y = clampY(frame.midY - size.height / 2 + offset, height: size.height, on: screen)
            return NSPoint(x: frame.minX, y: y)
        case .rightMid:
            let y = clampY(frame.midY - size.height / 2 + offset, height: size.height, on: screen)
            return NSPoint(x: frame.maxX - size.width, y: y)
        }
    }

    /// Remember a free drag as an offset from the edge’s mid so it survives a
    /// resolution change, and still clamps onto the display.
    static func storeFreeOrigin(_ origin: NSPoint, size: NSSize, on screen: NSScreen) {
        switch PillPlacement.edge {
        case .topCenter, .bottomCenter:
            let clamped = clampX(origin.x, width: size.width, on: screen)
            let center = clamped + size.width / 2
            PillPlacement.offset = center - screen.frame.midX
        case .leftMid, .rightMid:
            let clamped = clampY(origin.y, height: size.height, on: screen)
            let center = clamped + size.height / 2
            PillPlacement.offset = center - screen.frame.midY
        }
    }
}
