import Foundation
import DualSenseKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class RecordingMousePoster: MousePosting {
    var moves: [(Double, Double)] = []
    var scrolls: [(Int32, Int32)] = []

    func moveBy(dx: Double, dy: Double) {
        moves.append((dx, dy))
    }

    func scroll(dx: Int32, dy: Int32) {
        scrolls.append((dx, dy))
    }
}

@main
struct SelfTest {
    static func main() throws {
        let config = BridgeConfig()
        let configData = try JSONEncoder().encode(config)
        let decodedConfig = try JSONDecoder().decode(BridgeConfig.self, from: configData)
        expect(decodedConfig == config, "BridgeConfig should round-trip through JSON")

        let rgb = RGBColorRequest(r: 255, g: 64, b: 0)
        let rgbData = try JSONEncoder().encode(rgb)
        let decodedRGB = try JSONDecoder().decode(RGBColorRequest.self, from: rgbData)
        expect(decodedRGB == rgb, "RGBColorRequest should round-trip through JSON")

        let playerLEDs = PlayerLEDRequest(mask: 31)
        let playerLEDData = try JSONEncoder().encode(playerLEDs)
        let decodedPlayerLEDs = try JSONDecoder().decode(PlayerLEDRequest.self, from: playerLEDData)
        expect(decodedPlayerLEDs == playerLEDs, "PlayerLEDRequest should round-trip through JSON")

        let micLED = MicMuteLEDRequest(on: true)
        let decodedMicLED = try JSONDecoder().decode(MicMuteLEDRequest.self, from: try JSONEncoder().encode(micLED))
        expect(decodedMicLED == micLED, "MicMuteLEDRequest should round-trip through JSON")

        let rumble = RumbleRequest(left: 0.25, right: 0.75, durationMs: 500)
        let decodedRumble = try JSONDecoder().decode(RumbleRequest.self, from: try JSONEncoder().encode(rumble))
        expect(decodedRumble == rumble, "RumbleRequest should round-trip through JSON")

        let triggers = TriggerRequest(
            left: TriggerSideRequest(mode: .feedback, startPosition: 0.1, strength: 0.5),
            right: TriggerSideRequest(mode: .off, startPosition: nil, strength: nil)
        )
        let decodedTriggers = try JSONDecoder().decode(TriggerRequest.self, from: try JSONEncoder().encode(triggers))
        expect(decodedTriggers == triggers, "TriggerRequest should round-trip through JSON")

        let executor = ActionExecutor(permissionService: PermissionService())
        expect(!executor.isShellCommandAllowed("say hello", shellConfig: ShellConfig()), "shell should be disabled by default")
        let exactShell = ShellConfig(enabled: true, allowedCommands: ["say hello"], allowedScriptDirectories: [])
        expect(executor.isShellCommandAllowed("say hello", shellConfig: exactShell), "exact shell whitelist should pass")
        let directoryShell = ShellConfig(enabled: true, allowedCommands: [], allowedScriptDirectories: ["~/Scripts"])
        expect(executor.isShellCommandAllowed("~/Scripts/notify.sh", shellConfig: directoryShell), "script directory whitelist should pass")

        let expectedToken = "test-token"
        expect(
            TokenService.isAuthorized(headers: ["authorization": "Bearer \(expectedToken)"], expectedToken: expectedToken),
            "bearer token should authorize"
        )
        expect(
            TokenService.isAuthorized(headers: ["x-dualsensebridge-token": expectedToken], expectedToken: expectedToken),
            "custom token header should authorize"
        )

        let eventBus = EventBus()
        eventBus.publish(BridgeEvent(type: "test.one", payload: [:]))
        eventBus.publish(BridgeEvent(type: "test.two", payload: [:]))
        expect(eventBus.recent(limit: 1).map(\.type) == ["test.two"], "recent events should return newest events")

        let poster = RecordingMousePoster()
        let mapper = TouchpadMouseMapper(mousePoster: poster)
        var touchpad = TouchpadConfig()
        touchpad.accelerationEnabled = false
        mapper.primaryMoved(x: 0.1, y: 0.1, config: touchpad)
        expect(poster.moves.isEmpty, "first touchpad movement should seed state")
        mapper.primaryMoved(x: 0.2, y: 0.0, config: touchpad)
        expect(poster.moves.count == 1, "second touchpad movement should post cursor delta")

        var emitted: [ButtonGesture] = []
        let recognizer = ButtonGestureRecognizer(
            configProvider: {
                GestureTimingConfig(
                    doubleClickWindowMilliseconds: 80,
                    longPressMilliseconds: 100,
                    triggerPressThreshold: 0.55,
                    triggerReleaseThreshold: 0.35
                )
            },
            emit: { emitted.append($0) }
        )
        recognizer.update(button: .buttonHome, pressed: true)
        recognizer.update(button: .buttonHome, pressed: false)
        Thread.sleep(forTimeInterval: 0.14)
        expect(emitted.contains(ButtonGesture(button: .buttonHome, kind: .singleClick)), "home single click should be emitted")

        emitted.removeAll()
        recognizer.update(button: .buttonHome, pressed: true)
        recognizer.update(button: .buttonHome, pressed: false)
        Thread.sleep(forTimeInterval: 0.02)
        recognizer.update(button: .buttonHome, pressed: true)
        recognizer.update(button: .buttonHome, pressed: false)
        Thread.sleep(forTimeInterval: 0.04)
        expect(emitted.contains(ButtonGesture(button: .buttonHome, kind: .doubleClick)), "home double click should be emitted")

        emitted.removeAll()
        recognizer.update(button: .buttonMicrophoneMute, pressed: true)
        Thread.sleep(forTimeInterval: 0.12)
        recognizer.update(button: .buttonMicrophoneMute, pressed: false)
        Thread.sleep(forTimeInterval: 0.04)
        expect(
            emitted.contains(ButtonGesture(button: .buttonMicrophoneMute, kind: .longPress)),
            "microphone mute long press should be emitted"
        )

        var bluetoothReport = Data(repeating: 0, count: 78)
        bluetoothReport[0] = 0x31
        bluetoothReport[11] = 0x07
        expect(DualSenseHIDService.parseSpecialButtons(report: bluetoothReport) == 0x07, "bluetooth special buttons should parse")
        let parsedButtons = DualSenseHIDService.pressedSpecialButtons(from: 0x07)
        expect(parsedButtons.contains { $0.0 == .buttonHome && $0.1 }, "home bit should parse")
        expect(parsedButtons.contains { $0.0 == .buttonMicrophoneMute && $0.1 }, "microphone mute bit should parse")

        var fullInput = Data(repeating: 0, count: 78)
        fullInput[0] = 0x31
        fullInput[9] = 0xf0
        fullInput[10] = 0xf0
        fullInput[11] = 0x07
        fullInput[17] = 0x34
        fullInput[18] = 0x12
        fullInput[19] = 0x00
        fullInput[20] = 0x80
        fullInput[21] = 0xff
        fullInput[22] = 0x7f
        fullInput[23] = 0xfe
        fullInput[24] = 0xff
        fullInput[25] = 0x02
        fullInput[26] = 0x00
        fullInput[27] = 0x00
        fullInput[28] = 0xff
        fullInput[29] = 0x78
        fullInput[30] = 0x56
        fullInput[31] = 0x34
        fullInput[32] = 0x12
        expect(DualSenseHIDService.parseSpecialButtons(report: fullInput) == 0x07, "full input special bits should parse")
        let parsedInput = DualSenseProtocol.parseInputReport(fullInput)
        expect(parsedInput?.motion?.gyroX == 0x1234, "gyro x should parse as little-endian Int16")
        expect(parsedInput?.motion?.gyroY == Int16.min, "gyro y should parse signed Int16")
        expect(parsedInput?.motion?.gyroZ == Int16.max, "gyro z should parse signed Int16")
        expect(parsedInput?.motion?.accelX == -2, "accel x should parse signed Int16")
        expect(parsedInput?.motion?.accelY == 2, "accel y should parse signed Int16")
        expect(parsedInput?.motion?.accelZ == -256, "accel z should parse signed Int16")
        expect(parsedInput?.motion?.timestamp == 0x12345678, "motion timestamp should parse little-endian UInt32")

        let outputReport = DualSenseHIDService.bluetoothOutputReport(playerLEDMask: 0x1f)
        expect(outputReport.count == 78, "player LED output report should use bluetooth report size")
        expect(outputReport[0] == 0x31, "player LED output report should use bluetooth output report id")
        expect((outputReport[4] & 0x10) != 0, "player LED output report should enable player indicator control")
        expect(outputReport[46] == 0x1f, "player LED output report should include masked LED value")
        expect(outputReport[5] == 0 && outputReport[6] == 0, "player LED output report should not set motor bytes")

        let rumbleReport = DualSenseHIDService.bluetoothOutputReport(leftMotor: 64, rightMotor: 192)
        expect(rumbleReport[3] == 0x03, "rumble report should enable compatible rumble flags")
        expect(rumbleReport[5] == 192, "rumble report should set right motor byte")
        expect(rumbleReport[6] == 64, "rumble report should set left motor byte")
        expect(rumbleReport[46] == 0, "rumble report should not set player LED bytes")

        _ = AudioService().outputDevices()

        print("SelfTest passed")
    }
}
