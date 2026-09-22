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

/// Collapsed-notch chrome theme. Applies to the tab only, not the DFR stream.
enum NotchTheme: String, CaseIterable {
    case black
    case graphite
    case softAccent

    var menuTitle: String {
        switch self {
        case .black: return L("Black")
        case .graphite: return L("Graphite")
        case .softAccent: return L("Soft accent")
        }
    }

    /// Fill for the collapsed notch silhouette.
    var fillColor: NSColor {
        switch self {
        case .black:
            // Opaque. A 0.97 fill antialiases into a light rim on the wallpaper,
            // which on a side tab reads as a floating window outline.
            return NSColor(calibratedWhite: 0.04, alpha: 1)
        case .graphite:
            return NSColor(calibratedWhite: 0.16, alpha: 1)
        case .softAccent:
            // Deep blue — tasteful tint, still dark enough for white labels.
            return NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.24, alpha: 1)
        }
    }
}

/// Collapsed notch size. M matches 0.4.0 (132×32). S scales ~85%.
enum NotchSize: String, CaseIterable {
    case small
    case medium

    var menuTitle: String {
        switch self {
        case .small: return L("S")
        case .medium: return L("M")
        }
    }

    /// Uniform scale vs the medium (current) notch.
    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        }
    }
}

/// Fullscreen edge hit-zone thickness. 0.4.2 locks this to Wide.
enum HitZoneWidth: String, CaseIterable {
    case narrow
    case normal
    case wide

    var menuTitle: String {
        switch self {
        case .narrow: return L("Narrow")
        case .normal: return L("Normal")
        case .wide: return L("Wide")
        }
    }

    /// Extra points inward from the bezel beyond the visual notch, when fullscreen.
    var pad: CGFloat {
        switch self {
        case .narrow: return 2
        case .normal: return 8
        case .wide: return 16
        }
    }
}

/// The volume slider anchored to the right wing. It does not expand the Touch Bar.
/// The panel controller owns the lifetime; layout only reads it.
enum VolumeChrome {
    static var sliderVisible = false
}

