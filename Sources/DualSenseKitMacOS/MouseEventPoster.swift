import AppKit
import CoreGraphics
import Foundation

protocol MousePosting {
    func moveBy(dx: Double, dy: Double)
    func scroll(dx: Int32, dy: Int32)
}

final class MouseEventPoster: MousePosting {
    private let permissionService: PermissionService

    init(permissionService: PermissionService = PermissionService()) {
        self.permissionService = permissionService
    }

    func moveBy(dx: Double, dy: Double) {
        guard permissionService.isAccessibilityTrusted() else { return }
        let current = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let nextAppKit = CGPoint(x: current.x + dx, y: current.y + dy)
        let nextQuartz = CGPoint(x: nextAppKit.x, y: screenHeight - nextAppKit.y)
        CGWarpMouseCursorPosition(nextQuartz)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: nextQuartz, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func scroll(dx: Int32, dy: Int32) {
        guard permissionService.isAccessibilityTrusted() else { return }
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }
}
