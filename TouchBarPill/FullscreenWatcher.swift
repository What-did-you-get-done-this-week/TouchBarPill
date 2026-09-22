import AppKit

/// Detects system / space fullscreen via public AppKit presentation options
/// and space-change notifications. Does not read other apps’ windows or data.
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reevaluate),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Presentation options can flip without a space change (some players).
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
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

    @objc private func reevaluate() {
        let options = NSApp.currentSystemPresentationOptions
        // Fullscreen spaces, or apps that force-hide the menu bar (cinema /
        // immersive players). Do not treat system “auto-hide menu bar” alone —
        // that preference is common on notch Macs and would keep the tab tucked.
        let byPresentation =
            options.contains(.fullScreen)
            || options.contains(.hideMenuBar)

        let next = byPresentation
        guard next != isFullscreen else { return }
        isFullscreen = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
