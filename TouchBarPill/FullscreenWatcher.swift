import AppKit
import CoreGraphics

/// Why the notch should tuck away. Diagnostics print `token`.
enum FullscreenKind: Equatable {
    case none
    case system
    case cinemaWindow
    case systemAndCinema
    case manual

    var hidesNotch: Bool { self != .none }

    /// Stable diagnostic token. `cinema-window` means a frontmost on-screen
    /// window frame covers the chosen display (browser / YouTube fullscreen).
    var token: String {
        switch self {
        case .none: return "no"
        case .system: return "system"
        case .cinemaWindow: return "cinema-window"
        case .systemAndCinema: return "system+cinema-window"
        case .manual: return "manual"
        }
    }
}

/// Pure frame tests. No window pixels, titles, or file access.
enum CinemaGeometry {
    /// Enter cinema when the frontmost content window covers about 98% of the display.
    static let coverageEnter: CGFloat = 0.98
    /// Stay in cinema until coverage drops clearly, so a 1px flicker does not show the notch.
    static let coverageExit: CGFloat = 0.94

    /// CGWindow bounds use a top-left origin on the primary display, y down.
    /// Cocoa screens use a bottom-left origin, y up.
    static func cocoaRect(fromCGWindow cg: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: cg.origin.x,
            y: primaryMaxY - cg.origin.y - cg.height,
            width: cg.width,
            height: cg.height
        )
    }

    /// True when `window` covers the chosen display.
    /// Area ratio is the main test. A window that reaches every edge within a
    /// small slack (menu bar / notch) also counts, so browser fullscreen that
    /// stops a hair short of the full frame still hides the notch.
    static func coversDisplay(_ screen: CGRect, window: CGRect, latched: Bool) -> Bool {
        let hit = window.intersection(screen)
        guard !hit.isNull, hit.width > 1, hit.height > 1 else { return false }
        let area = screen.width * screen.height
        guard area > 1 else { return false }
        let ratio = (hit.width * hit.height) / area
        let threshold = latched ? coverageExit : coverageEnter
        if ratio >= threshold { return true }
        let xSlack = max(12, screen.width * 0.02)
        let ySlack = max(40, screen.height * 0.045)
        let core = screen.insetBy(dx: xSlack, dy: ySlack)
        guard core.width > 1, core.height > 1 else { return false }
        return window.contains(core)
    }

    /// Skip menu bar, Dock, tooltips, and notches. The first remaining window
    /// on this display is the frontmost content window.
    static func isContentWindow(windowArea: CGFloat, intersectionArea: CGFloat, screenArea: CGFloat) -> Bool {
        guard screenArea > 1 else { return false }
        if windowArea < screenArea * 0.15 { return false }
        if intersectionArea < screenArea * 0.10 { return false }
        return true
    }
}

/// Fullscreen / cinema hide.
/// System presentation options catch a real fullscreen space.
/// Browser video fullscreen (YouTube) often does not set those options: the
/// frontmost window simply covers the display. That case uses on-screen
/// window **frames** from `CGWindowListCopyWindowInfo` (bounds, owner pid,
/// layer, alpha). It does not capture pixels, read window titles, touch
/// Accessibility, or open another app’s files — so it does not raise the
/// “access data from other apps” / screen-recording prompt.
/// Manual “Cinema mode” is the fallback when frames are not enough.
final class FullscreenWatcher {
    static let shared = FullscreenWatcher()
    static let didChange = Notification.Name("FullscreenWatcherDidChange")

    private(set) var kind: FullscreenKind = .none
    /// Coverage of the frontmost content window on the chosen display, 0...1.
    private(set) var frontCoverage: CGFloat = 0
    private var windowLatched = false
    private var poll: Timer?

    var isFullscreen: Bool { kind.hidesNotch }