/// Persisted placement, pin, and notch-chrome settings.
/// Launch never writes these. Missing keys mean: top center, not pinned,
/// discreet fade at 52% opacity (always on), soft accent, small size.
/// A saved theme, size, or edge is kept. Resetting defaults (deleting the keys)
/// returns to those values. Fullscreen hit zone is always Wide.
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
    static let themeKey = "NotchTheme"
    static let sizeKey = "NotchSize"
    static let hitZoneKey = "HitZoneWidth"
    static let revealDelayKey = "RevealDelay"
    static let fullscreenHideDelayKey = "FullscreenHideDelay"
    static let cinemaModeKey = "CinemaMode"

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

    /// Always on. There is no UI toggle in 0.4.2. A stored "off" is ignored.
    static var discreetMode: Bool { true }

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

    /// Collapsed chrome theme. Soft accent when the key is missing.
    static var theme: NotchTheme {
        get {
            if let raw = UserDefaults.standard.string(forKey: themeKey),
               let theme = NotchTheme(rawValue: raw) {
                return theme
            }
            return .softAccent
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: themeKey) }
    }

    /// Collapsed notch size. Small when the key is missing.
    static var size: NotchSize {
        get {
            if let raw = UserDefaults.standard.string(forKey: sizeKey),
               let size = NotchSize(rawValue: raw) {
                return size
            }
            return .small
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sizeKey) }
    }

    /// Fullscreen edge hit zone. Locked to Wide so the cinema pad is easy to find.
    static var hitZone: HitZoneWidth { .wide }

    /// Hover-expand delay. Snappier than 0.4.0’s 0.14s.
    /// `defaults write com.touchbarpill.TouchBarPill RevealDelay -float 0.08`
    static var revealDelay: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: revealDelayKey)
        guard raw > 0 else { return 0.09 }
        return min(max(raw, 0.04), 1)
    }

    /// Fullscreen re-conceal delay after the pointer leaves.
    /// `defaults write com.touchbarpill.TouchBarPill FullscreenHideDelay -float 0.25`
    static var fullscreenHideDelay: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: fullscreenHideDelayKey)
        guard raw > 0 else { return 0.22 }
        return min(max(raw, 0.05), 3)
    }

    /// Manual override when window-frame detection cannot see a player.
    /// Off by default. The status menu toggles it. Does not grant any permission.
    static var cinemaMode: Bool {
        get { UserDefaults.standard.bool(forKey: cinemaModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: cinemaModeKey) }
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

    /// How far a side tab tucks past the bezel so the flat edge cannot leave a seam.
    static let bezelOverhang: CGFloat = 3

    /// Extra inward hit pad on left/right so scroll and click land on a thin tab.
    static let sideHitPad: CGFloat = 14

    /// Visual collapsed notch size (theme/size prefs). Side edges swap axes.
    /// The volume slider is extra panel space, not part of this silhouette.
    static func visualCollapsedSize(for edge: PillEdge = PillPlacement.edge) -> NSSize {
        let size = ZonePolicy.visualSize(edge: NotchEdgeKind(edge), scale: PillPlacement.size.scale)
        return NSSize(width: size.width, height: size.height)
    }

    /// Transparent inward pad. Side tabs always keep a little pad so the wheel
    /// hits. Cinema uses the wide pad on every edge.
    static func interactionPad(for edge: PillEdge, immersive: Bool) -> CGFloat {
        let cinema: CGFloat = immersive ? PillPlacement.hitZone.pad : 0
        let side: CGFloat = edge.isVerticalEdge ? sideHitPad : 0
        return max(cinema, side)
    }

    /// Panel size including fullscreen hit-zone pad when immersive.
    static func collapsedSize(
        for edge: PillEdge = PillPlacement.edge,
        immersive: Bool = FullscreenWatcher.shared.isFullscreen
    ) -> NSSize {
        let visual = visualCollapsedSize(for: edge)
        let slider = VolumeChrome.sliderVisible ? ZonePolicy.sliderLength * PillPlacement.size.scale : 0
        let extra = slider + interactionPad(for: edge, immersive: immersive)
        guard extra > 0 else { return visual }
        switch edge {
        case .topCenter, .bottomCenter:
            return NSSize(width: visual.width, height: visual.height + extra)
        case .leftMid, .rightMid:
            return NSSize(width: visual.width + extra, height: visual.height)
        }
    }

    /// Rect of the drawn notch inside a (possibly padded) panel, flush to the bezel.
    static func visualCollapsedRect(in bounds: NSRect, edge: PillEdge = PillPlacement.edge) -> NSRect {
        let visual = visualCollapsedSize(for: edge)
        switch edge {
        case .topCenter:
            return NSRect(x: bounds.minX, y: bounds.maxY - visual.height, width: visual.width, height: visual.height)
        case .bottomCenter:
            return NSRect(x: bounds.minX, y: bounds.minY, width: visual.width, height: visual.height)
        case .leftMid:
            return NSRect(x: bounds.minX, y: bounds.minY, width: visual.width, height: visual.height)
        case .rightMid:
            return NSRect(x: bounds.maxX - visual.width, y: bounds.minY, width: visual.width, height: visual.height)
        }
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
            return NSPoint(x: frame.minX - bezelOverhang, y: y)
        case .rightMid:
            let y = clampY(frame.midY - size.height / 2 + offset, height: size.height, on: screen)
            return NSPoint(x: frame.maxX - size.width + bezelOverhang, y: y)
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

extension NotchEdgeKind {
    init(_ edge: PillEdge) {
        switch edge {
        case .topCenter: self = .top
        case .bottomCenter: self = .bottom
        case .leftMid: self = .left
        case .rightMid: self = .right
        }
    }
}
