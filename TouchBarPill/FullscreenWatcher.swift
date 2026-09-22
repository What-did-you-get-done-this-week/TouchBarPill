import AppKit

/// Detects fullscreen / menu-bar-hidden via public AppKit presentation options
/// and screen geometry. Does not read other apps’ windows or data.
final class FullscreenWatcher {
    static let shared = FullscreenWatcher()
    static let didChange = Notification.Name("FullscreenWatcherDidChange")

    private(set) var isFullscreen = false
    private var poll: Timer?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reevaluate),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Presentation options can flip without a space change (some players).
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.reevaluate()
        }
        timer.tolerance = 0.1
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

    @objc private func reevaluate() {
        let next = Self.immersive()
        guard next != isFullscreen else { return }
        isFullscreen = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// True when a fullscreen space or a hidden menu bar (cinema) is in effect.
    /// The auto-hide menu bar *preference* does not count while the bar still
    /// reserves space at the top of a screen.
    static func immersive() -> Bool {
        let options = NSApp.currentSystemPresentationOptions
        if options.contains(.fullScreen) || options.contains(.hideMenuBar) {
            return true
        }
        // Bar is actually gone. Players sometimes hide it (and the Dock) a
        // moment before the fullScreen bit is published.
        guard menuBarReservedHeight() < 1 else { return false }
        if options.contains(.hideDock) { return true }
        if !options.contains(.autoHideMenuBar) { return true }
        return false
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
