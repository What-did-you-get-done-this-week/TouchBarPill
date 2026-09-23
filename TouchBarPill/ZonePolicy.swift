import CoreGraphics
import Foundation

/// Hit zones on the collapsed notch. Only `center` may expand the Touch Bar.
enum ZoneID: String, Equatable {
    /// Idle: the timer button. Running: pause. Paused: resume.
    case focusPrimary
    /// Present only while a focus session exists. Ends the session.
    case focusStop
    case center
    case volume
    case volumeSlider
}

/// Which bezel the notch hangs from. Independent of AppKit so layout can be tested.
enum NotchEdgeKind: Equatable {
    case top
    case bottom
    case left
    case right

    var isVertical: Bool { self == .left || self == .right }
}

/// Collapsed three-zone geometry and the hover-expand rule.
///
/// Top and bottom, left to right: focus control, center title (or minutes), volume.
/// Left and right edges stack the same three controls top to bottom so they stay
/// readable: wings upright, the long “Touch Bar” title rotated along the bezel.
/// The volume slider grows inward from the volume wing and is not the Touch Bar.
enum ZonePolicy {
    static let focusSpan: CGFloat = 80
    static let centerSpan: CGFloat = 112
    static let volumeSpan: CGFloat = 50
    static let depth: CGFloat = 36
    static let sliderLength: CGFloat = 118
    static let sliderBreadth: CGFloat = 44

    static var span: CGFloat { focusSpan + centerSpan + volumeSpan }

    /// How far the collapsed notch hangs off the bezel, relative to `depth`.
    enum NotchScaleTier: Equatable {
        /// Depth equals the menu-bar band passed in (size S).
        case menuBar
        /// Pre-0.5.0 size S. That height is size M.
        case legacySmall
    }

    /// Scale size S used before 0.5.0. `depth` × this is the old S height (now M).
    static let legacySmallScale: CGFloat = 0.85

    /// A measured menu-bar band outside this range is not a menu bar.
    static func saneMenuBarHeight(_ measured: CGFloat) -> CGFloat {
        if measured >= 12 && measured <= 64 { return measured }
        return 24
    }

    /// Uniform scale for span and depth. Size S’s depth is the menu bar.
    static func scale(for tier: NotchScaleTier, menuBarHeight: CGFloat) -> CGFloat {
        switch tier {
        case .menuBar:
            return saneMenuBarHeight(menuBarHeight) / depth
        case .legacySmall:
            return legacySmallScale
        }
    }

    /// Protrusion from the attaching edge. On the top edge this is the notch height.
    static func protrusion(for tier: NotchScaleTier, menuBarHeight: CGFloat) -> CGFloat {
        scale(for: tier, menuBarHeight: menuBarHeight) * depth
    }

    /// How far a pinned top-center strip sits below the top of the screen.
    /// `menuBarReserved` is `frame.maxY - visibleFrame.maxY` on that display
    /// (0 when it is not showing a menu bar). The strip's top edge then meets
    /// the bottom of the menu bar, so the menus stay clickable.
    static func pinnedTopDrop(menuBarReserved: CGFloat) -> CGFloat {
        guard menuBarReserved.isFinite, menuBarReserved > 0 else { return 0 }
        return menuBarReserved
    }

    /// Top-center expanded drop. Pin on (committed or a hover preview) uses the
    /// menu-bar reserve. Pin off keeps the unpinned gap, including 0.
    static func expandedTopDrop(pinOn: Bool, menuBarReserved: CGFloat, unpinnedGap: CGFloat) -> CGFloat {
        if pinOn { return pinnedTopDrop(menuBarReserved: menuBarReserved) }
        return unpinnedGap
    }

