import CoreGraphics
import XCTest
@testable import TouchBarPillPolicy

final class ZonePolicyTests: XCTestCase {
    func testOnlyCenterExpandsTouchBar() {
        XCTAssertTrue(ZonePolicy.expandsTouchBar(.center))
        XCTAssertFalse(ZonePolicy.expandsTouchBar(.focusPrimary))
        XCTAssertFalse(ZonePolicy.expandsTouchBar(.focusStop))
        XCTAssertFalse(ZonePolicy.expandsTouchBar(.volume))
        XCTAssertFalse(ZonePolicy.expandsTouchBar(.volumeSlider))
        XCTAssertFalse(ZonePolicy.expandsTouchBar(nil))
    }

    func testWingHoverCancelsPendingExpand() {
        XCTAssertTrue(ZonePolicy.keepExpandPending(zone: .center))
        XCTAssertFalse(ZonePolicy.keepExpandPending(zone: .focusPrimary))
        XCTAssertFalse(ZonePolicy.keepExpandPending(zone: .focusStop))
        XCTAssertFalse(ZonePolicy.keepExpandPending(zone: .volume))
        XCTAssertFalse(ZonePolicy.keepExpandPending(zone: .volumeSlider))
        XCTAssertFalse(ZonePolicy.keepExpandPending(zone: nil))
    }

