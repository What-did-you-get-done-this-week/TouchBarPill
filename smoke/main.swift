import CoreGraphics
import Foundation

/// Proves wing hover cannot expand the Touch Bar, and that focus minutes
/// advance on the minute boundary only.
@main
enum ZoneSmoke {
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

        var pending = false
        func hover(_ zone: ZoneID?) {
            pending = ZonePolicy.keepExpandPending(zone: zone)
        }
        hover(.center)
        check(pending, "center arms expand")
        hover(.focusPrimary)
        check(!pending, "moving to the focus wing cancels expand")
        hover(.center)
        hover(.focusStop)
        check(!pending, "stop cancels expand")
        hover(.center)
        hover(.volume)
        check(!pending, "volume wing cancels expand")
        hover(.center)
        hover(.volumeSlider)
        check(!pending, "slider cancels expand")
        hover(nil)
        check(!pending, "leaving cancels expand")

        let scale: CGFloat = 1
        let edges: [NotchEdgeKind] = [.top, .bottom, .left, .right]
        for edge in edges {
            let size = ZonePolicy.visualSize(edge: edge, scale: scale)
            let visual = CGRect(x: 40, y: 80, width: size.width, height: size.height)
            for active in [false, true] {
                let layout = ZonePolicy.layout(
                    visual: visual,
                    edge: edge,
                    scale: scale,
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
                    if expected != .volume && expected != .volumeSlider {
                        check(!layout.scrollAdjustsVolume(at: point, slop: 6), "\(edge) \(expected) is not a volume scroll")
                    } else {
                        check(layout.scrollAdjustsVolume(at: point, slop: 6), "\(edge) \(expected) scrolls volume")
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
                check(layout.slider.intersects(layout.volume.insetBy(dx: -0.5, dy: -0.5)), "\(edge) slider touches the volume wing")
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
        check(ZonePolicy.secondsUntilNextMinute(elapsed: 59) == 1, "59s waits one second, not a tick loop")
        check(ZonePolicy.secondsUntilNextMinute(elapsed: 90) == 30, "90s waits 30s")
        let early = ZonePolicy.secondsUntilNextMinute(elapsed: 30)
        check(early > 20, "mid-minute wait is not one second")

        // Arturo-validated: after 0.4.7 user reported inverted; 0.4.8 flips once.
        let naturalPositive = ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: 10, precise: true, invertedFromDevice: true)
        let naturalNegative = ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: -10, precise: true, invertedFromDevice: true)
        check((naturalPositive ?? 0) < 0, "0.4.8 flip: natural-on positive deltaY is a downward step")
        check((naturalNegative ?? 0) > 0, "0.4.8 flip: natural-on negative deltaY is an upward step")
        let legacyNegative = ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: -10, precise: true, invertedFromDevice: false)
        let legacyPositive = ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: 10, precise: true, invertedFromDevice: false)
        check((legacyNegative ?? 0) < 0, "0.4.8 flip: natural-off negative deltaY is a downward step")
        check((legacyPositive ?? 0) > 0, "0.4.8 flip: natural-off positive deltaY is an upward step")
        check(ZonePolicy.volumeScrollSteps(deltaX: 0, deltaY: 0.1, precise: true, invertedFromDevice: true) == nil, "tiny precise delta is ignored")

        let track = CGRect(x: 10, y: 20, width: 12, height: 80)
        let geometry = ZonePolicy.SliderGeometry(capsule: CGRect(x: 0, y: 0, width: 40, height: 120), label: .zero, track: track)
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

        if failures.isEmpty {
            print("zone-smoke ok")
        } else {
            for failure in failures {
                print("FAIL \(failure)")
            }
            exit(1)
        }
    }
}
