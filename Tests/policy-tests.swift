import CoreGraphics
import Foundation

/// Hermetic policy checks. Command Line Tools has no XCTest, so `build-cli.sh`
/// compiles this runner with `ZonePolicy.swift` only.
@main
enum PolicyTests {
    static func main() {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        check(ZonePolicy.expandsTouchBar(.center), "center expands")
        check(!ZonePolicy.expandsTouchBar(.focusPrimary), "focus control does not expand")
        check(!ZonePolicy.expandsTouchBar(.focusStop), "stop does not expand")
        check(!ZonePolicy.expandsTouchBar(.volume), "volume wing does not expand")
        check(!ZonePolicy.expandsTouchBar(.volumeSlider), "volume slider does not expand")
        check(!ZonePolicy.expandsTouchBar(nil), "empty hover does not expand")
        check(ZonePolicy.keepExpandPending(zone: .center), "center keeps expand pending")
        check(!ZonePolicy.keepExpandPending(zone: .focusPrimary), "focus wing cancels expand")
        check(!ZonePolicy.keepExpandPending(zone: .focusStop), "stop cancels expand")
        check(!ZonePolicy.keepExpandPending(zone: .volume), "volume wing cancels expand")
        check(!ZonePolicy.keepExpandPending(zone: .volumeSlider), "slider cancels expand")
        check(!ZonePolicy.keepExpandPending(zone: nil), "leaving cancels expand")

        let edges: [NotchEdgeKind] = [.top, .bottom, .left, .right]
        for edge in edges {
            let size = ZonePolicy.visualSize(edge: edge, scale: 1)
            let visual = CGRect(x: 40, y: 80, width: size.width, height: size.height)
            for active in [false, true] {
                let layout = ZonePolicy.layout(
                    visual: visual,
                    edge: edge,
                    scale: 1,
                    sliderVisible: true,
                    focusActive: active
                )
                let samples: [(ZoneID, CGRect)] = [
                    (.focusPrimary, layout.focusPrimary),
                    (.center, layout.center),
                    (.volume, layout.volume),
                    (.volumeSlider, layout.slider),
                ]
                for (expected, rect) in samples {
                    let point = CGPoint(x: rect.midX, y: rect.midY)
                    let zone = layout.zone(containing: point)
                    check(zone == expected, "\(edge) active=\(active) mid \(expected) got \(String(describing: zone))")
                    check(
                        ZonePolicy.expandsTouchBar(zone) == (expected == .center),
                        "\(edge) expand bit for \(expected)"
                    )
                    if expected == .volume || expected == .volumeSlider {
                        check(layout.scrollAdjustsVolume(at: point, slop: 6), "\(edge) \(expected) scrolls volume")
                    } else {
                        check(!layout.scrollAdjustsVolume(at: point, slop: 6), "\(edge) \(expected) is not a volume scroll")
                    }
                }
                if active {
                    let stop = CGPoint(x: layout.focusStop.midX, y: layout.focusStop.midY)
                    check(layout.zone(containing: stop) == .focusStop, "\(edge) stop zone")
                    check(!ZonePolicy.expandsTouchBar(layout.zone(containing: stop)), "\(edge) stop does not expand")
                } else {
                    check(layout.focusStop == .zero, "\(edge) idle has no stop target")
                }
                check(!layout.center.intersects(layout.slider), "\(edge) slider misses the center")
                check(
                    layout.slider.intersects(layout.volume.insetBy(dx: -0.5, dy: -0.5)),
                    "\(edge) slider touches the volume wing"
                )
            }
        }

        check(ZonePolicy.wholeMinutes(elapsed: 0) == 0, "0s is 0m")
        check(ZonePolicy.wholeMinutes(elapsed: 59.9) == 0, "59.9s is still 0m")
        check(ZonePolicy.wholeMinutes(elapsed: 60) == 1, "60s is 1m")
        check(ZonePolicy.wholeMinutes(elapsed: 12 * 60 + 59) == 12, "12m59s is 12m")
        check(ZonePolicy.minuteLabel(elapsed: 0) == "0m", "label 0m")
        check(ZonePolicy.minuteLabel(elapsed: 60) == "1m", "label 1m")
        check(ZonePolicy.minuteLabel(elapsed: 12 * 60) == "12m", "label 12m")
        check(ZonePolicy.secondsUntilNextMinute(elapsed: 0) == 60, "fresh session waits a minute")
        check(ZonePolicy.secondsUntilNextMinute(elapsed: 59) == 1, "59s waits one second")
        check(ZonePolicy.secondsUntilNextMinute(elapsed: 90) == 30, "90s waits 30s")
        check(ZonePolicy.secondsUntilNextMinute(elapsed: 30) > 20, "mid-minute wait is not one second")

        // Natural scrolling: fingers toward the lid (away from you) are a negative
        // scrollingDeltaY and raise volume. That is the 0.4.8 contract.
        let away = ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: -10, precise: true, invertedFromDevice: true)
        let toward = ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: 10, precise: true, invertedFromDevice: true)
        check((away ?? 0) > 0, "fingers away from you (negative deltaY, natural on) raise volume")
        check((toward ?? 0) < 0, "fingers toward you (positive deltaY, natural on) lower volume")
        check(
            ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: -1, precise: false, invertedFromDevice: true) == 2,
            "line scroll away is a louder step"
        )
        check(
            ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: 1, precise: false, invertedFromDevice: true) == -2,
            "line scroll toward you is a quieter step"
        )
        let legacyNegative = ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: -10, precise: true, invertedFromDevice: false)
        let legacyPositive = ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: 10, precise: true, invertedFromDevice: false)
        check((legacyNegative ?? 0) < 0, "natural-off negative deltaY is a downward step")
        check((legacyPositive ?? 0) > 0, "natural-off positive deltaY is an upward step")
        check(
            ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: 0.1, precise: true, invertedFromDevice: true) == nil,
            "tiny precise delta is ignored"
        )

        let track = CGRect(x: 10, y: 20, width: 12, height: 80)
        let geometry = ZonePolicy.SliderGeometry(
            capsule: CGRect(x: 0, y: 0, width: 40, height: 120),
            label: .zero,
            track: track
        )
        let half = geometry.fillRect(fraction: 0.5, edge: .top)
        check(abs(half.minY - track.minY) < 0.01, "top bar 50% starts at the bottom of the track")
        check(abs(half.height - 40) < 0.01, "top bar 50% is the lower half")
        check(half.maxY < track.maxY - 1, "top bar 50% does not reach the lid")
        let full = geometry.fillRect(fraction: 1, edge: .top)
        check(abs(full.minY - track.minY) < 0.01 && abs(full.maxY - track.maxY) < 0.01, "top bar 100% fills to the lid")
        check(abs(geometry.fillRect(fraction: 0, edge: .top).height) < 0.01, "top bar 0% is empty")
        check(abs(geometry.fraction(at: CGPoint(x: track.midX, y: track.maxY), edge: .top) - 1) < 0.01, "pointer at the lid end is 100%")
        check(abs(geometry.fraction(at: CGPoint(x: track.midX, y: track.minY), edge: .top) - 0) < 0.01, "pointer at the user end is 0%")
        let bottomHalf = geometry.fillRect(fraction: 0.5, edge: .bottom)
        check(abs(bottomHalf.minY - track.minY) < 0.01 && abs(bottomHalf.height - 40) < 0.01, "bottom bar also fills upward")

        check(ZonePolicy.wantsCrossedSpeaker(muted: true, level: 0.4), "mute crosses the speaker")
        check(ZonePolicy.wantsCrossedSpeaker(muted: false, level: 0), "zero volume crosses the speaker")
        check(ZonePolicy.wantsCrossedSpeaker(muted: false, level: 0.004), "rounded 0% crosses the speaker")
        check(!ZonePolicy.wantsCrossedSpeaker(muted: false, level: 0.2), "audible volume keeps the speaker")
        check(!ZonePolicy.wantsCrossedSpeaker(muted: false, level: nil), "unknown level is not forced silent")

        let strip = CGRect(x: 100, y: 800, width: 400, height: 48)
        let notch = CGRect(x: 250, y: 860, width: 160, height: 32)
        check(
            ZonePolicy.pointerOutsideChrome(mouse: CGPoint(x: 300, y: 820), rects: [strip, notch], slack: 12) == false,
            "pointer on the strip is inside"
        )
        check(
            ZonePolicy.pointerOutsideChrome(mouse: CGPoint(x: 300, y: 870), rects: [strip, notch], slack: 12) == false,
            "pointer on the notch is inside"
        )
        check(
            ZonePolicy.pointerOutsideChrome(mouse: CGPoint(x: 10, y: 10), rects: [strip, notch], slack: 12),
            "pointer away from notch and strip is outside"
        )
        check(
            ZonePolicy.pointerOutsideChrome(mouse: CGPoint(x: 90, y: 820), rects: [strip, notch], slack: 12) == false,
            "slack keeps a near miss inside"
        )
        check(
            ZonePolicy.pointerOutsideChrome(mouse: CGPoint(x: 0, y: 0), rects: [.zero], slack: 12),
            "an empty rect does not count as chrome"
        )

        let schedule = ZonePolicy.collapseIntent(
            expanded: true,
            pinned: false,
            dragging: false,
            pointerOutside: true,
            collapsePending: false
        )
        check(schedule == .schedule, "expanded + not pinned + pointer outside schedules collapse")
        check(ZonePolicy.mayArmCollapse(expanded: true, pinned: false, dragging: false), "open unpinned strip may arm collapse")
        check(
            ZonePolicy.collapseIntent(
                expanded: true, pinned: true, dragging: false, pointerOutside: true, collapsePending: true
            ) == .cancel,
            "pin cancels collapse"
        )
        check(
            ZonePolicy.collapseIntent(
                expanded: true, pinned: false, dragging: false, pointerOutside: false, collapsePending: true
            ) == .cancel,
            "pointer back inside cancels a pending collapse"
        )
        check(
            ZonePolicy.collapseIntent(
                expanded: true, pinned: false, dragging: false, pointerOutside: false, collapsePending: false
            ) == .none,
            "pointer inside with nothing pending leaves collapse alone"
        )
        check(
            ZonePolicy.collapseIntent(
                expanded: false, pinned: false, dragging: false, pointerOutside: true, collapsePending: false
            ) == .none,
            "collapsed strip does not schedule collapse"
        )
        check(
            ZonePolicy.collapseIntent(
                expanded: true, pinned: false, dragging: true, pointerOutside: true, collapsePending: true
            ) == .none,
            "dragging does not schedule collapse"
        )
        check(!ZonePolicy.mayArmCollapse(expanded: true, pinned: true, dragging: false), "pin blocks arming collapse")
        check(!ZonePolicy.mayArmCollapse(expanded: false, pinned: false, dragging: false), "collapsed strip cannot arm collapse")

        let bar: CGFloat = 25
        let smallScale = ZonePolicy.scale(for: .menuBar, menuBarHeight: bar)
        let mediumScale = ZonePolicy.scale(for: .legacySmall, menuBarHeight: bar)
        check(abs(ZonePolicy.protrusion(for: .menuBar, menuBarHeight: bar) - 25) < 0.01, "S depth matches the menu bar")
        check(
            abs(ZonePolicy.protrusion(for: .legacySmall, menuBarHeight: bar) - ZonePolicy.depth * 0.85) < 0.01,
            "M depth is the pre-0.5.0 S height"
        )
        check(abs(ZonePolicy.legacySmallScale - 0.85) < 0.001, "legacy small scale stays 0.85")
        let smallTop = ZonePolicy.visualSize(edge: .top, scale: smallScale)
        check(abs(smallTop.height - 25) < 0.01, "top S height is the menu bar")
        let mediumTop = ZonePolicy.visualSize(edge: .top, scale: mediumScale)
        check(abs(mediumTop.height - ZonePolicy.depth * 0.85) < 0.01, "top M height is old S")
        check(abs(mediumTop.width - ZonePolicy.span * 0.85) < 0.01, "M width is old S width")
        let smallSide = ZonePolicy.visualSize(edge: .left, scale: smallScale)
        check(abs(smallSide.width - 25) < 0.01, "side S thickness is the menu bar")
        check(ZonePolicy.protrusion(for: .menuBar, menuBarHeight: 0) == 24, "a missing menu bar falls back to 24")
        check(ZonePolicy.protrusion(for: .menuBar, menuBarHeight: 200) == 24, "an absurd menu bar falls back to 24")
        check(abs(ZonePolicy.protrusion(for: .menuBar, menuBarHeight: 37) - 37) < 0.01, "a taller bar is used as S")
        check(ZonePolicy.pinnedTopDrop(menuBarReserved: 25) == 25, "pinned top strip drops by the menu bar")
        check(ZonePolicy.pinnedTopDrop(menuBarReserved: 0) == 0, "a hidden menu bar does not invent a gap")
        check(ZonePolicy.pinnedTopDrop(menuBarReserved: -4) == 0, "a negative reserve is not a drop")

        let pinnedY = ZonePolicy.expandedTopOriginY(
            pinOn: true, screenMaxY: 900, visibleMaxY: 875, stripHeight: 40, unpinnedGap: 31
        )
        check(abs(pinnedY - 835) < 0.01, "pinned top origin sits one strip below the menu bar")
        check(abs((pinnedY + 40) - 875) < 0.01, "pinned top strip maxY is visibleFrame.maxY")
        check(pinnedY + 40 <= 875, "pinned strip does not cover the menu bar")
        let unpinnedY = ZonePolicy.expandedTopOriginY(
            pinOn: false, screenMaxY: 900, visibleMaxY: 875, stripHeight: 40, unpinnedGap: 31
        )
        check(abs(unpinnedY - 829) < 0.01, "unpinned top expand keeps its gap")
        let hiddenBarY = ZonePolicy.expandedTopOriginY(
            pinOn: true, screenMaxY: 900, visibleMaxY: 900, stripHeight: 40, unpinnedGap: 6
        )
        check(abs(hiddenBarY - 860) < 0.01, "pin with no menu bar does not invent a gap")

        check(
            ZonePolicy.pinStripMotion(overlay: true, committed: false, expanded: false, restoringHover: false) == .holdOpen,
            "hover pin on opens a collapsed strip"
        )
        check(
            ZonePolicy.pinStripMotion(overlay: true, committed: false, expanded: true, restoringHover: false) == .unchanged,
            "hover pin on keeps an open strip and repositions it"
        )
        check(
            ZonePolicy.pinStripMotion(overlay: false, committed: true, expanded: true, restoringHover: false) == .holdClosed,
            "hover pin off closes the strip immediately"
        )
        check(
            ZonePolicy.pinStripMotion(overlay: false, committed: true, expanded: false, restoringHover: false) == .unchanged,
            "hover pin off leaves a collapsed notch collapsed"
        )
        check(
            ZonePolicy.pinStripMotion(overlay: nil, committed: false, expanded: true, restoringHover: true) == .holdClosed,
            "leaving the pin row restores an unpinned notch immediately"
        )
        check(
            ZonePolicy.pinStripMotion(overlay: nil, committed: true, expanded: false, restoringHover: true) == .holdOpen,
            "leaving the pin row restores a pinned strip"
        )
        check(
            ZonePolicy.pinStripMotion(overlay: nil, committed: false, expanded: true, restoringHover: false) == .unchanged,
            "a size hover does not snap an unpinned strip shut"
        )
        check(
            ZonePolicy.pinStripMotion(overlay: nil, committed: true, expanded: false, restoringHover: false) == .holdOpen,
            "committing pin on opens the strip"
        )
        check(
            ZonePolicy.pinStripMotion(overlay: nil, committed: true, expanded: true, restoringHover: false) == .unchanged,
            "committing pin on leaves an open strip open"
        )

        if failures.isEmpty {
            print("policy-tests ok")
        } else {
            for failure in failures {
                print("FAIL \(failure)")
            }
            exit(1)
        }
    }
}
