import Foundation
import GameController

final class LightService: @unchecked Sendable {
    private weak var controllerService: ControllerService?
    private let eventBus: EventBus?
    private let queue = DispatchQueue(label: "DualSenseKitDemo.LightService")
    private var lightingState = LightingState()
    private var animationWorkItem: DispatchWorkItem?

    init(controllerService: ControllerService, eventBus: EventBus? = nil) {
        self.controllerService = controllerService
        self.eventBus = eventBus
    }

    func state() -> LightingState {
        queue.sync { lightingState }
    }

    @discardableResult
    func apply(_ state: LightingState) -> Bool {
        let next = sanitized(state)
        animationWorkItem?.cancel()
        queue.sync {
            lightingState = next
        }
        if next.animation.enabled {
            startLightbarAnimation(periodMs: next.animation.periodMs)
        }
        return applyCurrentState()
    }

    @discardableResult
    func setColor(_ color: RGBColorRequest) -> Bool {
        setLightbar(LightbarRequest(
            r: color.r,
            g: color.g,
            b: color.b,
            brightness: state().lightbar.brightness
        ))
    }

    @discardableResult
    func setLightbar(_ request: LightbarRequest) -> Bool {
        let newState = queue.sync { () -> LightingState in
            var next = lightingState
            next.lightbar.r = request.r ?? next.lightbar.r
            next.lightbar.g = request.g ?? next.lightbar.g
            next.lightbar.b = request.b ?? next.lightbar.b
            next.lightbar.brightness = clamp01(request.brightness ?? next.lightbar.brightness)
            lightingState = next
            return next
        }
        return applyLightbar(newState.lightbar)
    }

    @discardableResult
    func setPlayerLEDs(_ request: PlayerLEDRequest) -> Bool {
        let newState = queue.sync { () -> LightingState in
            var next = lightingState
            next.playerLEDs.mask = request.mask & 0x1f
            if let brightnessLinear = request.brightnessLinear {
                next.playerLEDs.brightnessLinear = clamp01(brightnessLinear)
                next.playerLEDs.brightness = UInt8(clamping: Int((1 - clamp01(brightnessLinear)) * 2))
            } else if let brightness = request.brightness {
                next.playerLEDs.brightness = min(brightness, 2)
                next.playerLEDs.brightnessLinear = nil
            }
            lightingState = next
            return next
        }
        return controllerService?.setPlayerLEDs(mask: newState.playerLEDs.mask, brightness: nil) ?? false
    }

    @discardableResult
    func setMicLED(_ request: MicMuteLEDRequest) -> Bool {
        let mode = request.mode ?? (request.on == true ? .on : .off)
        queue.sync {
            lightingState.micLED.mode = mode
        }
        return controllerService?.setMicMuteLED(MicMuteLEDRequest(on: nil, mode: mode)) ?? false
    }

    func setAnimation(_ request: LightingAnimationRequest) -> LightingState {
        animationWorkItem?.cancel()
        let period = max(300, min(request.periodMs ?? 1600, 10000))
        queue.sync {
            lightingState.animation = LightingAnimationState(
                enabled: request.enabled,
                target: request.target ?? "lightbar",
                periodMs: period
            )
        }
        if request.enabled {
            startLightbarAnimation(periodMs: period)
        }
        return state()
    }

    func resetEffects() {
        animationWorkItem?.cancel()
        queue.sync {
            lightingState.animation.enabled = false
            lightingState.playerLEDs.mask = 0
            lightingState.micLED.mode = .off
        }
        _ = controllerService?.setPlayerLEDs(mask: 0, brightness: nil)
        _ = controllerService?.setMicMuteLED(MicMuteLEDRequest(on: nil, mode: .off))
    }

    func probePlayerLEDs(_ request: PlayerLEDProbeRequest) -> PlayerLEDProbeResult {
        let start = request.start ?? 0
        let end = request.end ?? 255
        let step = max(1, request.step ?? 16)
        let dwell = max(20, min(request.dwellMs ?? 80, 1000))
        let mask = (request.mask ?? max(state().playerLEDs.mask, 0x04)) & 0x1f
        var tested: [UInt8] = []
        var value = start
        while value <= end {
            tested.append(value)
            _ = controllerService?.setPlayerLEDs(mask: mask, brightness: value)
            eventBus?.publish(BridgeEvent(type: "light.playerLEDs.probe", payload: [
                "brightness": "\(value)",
                "mask": "\(mask)"
            ]))
            Thread.sleep(forTimeInterval: Double(dwell) / 1000)
            if UInt16(value) + UInt16(step) > UInt16(UInt8.max) { break }
            value += step
            if value == 0 { break }
        }
        _ = setPlayerLEDs(PlayerLEDRequest(mask: state().playerLEDs.mask, brightness: state().playerLEDs.brightness))
        return PlayerLEDProbeResult(
            testedValues: tested,
            linearBrightnessSupported: false,
            colorSupported: false,
            note: "Probe sends only the documented player LED brightness byte. Current SDK treats confirmed behavior as three-level white indicators until manual observation proves otherwise."
        )
    }

    private func applyCurrentState() -> Bool {
        let current = state()
        let lightbarOK = applyLightbar(current.lightbar)
        let playerOK = controllerService?.setPlayerLEDs(mask: current.playerLEDs.mask, brightness: nil) ?? false
        let micOK = controllerService?.setMicMuteLED(MicMuteLEDRequest(on: nil, mode: current.micLED.mode)) ?? false
        return lightbarOK || playerOK || micOK
    }

    private func applyLightbar(_ lightbar: LightbarState) -> Bool {
        if controllerService?.setLightbar(LightbarRequest(
            r: lightbar.r,
            g: lightbar.g,
            b: lightbar.b,
            brightness: lightbar.brightness
        )) == true {
            return true
        }
        guard let light = controllerService?.connectedController?.light else { return false }
        light.color = GCColor(
            red: Float(lightbar.r) / 255 * lightbar.brightness,
            green: Float(lightbar.g) / 255 * lightbar.brightness,
            blue: Float(lightbar.b) / 255 * lightbar.brightness
        )
        return true
    }

    private func startLightbarAnimation(periodMs: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.runLightbarAnimation(periodMs: periodMs)
        }
        animationWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    private func runLightbarAnimation(periodMs: Int) {
        var phase: Double = 0
        while !(animationWorkItem?.isCancelled ?? true), state().animation.enabled {
            var current = state().lightbar
            let baseBrightness = max(0.05, current.brightness)
            let scale = Float((sin(phase) + 1) / 2) * baseBrightness
            current.brightness = scale
            _ = applyLightbar(current)
            Thread.sleep(forTimeInterval: 0.05)
            phase += (2 * .pi) / (Double(periodMs) / 50)
        }
    }

    private func sanitized(_ state: LightingState) -> LightingState {
        var copy = state
        copy.lightbar.brightness = clamp01(copy.lightbar.brightness)
        copy.playerLEDs.mask &= 0x1f
        copy.playerLEDs.brightness = min(copy.playerLEDs.brightness, 2)
        copy.playerLEDs.brightnessLinear = copy.playerLEDs.brightnessLinear.map(clamp01)
        copy.playerLEDs.linearBrightnessSupported = false
        copy.playerLEDs.colorSupported = false
        copy.animation.periodMs = max(300, min(copy.animation.periodMs, 10000))
        return copy
    }

    private func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}