    /// Origin Y of the top-center expanded strip. With pin on, the strip's top
    /// edge is `visibleMaxY` (just under the menu bar) and does not cover it.
    static func expandedTopOriginY(
        pinOn: Bool,
        screenMaxY: CGFloat,
        visibleMaxY: CGFloat,
        stripHeight: CGFloat,
        unpinnedGap: CGFloat
    ) -> CGFloat {
        let drop = expandedTopDrop(
            pinOn: pinOn,
            menuBarReserved: screenMaxY - visibleMaxY,
            unpinnedGap: unpinnedGap
        )
        return screenMaxY - stripHeight - drop
    }

    /// Which status-menu row is driving a live preview, commit, or leave.
    enum MenuFramePreview: Equatable {
        case position
        case pin
        case theme
        case notchSize
    }

    /// Position and pin travel with the pre-preview window animation
    /// (`NSAnimationContext` + `animator().setFrame`). Theme and notch size jump.
    static func animatesMenuFrame(_ preview: MenuFramePreview) -> Bool {
        switch preview {
        case .position, .pin:
            return true
        case .theme, .notchSize:
            return false
        }
    }

    /// Leaving a position or pin hover animates back. Leaving theme or size jumps.
    static func animatesMenuFrameRestore(hasEdge: Bool, hasPin: Bool) -> Bool {
        hasEdge || hasPin
    }

    /// What a pin hover, or the frame that clears one, should do to the strip.
    enum PinStripMotion: Equatable {
        /// Open now. At top center the pinned drop applies.
        case holdOpen
        /// Close now, back to the notch. Do not wait out leave-collapse.
        case holdClosed
        /// Leave open/closed as they are. Normal leave-collapse still applies.
        case unchanged
    }

    /// `overlay` is the Pin menu hover (`nil` when that row is not previewing).
    /// `restoringHover` is the frame after the hover ends without a click.
    /// A hover of pin-on opens the strip; a hover of pin-off closes it.
    /// Leaving snaps back to the committed pin instead of the 0.4s collapse.
    /// Other hovers (`overlay == nil` and not restoring) do not touch this.
    static func pinStripMotion(
        overlay: Bool?,
        committed: Bool,
        expanded: Bool,
        restoringHover: Bool
    ) -> PinStripMotion {
        let effective = overlay ?? committed
        if effective {
            return expanded ? .unchanged : .holdOpen
        }
        let pinHoverFrame = overlay != nil || restoringHover
        if pinHoverFrame && expanded { return .holdClosed }
        return .unchanged
    }

    /// Hover-expand is the center tab only. Wings and the slider never open the stream.
    static func expandsTouchBar(_ zone: ZoneID?) -> Bool {
        zone == .center
    }

    /// A pending expand stays only while the pointer remains on the center.
    static func keepExpandPending(zone: ZoneID?) -> Bool {
        expandsTouchBar(zone)
    }

    /// Crossed speaker when output is muted or the level is zero.
    /// A missing level (no software volume) is not treated as zero.
    static func wantsCrossedSpeaker(muted: Bool, level: Float?) -> Bool {
        if muted { return true }
        guard let level else { return false }
        return level <= 0.005
    }

    /// Volume-wing scroll steps. Positive raises output toward 100%.
    ///
    /// With natural scrolling on, fingers toward the top of the trackpad (away
    /// from the user, toward the lid) produce a negative `scrollingDeltaY` and
    /// raise volume. Fingers toward the user produce a positive delta and lower
    /// it. The bar fills upward toward 100% and empties toward 0%.
    ///
    /// Natural scrolling off undoes the device inversion first. One extra
    /// negation is the last step, so it is not applied twice. Momentum events
    /// keep the gesture's sign (`momentumPhase` is not flipped).
    static func volumeScrollSteps(
        deltaX: CGFloat,
        deltaY: CGFloat,
        precise: Bool,
        invertedFromDevice: Bool
    ) -> Float? {
        var dx = deltaX
        var dy = deltaY
        if !invertedFromDevice {
            dx = -dx
            dy = -dy
        }
        let dominant = abs(dy) >= abs(dx) ? dy : dx
        let minDelta: CGFloat = precise ? 0.35 : 0.01
        guard abs(dominant) >= minDelta else { return nil }
        let raw: Float
        if precise {
            raw = Float(dominant) / 8.0
        } else {
            raw = dominant > 0 ? 2 : -2
        }
        let steps = -raw
        guard abs(steps) > 0.04 else { return nil }
        return steps
    }

