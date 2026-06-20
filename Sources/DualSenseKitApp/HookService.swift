import DualSenseKitRuntime
import Foundation

final class HookService: @unchecked Sendable {
    private let controllerService: ControllerService
    private let lightService: LightService
    private let queue = DispatchQueue(label: "DualSenseKitApp.HookService")
    private var lightTimer: DispatchSourceTimer?
    private var rumbleTimer: DispatchSourceTimer?
    private var lightPulseOn = false
    private var rumblePulseOn = false
    private var breathPhase = 0

    init(controllerService: ControllerService, lightService: LightService) {
        self.controllerService = controllerService
        self.lightService = lightService
    }

    @discardableResult
    func execute(_ hook: HookDefinition) -> HookExecutionResult {
        guard hook.enabled else {
            return HookExecutionResult(ok: false, message: "hook_disabled")
        }
        var messages: [String] = []
        var ok = true
        for command in hook.commands {
            let result = execute(command)
            ok = ok && result.ok
            messages.append(result.message)
        }
        return HookExecutionResult(ok: ok, message: messages.isEmpty ? "no_commands" : messages.joined(separator: ","))
    }

    func stop() {
        stopLight(reset: true)
        stopRumble(reset: true)
    }

    private func execute(_ command: HookCommand) -> HookExecutionResult {
        switch command.kind {
        case .heartbeatRumble:
            startHeartbeat(command)
            return HookExecutionResult(ok: true, message: "heartbeat_started")
        case .playerLEDs:
            let ok = controllerService.setPlayerLEDs(mask: command.playerMask, brightness: command.playerBrightness)
            return HookExecutionResult(ok: ok, message: ok ? "player_leds_set" : "player_leds_failed")
        case .solidLightbar:
            stopLight(reset: false)
            let ok = setLight(command.colorA, brightness: command.brightness)
            return HookExecutionResult(ok: ok, message: ok ? "lightbar_set" : "lightbar_failed")
        case .breathingLightbar:
            startBreathing(command)
            return HookExecutionResult(ok: true, message: "breathing_started")
        case .alternatingLightbar:
            startAlternating(command)
            return HookExecutionResult(ok: true, message: "alternating_started")
        case .stopEffects:
            switch command.stopChannel {
            case .light:
                stopLight(reset: command.resetOnStop)
            case .rumble:
                stopRumble(reset: command.resetOnStop)
            case .all:
                stopLight(reset: command.resetOnStop)
                stopRumble(reset: command.resetOnStop)
            }
            return HookExecutionResult(ok: true, message: "effects_stopped")
        }
    }

    private func startHeartbeat(_ command: HookCommand) {
        stopRumble(reset: false)
        rumblePulseOn = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(50, command.intervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.rumblePulseOn.toggle()
            let heavy = command.strength
            let light = self.rumblePulseOn ? max(0.1, command.strength * 0.55) : command.strength
            _ = self.controllerService.setRumble(RumbleRequest(
                left: heavy,
                right: light,
                durationMs: command.durationMs
            ))
        }
        rumbleTimer = timer
        timer.resume()
    }

    private func startBreathing(_ command: HookCommand) {
        stopLight(reset: false)
        breathPhase = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(50, command.intervalMs / 24)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.breathPhase = (self.breathPhase + 1) % 48
            let angle = Double(self.breathPhase) / 48.0 * .pi * 2
            let level = Float((sin(angle - .pi / 2) + 1) / 2)
            _ = self.setLight(command.colorA, brightness: max(0.05, command.brightness * level))
        }
        lightTimer = timer
        timer.resume()
    }

    private func startAlternating(_ command: HookCommand) {
        stopLight(reset: false)
        lightPulseOn = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(50, command.intervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lightPulseOn.toggle()
            let color = self.lightPulseOn ? command.colorA : command.colorB
            _ = self.setLight(color, brightness: command.brightness)
        }
        lightTimer = timer
        timer.resume()
    }

    private func stopLight(reset: Bool) {
        queue.sync {
            lightTimer?.cancel()
            lightTimer = nil
            lightPulseOn = false
            breathPhase = 0
        }
        if reset {
            _ = setLight(HookColor(r: 0, g: 0, b: 0), brightness: 0)
        }
    }

    private func stopRumble(reset: Bool) {
        queue.sync {
            rumbleTimer?.cancel()
            rumbleTimer = nil
            rumblePulseOn = false
        }
        if reset {
            _ = controllerService.setRumble(RumbleRequest(left: 0, right: 0, durationMs: nil))
            _ = controllerService.stopEffectPattern()
        }
    }

    @discardableResult
    private func setLight(_ color: HookColor, brightness: Float) -> Bool {
        let request = LightbarRequest(r: color.r, g: color.g, b: color.b, brightness: brightness)
        // Hook light commands must not touch player LEDs. HID output preserves the
        // controller output state, while GameController's light API may refresh
        // the whole light group on some firmware versions.
        return controllerService.setLightbar(request) || lightService.setLightbar(request)
    }
}

struct HookExecutionResult {
    var ok: Bool
    var message: String
}