    func testLayoutZonesOnEveryEdge() {
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
                    XCTAssertEqual(layout.zone(containing: point), expected, "\(edge) active=\(active)")
                    XCTAssertEqual(ZonePolicy.expandsTouchBar(layout.zone(containing: point)), expected == .center)
                    if expected == .volume || expected == .volumeSlider {
                        XCTAssertTrue(layout.scrollAdjustsVolume(at: point, slop: 6))
                    } else {
                        XCTAssertFalse(layout.scrollAdjustsVolume(at: point, slop: 6))
                    }
                }
                if active {
                    let stop = CGPoint(x: layout.focusStop.midX, y: layout.focusStop.midY)
                    XCTAssertEqual(layout.zone(containing: stop), .focusStop)
                    XCTAssertFalse(ZonePolicy.expandsTouchBar(layout.zone(containing: stop)))
                } else {
                    XCTAssertEqual(layout.focusStop, .zero)
                }
                XCTAssertFalse(layout.center.intersects(layout.slider))
                XCTAssertTrue(layout.slider.intersects(layout.volume.insetBy(dx: -0.5, dy: -0.5)))
            }
        }
    }

    func testFocusMinutesAdvanceOnTheMinute() {
        XCTAssertEqual(ZonePolicy.wholeMinutes(elapsed: 0), 0)
        XCTAssertEqual(ZonePolicy.wholeMinutes(elapsed: 59.9), 0)
        XCTAssertEqual(ZonePolicy.wholeMinutes(elapsed: 60), 1)
        XCTAssertEqual(ZonePolicy.wholeMinutes(elapsed: 12 * 60 + 59), 12)
        XCTAssertEqual(ZonePolicy.minuteLabel(elapsed: 0), "0m")
        XCTAssertEqual(ZonePolicy.minuteLabel(elapsed: 60), "1m")
        XCTAssertEqual(ZonePolicy.minuteLabel(elapsed: 12 * 60), "12m")
        XCTAssertEqual(ZonePolicy.secondsUntilNextMinute(elapsed: 0), 60)
        XCTAssertEqual(ZonePolicy.secondsUntilNextMinute(elapsed: 59), 1)
        XCTAssertEqual(ZonePolicy.secondsUntilNextMinute(elapsed: 90), 30)
        XCTAssertGreaterThan(ZonePolicy.secondsUntilNextMinute(elapsed: 30), 20)
    }

    /// Natural scrolling on: fingers toward the lid (away from you) are a negative
    /// `scrollingDeltaY` and must raise volume. Validated in 0.4.8.
    func testFingersAwayIsLouderWithNaturalScrolling() {
        let away = ZonePolicy.volumeScrollSteps(
            deltaX: 0, deltaY: -10, precise: true, invertedFromDevice: true
        )
        let toward = ZonePolicy.volumeScrollSteps(
            deltaX: 0, deltaY: 10, precise: true, invertedFromDevice: true
        )
        XCTAssertGreaterThan(away ?? 0, 0, "fingers away from you (negative deltaY) raise volume")
        XCTAssertLessThan(toward ?? 0, 0, "fingers toward you (positive deltaY) lower volume")

        let lineAway = ZonePolicy.volumeScrollSteps(
            deltaX: 0, deltaY: -1, precise: false, invertedFromDevice: true
        )
        let lineToward = ZonePolicy.volumeScrollSteps(
            deltaX: 0, deltaY: 1, precise: false, invertedFromDevice: true
        )
        XCTAssertEqual(lineAway, 2)
        XCTAssertEqual(lineToward, -2)
    }

    func testNaturalScrollingOffKeepsTheOppositeDeviceSign() {
        let negative = ZonePolicy.volumeScrollSteps(
            deltaX: 0, deltaY: -10, precise: true, invertedFromDevice: false
        )
        let positive = ZonePolicy.volumeScrollSteps(
            deltaX: 0, deltaY: 10, precise: true, invertedFromDevice: false
        )
        XCTAssertLessThan(negative ?? 0, 0)
        XCTAssertGreaterThan(positive ?? 0, 0)
    }

    func testTinyPreciseDeltaIsIgnored() {
        XCTAssertNil(ZonePolicy.volumeScrollSteps(
            deltaX: 0, deltaY: 0.1, precise: true, invertedFromDevice: true
        ))
    }

    func testVolumeBarFillsUpwardTowardTheLid() {
        let track = CGRect(x: 10, y: 20, width: 12, height: 80)
        let geometry = ZonePolicy.SliderGeometry(
            capsule: CGRect(x: 0, y: 0, width: 40, height: 120),
            label: .zero,
            track: track
        )
        let half = geometry.fillRect(fraction: 0.5, edge: .top)
        XCTAssertEqual(half.minY, track.minY, accuracy: 0.01)
        XCTAssertEqual(half.height, 40, accuracy: 0.01)
        XCTAssertLessThan(half.maxY, track.maxY - 1)
        let full = geometry.fillRect(fraction: 1, edge: .top)
        XCTAssertEqual(full.minY, track.minY, accuracy: 0.01)
        XCTAssertEqual(full.maxY, track.maxY, accuracy: 0.01)
        XCTAssertEqual(geometry.fillRect(fraction: 0, edge: .top).height, 0, accuracy: 0.01)
        XCTAssertEqual(geometry.fraction(at: CGPoint(x: track.midX, y: track.maxY), edge: .top), 1, accuracy: 0.01)
        XCTAssertEqual(geometry.fraction(at: CGPoint(x: track.midX, y: track.minY), edge: .top), 0, accuracy: 0.01)
        let bottomHalf = geometry.fillRect(fraction: 0.5, edge: .bottom)
        XCTAssertEqual(bottomHalf.minY, track.minY, accuracy: 0.01)
        XCTAssertEqual(bottomHalf.height, 40, accuracy: 0.01)
    }

    func testCrossedSpeakerAtMuteOrZero() {
        XCTAssertTrue(ZonePolicy.wantsCrossedSpeaker(muted: true, level: 0.4))
        XCTAssertTrue(ZonePolicy.wantsCrossedSpeaker(muted: false, level: 0))
        XCTAssertTrue(ZonePolicy.wantsCrossedSpeaker(muted: false, level: 0.004))
        XCTAssertFalse(ZonePolicy.wantsCrossedSpeaker(muted: false, level: 0.2))
        XCTAssertFalse(ZonePolicy.wantsCrossedSpeaker(muted: false, level: nil))
    }

    func testPointerOutsideChrome() {
        let strip = CGRect(x: 100, y: 800, width: 400, height: 48)
        let notch = CGRect(x: 250, y: 860, width: 160, height: 32)
        XCTAssertFalse(ZonePolicy.pointerOutsideChrome(
            mouse: CGPoint(x: 300, y: 820), rects: [strip, notch], slack: 12
        ))
        XCTAssertFalse(ZonePolicy.pointerOutsideChrome(
            mouse: CGPoint(x: 300, y: 870), rects: [strip, notch], slack: 12
        ))
        XCTAssertTrue(ZonePolicy.pointerOutsideChrome(
            mouse: CGPoint(x: 10, y: 10), rects: [strip, notch], slack: 12
        ))
        XCTAssertFalse(ZonePolicy.pointerOutsideChrome(
            mouse: CGPoint(x: 90, y: 820), rects: [strip, notch], slack: 12
        ))
        XCTAssertTrue(ZonePolicy.pointerOutsideChrome(
            mouse: CGPoint(x: 0, y: 0), rects: [.zero], slack: 12
        ))
    }

    func testExpandedUnpinnedPointerOutsideSchedulesCollapse() {
        XCTAssertEqual(
            ZonePolicy.collapseIntent(
                expanded: true,
                pinned: false,
                dragging: false,
                pointerOutside: true,
                collapsePending: false
            ),
            .schedule
        )
        XCTAssertTrue(ZonePolicy.mayArmCollapse(expanded: true, pinned: false, dragging: false))
    }

    func testPinnedOrInsidePointerDoesNotScheduleCollapse() {
        XCTAssertEqual(
            ZonePolicy.collapseIntent(
                expanded: true,
                pinned: true,
                dragging: false,
                pointerOutside: true,
                collapsePending: true
            ),
            .cancel
        )
        XCTAssertEqual(
            ZonePolicy.collapseIntent(
                expanded: true,
                pinned: false,
                dragging: false,
                pointerOutside: false,
                collapsePending: true
            ),
            .cancel
        )
        XCTAssertEqual(
            ZonePolicy.collapseIntent(
                expanded: true,
                pinned: false,
                dragging: false,
                pointerOutside: false,
                collapsePending: false
            ),
            .none
        )
        XCTAssertEqual(
            ZonePolicy.collapseIntent(
                expanded: false,
                pinned: false,
                dragging: false,
                pointerOutside: true,
                collapsePending: false
            ),
            .none
        )
        XCTAssertEqual(
            ZonePolicy.collapseIntent(
                expanded: true,
                pinned: false,
                dragging: true,
                pointerOutside: true,
                collapsePending: true
            ),
            .none
        )
        XCTAssertFalse(ZonePolicy.mayArmCollapse(expanded: true, pinned: true, dragging: false))
        XCTAssertFalse(ZonePolicy.mayArmCollapse(expanded: false, pinned: false, dragging: false))
    }
}
