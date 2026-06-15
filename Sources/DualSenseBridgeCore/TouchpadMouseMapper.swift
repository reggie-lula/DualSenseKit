import Foundation

final class TouchpadMouseMapper {
    private let mousePoster: MousePosting
    private var lastPrimary: (x: Float, y: Float)?
    private var lastSecondary: (x: Float, y: Float)?

    init(mousePoster: MousePosting = MouseEventPoster()) {
        self.mousePoster = mousePoster
    }

    func resetPrimary() {
        lastPrimary = nil
    }

    func resetSecondary() {
        lastSecondary = nil
    }

    func primaryMoved(x: Float, y: Float, config: TouchpadConfig) {
        guard config.enabled else { return }
        defer { lastPrimary = (x, y) }
        guard let lastPrimary else { return }
        let rawDX = Double(x - lastPrimary.x)
        let rawDY = Double(y - lastPrimary.y)
        guard abs(rawDX) >= config.deadZone || abs(rawDY) >= config.deadZone else { return }
        let factor = config.accelerationEnabled ? max(1, (abs(rawDX) + abs(rawDY)) * 8) : 1
        let dx = rawDX * config.sensitivity * factor * (config.invertX ? -1 : 1)
        let dy = rawDY * config.sensitivity * factor * (config.invertY ? -1 : 1)
        mousePoster.moveBy(dx: dx, dy: dy)
    }

    func secondaryMoved(x: Float, y: Float, config: TouchpadConfig) {
        guard config.enabled else { return }
        defer { lastSecondary = (x, y) }
        guard let lastSecondary else { return }
        let rawDX = Double(x - lastSecondary.x)
        let rawDY = Double(y - lastSecondary.y)
        guard abs(rawDX) >= config.deadZone || abs(rawDY) >= config.deadZone else { return }
        mousePoster.scroll(
            dx: Int32(rawDX * config.scrollSensitivity * 100),
            dy: Int32(rawDY * config.scrollSensitivity * 100 * (config.invertY ? -1 : 1))
        )
    }
}
