import Foundation
import DualSenseKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectBluetoothCRC(_ report: Data, _ message: String) {
    let expected = DualSenseProtocol.crc32(bytes: [0xa2] + report.dropLast(4))
    let actual = UInt32(report[74])
        | (UInt32(report[75]) << 8)
        | (UInt32(report[76]) << 16)
        | (UInt32(report[77]) << 24)
    expect(actual == expected, message)
}

private func makeBluetoothOutputReport(for state: DualSenseOutputState, sequence: UInt8 = 0) -> Data {
    DualSenseHIDService.outputReport(state: state, transport: "Bluetooth", sequence: sequence)
}

private func usbReport(for state: DualSenseOutputState) -> Data {
    DualSenseHIDService.outputReport(state: state, transport: "USB")
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
        expect(DualSenseHIDService.parseSpecialButtons(report: fullInput) == 0x07, "full input special bits should parse")

        let outputReport = DualSenseHIDService.bluetoothOutputReport(playerLEDMask: 0x1f)
        expect(outputReport.count == 78, "player LED output report should use bluetooth report size")
        expect(outputReport[0] == 0x31, "player LED output report should use bluetooth output report id")
        expect(outputReport[4] == 0x10, "player LED output report should only enable player indicator control")
        expect(outputReport[4] != 0xf7, "player LED output report should not carry stale validFlag1")
        expect((outputReport[41] & 0x01) == 0, "plain player LED output should not set brightness control")
        expect(outputReport[45] == 0, "plain player LED output should not write brightness")
        expect(outputReport[46] == 0x1f, "player LED output report should include masked LED value")
        expect(outputReport[5] == 0 && outputReport[6] == 0, "player LED output report should not set motor bytes")
        expectBluetoothCRC(outputReport, "player LED bluetooth report should include a valid CRC")

        var playerLEDState = DualSenseOutputState()
        DualSenseProtocol.apply(.playerLEDs(mask: 0x1f), to: &playerLEDState)
        let usbPlayerLEDReport = usbReport(for: playerLEDState)
        expect(usbPlayerLEDReport.count == 48, "player LED USB report should use USB report size")
        expect(usbPlayerLEDReport[0] == 0x02, "player LED USB report should use USB output report id")
        expect(usbPlayerLEDReport[2] == 0x10, "player LED USB report should only enable player indicator control")
        expect(usbPlayerLEDReport[2] != 0xf7, "player LED USB report should not carry stale validFlag1")
        expect((usbPlayerLEDReport[39] & 0x01) == 0, "plain player LED USB report should not set brightness control")
        expect(usbPlayerLEDReport[43] == 0, "plain player LED USB report should not write brightness")
        expect(usbPlayerLEDReport[44] == 0x1f, "player LED USB report should include masked LED value")

        var unsafeBrightnessState = DualSenseOutputState()
        DualSenseProtocol.apply(.playerLEDs(mask: 0x04, brightness: 255), to: &unsafeBrightnessState)
        let clampedBrightnessReport = makeBluetoothOutputReport(for: unsafeBrightnessState, sequence: 3)
        expect((clampedBrightnessReport[41] & 0x01) != 0, "brightness report should set brightness control")
        expect(clampedBrightnessReport[45] == 2, "player LED brightness should be clamped to the safe 0...2 range")
        expect(clampedBrightnessReport[46] == 0x04, "brightness clamp should preserve player LED mask")
        expectBluetoothCRC(clampedBrightnessReport, "clamped brightness bluetooth report should include a valid CRC")

        var lightbarState = DualSenseOutputState()
        DualSenseProtocol.apply(.lightbar(red: 12, green: 34, blue: 56, brightness: nil), to: &lightbarState)
        let lightbarReport = makeBluetoothOutputReport(for: lightbarState, sequence: 4)
        expect(lightbarReport[4] == 0x04, "lightbar report should only enable lightbar control")
        expect(lightbarReport[4] != 0xf7, "lightbar report should not carry stale validFlag1")
        expect(lightbarReport[47] == 12 && lightbarReport[48] == 34 && lightbarReport[49] == 56, "lightbar report should write RGB bytes")
        expect(lightbarReport[46] == 0, "fresh lightbar report should not carry player LED mask")
        expect((lightbarReport[41] & 0x01) == 0, "fresh lightbar report should not set player brightness control")
        expectBluetoothCRC(lightbarReport, "lightbar bluetooth report should include a valid CRC")

        let usbLightbarReport = usbReport(for: lightbarState)
        expect(usbLightbarReport[0] == 0x02, "lightbar USB report should use USB output report id")
        expect(usbLightbarReport[2] == 0x04, "lightbar USB report should only enable lightbar control")
        expect(usbLightbarReport[45] == 12 && usbLightbarReport[46] == 34 && usbLightbarReport[47] == 56, "lightbar USB report should write RGB bytes")
        expect(usbLightbarReport[44] == 0, "fresh USB lightbar report should not carry player LED mask")

        var micState = DualSenseOutputState()
        DualSenseProtocol.apply(.micMuteLED(control: 2), to: &micState)
        let micReport = makeBluetoothOutputReport(for: micState, sequence: 5)
        expect(micReport[4] == 0x01, "mic LED report should only enable mic LED control")
        expect(micReport[4] != 0xf7, "mic LED report should not carry stale validFlag1")
        expect(micReport[11] == 2, "mic LED report should write breathe control")
        expect(micReport[46] == 0, "mic LED report should not carry player LED mask")
        expect(micReport[47] == 0 && micReport[48] == 0 && micReport[49] == 0, "mic LED report should not carry lightbar RGB")
        expectBluetoothCRC(micReport, "mic LED bluetooth report should include a valid CRC")

        let usbMicReport = usbReport(for: micState)
        expect(usbMicReport[0] == 0x02, "mic LED USB report should use USB output report id")
        expect(usbMicReport[2] == 0x01, "mic LED USB report should only enable mic LED control")
        expect(usbMicReport[9] == 2, "mic LED USB report should write breathe control")

        let rumbleReport = DualSenseHIDService.bluetoothOutputReport(leftMotor: 192, rightMotor: 64)
        expect(rumbleReport[3] == 0x03, "rumble report should enable compatible rumble flags")
        expect(rumbleReport[4] == 0, "rumble report should not set LED valid flags")
        expect(rumbleReport[5] == 64, "rumble report should set light/right motor byte")
        expect(rumbleReport[6] == 192, "rumble report should set heavy/left motor byte")
        expect(rumbleReport[46] == 0, "rumble report should not set player LED bytes")
        expect(rumbleReport[47] == 0 && rumbleReport[48] == 0 && rumbleReport[49] == 0, "fresh rumble report should not carry lightbar RGB")
        expectBluetoothCRC(rumbleReport, "rumble bluetooth report should include a valid CRC")

        var rumbleState = DualSenseOutputState()
        DualSenseProtocol.apply(.rumble(leftMotor: 192, rightMotor: 64), to: &rumbleState)
        let usbRumbleReport = usbReport(for: rumbleState)
        expect(usbRumbleReport[0] == 0x02, "rumble USB report should use USB output report id")
        expect(usbRumbleReport[1] == 0x03, "rumble USB report should enable compatible rumble flags")
        expect(usbRumbleReport[2] == 0, "rumble USB report should not set LED valid flags")
        expect(usbRumbleReport[3] == 64, "rumble USB report should set light/right motor byte")
        expect(usbRumbleReport[4] == 192, "rumble USB report should set heavy/left motor byte")
        expect(usbRumbleReport[44] == 0, "fresh USB rumble report should not carry player LED mask")
        expect(usbRumbleReport[45] == 0 && usbRumbleReport[46] == 0 && usbRumbleReport[47] == 0, "fresh USB rumble report should not carry lightbar RGB")

        _ = AudioService().outputDevices()

        print("SelfTest passed")
    }
}