    /// What the expanded strip should do with a pending leave-collapse.
    enum CollapseIntent: Equatable {
        /// Arm the leave-collapse delay.
        case schedule
        /// Drop a pending collapse and keep the strip open.
        case cancel
        /// Leave the pending collapse alone.
        case none
    }

    /// Leave-collapse can be armed only while the strip is open, unpinned, and not being dragged.
    static func mayArmCollapse(expanded: Bool, pinned: Bool, dragging: Bool) -> Bool {
        expanded && !pinned && !dragging
    }

    /// Expanded, unpinned, pointer outside the live chrome: schedule collapse.
    /// Pin cancels a pending collapse. A pointer that comes back inside cancels it.
    /// Dragging, or a collapsed strip, does not schedule one.
    static func collapseIntent(
        expanded: Bool,
        pinned: Bool,
        dragging: Bool,
        pointerOutside: Bool,
        collapsePending: Bool
    ) -> CollapseIntent {
        guard mayArmCollapse(expanded: expanded, pinned: pinned, dragging: dragging) else {
            if expanded && pinned && !dragging { return .cancel }
            return .none
        }
        if pointerOutside { return .schedule }
        if collapsePending { return .cancel }
        return .none
    }

    /// True when `mouse` misses every live chrome rect, even after `slack` points.
    /// Empty rects are ignored so a hidden slider cannot pin the pointer at the origin.
    static func pointerOutsideChrome(mouse: CGPoint, rects: [CGRect], slack: CGFloat) -> Bool {
        let pad = max(0, slack)
        for rect in rects where rect.width > 1 && rect.height > 1 {
            if rect.insetBy(dx: -pad, dy: -pad).contains(mouse) {
                return false
            }
        }
        return true
    }

    struct Layout: Equatable {
        var focusPrimary: CGRect
        var focusStop: CGRect
        var center: CGRect
        var volume: CGRect
        /// Zero when the slider is hidden.
        var slider: CGRect

        var focusWing: CGRect {
            if focusStop.width > 1, focusStop.height > 1 {
                return focusPrimary.union(focusStop)
            }
            return focusPrimary
        }

        func zone(containing point: CGPoint) -> ZoneID? {
            if slider.width > 1, slider.height > 1, slider.contains(point) {
                return .volumeSlider
            }
            if focusStop.width > 1, focusStop.height > 1, focusStop.contains(point) {
                return .focusStop
            }
            if focusPrimary.contains(point) { return .focusPrimary }
            if center.contains(point) { return .center }
            if volume.contains(point) { return .volume }
            return nil
        }

        /// Scroll changes volume on the wing, the slider, and a few points of slop
        /// that do not land on the focus wing or the center title.
        func scrollAdjustsVolume(at point: CGPoint, slop: CGFloat) -> Bool {
            let zone = zone(containing: point)
            if zone == .volume || zone == .volumeSlider { return true }
            let grown = volume.insetBy(dx: -slop, dy: -slop)
            let sliderGrown = (slider.width > 1 && slider.height > 1)
                ? slider.insetBy(dx: -slop, dy: -slop)
                : CGRect.null
            let near = grown.contains(point) || sliderGrown.contains(point)
            if !near { return false }
            if focusWing.contains(point) || center.contains(point) { return false }
            return true
        }
    }

    struct SliderGeometry: Equatable {
        var capsule: CGRect
        var label: CGRect
        var track: CGRect

