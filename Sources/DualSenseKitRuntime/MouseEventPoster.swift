import AppKit
import CoreGraphics
import Foundation

public protocol MousePosting {
    func moveBy(dx: Double, dy: Double)
    func scroll(dx: Int32, dy: Int32)
}

public final class MouseEventPoster: MousePosting {
    private let permissionService: PermissionService

    public init(permissionService: PermissionService = PermissionService()) {
        self.permissionService = permissionService
    }

    public func moveBy(dx: Double, dy: Double) {
        guard permissionService.isAccessibilityTrusted() else { return }
        let current = NSEvent.mouseLocation
        let unionFrame = Self.unionScreenFrame()
        let nextAppKit = CGPoint(
            x: min(unionFrame.maxX, max(unionFrame.minX, current.x + dx)),
            y: min(unionFrame.maxY, max(unionFrame.minY, current.y + dy))
        )
        let mainMaxY = NSScreen.screens.first?.frame.maxY ?? unionFrame.maxY
        let nextQuartz = CGPoint(x: nextAppKit.x, y: mainMaxY - nextAppKit.y)
        CGWarpMouseCursorPosition(nextQuartz)

        // When a mouse button is held down, post a drag event so the window manager
        // treats the movement as a click-drag (required for window/file dragging).
        let pressed = NSEvent.pressedMouseButtons
        let eventType: CGEventType
        let mouseButton: CGMouseButton
        if pressed & (1 << 0) != 0 {
            eventType = .leftMouseDragged;  mouseButton = .left
        } else if pressed & (1 << 1) != 0 {
            eventType = .rightMouseDragged; mouseButton = .right
        } else if pressed & (1 << 2) != 0 {
            eventType = .otherMouseDragged; mouseButton = .center
        } else {
            eventType = .mouseMoved;        mouseButton = .left
        }
        CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: nextQuartz, mouseButton: mouseButton)?
            .post(tap: .cghidEventTap)
    }

    public func scroll(dx: Int32, dy: Int32) {
        guard permissionService.isAccessibilityTrusted() else { return }
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private static func screenFrame(containing point: CGPoint) -> CGRect? {
        NSScreen.screens.first { $0.frame.contains(point) }?.frame
    }

    private static func unionScreenFrame() -> CGRect {
        NSScreen.screens.map(\.frame).reduce(NSScreen.main?.frame ?? .zero) { $0.union($1) }
    }
}
