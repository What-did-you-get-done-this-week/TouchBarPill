import AppKit
import QuartzCore

enum PillMetrics {
    /// Collapsed notch tab. Width stays 132. Height is 80% of the previous
    /// 40-pt notch so the tab sits shorter on the screen edge. Ear and bottom
    /// radii scale with that height so the silhouette stays the same.
    static let collapsedSize = NSSize(width: 132, height: 32)
    static let notchEarRadius: CGFloat = 11
    static let notchBottomRadius: CGFloat = 10

    /// Expanded strip: 15% larger than the previous 0.75 scale (0.75 × 1.15).
    static let expandedScale: CGFloat = 0.75 * 1.15
    static let expandedChromeScale: CGFloat = 1.15
    static let streamHeight: CGFloat = 36 * expandedScale
    static let streamPadX: CGFloat = 8 * expandedScale
    static let streamPadY: CGFloat = 6 * expandedScale
    static let expandedCornerRadius: CGFloat = 16 * expandedScale
    static let fallbackCardSize = NSSize(width: 520 * expandedScale, height: 136 * expandedScale)
    static let fallbackInset = NSSize(width: 16 * expandedScale, height: 12 * expandedScale)
    static let minExpandedWidth: CGFloat = 320 * expandedScale
    static let fallbackTitleFont: CGFloat = 13 * expandedChromeScale
    static let fallbackBodyFont: CGFloat = 11 * expandedChromeScale
    static let fallbackTitleHeight: CGFloat = 18 * expandedChromeScale
    static let fallbackButtonWidth: CGFloat = 96 * expandedChromeScale
    static let fallbackButtonHeight: CGFloat = 24 * expandedChromeScale
    static let fallbackBodyBottom: CGFloat = 28 * expandedChromeScale
    static let fallbackBodyTrim: CGFloat = 48 * expandedChromeScale
    static let pinButtonSize: CGFloat = 22
    static let sideExpandedInset: CGFloat = 10

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
    /// Window coordinates. Transparent ear pockets should not eat clicks.
    var shapeContains: ((NSPoint) -> Bool)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseEntered, .mouseExited:
            super.sendEvent(event)
            return
        default:
            break
        }
        if let content = contentView, let shapeContains {
            let local = content.convert(event.locationInWindow, from: nil)
            if !shapeContains(local) {
                return
            }
        }
        super.sendEvent(event)
    }
}

final class PillPanelController: NSObject {
    let mirror: DFRMirror

    private let panel: PillPanel
    private let root: PillRootView
    private var expanded = false
    private var animating = false
    private var hovering = false
    private var dragging = false
    private var collapseItem: DispatchWorkItem?
    private var expandItem: DispatchWorkItem?
    private var discreetItem: DispatchWorkItem?
    private var chromeGeneration = 0

    var isVisible: Bool { panel.isVisible }

    init(mirror: DFRMirror) {
        self.mirror = mirror
        panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: DisplayList.collapsedSize()),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        root = PillRootView(frame: NSRect(origin: .zero, size: DisplayList.collapsedSize()))
        super.init()
        configurePanel()
        panel.shapeContains = { [weak root] point in
            guard let root else { return false }
            return PillShape.path(
                in: root.bounds,
                expanded: root.showsExpandedShape,
                edge: PillPlacement.edge
            ).contains(point)
        }
        root.onEntered = { [weak self] in self?.pointerEntered() }
        root.onExited = { [weak self] in self?.pointerExited() }
        root.onPress = { [weak self] in self?.pressBegan() }
        root.onClick = { [weak self] in self?.clickCollapsed() }
        root.onDrag = { [weak self] origin in self?.dragCollapsed(to: origin) }
        root.onDragEnd = { [weak self] in self?.finishDrag() }
        root.onRetry = { [weak self] in self?.retry() }
        root.onQuit = { NSApp.terminate(nil) }
        root.onUnpin = { [weak self] in self?.unpin() }
        root.pinVisibility = { [weak self] in
            guard let self else { return false }
            return self.expanded && self.hovering && PillPlacement.pinExpanded
        }
        root.streamView.onMouse = { [weak self] event in
            guard let self, self.expanded else { return }
            self.mirror.postMouseEvent(event, in: self.root.streamView)
        }
        mirror.attachStream(to: root.streamView)
        if let screen = DisplayList.resolved() {
            panel.setFrame(collapsedFrame(on: screen), display: false)
        }
        root.apply(mirror: mirror, expanded: false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(placementChanged),
            name: PillPlacement.didChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        guard let screen = DisplayList.resolved() else { return }
        collapseItem?.cancel()
        let pinned = PillPlacement.pinExpanded
        expanded = pinned
        hovering = false
        panel.alphaValue = 1
        panel.setFrame(pinned ? expandedFrame(on: screen) : collapsedFrame(on: screen), display: false)
        root.apply(mirror: mirror, expanded: pinned)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        root.updateTrackingAreas()
        root.refreshPinChrome()
        if !pinned && panel.frame.contains(NSEvent.mouseLocation) {
            pointerEntered()
        } else {
            refreshChromeOpacity(animated: false)
        }
    }

