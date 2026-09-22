import AppKit

/// Shows the live DFR frame and forwards pointer events into the simulator.
/// Hidden while the pill is collapsed, so it does not eat hover hits.
final class TouchBarStreamView: NSView {
    var onMouse: ((NSEvent) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onContextMenu?(event)
            return
        }
        forward(event)
    }
    override func mouseUp(with event: NSEvent) { forward(event) }
    override func mouseDragged(with event: NSEvent) { forward(event) }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) { forward(event) }
    override func otherMouseUp(with event: NSEvent) { forward(event) }
    override func otherMouseDragged(with event: NSEvent) { forward(event) }
    override func mouseMoved(with event: NSEvent) { forward(event) }
    override func mouseEntered(with event: NSEvent) { forward(event) }
    override func mouseExited(with event: NSEvent) { forward(event) }

    private func forward(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .mouseEntered, .mouseExited:
            onMouse?(event)
        default:
            break
        }
    }
}
