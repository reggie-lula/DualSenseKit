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
    func execute(_ hook: HookDefinition, source: String = "unspecified") -> HookExecutionResult {
        DiagnosticsLog.write(event: "hook.execute", [
            "source": source,
            "hook": hook.slug,
            "enabled": "\(hook.enabled)",
            "commandCount": "\(hook.commands.count)"
        ])
        guard hook.enabled else {
            return HookExecutionResult(ok: false, message: "hook_disabled")
        }
        var messages: [String] = []
        var ok = true
        for command in hook.commands {
            let result = execute(command, source: source)
            ok = ok && result.ok
            messages.append(result.message)
        }
        DiagnosticsLog.write(event: "hook.execute.result", [
            "source": source,
            "hook": hook.slug,
            "ok": "\(ok)",
            "message": messages.joined(separator: ",")
        ])
        return HookExecutionResult(ok: ok, message: messages.isEmpty ? "no_commands" : messages.joined(separator: ","))
    }

    func stop() {
        stopLight(reset: true)
        stopRumble(reset: true)
    }

    func stopContinuousEffects(reset: Bool) {
        stopLight(reset: reset)
        stopRumble(reset: reset)
    }

    private func execute(_ command: HookCommand, source: String) -> HookExecutionResult {
        withOutputSource(source) {
            switch command.kind {
            case .heartbeatRumble:
                startHeartbeat(command, source: source)
                return HookExecutionResult(ok: true, message: "heartbeat_started")
            case .playerLEDs:
                let ok = controllerService.setPlayerLEDs(mask: command.playerMask, brightness: command.playerBrightness)
                return HookExecutionResult(ok: ok, message: ok ? "player_leds_set" : "player_leds_failed")
            case .solidLightbar:
                stopLight(reset: false)
                let result = setLightOutcome(command.colorA, brightness: command.brightness)
                return HookExecutionResult(ok: result.ok, message: result.message)
            case .breathingLightbar:
                startBreathing(command, source: source)
                return HookExecutionResult(ok: true, message: "breathing_started")
            case .alternatingLightbar:
                startAlternating(command, source: source)
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
    }

    private func startHeartbeat(_ command: HookCommand, source: String) {
        stopRumble(reset: false)
        rumblePulseOn = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(50, command.intervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.rumblePulseOn.toggle()
            let heavy = command.strength
            let light = self.rumblePulseOn ? max(0.1, command.strength * 0.55) : command.strength
            self.withOutputSource(source) {
                _ = self.controllerService.setRumble(RumbleRequest(
                    left: heavy,
                    right: light,
                    durationMs: command.durationMs
                ))
            }
        }
        rumbleTimer = timer
        timer.resume()
    }

    private func startBreathing(_ command: HookCommand, source: String) {
        stopLight(reset: false)
        breathPhase = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(50, command.intervalMs / 24)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.breathPhase = (self.breathPhase + 1) % 48
            let angle = Double(self.breathPhase) / 48.0 * .pi * 2
            let level = Float((sin(angle - .pi / 2) + 1) / 2)
            self.withOutputSource(source) {
                _ = self.setLight(command.colorA, brightness: max(0.05, command.brightness * level))
            }
        }
        lightTimer = timer
        timer.resume()
    }

    private func startAlternating(_ command: HookCommand, source: String) {
        stopLight(reset: false)
        lightPulseOn = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(50, command.intervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lightPulseOn.toggle()
            let color = self.lightPulseOn ? command.colorA : command.colorB
            self.withOutputSource(source) {
                _ = self.setLight(color, brightness: command.brightness)
            }
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
        setLightOutcome(color, brightness: brightness).ok
    }

    private func setLightOutcome(_ color: HookColor, brightness: Float) -> HookExecutionResult {
        let request = LightbarRequest(r: color.r, g: color.g, b: color.b, brightness: brightness)
        // Hook light commands must not touch player LEDs. HID output preserves the
        // controller output state, while GameController's light API may refresh
        // the whole light group on some firmware versions.
        if controllerService.setLightbar(request) {
            return HookExecutionResult(ok: true, message: "lightbar_set_hid")
        }
        if lightService.setLightbar(request) {
            return HookExecutionResult(ok: true, message: "lightbar_set_gamecontroller")
        }
        return HookExecutionResult(ok: false, message: "lightbar_failed")
    }

    @discardableResult
    private func withOutputSource<T>(_ source: String, _ body: () -> T) -> T {
        controllerService.setOutputSource(source)
        defer { controllerService.setOutputSource(nil) }
        return body()
    }
}

struct HookExecutionResult {
    var ok: Bool
    var message: String
}
