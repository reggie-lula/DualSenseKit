import Foundation

final class TouchpadMouseMapper {
    private let mousePoster: MousePosting
    private var lastPrimary: (x: Float, y: Float)?
    private var lastSecondary: (x: Float, y: Float)?
    private var lastPrimaryUpdate: Date?
    private var lastSecondaryUpdate: Date?
    private var secondaryActive = false
    private let inactivityInterval: TimeInterval

    init(mousePoster: MousePosting = MouseEventPoster(), inactivityInterval: TimeInterval = 0.15) {
        self.mousePoster = mousePoster
        self.inactivityInterval = inactivityInterval
    }

    func resetPrimary() {
        lastPrimary = nil
        lastPrimaryUpdate = nil
    }

    func resetSecondary() {
        lastSecondary = nil
        lastSecondaryUpdate = nil
        secondaryActive = false
        resetPrimary()
    }

    func secondaryBegan(x: Float, y: Float) {
        secondaryActive = true
        lastSecondary = (x, y)
        lastSecondaryUpdate = Date()
        resetPrimary()
    }

    func primaryMoved(x: Float, y: Float, config: TouchpadConfig) {
        guard config.enabled else { return }
        guard !secondaryActive else {
            resetPrimary()
            return
        }
        let now = Date()
        defer {
            lastPrimary = (x, y)
            lastPrimaryUpdate = now
        }
        guard let lastPrimary,
              let lastPrimaryUpdate,
              now.timeIntervalSince(lastPrimaryUpdate) <= inactivityInterval else { return }
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
        secondaryActive = true
        resetPrimary()
        let now = Date()
        defer {
            lastSecondary = (x, y)
            lastSecondaryUpdate = now
        }
        guard let lastSecondary,
              let lastSecondaryUpdate,
              now.timeIntervalSince(lastSecondaryUpdate) <= inactivityInterval else { return }
        let rawDX = Double(x - lastSecondary.x)
        let rawDY = Double(y - lastSecondary.y)
        guard abs(rawDX) >= config.deadZone || abs(rawDY) >= config.deadZone else { return }
        mousePoster.scroll(
            dx: Int32(rawDX * config.scrollSensitivity * 100),
            dy: Int32(rawDY * config.scrollSensitivity * 100 * (config.invertY ? -1 : 1))
        )
    }
}
