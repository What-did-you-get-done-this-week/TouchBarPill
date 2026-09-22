import AppKit
import QuartzCore

enum PillMetrics {
    static let collapsedSize = NSSize(width: 132, height: 32)

    /// Leave-collapse delay. Hardcoded at 0.4s unless overridden:
    /// `defaults write com.touchbarpill.TouchBarPill CollapseDelay -float 0.5`
    static var collapseDelay: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: "CollapseDelay")
        guard raw > 0 else { return 0.4 }
        return min(max(raw, 0.15), 2)
    }
}

/// Borderless, non-activating panel. Clicks must not activate TouchBarPill,
/// or the adaptive Touch Bar would switch to this app's empty bar.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PillPanelController: NSObject {
    let mirror: DFRMirror

    private let panel: PillPanel
    private let root: PillRootView
    private var expanded = false
    private var animating = false
    private var collapseItem: DispatchWorkItem?
    private var screenTimer: Timer?
    private var chromeGeneration = 0

    var isVisible: Bool { panel.isVisible }

    init(mirror: DFRMirror) {
        self.mirror = mirror
        panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: PillMetrics.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        root = PillRootView(frame: NSRect(origin: .zero, size: PillMetrics.collapsedSize))
        super.init()
        configurePanel()
        root.onEntered = { [weak self] in self?.pointerEntered() }
        root.onExited = { [weak self] in self?.pointerExited() }
        root.onRetry = { [weak self] in self?.retry() }
        root.streamView.onMouse = { [weak self] event in
            guard let self, self.expanded else { return }
            self.mirror.postMouseEvent(event, in: self.root.streamView)
        }
        mirror.attachStream(to: root.streamView)
        if let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first {
            panel.setFrame(collapsedFrame(on: screen), display: false)
        }
        root.apply(mirror: mirror, expanded: false)
        screenTimer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.followScreen()
        }
        if let screenTimer {
            RunLoop.main.add(screenTimer, forMode: .common)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        screenTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        if let screen = screenUnderMouse() ?? screenForPanel() {
            panel.setFrame(collapsedFrame(on: screen), display: false)
        }
        expanded = false
        root.apply(mirror: mirror, expanded: false)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        root.updateTrackingAreas()
        if panel.frame.contains(NSEvent.mouseLocation) {
            pointerEntered()
        }
    }

    func hide() {
        collapseItem?.cancel()
        expanded = false
        root.apply(mirror: mirror, expanded: false)
        panel.orderOut(nil)
    }

    func mirrorStateChanged() {
        root.apply(mirror: mirror, expanded: expanded)
        guard expanded, let screen = screenForPanel() else { return }
        let target = expandedFrame(on: screen)
        guard panel.frame != target else { return }
        animate(to: target, expanding: true)
    }

    private func configurePanel() {
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isRestorable = false
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        // One level above menu-bar status items, still under pop-up menus.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel("Touch Bar pill")
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
    }

    private func pointerEntered() {
        collapseItem?.cancel()
        guard !expanded else { return }
        setExpanded(true)
    }

    private func pointerExited() {
        guard expanded else { return }
        scheduleCollapse()
    }

    private func scheduleCollapse() {
        collapseItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) {
                return
            }
            self.setExpanded(false)
        }
        collapseItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PillMetrics.collapseDelay, execute: work)
    }

    private func setExpanded(_ expand: Bool) {
        collapseItem?.cancel()
        let was = expanded
        expanded = expand
        guard let screen = screenForPanel() ?? screenUnderMouse() ?? NSScreen.main else { return }
        let target = expand ? expandedFrame(on: screen) : collapsedFrame(on: screen)
        root.apply(mirror: mirror, expanded: expand)
        if was == expand && panel.frame == target {
            return
        }
        animate(to: target, expanding: expand)
    }

    private func animate(to target: NSRect, expanding: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduceMotion ? 0.01 : (expanding ? 0.34 : 0.26)
        animating = true
        chromeGeneration += 1
        let generation = chromeGeneration
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            guard let self, generation == self.chromeGeneration else { return }
            self.animating = false
            self.panel.invalidateShadow()
            if !expanding && !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.expanded = false
                self.root.apply(mirror: self.mirror, expanded: false)
            }
        }
    }

    private func retry() {
        mirror.stop()
        mirror.start()
    }

    @objc private func screensChanged() {
        followScreen()
    }

    private func followScreen() {
        guard panel.isVisible, !expanded, !animating else { return }
        guard let screen = screenUnderMouse() else { return }
        let target = collapsedFrame(on: screen)
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }

    private func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    private func screenForPanel() -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
    }

    private func topGap(on screen: NSScreen) -> CGFloat {
        guard hasNotch(screen) else { return 0 }
        return (screen.frame.maxY - screen.visibleFrame.maxY) + 6
    }

    private func hasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.auxiliaryTopLeftArea.width > 0 || screen.safeAreaInsets.top > 0
        }
        return false
    }

    private func collapsedFrame(on screen: NSScreen) -> NSRect {
        let size = PillMetrics.collapsedSize
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - topGap(on: screen),
            width: size.width,
            height: size.height
        )
    }

    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let gap = topGap(on: screen)
        if !mirror.hasFrame {
            let size = NSSize(width: min(520, screen.frame.width - 48), height: 136)
            return NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height - gap,
                width: size.width,
                height: size.height
            )
        }

        let aspect = displayAspect()
        let maxWidth = max(320, screen.frame.width - 36)
        let padX: CGFloat = 8
        let padY: CGFloat = 6
        var streamHeight: CGFloat = 36
        var streamWidth = streamHeight * aspect
        if streamWidth + padX * 2 > maxWidth {
            streamWidth = maxWidth - padX * 2
            streamHeight = streamWidth / aspect
        }
        let width = streamWidth + padX * 2
        let height = max(streamHeight + padY * 2, PillMetrics.collapsedSize.height)
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height - gap,
            width: width,
            height: height
        )
    }

    private func displayAspect() -> CGFloat {
        if mirror.lastSurfaceWidth > 10 && mirror.lastSurfaceHeight > 5 {
            return CGFloat(mirror.lastSurfaceWidth) / CGFloat(mirror.lastSurfaceHeight)
        }
        let size = mirror.touchBarPointSize
        if size.width > 10 && size.height > 5 {
            return size.width / size.height
        }
        return 1004.0 / 30.0
    }
}