    func hide() {
        collapseItem?.cancel()
        expandItem?.cancel()
        expandItem = nil
        discreetItem?.cancel()
        discreetItem = nil
        expanded = false
        hovering = false
        root.apply(mirror: mirror, expanded: false)
        panel.alphaValue = 1
        panel.orderOut(nil)
    }

    func mirrorStateChanged() {
        root.apply(mirror: mirror, expanded: expanded)
        guard expanded, let screen = DisplayList.resolved() else { return }
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
        panel.setAccessibilityLabel(L("Touch Bar"))
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
    }

    private func unpin() {
        guard PillPlacement.pinExpanded else { return }
        PillPlacement.pinExpanded = false
        PillPlacement.postChange()
    }

    private func pointerEntered() {
        hovering = true
        collapseItem?.cancel()
        discreetItem?.cancel()
        discreetItem = nil
        setOpacity(1, animated: true)
        root.refreshPinChrome()
        guard !expanded, !dragging else { return }
        // A short delay lets a press-and-drag park the tab. A plain hover
        // still opens it. The drag loop runs in event-tracking mode, so this
        // timer does not fire until the press ends unless it was cancelled.
        scheduleExpand()
    }

    /// Hover-expand delay. Long enough to begin a drag, short enough that
    /// resting the pointer still feels immediate.
    private func scheduleExpand() {
        expandItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.expanded, !self.dragging, self.hovering else { return }
            self.setExpanded(true)
        }
        expandItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func pressBegan() {
        expandItem?.cancel()
        expandItem = nil
    }

    private func clickCollapsed() {
        hovering = true
        expandItem?.cancel()
        expandItem = nil
        discreetItem?.cancel()
        discreetItem = nil
        setOpacity(1, animated: false)
        guard !expanded else { return }
        setExpanded(true)
    }

    private func pointerExited() {
        expandItem?.cancel()
        expandItem = nil
        // Tracking areas fire while the window is resizing. Ignore an exit
        // that still lands inside the panel.
        if panel.frame.contains(NSEvent.mouseLocation) {
            hovering = true
            root.refreshPinChrome()
            return
        }
        hovering = false
        root.refreshPinChrome()
        guard expanded else {
            refreshChromeOpacity(animated: true)
            return
        }
        // Pinned stays open. The pointer can leave.
        guard !PillPlacement.pinExpanded else { return }
        scheduleCollapse()
    }

