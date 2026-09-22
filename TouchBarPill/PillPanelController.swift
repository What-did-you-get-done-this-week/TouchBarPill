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
    private var discreetItem: DispatchWorkItem?
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
        panel.shapeContains = { [weak root] point in
            guard let root else { return false }
            return PillShape.path(in: root.bounds, expanded: root.showsExpandedShape).contains(point)
        }
        root.onEntered = { [weak self] in self?.pointerEntered() }
        root.onExited = { [weak self] in self?.pointerExited() }
        root.onDrag = { [weak self] x in self?.dragCollapsed(toX: x) }
        root.onDragEnd = { [weak self] in self?.finishDrag() }
        root.onRetry = { [weak self] in self?.retry() }
        root.onQuit = { NSApp.terminate(nil) }
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
        if !pinned && panel.frame.contains(NSEvent.mouseLocation) {
            pointerEntered()
        } else {
            refreshChromeOpacity(animated: false)
        }
    }

    func hide() {
        collapseItem?.cancel()
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

    private func pointerEntered() {
        hovering = true
        collapseItem?.cancel()
        discreetItem?.cancel()
        discreetItem = nil
        setOpacity(1, animated: true)
        guard !expanded, !dragging else { return }
        setExpanded(true)
    }

    private func pointerExited() {
        // Tracking areas fire while the window is resizing. Ignore an exit
        // that still lands inside the panel.
        if panel.frame.contains(NSEvent.mouseLocation) {
            hovering = true
            return
        }
        hovering = false
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
        refreshChromeOpacity(animated: true)
    }

    private func dragCollapsed(toX x: CGFloat) {
        dragging = true
        collapseItem?.cancel()
        discreetItem?.cancel()
        discreetItem = nil
        setOpacity(1, animated: false)
        guard let screen = DisplayList.resolved() else { return }
        var frame = collapsedFrame(on: screen)
        frame.origin.x = DisplayList.clamp(x, width: frame.width, on: screen)
        panel.setFrame(frame, display: true)
    }

    private func finishDrag() {
        // Clear before posting so the placement observer can refresh opacity.
        // The frame is already where the drag left it.
        dragging = false
        guard let screen = DisplayList.resolved() else { return }
        DisplayList.storeFreeX(panel.frame.origin.x, width: panel.frame.width, on: screen)
        PillPlacement.postChange()
        if panel.frame.contains(NSEvent.mouseLocation) {
            pointerEntered()
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
        let size = PillMetrics.collapsedSize
        // Flush with the physical top of the chosen display. Horizontal
        // position is the saved anchor. The notch path's straight edge is
        // the window's top edge, so there is no menu-bar gap here.
        let x = DisplayList.collapsedOriginX(width: size.width, on: screen)
        return NSRect(
            x: x,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The expanded strip stays top-centered on the chosen display. It does
    /// not slide under the notch: a wide Touch Bar parked in a corner would
    /// clamp into the bezel, and the controls would jump every time the tab
    /// moves. Collapsing returns the tab to its saved X.
    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let gap = topGap(on: screen)
        if !mirror.hasFrame {
            let size = NSSize(
                width: min(PillMetrics.fallbackCardSize.width, screen.frame.width - 48),
                height: PillMetrics.fallbackCardSize.height
            )
            return NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height - gap,
                width: size.width,
                height: size.height
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
        let width = streamWidth + padX * 2
        let height = streamHeight + padY * 2
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
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onRetry: (() -> Void)?
    var onQuit: (() -> Void)?

    let streamView = TouchBarStreamView(frame: .zero)
    private let chrome = CollapsedChromeView(frame: .zero)
    private let fallback = FallbackView(frame: .zero)
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
        fallback.onRetry = { [weak self] in self?.onRetry?() }
        let present: (NSEvent) -> Void = { [weak self] event in
            self?.presentQuitMenu(with: event)
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
    }

    override func layout() {
        super.layout()
        updateChrome()
        streamView.frame = bounds.insetBy(dx: PillMetrics.streamPadX, dy: PillMetrics.streamPadY)
        chrome.frame = bounds
        fallback.frame = bounds.insetBy(dx: PillMetrics.fallbackInset.width, dy: PillMetrics.fallbackInset.height)
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard PillShape.path(in: bounds, expanded: showsExpandedShape).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = PillShape.path(in: bounds, expanded: showsExpandedShape)
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
            presentQuitMenu(with: event)
            return
        }
        guard !showsExpandedShape else { return }
        trackClickOrDrag()
    }

    /// A small click expands. A horizontal drag parks the collapsed notch
    /// and does not expand until the pointer is released on top of it.
    private func trackClickOrDrag() {
        guard let window else {
            onEntered?()
            return
        }
        let startMouseX = NSEvent.mouseLocation.x
        let startFrameX = window.frame.origin.x
        var moved = false
        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseUp { break }
            let dx = NSEvent.mouseLocation.x - startMouseX
            if abs(dx) > 3 {
                moved = true
                onDrag?(startFrameX + dx)
            }
        }
        if moved {
            onDragEnd?()
        } else {
            onEntered?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        presentQuitMenu(with: event)
    }

    private func presentQuitMenu(with event: NSEvent) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: L("Quit TouchBarPill"), action: #selector(performQuit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func performQuit(_ sender: Any?) {
        onQuit?()
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

/// Collapsed: a tab hanging from the screen edge. The top side is straight and
/// flush with the window top. Each top corner is a concave quarter that sweeps
/// inward into the vertical side. The bottom corners are ordinary convex rounds.
enum PillShape {
    static func path(in rect: NSRect, expanded: Bool) -> NSBezierPath {
        if expanded {
            let radius = min(PillMetrics.expandedCornerRadius, rect.height / 2, rect.width / 2)
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        return notchTab(in: rect)
    }

    static func notchTab(in rect: NSRect) -> NSBezierPath {
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
}

/// Centered “Touch Bar” label only. Draws nothing interactive; hits fall through.
final class CollapsedChromeView: NSView {
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
        let origin = NSPoint(
            x: floor((bounds.width - textSize.width) / 2),
            y: floor((bounds.height - textSize.height) / 2) - 1
        )
        title.draw(at: origin, withAttributes: attributes)
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
