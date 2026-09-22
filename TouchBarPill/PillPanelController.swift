import AppKit
import QuartzCore

enum PillMetrics {
    /// Medium (default) collapsed notch. S scales via `PillPlacement.size`.
    static let collapsedSize = NSSize(width: 132, height: 32)
    static let notchEarRadius: CGFloat = 11
    static let notchBottomRadius: CGFloat = 10

    static var scaledEarRadius: CGFloat { notchEarRadius * PillPlacement.size.scale }
    static var scaledBottomRadius: CGFloat { notchBottomRadius * PillPlacement.size.scale }

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
    private var fullscreenHideItem: DispatchWorkItem?
    private var pendingFocusClick: DispatchWorkItem?
    private var volumeFlashItem: DispatchWorkItem?
    private var scrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var lastScrollStamp: TimeInterval = -1
    /// Hover-expand waits until this time so a volume scroll is not swallowed.
    private var volumeHoldUntil = Date.distantPast
    /// Big readout stays up until this time. Cinema must not hide it early.
    private var volumeHUDUntil = Date.distantPast
    private var chromeGeneration = 0
    /// Fullscreen: notch draws nothing, but the wide edge pad still receives hits.
    private var fullscreenConcealed = false

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
            return root.hitShapeContains(point)
        }
        root.onEntered = { [weak self] in self?.pointerEntered() }
        root.onExited = { [weak self] in self?.pointerExited() }
        root.onPress = { [weak self] in self?.pressBegan() }
        root.onClick = { [weak self] in self?.scheduleFocusClick() }
        root.onDoubleClick = { [weak self] in self?.doubleClickCollapsed() }
        root.onScroll = { [weak self] event in self?.scrollCollapsed(event) }
        root.onDrag = { [weak self] origin in self?.dragCollapsed(to: origin) }
        root.onDragEnd = { [weak self] in self?.finishDrag() }
        root.onRetry = { [weak self] in self?.retry() }
        root.onQuit = { NSApp.terminate(nil) }
        root.onUnpin = { [weak self] in self?.unpin() }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusChanged),
            name: FocusSession.didChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fullscreenChanged),
            name: FullscreenWatcher.didChange,
            object: nil
        )
        root.refreshFocusChrome()
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.handleGlobalScroll(event)
        }
        // Events that hit this panel never reach the global monitor.
        // Side tabs are thin; this catches the wheel even when the view misses it.
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            guard self.panel.isVisible, !self.expanded, self.scrollHit() else { return event }
            self.scrollCollapsed(event)
            return nil
        }
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
        }
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
        // Shadow off before the window is ordered in. Turning it off afterwards
        // leaves a light rim on side tabs (graphite reads as a floating pill).
        updatePanelShadow()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        root.updateTrackingAreas()
        if !pinned && panel.frame.contains(NSEvent.mouseLocation) {
            pointerEntered()
        } else if FullscreenWatcher.shared.isFullscreen {
            concealForFullscreen(immediate: true)
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
        volumeFlashItem?.cancel()
        volumeFlashItem = nil
        volumeHUDUntil = .distantPast
        VolumeChrome.extraDepth = 0
        VolumeChrome.extraSpan = 0
        expanded = false
        hovering = false
        root.setVolumeReadout(percent: nil, muted: false)
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
        panel.hasShadow = false
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
        fullscreenHideItem?.cancel()
        fullscreenHideItem = nil
        if fullscreenConcealed {
            setFullscreenConcealed(false, animated: false)
        }
        setOpacity(1, animated: true)
        root.refreshFocusChrome()
        guard !expanded, !dragging else { return }
        if Date() < volumeHoldUntil { return }
        // A short delay lets a press-and-drag park the tab. A plain hover
        // still opens it. The drag loop runs in event-tracking mode, so this
        // timer does not fire until the press ends unless it was cancelled.
        scheduleExpand()
    }

    /// Hover-expand delay. Long enough to begin a drag, short enough that
    /// resting the pointer still feels immediate. Default ~0.09s (snappier).
    private func scheduleExpand() {
        expandItem?.cancel()
        guard pendingFocusClick == nil else { return }
        guard Date() >= volumeHoldUntil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.expanded, !self.dragging, self.hovering else { return }
            guard self.pendingFocusClick == nil else { return }
            guard Date() >= self.volumeHoldUntil else { return }
            // A press owns the notch (focus click or drag). Do not open under it.
            if (NSEvent.pressedMouseButtons & 1) != 0 { return }
            self.setExpanded(true)
        }
        expandItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PillPlacement.revealDelay, execute: work)
    }

    private func pressBegan() {
        expandItem?.cancel()
        expandItem = nil
        pendingFocusClick?.cancel()
        pendingFocusClick = nil
    }

    /// Debounce single-click focus so a double-click can steal it for mute.
    private func scheduleFocusClick() {
        pendingFocusClick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFocusClick = nil
            self.clickCollapsed()
        }
        pendingFocusClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// Click on the collapsed notch toggles the focus timer. It does not expand.
    /// Hover (after a short delay) still expands the Touch Bar stream.
    /// A click that started collapsed still counts if hover opened the strip
    /// during the double-click wait — that race was dropping right-edge clicks.
    private func clickCollapsed() {
        guard !dragging else { return }
        expandItem?.cancel()
        expandItem = nil
        let keepExpanded = expanded
        if !keepExpanded {
            discreetItem?.cancel()
            discreetItem = nil
            fullscreenHideItem?.cancel()
            fullscreenHideItem = nil
            // Reveal if fullscreen-concealed so the timer label is readable.
            if fullscreenConcealed {
                setFullscreenConcealed(false, animated: false)
            }
            setOpacity(1, animated: false)
        }
        FocusSession.shared.toggleFromClick()
        root.refreshFocusChrome()
        panel.contentView?.needsDisplay = true
        if !keepExpanded {
            // Stay collapsed; hover continues to own expand.
            refreshChromeOpacity(animated: true)
        }
    }

    /// Double-click collapsed notch: toggle system mute (does not expand).
    private func doubleClickCollapsed() {
        guard !expanded else { return }
        pendingFocusClick?.cancel()
        pendingFocusClick = nil
        expandItem?.cancel()
        expandItem = nil
        if fullscreenConcealed {
            setFullscreenConcealed(false, animated: false)
        }
        setOpacity(1, animated: false)
        let muted = SystemVolume.toggleMute()
        let percent = Int(((SystemVolume.volume() ?? 0) * 100).rounded())
        flashVolume(percent: percent, muted: muted)
    }

    /// Scroll over the collapsed notch, or the revealed fullscreen hit pad.
    /// A global monitor delivers the same wheel when this panel is not key.
    /// The stamp skips the duplicate. Expand waits so the gesture is not eaten.
    private func handleGlobalScroll(_ event: NSEvent) {
        let apply = { [weak self] in
            guard let self, self.panel.isVisible, !self.expanded else { return }
            guard self.scrollHit() else { return }
            self.scrollCollapsed(event)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Notch plus a little inward slop. Side edges need this: the visual tab is
    /// only ~32pt deep, and a wheel event often lands just inside that.
    private func scrollFrame() -> NSRect {
        var frame = panel.frame
        let slop: CGFloat = PillPlacement.edge.isVerticalEdge ? 22 : 10
        switch PillPlacement.edge {
        case .leftMid:
            frame.size.width += slop
        case .rightMid:
            frame.origin.x -= slop
            frame.size.width += slop
        case .topCenter:
            frame.origin.y -= slop
            frame.size.height += slop
        case .bottomCenter:
            frame.size.height += slop
        }
        return frame
    }

    private func scrollHit() -> Bool {
        guard panel.isVisible, !expanded else { return false }
        return scrollFrame().contains(NSEvent.mouseLocation)
    }

    private func scrollCollapsed(_ event: NSEvent) {
        guard !expanded else { return }
        if event.timestamp == lastScrollStamp { return }
        lastScrollStamp = event.timestamp
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice {
            dx = -dx
            dy = -dy
        }
        // Vertical wheel, horizontal scrub, and Option+scroll all count.
        // The larger axis wins so a side tab still hears a sideways two-finger scrub.
        let dominant = abs(dy) >= abs(dx) ? dy : dx
        let minDelta: CGFloat = event.hasPreciseScrollingDeltas ? 0.35 : 0.01
        guard abs(dominant) >= minDelta else { return }
        // Positive = volume up. One wheel click is two system steps.
        let steps: Float
        if event.hasPreciseScrollingDeltas {
            steps = Float(dominant) / 8.0
        } else {
            steps = dominant > 0 ? 2 : -2
        }
        guard abs(steps) > 0.04 else { return }
        noteVolumeGesture()
        guard let volume = SystemVolume.adjust(by: steps * SystemVolume.step) else { return }
        let percent = Int((volume * 100).rounded())
        flashVolume(percent: percent, muted: SystemVolume.isMuted())
    }

    /// Keep the strip collapsed while the wheel is moving volume.
    private func noteVolumeGesture() {
        volumeHoldUntil = Date().addingTimeInterval(0.9)
        expandItem?.cancel()
        expandItem = nil
        pendingFocusClick?.cancel()
        pendingFocusClick = nil
    }

    /// Large % (or 🔇) for ~0.8s. Grows the notch so the figure is readable on a 32pt tab.
    private func flashVolume(percent: Int, muted: Bool) {
        volumeFlashItem?.cancel()
        // Mark the HUD first so un-conceal does not immediately hide it again.
        volumeHUDUntil = Date().addingTimeInterval(0.85)
        discreetItem?.cancel()
        discreetItem = nil
        fullscreenHideItem?.cancel()
        fullscreenHideItem = nil
        if fullscreenConcealed {
            setFullscreenConcealed(false, animated: false)
        }
        setOpacity(1, animated: false)
        setVolumeHUD(active: true)
        root.setVolumeReadout(percent: percent, muted: muted)
        let work = DispatchWorkItem { [weak self] in
            self?.endVolumeHUD()
        }
        volumeFlashItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    private func endVolumeHUD() {
        volumeFlashItem = nil
        volumeHUDUntil = .distantPast
        setVolumeHUD(active: false)
        root.setVolumeReadout(percent: nil, muted: false)
        guard !expanded, !dragging else { return }
        if FullscreenWatcher.shared.isFullscreen && !pointerInsidePanel() {
            concealForFullscreen(immediate: false)
            return
        }
        refreshChromeOpacity(animated: true)
        if hovering {
            scheduleExpand()
        }
    }

    private func setVolumeHUD(active: Bool) {
        let depth: CGFloat = active ? 36 : 0
        let span: CGFloat = active ? 72 : 0
        guard VolumeChrome.extraDepth != depth || VolumeChrome.extraSpan != span else { return }
        VolumeChrome.extraDepth = depth
        VolumeChrome.extraSpan = span
        guard !expanded, !dragging, panel.isVisible, let screen = DisplayList.resolved() else { return }
        panel.setFrame(collapsedFrame(on: screen), display: true)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        root.updateTrackingAreas()
        updatePanelShadow()
    }

    private var volumeHUDActive: Bool {
        VolumeChrome.isActive || Date() < volumeHUDUntil
    }

    private func pointerExited() {
        expandItem?.cancel()
        expandItem = nil
        // Tracking areas fire while the window is resizing. Ignore an exit
        // that still lands inside the panel.
        if panel.frame.contains(NSEvent.mouseLocation) {
            hovering = true
            return
        }
        hovering = false
        guard expanded else {
            refreshChromeOpacity(animated: true)
            scheduleFullscreenConcealIfNeeded()
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
            self.root.refreshFocusChrome()
            self.refreshChromeOpacity(animated: true)
            if !expanding {
                self.scheduleFullscreenConcealIfNeeded()
            }
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

    @objc private func focusChanged() {
        root.refreshFocusChrome()
        if !expanded {
            panel.displayIfNeeded()
        }
    }

    @objc private func fullscreenChanged() {
        guard !dragging else { return }
        if FullscreenWatcher.shared.isFullscreen {
            if expanded && !PillPlacement.pinExpanded && !pointerInsidePanel() {
                collapseItem?.cancel()
                expanded = false
                hovering = false
                if let screen = DisplayList.resolved() {
                    panel.setFrame(collapsedFrame(on: screen), display: true)
                }
                root.apply(mirror: mirror, expanded: false)
            } else if !expanded {
                syncCollapsedHitFrame()
            }
            // Cinema: hide immediately unless the pointer is already on the pad
            // or the strip is pinned open.
            concealForFullscreen(immediate: true)
        } else {
            fullscreenHideItem?.cancel()
            fullscreenHideItem = nil
            if !expanded {
                syncCollapsedHitFrame()
            }
            if fullscreenConcealed {
                setFullscreenConcealed(false, animated: false)
            }
            refreshChromeOpacity(animated: true)
        }
    }

    /// Grow or shrink the collapsed panel so the Wide pad exists only in cinema.
    private func syncCollapsedHitFrame() {
        guard !expanded, !dragging, panel.isVisible, let screen = DisplayList.resolved() else { return }
        let frame = collapsedFrame(on: screen)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        root.updateTrackingAreas()
    }

    private func pointerInsidePanel() -> Bool {
        panel.frame.contains(NSEvent.mouseLocation)
    }

    /// Hide the collapsed notch while fullscreen. Immediate on enter; a short
    /// delay on leave so the edge does not flicker. Pinned-expanded stays.
    private func concealForFullscreen(immediate: Bool) {
        fullscreenHideItem?.cancel()
        fullscreenHideItem = nil
        guard FullscreenWatcher.shared.isFullscreen, panel.isVisible else { return }
        if volumeHUDActive {
            return
        }
        if PillPlacement.pinExpanded && expanded { return }
        if expanded || dragging { return }
        if pointerInsidePanel() {
            hovering = true
            setFullscreenConcealed(false, animated: false)
            setOpacity(1, animated: false)
            return
        }
        hovering = false
        if immediate || PillPlacement.fullscreenHideDelay <= 0.05 {
            setFullscreenConcealed(true, animated: false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullscreenHideItem = nil
            guard FullscreenWatcher.shared.isFullscreen else { return }
            guard !self.expanded, !self.dragging else { return }
            if self.pointerInsidePanel() {
                self.hovering = true
                self.setFullscreenConcealed(false, animated: false)
                return
            }
            self.hovering = false
            self.setFullscreenConcealed(true, animated: false)
        }
        fullscreenHideItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PillPlacement.fullscreenHideDelay, execute: work)
    }

    private func scheduleFullscreenConcealIfNeeded() {
        concealForFullscreen(immediate: false)
    }

    private func setFullscreenConcealed(_ conceal: Bool, animated: Bool) {
        fullscreenConcealed = conceal
        root.chromeSuppressed = conceal && !expanded
        panel.hasShadow = !conceal
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        if conceal {
            discreetItem?.cancel()
            discreetItem = nil
            root.needsDisplay = true
            panel.invalidateShadow()
        } else {
            setOpacity(1, animated: animated)
            refreshChromeOpacity(animated: animated)
            panel.invalidateShadow()
        }
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

        root.apply(mirror: mirror, expanded: expanded)
        refreshChromeOpacity(animated: true)
        if !PillPlacement.pinExpanded && expanded && !hovering && !panel.frame.contains(NSEvent.mouseLocation) {
            scheduleCollapse()
        } else if !expanded {
            scheduleFullscreenConcealIfNeeded()
        }
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
            // Drag end is not a focus click. Resume hover-expand.
            hovering = true
            setOpacity(1, animated: false)
            scheduleExpand()
        } else {
            hovering = false
            refreshChromeOpacity(animated: true)
            scheduleFullscreenConcealIfNeeded()
        }
    }

    private func refreshChromeOpacity(animated: Bool) {
        updatePanelShadow()
        if volumeHUDActive {
            if fullscreenConcealed { setFullscreenConcealed(false, animated: false) }
            setOpacity(1, animated: false)
            return
        }
        if fullscreenConcealed {
            root.chromeSuppressed = !expanded
            panel.hasShadow = expanded
            if panel.alphaValue < 0.99 { setOpacity(1, animated: false) }
            return
        }
        if FullscreenWatcher.shared.isFullscreen && !expanded && !hovering && !dragging {
            scheduleFullscreenConcealIfNeeded()
            return
        }
        root.chromeSuppressed = false
        let wantsFull = expanded || hovering || dragging
        if wantsFull {
            discreetItem?.cancel()
            discreetItem = nil
            setOpacity(1, animated: animated && !dragging)
            return
        }
        // Already faded: a new opacity level applies immediately.
        if panel.alphaValue < 0.98 && panel.alphaValue > 0.08 {
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
            guard !self.fullscreenConcealed, !FullscreenWatcher.shared.isFullscreen else { return }
            self.setOpacity(PillPlacement.discreetOpacity, animated: true)
        }
        discreetItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PillPlacement.idleDelay, execute: work)
    }

    /// Side tabs sit on the wallpaper. The window shadow becomes a light hairline
    /// along the inward curve, so the notch reads as a floating pill. Top and
    /// bottom keep the soft shadow. Cinema conceal has no shadow either.
    private func updatePanelShadow() {
        let sideCollapsed = !expanded && PillPlacement.edge.isVerticalEdge
        let concealed = fullscreenConcealed && !expanded
        panel.hasShadow = !sideCollapsed && !concealed
        if !panel.hasShadow {
            panel.invalidateShadow()
        }
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
    var onDoubleClick: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onRetry: (() -> Void)?
    var onQuit: (() -> Void)?
    var onUnpin: (() -> Void)?
    /// Fullscreen conceal: hit pad stays live, nothing is drawn.
    var chromeSuppressed = false {
        didSet {
            chrome.isHidden = showsExpandedShape || chromeSuppressed
            needsDisplay = true
        }
    }

    let streamView = TouchBarStreamView(frame: .zero)
    private let chrome = CollapsedChromeView(frame: .zero)
    private let fallback = FallbackView(frame: .zero)
    private var tracking: NSTrackingArea?
    private(set) var showsExpandedShape = false
    /// Time-based double-click. Non-activating panels sometimes leave clickCount at 1.
    private var lastClickUp = Date.distantPast
    private var lastClickPoint = NSPoint.zero
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

    /// Hit path includes the fullscreen pad; visual chrome stays flush to the edge.
    func hitShapeContains(_ point: NSPoint) -> Bool {
        if showsExpandedShape {
            return PillShape.path(in: bounds, expanded: true, edge: PillPlacement.edge).contains(point)
        }
        let visual = DisplayList.visualCollapsedRect(in: bounds)
        let path = PillShape.path(in: visual, expanded: false, edge: PillPlacement.edge)
        if path.contains(point) { return true }
        // Fullscreen pad: transparent strip between visual notch and inward edge.
        if FullscreenWatcher.shared.isFullscreen, bounds.contains(point) {
            return true
        }
        return false
    }

    func setVolumeReadout(percent: Int?, muted: Bool) {
        chrome.volumePercent = percent
        chrome.volumeMuted = muted
        chrome.volumeFlash = percent.map { muted ? "🔇" : "\($0)%" }
        chrome.refreshLabel()
        needsDisplay = true
    }

    func apply(mirror: DFRMirror, expanded: Bool) {
        showsExpandedShape = expanded
        if expanded { chromeSuppressed = false }
        chrome.edge = PillPlacement.edge
        chrome.needsDisplay = true
        fallback.title = mirror.simulatorReady ? L("Touch Bar") : L("Touch Bar unavailable")
        fallback.message = mirror.statusMessage
        chrome.isHidden = expanded || chromeSuppressed
        chrome.alphaValue = expanded || chromeSuppressed ? 0 : 1
        streamView.isHidden = !expanded
        streamView.alphaValue = expanded ? 1 : 0
        fallback.isHidden = !expanded || mirror.hasFrame
        fallback.alphaValue = fallback.isHidden ? 0 : 1
        needsLayout = true
        updateChrome()
        refreshFocusChrome()
    }

    func refreshFocusChrome() {
        chrome.refreshLabel()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateChrome()
        streamView.frame = bounds.insetBy(dx: PillMetrics.streamPadX, dy: PillMetrics.streamPadY)
        if showsExpandedShape {
            chrome.frame = bounds
        } else {
            chrome.frame = DisplayList.visualCollapsedRect(in: bounds)
        }
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
        guard hitShapeContains(local) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        if chromeSuppressed && !showsExpandedShape {
            NSColor.clear.setFill()
            dirtyRect.fill()
            return
        }
        if showsExpandedShape {
            let path = PillShape.path(in: bounds, expanded: true, edge: PillPlacement.edge)
            NSColor(calibratedWhite: 0.04, alpha: 0.97).setFill()
            path.fill()
            return
        }
        let visual = DisplayList.visualCollapsedRect(in: bounds)
        let path = PillShape.path(in: visual, expanded: false, edge: PillPlacement.edge)
        let fill = PillPlacement.theme.fillColor
        fill.setFill()
        // Same-color stroke covers the 1–2px light fringe the window server
        // leaves on the inward edge of a side tab.
        if PillPlacement.edge.isVerticalEdge {
            fill.setStroke()
            path.lineWidth = 3
            path.lineJoinStyle = .round
            path.stroke()
        }
        path.fill()
    }

    override func mouseEntered(with event: NSEvent) {
        onEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onExited?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !showsExpandedShape else {
            super.scrollWheel(with: event)
            return
        }
        onScroll?(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            presentContextMenu(with: event)
            return
        }
        guard !showsExpandedShape else { return }
        trackClickOrDrag(clickCount: max(1, event.clickCount))
    }

    /// A small click toggles focus. A double-click toggles mute. A drag along
    /// the attached edge parks the notch. Hover (not click) expands the Touch Bar.
    private func trackClickOrDrag(clickCount: Int) {
        guard let window else {
            onEntered?()
            return
        }
        onPress?()
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        let edge = PillPlacement.edge
        var moved = false
        var upClickCount = clickCount
        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseUp {
                upClickCount = max(upClickCount, next.clickCount)
                break
            }
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
            // 3pt was eating real clicks on the side edges, where the drag
            // axis is vertical and a press always jitters a few points.
            if abs(delta) > 10 {
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
            lastClickUp = .distantPast
            onDragEnd?()
            return
        }
        let now = Date()
        let gap = now.timeIntervalSince(lastClickUp)
        let travel = hypot(NSEvent.mouseLocation.x - lastClickPoint.x, NSEvent.mouseLocation.y - lastClickPoint.y)
        let systemDouble = upClickCount >= 2
        let timedDouble = gap < NSEvent.doubleClickInterval && gap > 0.02 && travel < 12 && lastClickUp != .distantPast
        if systemDouble || timedDouble {
            lastClickUp = .distantPast
            onDoubleClick?()
        } else {
            lastClickUp = now
            lastClickPoint = NSEvent.mouseLocation
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

    private func updateChrome() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.shadowOpacity = 0
        if showsExpandedShape {
            layer.masksToBounds = true
            layer.cornerCurve = .continuous
            layer.cornerRadius = min(PillMetrics.expandedCornerRadius, bounds.height / 2)
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        } else {
            // No hairline. A side tab with a stroke reads as a floating window.
            layer.masksToBounds = false
            layer.cornerRadius = 0
            layer.borderWidth = 0
            layer.borderColor = nil
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
        let ear = min(PillMetrics.scaledEarRadius, max(4, rect.height * 0.45), max(4, rect.width / 4))
        let bottom = min(PillMetrics.scaledBottomRadius, max(4, rect.height - ear - 2), max(4, rect.width / 2 - ear - 1))
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
        let ear = min(PillMetrics.scaledEarRadius, max(4, rect.height * 0.45), max(4, rect.width / 4))
        let tip = min(PillMetrics.scaledBottomRadius, max(4, rect.height - ear - 2), max(4, rect.width / 2 - ear - 1))
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

    /// Same ear math as the top notch, rotated so the straight edge is the left bezel.
    private static func leftNotch(in rect: NSRect) -> NSBezierPath {
        rotatedTopNotch(in: rect, attachmentOnRight: false)
    }

    /// Same ear math as the top notch, rotated so the straight edge is the right bezel.
    private static func rightNotch(in rect: NSRect) -> NSBezierPath {
        rotatedTopNotch(in: rect, attachmentOnRight: true)
    }

    /// Rotate the top-notch path 90°. Both ears stay the single quarter-curve
    /// that already meets the top edge. Determinant stays positive, so fill winding matches.
    private static func rotatedTopNotch(in rect: NSRect, attachmentOnRight: Bool) -> NSBezierPath {
        let local = NSRect(x: 0, y: 0, width: rect.height, height: rect.width)
        let path = topNotch(in: local)
        let transform: AffineTransform
        if attachmentOnRight {
            // (lx, ly) -> (minX + ly, minY + length - lx)
            transform = AffineTransform(
                m11: 0, m12: -1, m21: 1, m22: 0,
                tX: rect.minX, tY: rect.minY + rect.height
            )
        } else {
            // (lx, ly) -> (minX + depth - ly, minY + lx)
            transform = AffineTransform(
                m11: 0, m12: 1, m21: -1, m22: 0,
                tX: rect.minX + rect.width, tY: rect.minY
            )
        }
        path.transform(using: transform)
        return path
    }
}

/// Centered collapsed label. Idle shows “Touch Bar”; focus shows the timer.
/// All phases share the idle SF Pro Rounded premium styling (weight, tracking,
/// optical centering), scaled with notch size. Optional volume % flash.
final class CollapsedChromeView: NSView {
    var edge: PillEdge = .topCenter
    var volumeFlash: String?
    /// Nil hides the readout. Zero is a real level.
    var volumePercent: Int?
    var volumeMuted = false

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { !isHidden }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    override func accessibilityLabel() -> String? {
        if isHidden { return nil }
        if volumeMuted { return L("Muted") }
        if let volumeFlash { return volumeFlash }
        return FocusSession.shared.notchLabel
    }

    func refreshLabel() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if volumePercent != nil {
            drawVolumeHero()
            return
        }
        drawNotchLabel()
    }

    /// Large percent or 🔇. The panel grows while this is up so it is not a tiny flash.
    private func drawVolumeHero() {
        let percent = volumePercent ?? 0
        let hero = (volumeMuted ? "🔇" : "\(percent)%") as NSString
        let size = (volumeMuted ? 34 : 32) * PillPlacement.size.scale
        let font = Self.roundedFont(size: size, weight: .bold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: -0.4,
            .shadow: shadow,
        ]
        let textSize = hero.size(withAttributes: attributes)
        if !volumeMuted, let icon = Self.speakerImage(pointSize: size * 0.72) {
            let iconSize = icon.size
            // Drawn as an image, then the percent. Packaged below as a row.
            drawHeroRow(icon: icon, iconSize: iconSize, text: hero, textSize: textSize, attributes: attributes)
            return
        }
        drawCentered(hero, size: textSize, attributes: attributes)
    }

    private func drawHeroRow(
        icon: NSImage,
        iconSize: NSSize,
        text: NSString,
        textSize: NSSize,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let gap: CGFloat = 6
        let row = NSSize(width: iconSize.width + gap + textSize.width, height: max(iconSize.height, textSize.height))
        if edge.isVerticalEdge {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            if edge.attachesLeft {
                transform.translateX(by: bounds.midX - row.height / 2, yBy: bounds.midY + row.width / 2)
                transform.rotate(byDegrees: -90)
            } else {
                transform.translateX(by: bounds.midX + row.height / 2, yBy: bounds.midY - row.width / 2)
                transform.rotate(byDegrees: 90)
            }
            transform.concat()
            let iconY = (row.height - iconSize.height) / 2
            icon.draw(in: NSRect(x: 0, y: iconY, width: iconSize.width, height: iconSize.height))
            text.draw(at: NSPoint(x: iconSize.width + gap, y: (row.height - textSize.height) / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let origin = NSPoint(
                x: floor((bounds.width - row.width) / 2),
                y: floor((bounds.height - row.height) / 2) - 0.5
            )
            let iconY = origin.y + (row.height - iconSize.height) / 2
            icon.draw(in: NSRect(x: origin.x, y: iconY, width: iconSize.width, height: iconSize.height))
            text.draw(
                at: NSPoint(x: origin.x + iconSize.width + gap, y: origin.y + (row.height - textSize.height) / 2),
                withAttributes: attributes
            )
        }
    }

    private func drawCentered(_ title: NSString, size textSize: NSSize, attributes: [NSAttributedString.Key: Any]) {
        if edge.isVerticalEdge {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            if edge.attachesLeft {
                transform.translateX(by: bounds.midX - textSize.height / 2 - 0.5, yBy: bounds.midY + textSize.width / 2)
                transform.rotate(byDegrees: -90)
            } else {
                transform.translateX(by: bounds.midX + textSize.height / 2 + 0.5, yBy: bounds.midY - textSize.width / 2)
                transform.rotate(byDegrees: 90)
            }
            transform.concat()
            title.draw(at: .zero, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let origin = NSPoint(
                x: floor((bounds.width - textSize.width) / 2),
                y: floor((bounds.height - textSize.height) / 2) - 0.5
            )
            title.draw(at: origin, withAttributes: attributes)
        }
    }

    private func drawNotchLabel() {
        let session = FocusSession.shared
        let title = session.notchLabel as NSString
        let font = Self.labelFont()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(session.labelAlpha),
            .kern: Self.tracking,
        ]
        let textSize = title.size(withAttributes: attributes)
        let showPlay = session.phase == .idle
        if showPlay {
            drawIdleLabel(title: title, textSize: textSize, attributes: attributes)
            return
        }
        drawCentered(title, size: textSize, attributes: attributes)
    }

    /// Small ▶ only while idle, so a first click has something to aim at.
    private func drawIdleLabel(title: NSString, textSize: NSSize, attributes: [NSAttributedString.Key: Any]) {
        let playFont = Self.roundedFont(size: 8 * PillPlacement.size.scale, weight: .semibold)
        let playAttrs: [NSAttributedString.Key: Any] = [
            .font: playFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]
        let play = "▶" as NSString
        let playSize = play.size(withAttributes: playAttrs)
        let gap: CGFloat = 4
        let row = NSSize(width: playSize.width + gap + textSize.width, height: max(playSize.height, textSize.height))
        if edge.isVerticalEdge {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            if edge.attachesLeft {
                transform.translateX(by: bounds.midX - row.height / 2, yBy: bounds.midY + row.width / 2)
                transform.rotate(byDegrees: -90)
            } else {
                transform.translateX(by: bounds.midX + row.height / 2, yBy: bounds.midY - row.width / 2)
                transform.rotate(byDegrees: 90)
            }
            transform.concat()
            play.draw(at: NSPoint(x: 0, y: (row.height - playSize.height) / 2), withAttributes: playAttrs)
            title.draw(at: NSPoint(x: playSize.width + gap, y: (row.height - textSize.height) / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let origin = NSPoint(
                x: floor((bounds.width - row.width) / 2),
                y: floor((bounds.height - row.height) / 2) - 0.5
            )
            play.draw(at: NSPoint(x: origin.x, y: origin.y + (row.height - playSize.height) / 2 + 0.5), withAttributes: playAttrs)
            title.draw(at: NSPoint(x: origin.x + playSize.width + gap, y: origin.y), withAttributes: attributes)
        }
    }

    /// Same premium idle face for the timer.
    private static func labelFont() -> NSFont {
        roundedFont(size: 11.5 * PillPlacement.size.scale, weight: .medium)
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: rounded, size: size) ?? base
        }
        return base
    }

    private static func speakerImage(pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
        guard let image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = false
        return image
    }

    private static let tracking: CGFloat = -0.35
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