        /// Vertical bars: 0 at the bottom of the track (toward the user) and 1
        /// at the top (toward the lid). Horizontal bars: 0 at the wing, 1 inward.
        func fraction(at point: CGPoint, edge: NotchEdgeKind) -> CGFloat {
            switch edge {
            case .top, .bottom:
                guard track.height > 1 else { return 0 }
                return clamp((point.y - track.minY) / track.height)
            case .left:
                guard track.width > 1 else { return 0 }
                return clamp((point.x - track.minX) / track.width)
            case .right:
                guard track.width > 1 else { return 0 }
                return clamp((track.maxX - point.x) / track.width)
            }
        }

        /// Vertical fill grows from the bottom of the track upward, so 0% is
        /// empty and 100% reaches the lid end. Matches the scroll contract:
        /// fingers away from the user fill the bar in that same direction.
        func fillRect(fraction: CGFloat, edge: NotchEdgeKind) -> CGRect {
            let amount = clamp(fraction)
            switch edge {
            case .top, .bottom:
                let height = track.height * amount
                return CGRect(x: track.minX, y: track.minY, width: track.width, height: height)
            case .left:
                let width = track.width * amount
                return CGRect(x: track.minX, y: track.minY, width: width, height: track.height)
            case .right:
                let width = track.width * amount
                return CGRect(x: track.maxX - width, y: track.minY, width: width, height: track.height)
            }
        }
    }

    static func visualSize(edge: NotchEdgeKind, scale: CGFloat) -> CGSize {
        let span = self.span * scale
        let depth = self.depth * scale
        if edge.isVertical {
            return CGSize(width: depth, height: span)
        }
        return CGSize(width: span, height: depth)
    }

    static func layout(
        visual: CGRect,
        edge: NotchEdgeKind,
        scale: CGFloat,
        sliderVisible: Bool,
        focusActive: Bool
    ) -> Layout {
        let focusLength = visualLength(visual, edge: edge) * (focusSpan / span)
        let centerLength = visualLength(visual, edge: edge) * (centerSpan / span)
        let volumeLength = visualLength(visual, edge: edge) - focusLength - centerLength
        let focus: CGRect
        let center: CGRect
        let volume: CGRect
        if edge.isVertical {
            volume = CGRect(x: visual.minX, y: visual.minY, width: visual.width, height: volumeLength)
            center = CGRect(x: visual.minX, y: volume.maxY, width: visual.width, height: centerLength)
            focus = CGRect(x: visual.minX, y: center.maxY, width: visual.width, height: focusLength)
        } else {
            focus = CGRect(x: visual.minX, y: visual.minY, width: focusLength, height: visual.height)
            center = CGRect(x: focus.maxX, y: visual.minY, width: centerLength, height: visual.height)
            volume = CGRect(x: center.maxX, y: visual.minY, width: volumeLength, height: visual.height)
        }
        let split = splitFocus(focus, edge: edge, active: focusActive)
        let slider = sliderVisible ? sliderRect(anchoredTo: volume, edge: edge, scale: scale) : .zero
        return Layout(
            focusPrimary: split.primary,
            focusStop: split.stop,
            center: center,
            volume: volume,
            slider: slider
        )
    }

