import Foundation

public final class StickMouseMapper {
    private let mousePoster: MousePosting
    private let deadZone: Double
    private let maxStep: Double

    public init(mousePoster: MousePosting = MouseEventPoster(), deadZone: Double = 0.15, maxStep: Double = 22) {
        self.mousePoster = mousePoster
        self.deadZone = deadZone
        self.maxStep = maxStep
    }

    @discardableResult
    public func move(leftStickX x: Float, leftStickY y: Float, config: TouchpadConfig) -> Bool {
        move(stickX: x, stickY: y, enabled: config.leftStickMouseEnabled, config: config)
    }

    @discardableResult
    public func move(rightStickX x: Float, rightStickY y: Float, config: TouchpadConfig) -> Bool {
        move(stickX: x, stickY: y, enabled: config.rightStickMouseEnabled, config: config)
    }

    @discardableResult
    private func move(stickX x: Float, stickY y: Float, enabled: Bool, config: TouchpadConfig) -> Bool {
        guard enabled else { return false }
        let normalizedX = normalizedAxis(Double(x))
        let normalizedY = normalizedAxis(Double(y))
        guard normalizedX != 0 || normalizedY != 0 else { return false }

        let sensitivityScale = max(0.05, config.sensitivity / 900)
        let dx = normalizedX * maxStep * sensitivityScale * (config.invertX ? -1 : 1)
        let dy = normalizedY * maxStep * sensitivityScale * (config.invertY ? -1 : 1)
        mousePoster.moveBy(dx: dx, dy: dy)
        return true
    }

    private func normalizedAxis(_ value: Double) -> Double {
        let clamped = min(1, max(-1, value))
        let magnitude = abs(clamped)
        guard magnitude > deadZone else { return 0 }
        let adjusted = (magnitude - deadZone) / (1 - deadZone)
        let curved = adjusted * adjusted
        return (clamped < 0 ? -1 : 1) * curved
    }
}
