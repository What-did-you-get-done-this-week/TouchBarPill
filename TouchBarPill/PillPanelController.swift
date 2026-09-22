import AppKit
import QuartzCore

enum PillMetrics {
    /// Medium collapsed notch: focus wing, center title, volume wing.
    /// S (the fresh-install default) scales via `PillPlacement.size`.
    static var collapsedSize: NSSize {
        NSSize(width: ZonePolicy.span, height: ZonePolicy.depth)
    }
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

    /// Pointer may sit this far outside the strip or notch before we treat it as gone.
    static let collapseSlack: CGFloat = 12
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
    private var collapseToken = 0
    private var expandItem: DispatchWorkItem?
    private var discreetItem: DispatchWorkItem?
    private var fullscreenHideItem: DispatchWorkItem?
    private var scrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var pointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var collapseWatch: Timer?
    private var lastScrollStamp: TimeInterval = -1
    private var hoverZone: ZoneID?
    private var syncingPointer = false
    /// Second click of a double-click must not undo the mute.
    private var lastVolumeToggle = Date.distantPast
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
        root.onPointer = { [weak self] in self?.syncPointer() }
        root.onPointerExit = { [weak self] in self?.pointerExited() }
        root.onPress = { [weak self] in self?.pressBegan() }
        root.onFocusPrimary = { [weak self] in self?.focusPrimaryClicked() }
        root.onFocusStop = { [weak self] in self?.focusStopClicked() }
        root.onCenterClick = { [weak self] in self?.centerClicked() }
        root.onVolumeClick = { [weak self] in self?.volumeClicked() }
        root.onVolumeScrub = { [weak self] point in self?.scrubVolume(to: point) }
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
        // Tracking areas drop mouseExited when the cursor leaves into the menu
        // bar or another app. These monitors plus the timer read the pointer
        // location only — no other-app windows, pixels, or titles.
        let moveMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveMask) { [weak self] _ in
            if Thread.isMainThread {
                self?.sampleExpandedPointer()
            } else {
                DispatchQueue.main.async { self?.sampleExpandedPointer() }
            }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: moveMask) { [weak self] event in
            self?.sampleExpandedPointer()
            return event
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil
        )
        let watch = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.sampleExpandedPointer()
        }
        watch.tolerance = 0.08
        RunLoop.main.add(watch, forMode: .common)
        collapseWatch = watch
    }

    deinit {
        collapseWatch?.invalidate()
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
        }
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        guard let screen = DisplayList.resolved() else { return }
        cancelCollapse()
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
            syncPointer()
        } else if FullscreenWatcher.shared.isFullscreen {
            concealForFullscreen(immediate: true)
        } else {
            refreshChromeOpacity(animated: false)
        }
    }

    func hide() {
        cancelCollapse()
        expandItem?.cancel()
        expandItem = nil
        discreetItem?.cancel()
        discreetItem = nil
        VolumeChrome.sliderVisible = false
        hoverZone = nil
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

    /// Sample the pointer and apply zone rules. Wings never arm expand.
    /// Only the center tab does, after the existing short delay.
    private func syncPointer() {
        if syncingPointer || dragging { return }
        syncingPointer = true
        defer { syncingPointer = false }

        if expanded {
            if PillPlacement.pinExpanded {
                hovering = !pointerOutsideLiveChrome()
                cancelCollapse()
                return
            }
            if pointerOutsideLiveChrome() {
                hovering = false
                hoverZone = nil
                root.setHotZone(nil)
                ensureCollapseScheduled()
                return
            }
            hovering = true
            hoverZone = nil
            root.setHotZone(nil)
            cancelCollapse()
            discreetItem?.cancel()
            discreetItem = nil
            fullscreenHideItem?.cancel()
            fullscreenHideItem = nil
            if fullscreenConcealed { setFullscreenConcealed(false, animated: false) }
            setOpacity(1, animated: true)
            return
        }

        var inside = root.pointerInsideShape()
        var zone = inside ? root.zoneUnderPointer() : nil
        let wantsSlider = inside && (zone == .volume || zone == .volumeSlider)
        if wantsSlider != VolumeChrome.sliderVisible {
            VolumeChrome.sliderVisible = wantsSlider
            if panel.isVisible, let screen = DisplayList.resolved() {
                panel.setFrame(collapsedFrame(on: screen), display: true)
                root.needsLayout = true
                root.layoutSubtreeIfNeeded()
                root.updateTrackingAreas()
                updatePanelShadow()
            }
            inside = root.pointerInsideShape()
            zone = inside ? root.zoneUnderPointer() : nil
        }

        let wasZone = hoverZone
        hovering = inside
        hoverZone = inside ? zone : nil
        if hoverZone != wasZone {
            root.setHotZone(hoverZone)
        }

        if !inside {
            cancelExpand()
            refreshChromeOpacity(animated: true)
            scheduleFullscreenConcealIfNeeded()
            return
        }

        cancelCollapse()
        discreetItem?.cancel()
        discreetItem = nil
        fullscreenHideItem?.cancel()
        fullscreenHideItem = nil
        if fullscreenConcealed {
            setFullscreenConcealed(false, animated: false)
        }
        setOpacity(1, animated: true)
        if ZonePolicy.keepExpandPending(zone: hoverZone) {
            if expandItem == nil || !ZonePolicy.keepExpandPending(zone: wasZone) {
                scheduleExpand()
            }
        } else {
            cancelExpand()
        }
    }

    /// Hover-expand delay. Long enough to begin a drag, short enough that
    /// resting the pointer still feels immediate. Default ~0.09s (snappier).
    /// The work item refuses to open unless the pointer is still on the center.
    private func scheduleExpand() {
        expandItem?.cancel()
        guard ZonePolicy.expandsTouchBar(hoverZone), !expanded, !dragging else {
            expandItem = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.expanded, !self.dragging else { return }
            guard ZonePolicy.expandsTouchBar(self.hoverZone) else { return }
            if (NSEvent.pressedMouseButtons & 1) != 0 { return }
            self.setExpanded(true)
        }
        expandItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PillPlacement.revealDelay, execute: work)
    }

    private func cancelExpand() {
        expandItem?.cancel()
        expandItem = nil
    }

    private func pressBegan() {
        cancelExpand()
    }

    /// Timer icon starts focus. Pause freezes minutes. Resume continues them.
    /// None of these open the Touch Bar.
    private func focusPrimaryClicked() {
        guard !dragging, !expanded else { return }
        cancelExpand()
        switch FocusSession.shared.phase {
        case .idle:
            FocusSession.shared.start()
        case .running:
            FocusSession.shared.pause()
        case .paused:
            FocusSession.shared.resume()
        }
        if fullscreenConcealed {
            setFullscreenConcealed(false, animated: false)
        }
        setOpacity(1, animated: false)
        root.refreshFocusChrome()
    }

    /// Stop ends the session. The center title returns to “Touch Bar”.
    private func focusStopClicked() {
        guard !dragging, !expanded else { return }
        cancelExpand()
        FocusSession.shared.reset()
        if fullscreenConcealed {
            setFullscreenConcealed(false, animated: false)
        }
        setOpacity(1, animated: false)
        root.refreshFocusChrome()
    }

    /// The center is the Touch Bar hover target. A click does not change focus.
    private func centerClicked() {
        guard !dragging else { return }
        if ZonePolicy.expandsTouchBar(hoverZone) {
            scheduleExpand()
        }
    }

    /// Click or double-click on the volume wing or slider toggles mute once.
    private func volumeClicked() {
        guard !expanded, !dragging else { return }
        cancelExpand()
        let now = Date()
        if now.timeIntervalSince(lastVolumeToggle) < NSEvent.doubleClickInterval {
            lastVolumeToggle = .distantPast
            revealVolumeSlider()
            root.refreshVolumeChrome()
            return
        }
        lastVolumeToggle = now
        _ = SystemVolume.toggleMute()
        revealVolumeSlider()
        root.refreshVolumeChrome()
    }

    private func scrubVolume(to local: NSPoint) {
        guard !expanded else { return }
        cancelExpand()
        guard let fraction = root.volumeFraction(at: local) else { return }
        _ = SystemVolume.setLevel(Float(fraction))
        revealVolumeSlider()
        root.refreshVolumeChrome()
    }

    /// Show the anchored slider without opening the Touch Bar stream.
    private func revealVolumeSlider() {
        guard !expanded, !dragging else { return }
        if fullscreenConcealed {
            setFullscreenConcealed(false, animated: false)
        }
        setOpacity(1, animated: false)
        guard !VolumeChrome.sliderVisible else { return }
        VolumeChrome.sliderVisible = true
        guard panel.isVisible, let screen = DisplayList.resolved() else { return }
        panel.setFrame(collapsedFrame(on: screen), display: true)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        root.updateTrackingAreas()
        updatePanelShadow()
    }

    /// Scroll over the volume wing or its slider. The center and focus wing ignore the wheel.
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

    private func scrollHit() -> Bool {
        guard panel.isVisible, !expanded else { return false }
        return root.pointerOverVolume(slop: 6)
    }

    private func scrollCollapsed(_ event: NSEvent) {
        guard !expanded else { return }
        guard root.pointerOverVolume(slop: 6) else { return }
        if event.timestamp == lastScrollStamp { return }
        lastScrollStamp = event.timestamp
        // Natural scrolling on: positive scrollingDeltaY is fingers away from
        // the user and must raise volume. Mapping lives in volumeScrollSteps.
        guard let steps = ZonePolicy.volumeScrollSteps(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            invertedFromDevice: event.isDirectionInvertedFromDevice
        ) else { return }
        cancelExpand()
        guard SystemVolume.adjust(by: steps * SystemVolume.step) != nil else { return }
        revealVolumeSlider()
        root.refreshVolumeChrome()
    }

    /// Slider visible keeps the notch opaque the same way the old volume readout did.
    private var volumeHUDActive: Bool {
        VolumeChrome.sliderVisible
    }

    /// Notch plus expanded strip, with a few points of slack. Cinema coverage
    /// is not part of this test: a mid-range window must not keep the strip open.
    private func pointerOutsideLiveChrome() -> Bool {
        var rects = [panel.frame]
        if let screen = DisplayList.resolved() {
            rects.append(collapsedFrame(on: screen))
        }
        return ZonePolicy.pointerOutsideChrome(
            mouse: NSEvent.mouseLocation,
            rects: rects,
            slack: PillMetrics.collapseSlack
        )
    }

    private func cancelCollapse() {
        collapseToken += 1
        collapseItem?.cancel()
        collapseItem = nil
    }

    /// Start the leave-collapse delay. Repeating this restarts the delay, so
    /// the pointer watch must call `ensureCollapseScheduled` instead.
    private func scheduleCollapse() {
        guard expanded, !PillPlacement.pinExpanded, !dragging else { return }
        collapseItem?.cancel()
        collapseToken += 1
        let token = collapseToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.collapseToken == token else { return }
            self.collapseItem = nil
            guard self.expanded, !PillPlacement.pinExpanded, !self.dragging else { return }
            guard self.panel.isVisible else { return }
            if !self.pointerOutsideLiveChrome() {
                self.hovering = true
                return
            }
            self.hovering = false
            self.hoverZone = nil
            self.root.setHotZone(nil)
            self.setExpanded(false)
        }
        collapseItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PillMetrics.collapseDelay, execute: work)
    }

    private func ensureCollapseScheduled() {
        guard collapseItem == nil else { return }
        scheduleCollapse()
    }

    /// mouseExited on the expanded strip, or on the center zone, always arms
    /// collapse. A missed exit is covered by `sampleExpandedPointer`.
    private func pointerExited() {
        let leftExpanded = expanded
        let leftCenter = hoverZone == .center
        if leftExpanded || leftCenter {
            hovering = false
            hoverZone = nil
            root.setHotZone(nil)
            cancelExpand()
            if leftExpanded {
                scheduleCollapse()
            } else {
                refreshChromeOpacity(animated: true)
                scheduleFullscreenConcealIfNeeded()
            }
            return
        }
        syncPointer()
    }

    /// If the strip is open, unpinned, and the pointer is outside, arm collapse.
    /// Safe to call from a timer, a mouse monitor, or an app switch.
    private func sampleExpandedPointer() {
        guard panel.isVisible, expanded, !dragging else { return }
        if PillPlacement.pinExpanded {
            cancelCollapse()
            return
        }
        if pointerOutsideLiveChrome() {
            hovering = false
            hoverZone = nil
            root.setHotZone(nil)
            ensureCollapseScheduled()
        } else if collapseItem != nil {
            cancelCollapse()
            hovering = true
        }
    }

    @objc private func frontmostAppChanged() {
        sampleExpandedPointer()
    }

    private func setExpanded(_ expand: Bool) {
        cancelCollapse()
        if expand {
            cancelExpand()
            VolumeChrome.sliderVisible = false
        }
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
                self.syncPointer()
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
                cancelCollapse()
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
            cancelCollapse()
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
        if !PillPlacement.pinExpanded && expanded && pointerOutsideLiveChrome() {
            hovering = false
            hoverZone = nil
            root.setHotZone(nil)
            scheduleCollapse()
        } else if !expanded {
            scheduleFullscreenConcealIfNeeded()
        }
    }

    private func dragCollapsed(to origin: NSPoint) {
        dragging = true
        cancelCollapse()
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
        syncPointer()
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
    var onPointer: (() -> Void)?
    var onPointerExit: (() -> Void)?
    var onPress: (() -> Void)?
    var onFocusPrimary: (() -> Void)?
    var onFocusStop: (() -> Void)?
    var onCenterClick: (() -> Void)?
    var onVolumeClick: (() -> Void)?
    var onVolumeScrub: ((NSPoint) -> Void)?
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
    private var zoneTrackers: [NSTrackingArea] = []
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
        let layout = currentLayout()
        if layout.slider.width > 1, layout.slider.contains(point) { return true }
        // Fullscreen pad: transparent strip between visual notch and inward edge.
        if FullscreenWatcher.shared.isFullscreen, bounds.contains(point) {
            return true
        }
        return false
    }

    func currentLayout() -> ZonePolicy.Layout {
        let visual = showsExpandedShape ? bounds : DisplayList.visualCollapsedRect(in: bounds)
        return ZonePolicy.layout(
            visual: visual,
            edge: NotchEdgeKind(PillPlacement.edge),
            scale: PillPlacement.size.scale,
            sliderVisible: VolumeChrome.sliderVisible && !showsExpandedShape,
            focusActive: FocusSession.shared.phase != .idle
        )
    }

    func pointerInsideShape() -> Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return hitShapeContains(local)
    }

    func zoneUnderPointer() -> ZoneID? {
        guard let window, !showsExpandedShape else { return nil }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard hitShapeContains(local) else { return nil }
        return currentLayout().zone(containing: local)
    }

    func pointerOverVolume(slop: CGFloat) -> Bool {
        guard let window, !showsExpandedShape else { return false }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return currentLayout().scrollAdjustsVolume(at: local, slop: slop)
    }

    func volumeFraction(at local: NSPoint) -> CGFloat? {
        let layout = currentLayout()
        guard layout.slider.width > 1, layout.slider.height > 1 else { return nil }
        let edge = NotchEdgeKind(PillPlacement.edge)
        return ZonePolicy.sliderGeometry(capsule: layout.slider, edge: edge).fraction(at: local, edge: edge)
    }

    func setHotZone(_ zone: ZoneID?) {
        chrome.hotZone = zone
    }

    func refreshVolumeChrome() {
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
        if !showsExpandedShape {
            updateTrackingAreas()
        }
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
        for tracker in zoneTrackers {
            removeTrackingArea(tracker)
        }
        zoneTrackers.removeAll()
        let options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited, .mouseMoved]
        func add(_ rect: NSRect) {
            guard rect.width > 1, rect.height > 1 else { return }
            let area = NSTrackingArea(rect: rect, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            zoneTrackers.append(area)
        }
        if showsExpandedShape {
            add(bounds)
            return
        }
        let layout = currentLayout()
        add(layout.focusPrimary)
        add(layout.focusStop)
        add(layout.center)
        add(layout.volume)
        add(layout.slider)
        add(bounds)
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
        let layout = currentLayout()
        if layout.slider.width > 1 {
            drawVolumeSlider(layout.slider)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onPointer?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExit?()
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer?()
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

    /// A small click hits the zone under the pointer. A drag along the attached
    /// edge parks the notch. A drag on the volume slider sets the level.
    /// Hover of the center (not a click) expands the Touch Bar.
    private func trackClickOrDrag(clickCount: Int) {
        guard let window else {
            onPointer?()
            return
        }
        onPress?()
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        let startLocal = convert(window.convertPoint(fromScreen: startMouse), from: nil)
        let zone = currentLayout().zone(containing: startLocal)
        let edge = PillPlacement.edge
        var movedNotch = false
        var scrubbed = false
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
            let along: CGFloat
            let across: CGFloat
            switch edge {
            case .topCenter, .bottomCenter:
                along = dx
                across = dy
            case .leftMid, .rightMid:
                along = dy
                across = dx
            }
            if scrubbed {
                let local = convert(window.convertPoint(fromScreen: mouse), from: nil)
                onVolumeScrub?(local)
                continue
            }
            if movedNotch {
                dragNotch(dx: dx, dy: dy, from: startOrigin, edge: edge)
                continue
            }
            let onSlider = zone == .volume || zone == .volumeSlider
            if onSlider, abs(across) > 5, abs(across) >= abs(along) {
                scrubbed = true
                let local = convert(window.convertPoint(fromScreen: mouse), from: nil)
                onVolumeScrub?(local)
            } else if abs(along) > 10 {
                movedNotch = true
                dragNotch(dx: dx, dy: dy, from: startOrigin, edge: edge)
            }
        }
        if movedNotch {
            onDragEnd?()
            return
        }
        if scrubbed { return }
        switch zone {
        case .focusPrimary:
            onFocusPrimary?()
        case .focusStop:
            onFocusStop?()
        case .center:
            onCenterClick?()
        case .volume, .volumeSlider:
            onVolumeClick?()
        case nil:
            break
        }
        _ = clickCount
    }

    private func dragNotch(dx: CGFloat, dy: CGFloat, from origin: NSPoint, edge: PillEdge) {
        switch edge {
        case .topCenter, .bottomCenter:
            onDrag?(NSPoint(x: origin.x + dx, y: origin.y))
        case .leftMid, .rightMid:
            onDrag?(NSPoint(x: origin.x, y: origin.y + dy))
        }
    }

    private func drawVolumeSlider(_ capsule: NSRect) {
        let edge = NotchEdgeKind(PillPlacement.edge)
        let geometry = ZonePolicy.sliderGeometry(capsule: capsule, edge: edge)
        let radius = min(14, capsule.width / 2, capsule.height / 2)
        let fill = PillPlacement.theme.fillColor
        let path = NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let silent = SystemVolume.showsCrossedSpeaker()
        let level = CGFloat(SystemVolume.volume() ?? 0)
        let trackPath = NSBezierPath(roundedRect: geometry.track, xRadius: geometry.track.width / 2, yRadius: geometry.track.height / 2)
        NSColor.white.withAlphaComponent(0.22).setFill()
        trackPath.fill()
        if !silent, level > 0.01 {
            let amount = geometry.fillRect(fraction: level, edge: edge)
            if amount.width > 0.5, amount.height > 0.5 {
                NSGraphicsContext.saveGraphicsState()
                trackPath.addClip()
                NSColor.white.setFill()
                amount.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if silent {
            drawSpeakerMark(crossed: true, in: geometry.label, pointSize: 16 * PillPlacement.size.scale)
        } else {
            let label = "\(Int((level * 100).rounded()))%"
            drawSliderLabel(label, in: geometry.label)
        }
    }

    private func drawSliderLabel(_ text: String, in rect: NSRect) {
        var point: CGFloat = 14 * PillPlacement.size.scale
        var font = NotchFont(size: point, weight: .bold)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: -0.35,
        ]
        var textSize = (text as NSString).size(withAttributes: attributes)
        while point > 9, textSize.width > rect.width - 2 || textSize.height > rect.height - 1 {
            point -= 0.5
            font = NotchFont(size: point, weight: .bold)
            attributes[.font] = font
            textSize = (text as NSString).size(withAttributes: attributes)
        }
        let origin = NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
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

/// Three collapsed zones. Left is the focus control (timer, then pause/stop).
/// Center is “Touch Bar”, or whole minutes while a session exists.
/// Right is the speaker. Hover highlight marks the live hit target.
final class CollapsedChromeView: NSView {
    var edge: PillEdge = .topCenter
    var hotZone: ZoneID? {
        didSet { if hotZone != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { !isHidden }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        if isHidden { return nil }
        let session = FocusSession.shared
        switch session.phase {
        case .idle:
            return L("Touch Bar")
        case .running, .paused:
            return session.notchLabel
        }
    }

    func refreshLabel() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = ZonePolicy.layout(
            visual: bounds,
            edge: NotchEdgeKind(edge),
            scale: PillPlacement.size.scale,
            sliderVisible: false,
            focusActive: FocusSession.shared.phase != .idle
        )
        NSGraphicsContext.saveGraphicsState()
        PillShape.path(in: bounds, expanded: false, edge: edge).addClip()
        drawDividers(layout)
        if let hotZone {
            let hot = hotRect(hotZone, layout: layout)
            if hot.width > 1 {
                let bubble = hot.insetBy(dx: 3, dy: 3)
                NSColor.white.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: bubble, xRadius: 6, yRadius: 6).fill()
            }
        }
        drawFocus(layout)
        drawCenter(layout.center)
        drawVolumeWing(layout.volume)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func hotRect(_ zone: ZoneID, layout: ZonePolicy.Layout) -> CGRect {
        switch zone {
        case .focusPrimary: return layout.focusPrimary
        case .focusStop: return layout.focusStop
        case .center: return layout.center
        case .volume, .volumeSlider: return layout.volume
        }
    }

    private func drawDividers(_ layout: ZonePolicy.Layout) {
        let color = NSColor.white.withAlphaComponent(0.22)
        color.setStroke()
        let ear = min(PillMetrics.scaledEarRadius, bounds.height * 0.35, bounds.width * 0.2)
        let tip = min(PillMetrics.scaledBottomRadius, 8)
        if edge.isVerticalEdge {
            strokeAcross(layout.center.maxY, insetStart: 4, insetEnd: 4, vertical: false)
            strokeAcross(layout.volume.maxY, insetStart: 4, insetEnd: 4, vertical: false)
            if layout.focusStop.height > 1 {
                strokeAcross(layout.focusStop.maxY, insetStart: 4, insetEnd: 4, vertical: false)
            }
        } else {
            strokeAcross(layout.focusWing.maxX, insetStart: ear, insetEnd: tip, vertical: true)
            strokeAcross(layout.center.maxX, insetStart: ear, insetEnd: tip, vertical: true)
            if layout.focusStop.width > 1 {
                strokeAcross(layout.focusPrimary.maxX, insetStart: 4, insetEnd: 4, vertical: true)
            }
        }
    }

    /// `vertical` means the divider itself is a vertical line (top/bottom notches).
    private func strokeAcross(_ position: CGFloat, insetStart: CGFloat, insetEnd: CGFloat, vertical: Bool) {
        let path = NSBezierPath()
        path.lineWidth = 1
        if vertical {
            let top = bounds.maxY - insetStart
            let bottom = bounds.minY + insetEnd
            guard top > bottom + 4 else { return }
            path.move(to: NSPoint(x: position, y: bottom))
            path.line(to: NSPoint(x: position, y: top))
        } else {
            let left = bounds.minX + insetStart
            let right = bounds.maxX - insetEnd
            guard right > left + 4 else { return }
            path.move(to: NSPoint(x: left, y: position))
            path.line(to: NSPoint(x: right, y: position))
        }
        path.stroke()
    }

    private func drawFocus(_ layout: ZonePolicy.Layout) {
        let session = FocusSession.shared
        let scale = PillPlacement.size.scale
        switch session.phase {
        case .idle:
            drawSymbol("timer", in: layout.focusPrimary, pointSize: 15 * scale, fallback: .clock)
        case .running:
            drawSymbol("pause.fill", in: layout.focusPrimary, pointSize: 12 * scale, fallback: .pause)
            drawSymbol("stop.fill", in: layout.focusStop, pointSize: 11 * scale, fallback: .stop)
        case .paused:
            drawSymbol("play.fill", in: layout.focusPrimary, pointSize: 12 * scale, fallback: .resume)
            drawSymbol("stop.fill", in: layout.focusStop, pointSize: 11 * scale, fallback: .stop)
        }
    }

    private func drawCenter(_ rect: CGRect) {
        let session = FocusSession.shared
        let scale = PillPlacement.size.scale
        let title = session.notchLabel
        let minutes = session.phase != .idle
        let size = (minutes ? 17 : 15.5) * scale
        let weight: NSFont.Weight = minutes ? .semibold : .medium
        let alpha = session.labelAlpha
        if edge.isVerticalEdge && !minutes {
            drawRotated(title, in: rect, size: size, weight: weight, alpha: alpha)
        } else if edge.isVerticalEdge && !textFits(title, in: rect, size: size, weight: weight) {
            drawRotated(title, in: rect, size: size, weight: weight, alpha: alpha)
        } else {
            drawFitted(title, in: rect, size: size, weight: weight, alpha: alpha)
        }
    }

    private func drawVolumeWing(_ rect: CGRect) {
        let crossed = SystemVolume.showsCrossedSpeaker()
        drawSpeakerMark(crossed: crossed, in: rect, pointSize: 14 * PillPlacement.size.scale)
    }

    private func textFits(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight) -> Bool {
        let font = NotchFont(size: size, weight: weight)
        let measured = (text as NSString).size(withAttributes: [.font: font, .kern: -0.35])
        return measured.width <= rect.width - 4 && measured.height <= rect.height - 2
    }

    private func drawFitted(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        var point = size
        var font = NotchFont(size: point, weight: weight)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .kern: -0.35,
        ]
        var textSize = (text as NSString).size(withAttributes: attributes)
        while point > 10, textSize.width > rect.width - 4 || textSize.height > rect.height - 2 {
            point -= 0.5
            font = NotchFont(size: point, weight: weight)
            attributes[.font] = font
            textSize = (text as NSString).size(withAttributes: attributes)
        }
        let origin = NSPoint(x: floor(rect.midX - textSize.width / 2), y: floor(rect.midY - textSize.height / 2) - 0.5)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// Same rotation the 0.4.3 side label used, centered on this zone.
    private func drawRotated(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        let font = NotchFont(size: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .kern: -0.35,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        if edge.attachesLeft {
            transform.translateX(by: rect.midX - textSize.height / 2, yBy: rect.midY + textSize.width / 2)
            transform.rotate(byDegrees: -90)
        } else {
            transform.translateX(by: rect.midX + textSize.height / 2, yBy: rect.midY - textSize.width / 2)
            transform.rotate(byDegrees: 90)
        }
        transform.concat()
        (text as NSString).draw(at: .zero, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private enum SymbolFallback {
        case clock, pause, stop, resume, speaker
    }

    private func drawSymbol(_ name: String, in rect: CGRect, pointSize: CGFloat, fallback: SymbolFallback) {
        guard rect.width > 2, rect.height > 2 else { return }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: NSColor.white.withAlphaComponent(0.94)))
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let side = pointSize * 1.2
            let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            image.isTemplate = false
            image.draw(in: box)
            return
        }
        drawFallback(fallback, in: rect)
    }

    private func drawFallback(_ kind: SymbolFallback, in rect: CGRect) {
        NSColor.white.withAlphaComponent(0.92).setStroke()
        NSColor.white.withAlphaComponent(0.92).setFill()
        let side = min(rect.width, rect.height) * 0.42
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        switch kind {
        case .clock:
            let ring = NSBezierPath(ovalIn: box)
            ring.lineWidth = 1.4
            ring.stroke()
            let hands = NSBezierPath()
            hands.move(to: NSPoint(x: box.midX, y: box.midY))
            hands.line(to: NSPoint(x: box.midX, y: box.maxY - 1.5))
            hands.move(to: NSPoint(x: box.midX, y: box.midY))
            hands.line(to: NSPoint(x: box.maxX - 2, y: box.midY))
            hands.lineWidth = 1.3
            hands.stroke()
        case .pause:
            let barW = side * 0.28
            let gap = side * 0.18
            NSBezierPath(roundedRect: CGRect(x: box.midX - gap / 2 - barW, y: box.minY, width: barW, height: side), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: CGRect(x: box.midX + gap / 2, y: box.minY, width: barW, height: side), xRadius: 1, yRadius: 1).fill()
        case .stop:
            NSBezierPath(roundedRect: box.insetBy(dx: side * 0.12, dy: side * 0.12), xRadius: 2, yRadius: 2).fill()
        case .resume:
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: box.minX + 1, y: box.minY))
            triangle.line(to: NSPoint(x: box.maxX, y: box.midY))
            triangle.line(to: NSPoint(x: box.minX + 1, y: box.maxY))
            triangle.close()
            triangle.fill()
        case .speaker:
            let mark = (SystemVolume.showsCrossedSpeaker() ? "🔇" : "♪") as NSString
            let font = NotchFont(size: side, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let textSize = mark.size(withAttributes: attributes)
            mark.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }
    }
}

/// Speaker on the volume wing and in the slider overlay.
/// Crossed when muted or at 0%; the ordinary speaker otherwise.
func drawSpeakerMark(crossed: Bool, in rect: CGRect, pointSize: CGFloat) {
    guard rect.width > 2, rect.height > 2 else { return }
    let name = crossed ? "speaker.slash.fill" : "speaker.wave.2.fill"
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: NSColor.white.withAlphaComponent(0.94)))
    if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let side = min(rect.width - 2, rect.height - 2, pointSize * 1.35)
        guard side > 2 else { return }
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        image.isTemplate = false
        image.draw(in: box)
        return
    }
    let mark = (crossed ? "🔇" : "♪") as NSString
    let font = NotchFont(size: min(pointSize, rect.height * 0.8), weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let textSize = mark.size(withAttributes: attributes)
    mark.draw(
        at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
        withAttributes: attributes
    )
}

func NotchFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let rounded = base.fontDescriptor.withDesign(.rounded) {
        return NSFont(descriptor: rounded, size: size) ?? base
    }
    return base
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
