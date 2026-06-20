import Foundation

public final class TouchpadMouseMapper {
    private let mousePoster: MousePosting
    private var lastPrimary: (x: Float, y: Float)?
    private var lastSecondary: (x: Float, y: Float)?
    private var lastPrimaryUpdate: Date?
    private var lastSecondaryUpdate: Date?
    private var smoothedPrimaryDX: Double = 0
    private var smoothedPrimaryDY: Double = 0
    private var secondaryActive = false
    private let inactivityInterval: TimeInterval

    public init(mousePoster: MousePosting = MouseEventPoster(), inactivityInterval: TimeInterval = 0.15) {
        self.mousePoster = mousePoster
        self.inactivityInterval = inactivityInterval
    }

    public func resetPrimary() {
        lastPrimary = nil
        lastPrimaryUpdate = nil
        smoothedPrimaryDX = 0
        smoothedPrimaryDY = 0
    }

    public func resetSecondary() {
        lastSecondary = nil
        lastSecondaryUpdate = nil
        secondaryActive = false
        resetPrimary()
    }

    public func secondaryBegan(x: Float, y: Float) {
        secondaryActive = true
        lastSecondary = (x, y)
        lastSecondaryUpdate = Date()
        resetPrimary()
    }

    public func primaryMoved(x: Float, y: Float, config: TouchpadConfig) {
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
        let magnitude = abs(rawDX) + abs(rawDY)
        let factor = config.accelerationEnabled ? min(2.4, max(0.65, 0.65 + magnitude * 5)) : 1
        let targetDX = rawDX * config.sensitivity * factor * (config.invertX ? -1 : 1)
        let targetDY = rawDY * config.sensitivity * factor * (config.invertY ? -1 : 1)
        let smoothing = 0.45
        smoothedPrimaryDX = smoothedPrimaryDX * (1 - smoothing) + targetDX * smoothing
        smoothedPrimaryDY = smoothedPrimaryDY * (1 - smoothing) + targetDY * smoothing
        guard abs(smoothedPrimaryDX) >= 0.35 || abs(smoothedPrimaryDY) >= 0.35 else { return }
        mousePoster.moveBy(dx: smoothedPrimaryDX, dy: smoothedPrimaryDY)
    }

    public func secondaryMoved(x: Float, y: Float, config: TouchpadConfig) {
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