final class PillRootView: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?
    var onRetry: (() -> Void)?

    let streamView = TouchBarStreamView(frame: .zero)
    private let chrome = CollapsedChromeView(frame: .zero)
    private let fallback = FallbackView(frame: .zero)
    private var tracking: NSTrackingArea?
    private var expanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.97).cgColor
        layer?.cornerCurve = CALayerCornerCurve.continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        addSubview(streamView)
        addSubview(chrome)
        addSubview(fallback)
        fallback.onRetry = { [weak self] in self?.onRetry?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(mirror: DFRMirror, expanded: Bool) {
        self.expanded = expanded
        chrome.isLive = mirror.hasFrame
        chrome.needsDisplay = true
        fallback.title = mirror.simulatorReady ? "Touch Bar" : "Touch Bar unavailable"
        fallback.message = mirror.statusMessage
        chrome.isHidden = expanded
        chrome.alphaValue = expanded ? 0 : 1
        streamView.isHidden = !expanded
        streamView.alphaValue = expanded ? 1 : 0
        fallback.isHidden = !expanded || mirror.hasFrame
        fallback.alphaValue = fallback.isHidden ? 0 : 1
        needsLayout = true
        updateCornerRadius()
    }

    override func layout() {
        super.layout()
        updateCornerRadius()
        streamView.frame = bounds.insetBy(dx: 8, dy: 6)
        chrome.frame = bounds
        fallback.frame = bounds.insetBy(dx: 16, dy: 12)
        fallback.layoutSubtreeIfNeeded()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onExited?()
    }

    override func mouseDown(with event: NSEvent) {
        if !expanded {
            onEntered?()
        }
    }

    private func updateCornerRadius() {
        let radius: CGFloat = expanded ? min(16, bounds.height / 2) : bounds.height / 2
        layer?.cornerRadius = radius
    }
}

/// Glyph, “TB”, and a live dot. Draws nothing interactive; hits fall through.
final class CollapsedChromeView: NSView {
    var isLive = false

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let icon = NSRect(x: 16, y: (bounds.height - 12) / 2, width: 26, height: 12)
        let outline = NSBezierPath(roundedRect: icon, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.92).setStroke()
        outline.lineWidth = 1.25
        outline.stroke()

        NSColor.white.withAlphaComponent(0.92).setFill()
        let segmentY = icon.midY - 2
        for index in 0..<3 {
            let segment = NSRect(x: icon.minX + 4 + CGFloat(index) * 6.2, y: segmentY, width: 4.2, height: 4)
            NSBezierPath(roundedRect: segment, xRadius: 1, yRadius: 1).fill()
        }

        let title = "TB" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
            .kern: 0.4,
        ]
        let textSize = title.size(withAttributes: attributes)
        let textOrigin = NSPoint(x: icon.maxX + 8, y: floor((bounds.height - textSize.height) / 2))
        title.draw(at: textOrigin, withAttributes: attributes)

        let dotAlpha: CGFloat = isLive ? 0.92 : 0.28
        NSColor.white.withAlphaComponent(dotAlpha).setFill()
        let dot = NSRect(x: bounds.width - 18, y: (bounds.height - 5) / 2, width: 5, height: 5)
        NSBezierPath(ovalIn: dot).fill()
    }
}

final class FallbackView: NSView {
    var onRetry: (() -> Void)?

    private let titleField = NSTextField(labelWithString: "Touch Bar")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Try Again", target: nil, action: nil)

    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue }
    }

    var message: String {
        get { bodyField.stringValue }
        set { bodyField.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = NSColor.white.withAlphaComponent(0.94)
        bodyField.font = .systemFont(ofSize: 11)
        bodyField.textColor = NSColor.white.withAlphaComponent(0.68)
        bodyField.maximumNumberOfLines = 3
        bodyField.cell?.wraps = true
        bodyField.cell?.isScrollable = false
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(retry(_:))
        button.setButtonType(.momentaryPushIn)
        addSubview(titleField)
        addSubview(bodyField)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleField.frame = NSRect(x: 0, y: bounds.height - 18, width: width, height: 18)
        button.frame = NSRect(x: 0, y: 0, width: 96, height: 24)
        let bodyHeight = max(0, bounds.height - 48)
        bodyField.frame = NSRect(x: 0, y: 28, width: width, height: bodyHeight)
        bodyField.preferredMaxLayoutWidth = width
    }

    @objc private func retry(_ sender: NSButton) {
        onRetry?()
    }
}