    private func scheduleCollapse() {
        collapseItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if PillPlacement.pinExpanded { return }
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
        guard let screen = DisplayList.resolved() else { return }
        let target = expand ? expandedFrame(on: screen) : collapsedFrame(on: screen)
        root.apply(mirror: mirror, expanded: expand)
        root.refreshPinChrome()
        if expand || hovering || dragging {
            discreetItem?.cancel()
            discreetItem = nil
            setOpacity(1, animated: false)
        }
        if was == expand && panel.frame == target {
            refreshChromeOpacity(animated: true)
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
                self.hovering = false
                self.root.apply(mirror: self.mirror, expanded: false)
            }
            self.root.refreshPinChrome()
            self.refreshChromeOpacity(animated: true)
        }
    }

    private func retry() {
        mirror.stop()
        mirror.start()
    }

    @objc private func screensChanged() {
        applyPlacementChange()
    }

    @objc private func placementChanged() {
        applyPlacementChange()
    }

    /// Move onto the chosen display, honor pin, and refresh idle opacity.
    /// Dragging owns the frame until mouse-up, so this waits.
    private func applyPlacementChange() {
        guard !dragging, panel.isVisible else { return }
        guard let screen = DisplayList.resolved() else { return }

        if PillPlacement.pinExpanded {
            collapseItem?.cancel()
            if !expanded {
                setExpanded(true)
                return
            }
        }

        let target = expanded ? expandedFrame(on: screen) : collapsedFrame(on: screen)
        if panel.frame != target {
            animate(to: target, expanding: expanded)
        }

        if !PillPlacement.pinExpanded && expanded && !hovering && !panel.frame.contains(NSEvent.mouseLocation) {
            scheduleCollapse()
        }
        root.refreshPinChrome()
        refreshChromeOpacity(animated: true)
    }

    private func dragCollapsed(to origin: NSPoint) {
        dragging = true
        collapseItem?.cancel()
        discreetItem?.cancel()
        discreetItem = nil
        setOpacity(1, animated: false)
        guard let screen = DisplayList.resolved() else { return }
        var frame = collapsedFrame(on: screen)
        switch PillPlacement.edge {
        case .topCenter, .bottomCenter:
            frame.origin.x = DisplayList.clampX(origin.x, width: frame.width, on: screen)
        case .leftMid, .rightMid:
            frame.origin.y = DisplayList.clampY(origin.y, height: frame.height, on: screen)
        }
        panel.setFrame(frame, display: true)
    }

    private func finishDrag() {
        // Clear before posting so the placement observer can refresh opacity.
        // The frame is already where the drag left it.
        dragging = false
        guard let screen = DisplayList.resolved() else { return }
        DisplayList.storeFreeOrigin(panel.frame.origin, size: panel.frame.size, on: screen)
        PillPlacement.postChange()
        if panel.frame.contains(NSEvent.mouseLocation) {
            clickCollapsed()
        } else {
            hovering = false
            refreshChromeOpacity(animated: true)
        }
    }

    private func refreshChromeOpacity(animated: Bool) {
        let wantsFull = expanded || hovering || dragging || !PillPlacement.discreetMode
        if wantsFull {
            discreetItem?.cancel()
            discreetItem = nil
            setOpacity(1, animated: animated && !dragging)
            return
        }
        // Already faded: a new opacity level applies immediately.
        if panel.alphaValue < 0.98 {
            discreetItem?.cancel()
            discreetItem = nil
            setOpacity(PillPlacement.discreetOpacity, animated: animated)
            return
        }
        guard discreetItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.discreetItem = nil
            guard !self.expanded, !self.hovering, !self.dragging, PillPlacement.discreetMode else { return }
            self.setOpacity(PillPlacement.discreetOpacity, animated: true)
        }
        discreetItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PillPlacement.idleDelay, execute: work)
    }

    private func setOpacity(_ alpha: CGFloat, animated: Bool) {
        if abs(panel.alphaValue - alpha) < 0.01 { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduceMotion {
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = alpha
        }
    }

    private func topGap(on screen: NSScreen) -> CGFloat {
        guard hasNotch(screen) else { return 0 }
        return (screen.frame.maxY - screen.visibleFrame.maxY) + 6
    }

    private func hasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            let auxiliaryWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            return auxiliaryWidth > 0 || screen.safeAreaInsets.top > 0
        }
        return false
    }

    private func collapsedFrame(on screen: NSScreen) -> NSRect {
        let size = DisplayList.collapsedSize()
        let origin = DisplayList.collapsedOrigin(size: size, on: screen)
        return NSRect(origin: origin, size: size)
    }

    /// Expanded strip follows the chosen edge. Top and bottom stay centered on
    /// that edge. Left and right use a horizontal strip near that side so the
    /// Touch Bar aspect ratio stays readable, clamped below the menu bar.
    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let size = expandedSize(on: screen)
        let frame = screen.frame
        let visible = screen.visibleFrame
        let gap = topGap(on: screen)

        switch PillPlacement.edge {
        case .topCenter:
            return NSRect(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - gap,
                width: size.width,
                height: size.height
            )
        case .bottomCenter:
            let y = max(frame.minY, min(visible.minY, frame.maxY - size.height))
            return NSRect(
                x: frame.midX - size.width / 2,
                y: y,
                width: size.width,
                height: size.height
            )
        case .leftMid:
            let x = frame.minX + PillMetrics.sideExpandedInset
            let idealY = frame.midY - size.height / 2
            let minY = max(frame.minY, visible.minY)
            let maxY = min(frame.maxY, visible.maxY) - size.height
            let y = maxY >= minY ? min(max(idealY, minY), maxY) : minY
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        case .rightMid:
            let x = frame.maxX - size.width - PillMetrics.sideExpandedInset
            let idealY = frame.midY - size.height / 2
            let minY = max(frame.minY, visible.minY)
            let maxY = min(frame.maxY, visible.maxY) - size.height
            let y = maxY >= minY ? min(max(idealY, minY), maxY) : minY
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    private func expandedSize(on screen: NSScreen) -> NSSize {
        if !mirror.hasFrame {
            return NSSize(
                width: min(PillMetrics.fallbackCardSize.width, screen.frame.width - 48),
                height: PillMetrics.fallbackCardSize.height
            )
        }

        let aspect = displayAspect()
        let maxWidth = max(PillMetrics.minExpandedWidth, screen.frame.width - 36)
        let padX = PillMetrics.streamPadX
        let padY = PillMetrics.streamPadY
        var streamHeight = PillMetrics.streamHeight
        var streamWidth = streamHeight * aspect
        if streamWidth + padX * 2 > maxWidth {
            streamWidth = maxWidth - padX * 2
            streamHeight = streamWidth / aspect
        }
        return NSSize(width: streamWidth + padX * 2, height: streamHeight + padY * 2)
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
    var onPress: (() -> Void)?
    var onClick: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onRetry: (() -> Void)?
    var onQuit: (() -> Void)?
    var onUnpin: (() -> Void)?
    var pinVisibility: (() -> Bool)?

    let streamView = TouchBarStreamView(frame: .zero)
    private let chrome = CollapsedChromeView(frame: .zero)
    private let fallback = FallbackView(frame: .zero)
    private let pinButton = PinButton(frame: .zero)
    private var tracking: NSTrackingArea?
    private(set) var showsExpandedShape = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(streamView)
        addSubview(chrome)
        addSubview(fallback)
        addSubview(pinButton)
        pinButton.isHidden = true
        pinButton.target = self
        pinButton.action = #selector(pinClicked(_:))
        fallback.onRetry = { [weak self] in self?.onRetry?() }
        let present: (NSEvent) -> Void = { [weak self] event in
            self?.presentContextMenu(with: event)
        }
        streamView.onContextMenu = present
        fallback.onContextMenu = present
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(mirror: DFRMirror, expanded: Bool) {
        showsExpandedShape = expanded
        chrome.edge = PillPlacement.edge
        chrome.needsDisplay = true
        fallback.title = mirror.simulatorReady ? L("Touch Bar") : L("Touch Bar unavailable")
        fallback.message = mirror.statusMessage
        chrome.isHidden = expanded
        chrome.alphaValue = expanded ? 0 : 1
        streamView.isHidden = !expanded
        streamView.alphaValue = expanded ? 1 : 0
        fallback.isHidden = !expanded || mirror.hasFrame
        fallback.alphaValue = fallback.isHidden ? 0 : 1
        needsLayout = true
        updateChrome()
        refreshPinChrome()
    }

    func refreshPinChrome() {
        let show = pinVisibility?() == true
        pinButton.isHidden = !show
        pinButton.alphaValue = show ? 1 : 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateChrome()
        streamView.frame = bounds.insetBy(dx: PillMetrics.streamPadX, dy: PillMetrics.streamPadY)
        chrome.frame = bounds
        fallback.frame = bounds.insetBy(dx: PillMetrics.fallbackInset.width, dy: PillMetrics.fallbackInset.height)
        fallback.layoutSubtreeIfNeeded()
        let pin = PillMetrics.pinButtonSize
        pinButton.frame = NSRect(
            x: bounds.maxX - pin - 8,
            y: bounds.maxY - pin - 6,
            width: pin,
            height: pin
        )
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard PillShape.path(in: bounds, expanded: showsExpandedShape, edge: PillPlacement.edge).contains(local) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = PillShape.path(in: bounds, expanded: showsExpandedShape, edge: PillPlacement.edge)
        NSColor(calibratedWhite: 0.04, alpha: 0.97).setFill()
        path.fill()
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onExited?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            presentContextMenu(with: event)
            return
        }
        guard !showsExpandedShape else { return }
        trackClickOrDrag()
    }

    /// A small click expands. A drag along the attached edge parks the notch
    /// and does not expand until the pointer is released on top of it.
    private func trackClickOrDrag() {
        guard let window else {
            onEntered?()
            return
        }
        onPress?()
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        let edge = PillPlacement.edge
        var moved = false
        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseUp { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            let delta: CGFloat
            switch edge {
            case .topCenter, .bottomCenter:
                delta = dx
            case .leftMid, .rightMid:
                delta = dy
            }
            if abs(delta) > 3 {
                moved = true
                switch edge {
                case .topCenter, .bottomCenter:
                    onDrag?(NSPoint(x: startOrigin.x + dx, y: startOrigin.y))
                case .leftMid, .rightMid:
                    onDrag?(NSPoint(x: startOrigin.x, y: startOrigin.y + dy))
                }
            }
        }
        if moved {
            onDragEnd?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        presentContextMenu(with: event)
    }

    private func presentContextMenu(with event: NSEvent) {
        let menu = NSMenu()
        if showsExpandedShape && PillPlacement.pinExpanded {
            let unpin = NSMenuItem(title: L("Unpin"), action: #selector(performUnpin(_:)), keyEquivalent: "")
            unpin.target = self
            menu.addItem(unpin)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: L("Quit TouchBarPill"), action: #selector(performQuit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func performQuit(_ sender: Any?) {
        onQuit?()
    }

    @objc private func performUnpin(_ sender: Any?) {
        onUnpin?()
    }

    @objc private func pinClicked(_ sender: Any?) {
        onUnpin?()
    }

    private func updateChrome() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        if showsExpandedShape {
            layer.masksToBounds = true
            layer.cornerCurve = .continuous
            layer.cornerRadius = min(PillMetrics.expandedCornerRadius, bounds.height / 2)
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        } else {
            layer.masksToBounds = false
            layer.cornerRadius = 0
            layer.borderWidth = 0
        }
        needsDisplay = true
    }
}

/// Collapsed: a tab hanging from the chosen screen edge. The attachment side
/// is straight and flush. Concave ears meet that edge; the free side is rounded.
enum PillShape {
    static func path(in rect: NSRect, expanded: Bool, edge: PillEdge) -> NSBezierPath {
        if expanded {
            let radius = min(PillMetrics.expandedCornerRadius, rect.height / 2, rect.width / 2)
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        return notchTab(in: rect, edge: edge)
    }

    static func notchTab(in rect: NSRect, edge: PillEdge) -> NSBezierPath {
        switch edge {
        case .topCenter:
            return topNotch(in: rect)
        case .bottomCenter:
            return bottomNotch(in: rect)
        case .leftMid:
            return leftNotch(in: rect)
        case .rightMid:
            return rightNotch(in: rect)
        }
    }

    /// Ears at the top edge; rounded free edge at the bottom.
    private static func topNotch(in rect: NSRect) -> NSBezierPath {
        let ear = min(PillMetrics.notchEarRadius, max(4, rect.height * 0.45), max(4, rect.width / 4))
        let bottom = min(PillMetrics.notchBottomRadius, max(4, rect.height - ear - 2), max(4, rect.width / 2 - ear - 1))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX, y: rect.maxY - ear),
            radius: ear,
            startAngle: 90,
            endAngle: 180,
            clockwise: false
        )
        path.line(to: NSPoint(x: rect.maxX - ear, y: rect.minY + bottom))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - ear - bottom, y: rect.minY + bottom),
            radius: bottom,
            startAngle: 0,
            endAngle: -90,
            clockwise: true
        )
        path.line(to: NSPoint(x: rect.minX + ear + bottom, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + ear + bottom, y: rect.minY + bottom),
            radius: bottom,
            startAngle: -90,
            endAngle: -180,
            clockwise: true
        )
        path.line(to: NSPoint(x: rect.minX + ear, y: rect.maxY - ear))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX, y: rect.maxY - ear),
            radius: ear,
            startAngle: 0,
            endAngle: 90,
            clockwise: false
        )
        path.close()
        return path
    }

    /// Flipped: ears meet the bottom edge.
    private static func bottomNotch(in rect: NSRect) -> NSBezierPath {
        let ear = min(PillMetrics.notchEarRadius, max(4, rect.height * 0.45), max(4, rect.width / 4))
        let tip = min(PillMetrics.notchBottomRadius, max(4, rect.height - ear - 2), max(4, rect.width / 2 - ear - 1))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX, y: rect.minY + ear),
            radius: ear,
            startAngle: -90,
            endAngle: -180,
            clockwise: true
        )
        path.line(to: NSPoint(x: rect.maxX - ear, y: rect.maxY - tip))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - ear - tip, y: rect.maxY - tip),
            radius: tip,
            startAngle: 0,
            endAngle: 90,
            clockwise: false
        )
        path.line(to: NSPoint(x: rect.minX + ear + tip, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + ear + tip, y: rect.maxY - tip),
            radius: tip,
            startAngle: 90,
            endAngle: 180,
            clockwise: false
        )
        path.line(to: NSPoint(x: rect.minX + ear, y: rect.minY + ear))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX, y: rect.minY + ear),
            radius: ear,
            startAngle: 0,
            endAngle: -90,
            clockwise: true
        )
        path.close()
        return path
    }

    /// Ears meet the left bezel; rounded free edge on the right.
    private static func leftNotch(in rect: NSRect) -> NSBezierPath {
        let ear = min(PillMetrics.notchEarRadius, max(4, rect.width * 0.45), max(4, rect.height / 4))
        let tip = min(PillMetrics.notchBottomRadius, max(4, rect.width - ear - 2), max(4, rect.height / 2 - ear - 1))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + ear, y: rect.minY),
            radius: ear,
            startAngle: 180,
            endAngle: 270,
            clockwise: false
        )
        path.line(to: NSPoint(x: rect.maxX - tip, y: rect.minY + ear))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - tip, y: rect.minY + ear + tip),
            radius: tip,
            startAngle: -90,
            endAngle: 0,
            clockwise: false
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - ear - tip))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - tip, y: rect.maxY - ear - tip),
            radius: tip,
            startAngle: 0,
            endAngle: 90,
            clockwise: false
        )
        path.line(to: NSPoint(x: rect.minX + ear, y: rect.maxY - ear))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + ear, y: rect.maxY),
            radius: ear,
            startAngle: -90,
            endAngle: -180,
            clockwise: true
        )
        path.close()
        return path
    }

    /// Ears meet the right bezel; rounded free edge on the left.
    private static func rightNotch(in rect: NSRect) -> NSBezierPath {
        let ear = min(PillMetrics.notchEarRadius, max(4, rect.width * 0.45), max(4, rect.height / 4))
        let tip = min(PillMetrics.notchBottomRadius, max(4, rect.width - ear - 2), max(4, rect.height / 2 - ear - 1))
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - ear, y: rect.minY),
            radius: ear,
            startAngle: 0,
            endAngle: -90,
            clockwise: true
        )
        path.line(to: NSPoint(x: rect.minX + tip, y: rect.minY + ear))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + tip, y: rect.minY + ear + tip),
            radius: tip,
            startAngle: -90,
            endAngle: -180,
            clockwise: true
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - ear - tip))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + tip, y: rect.maxY - ear - tip),
            radius: tip,
            startAngle: 180,
            endAngle: 90,
            clockwise: true
        )
        path.line(to: NSPoint(x: rect.maxX - ear, y: rect.maxY - ear))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - ear, y: rect.maxY),
            radius: ear,
            startAngle: -90,
            endAngle: 0,
            clockwise: false
        )
        path.close()
        return path
    }
}