    var diagnosticToken: String { kind.token }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(reevaluate),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(reevaluate),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(reevaluate),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reevaluate),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.reevaluate()
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        reevaluate()
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    /// Menu toggle and screen changes call this. The poll uses the same path.
    func refresh() {
        reevaluate()
    }

    @objc private func reevaluate() {
        let sample = Self.sample(windowLatched: windowLatched)
        windowLatched = sample.windowCovers
        frontCoverage = sample.coverage
        let next = sample.kind
        guard next != kind else { return }
        kind = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private struct Sample {
        var kind: FullscreenKind
        var windowCovers: Bool
        var coverage: CGFloat
    }

    private static func sample(windowLatched: Bool) -> Sample {
        let window = frontmostContent(latched: windowLatched)
        let system = systemImmersive()
        let kind: FullscreenKind
        if system && window.covers {
            kind = .systemAndCinema
        } else if window.covers {
            kind = .cinemaWindow
        } else if system {
            kind = .system
        } else if PillPlacement.cinemaMode {
            kind = .manual
        } else {
            kind = .none
        }
        return Sample(kind: kind, windowCovers: window.covers, coverage: window.coverage)
    }

    /// True when a fullscreen space or a hidden menu bar (system cinema) is in effect.
    /// The auto-hide menu bar *preference* does not count while the bar still
    /// reserves space at the top of a screen.
    static func systemImmersive() -> Bool {
        let options = NSApp.currentSystemPresentationOptions
        if options.contains(.fullScreen) || options.contains(.hideMenuBar) {
            return true
        }
        guard menuBarReservedHeight() < 1 else { return false }
        if options.contains(.hideDock) { return true }
        if !options.contains(.autoHideMenuBar) { return true }
        return false
    }

    private struct FrontWindow {
        var covers: Bool
        var coverage: CGFloat
    }

    /// Frontmost on-screen content window on the chosen display.
    /// Frames only: `kCGWindowBounds` plus pid / layer / alpha so we can skip
    /// ourselves, invisible windows, and desktop layers. No image, no title.
    private static func frontmostContent(latched: Bool) -> FrontWindow {
        guard let screen = DisplayList.resolved() else {
            return FrontWindow(covers: false, coverage: 0)
        }
        let primaryMaxY = primaryScreenMaxY()
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return FrontWindow(covers: false, coverage: 0)
        }
        let mine = pid_t(ProcessInfo.processInfo.processIdentifier)
        let screenFrame = screen.frame
        let screenArea = screenFrame.width * screenFrame.height
        guard screenArea > 1 else { return FrontWindow(covers: false, coverage: 0) }

        for info in list {
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            if owner == mine || owner <= 0 { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha < 0.05 { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer < 0 { continue }
            guard let cg = cgBounds(info) else { continue }
            let cocoa = CinemaGeometry.cocoaRect(fromCGWindow: cg, primaryMaxY: primaryMaxY)
            let hit = cocoa.intersection(screenFrame)
            if hit.isNull || hit.width < 2 || hit.height < 2 { continue }
            let windowArea = max(0, cocoa.width) * max(0, cocoa.height)
            let hitArea = hit.width * hit.height
            guard CinemaGeometry.isContentWindow(
                windowArea: windowArea,
                intersectionArea: hitArea,
                screenArea: screenArea
            ) else { continue }
            // A window that only clips this display from the next monitor is not
            // the frontmost window here. Keep walking.
            let mostlyHere = hitArea >= windowArea * 0.5 || hitArea >= screenArea * 0.5
            if !mostlyHere { continue }
            let coverage = min(1, hitArea / screenArea)
            let covers = CinemaGeometry.coversDisplay(screenFrame, window: cocoa, latched: latched)
            return FrontWindow(covers: covers, coverage: coverage)
        }
        return FrontWindow(covers: false, coverage: 0)
    }

    private static func cgBounds(_ info: [String: Any]) -> CGRect? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    /// Top of the global Cocoa space. CG y = 0 sits on this line.
    private static func primaryScreenMaxY() -> CGFloat {
        if let primary = NSScreen.screens.first(where: { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 }) {
            return primary.frame.maxY
        }
        return NSScreen.screens.map(\.frame.maxY).max() ?? 0
    }

    /// Largest menu-bar inset across screens. Zero means the bar is not reserving space.
    private static func menuBarReservedHeight() -> CGFloat {
        var reserve: CGFloat = 0
        for screen in NSScreen.screens {
            reserve = max(reserve, screen.frame.maxY - screen.visibleFrame.maxY)
        }
        return reserve
    }
}