    static func sliderGeometry(capsule: CGRect, edge: NotchEdgeKind) -> SliderGeometry {
        let bar: CGFloat = 12
        let pad: CGFloat = 5
        switch edge {
        case .top:
            let label = CGRect(x: capsule.minX + 2, y: capsule.minY + 4, width: capsule.width - 4, height: 26)
            let track = CGRect(
                x: capsule.midX - bar / 2,
                y: label.maxY + 2,
                width: bar,
                height: max(8, capsule.maxY - pad - (label.maxY + 2))
            )
            return SliderGeometry(capsule: capsule, label: label, track: track)
        case .bottom:
            let label = CGRect(x: capsule.minX + 2, y: capsule.maxY - 30, width: capsule.width - 4, height: 26)
            let track = CGRect(
                x: capsule.midX - bar / 2,
                y: capsule.minY + pad,
                width: bar,
                height: max(8, label.minY - 2 - (capsule.minY + pad))
            )
            return SliderGeometry(capsule: capsule, label: label, track: track)
        case .left:
            let label = CGRect(x: capsule.maxX - 38, y: capsule.minY + 2, width: 34, height: capsule.height - 4)
            let track = CGRect(
                x: capsule.minX + pad,
                y: capsule.midY - bar / 2,
                width: max(8, label.minX - 4 - (capsule.minX + pad)),
                height: bar
            )
            return SliderGeometry(capsule: capsule, label: label, track: track)
        case .right:
            let label = CGRect(x: capsule.minX + 4, y: capsule.minY + 2, width: 34, height: capsule.height - 4)
            let track = CGRect(
                x: label.maxX + 4,
                y: capsule.midY - bar / 2,
                width: max(8, capsule.maxX - pad - (label.maxX + 4)),
                height: bar
            )
            return SliderGeometry(capsule: capsule, label: label, track: track)
        }
    }

    static func wholeMinutes(elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return Int(elapsed / 60)
    }

    static func minuteLabel(elapsed: TimeInterval) -> String {
        "\(wholeMinutes(elapsed: elapsed))m"
    }

    /// Delay until the displayed minute changes. Not a one-second tick.
    static func secondsUntilNextMinute(elapsed: TimeInterval) -> TimeInterval {
        guard elapsed.isFinite, elapsed >= 0 else { return 60 }
        let remainder = elapsed.truncatingRemainder(dividingBy: 60)
        // Just after a boundary the next change is a minute away.
        // Just before it, wait out the fraction of a second that is left.
        if remainder < 0.02 { return 60 }
        return max(0.05, 60 - remainder)
    }

    // MARK: - Private

    private static func visualLength(_ visual: CGRect, edge: NotchEdgeKind) -> CGFloat {
        edge.isVertical ? visual.height : visual.width
    }

    /// Active session: primary (pause or resume) then stop, in reading order.
    private static func splitFocus(_ focus: CGRect, edge: NotchEdgeKind, active: Bool) -> (primary: CGRect, stop: CGRect) {
        guard active else { return (focus, .zero) }
        if edge.isVertical {
            let half = focus.height / 2
            let stop = CGRect(x: focus.minX, y: focus.minY, width: focus.width, height: half)
            let primary = CGRect(x: focus.minX, y: stop.maxY, width: focus.width, height: focus.height - half)
            return (primary, stop)
        }
        let half = focus.width / 2
        let primary = CGRect(x: focus.minX, y: focus.minY, width: half, height: focus.height)
        let stop = CGRect(x: primary.maxX, y: focus.minY, width: focus.width - half, height: focus.height)
        return (primary, stop)
    }

    /// Slider hangs inward off the volume wing. It touches that wing and misses the center.
    private static func sliderRect(anchoredTo volume: CGRect, edge: NotchEdgeKind, scale: CGFloat) -> CGRect {
        let length = sliderLength * scale
        let breadthLimit = edge.isVertical ? volume.height : volume.width
        let breadth = min(sliderBreadth * scale, max(16, breadthLimit - 4))
        switch edge {
        case .top:
            return CGRect(
                x: volume.midX - breadth / 2,
                y: volume.minY - length,
                width: breadth,
                height: length
            )
        case .bottom:
            return CGRect(
                x: volume.midX - breadth / 2,
                y: volume.maxY,
                width: breadth,
                height: length
            )
        case .left:
            return CGRect(
                x: volume.maxX,
                y: volume.midY - breadth / 2,
                width: length,
                height: breadth
            )
        case .right:
            return CGRect(
                x: volume.minX - length,
                y: volume.midY - breadth / 2,
                width: length,
                height: breadth
            )
        }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