/// Centered “Touch Bar” label. Rotates 90° on left/right edges.
final class CollapsedChromeView: NSView {
    var edge: PillEdge = .topCenter

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { !isHidden }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityLabel() -> String? { isHidden ? nil : L("Touch Bar") }

    override func draw(_ dirtyRect: NSRect) {
        let title = L("Touch Bar") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        ]
        let textSize = title.size(withAttributes: attributes)

        if edge.isVerticalEdge {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            // Draw upright into a sideways slot: rotate so the baseline runs
            // along the bezel.
            if edge.attachesLeft {
                transform.translateX(by: bounds.midX - textSize.height / 2 - 1, yBy: bounds.midY + textSize.width / 2)
                transform.rotate(byDegrees: -90)
            } else {
                transform.translateX(by: bounds.midX + textSize.height / 2 + 1, yBy: bounds.midY - textSize.width / 2)
                transform.rotate(byDegrees: 90)
            }
            transform.concat()
            title.draw(at: .zero, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let origin = NSPoint(
                x: floor((bounds.width - textSize.width) / 2),
                y: floor((bounds.height - textSize.height) / 2) - 1
            )
            title.draw(at: origin, withAttributes: attributes)
        }
    }
}

/// Soft pushpin shown only while the expanded strip is pinned and hovered.
final class PinButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        image = Self.pinImage()
        image?.isTemplate = false
        toolTip = L("Unpin")
        setAccessibilityLabel(L("Unpin"))
        alphaValue = 0.42
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private static func pinImage() -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { _ in
            let color = NSColor.white.withAlphaComponent(0.42)
            color.setStroke()
            let head = NSBezierPath(ovalIn: NSRect(x: 4.5, y: 7.5, width: 5, height: 5))
            head.lineWidth = 1
            head.stroke()
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: 7, y: 7.5))
            shaft.line(to: NSPoint(x: 7, y: 1.5))
            shaft.lineWidth = 1.2
            shaft.lineCapStyle = .round
            shaft.stroke()
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: 3.5, y: 9.5))
            cross.line(to: NSPoint(x: 10.5, y: 9.5))
            cross.lineWidth = 1
            cross.lineCapStyle = .round
            cross.stroke()
            return true
        }
    }
}

final class FallbackView: NSView {
    var onRetry: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    private let titleField = NSTextField(labelWithString: L("Touch Bar"))
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: L("Try Again"), target: nil, action: nil)

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
        titleField.font = .systemFont(ofSize: PillMetrics.fallbackTitleFont, weight: .semibold)
        titleField.textColor = NSColor.white.withAlphaComponent(0.94)
        bodyField.font = .systemFont(ofSize: PillMetrics.fallbackBodyFont)
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
        let titleHeight = PillMetrics.fallbackTitleHeight
        titleField.frame = NSRect(x: 0, y: bounds.height - titleHeight, width: width, height: titleHeight)
        button.frame = NSRect(x: 0, y: 0, width: PillMetrics.fallbackButtonWidth, height: PillMetrics.fallbackButtonHeight)
        let bodyHeight = max(0, bounds.height - PillMetrics.fallbackBodyTrim)
        bodyField.frame = NSRect(x: 0, y: PillMetrics.fallbackBodyBottom, width: width, height: bodyHeight)
        bodyField.preferredMaxLayoutWidth = width
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onContextMenu?(event)
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    @objc private func retry(_ sender: NSButton) {
        onRetry?()
    }
}
