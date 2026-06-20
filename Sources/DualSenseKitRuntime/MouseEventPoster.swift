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
        let screenFrame = Self.screenFrame(containing: current) ?? Self.unionScreenFrame()
        let nextAppKit = CGPoint(
            x: min(screenFrame.maxX - 1, max(screenFrame.minX, current.x + dx)),
            y: min(screenFrame.maxY - 1, max(screenFrame.minY, current.y + dy))
        )
        let mainMaxY = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        let nextQuartz = CGPoint(x: nextAppKit.x, y: mainMaxY - nextAppKit.y)
        CGWarpMouseCursorPosition(nextQuartz)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: nextQuartz, mouseButton: .left)?
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
