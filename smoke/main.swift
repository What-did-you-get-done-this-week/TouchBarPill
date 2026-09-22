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
