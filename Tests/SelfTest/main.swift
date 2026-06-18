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

        let playAudio = PlayAudioRequest(path: "/tmp/test.wav", systemSoundName: nil, useMacFallback: true, outputDeviceID: 83)
        let decodedPlayAudio = try JSONDecoder().decode(PlayAudioRequest.self, from: try JSONEncoder().encode(playAudio))
        expect(decodedPlayAudio == playAudio, "PlayAudioRequest should round-trip through JSON")

        let recordAudio = RecordAudioRequest(inputDeviceID: 90, useMacFallback: true, durationMs: 3000)
        let decodedRecordAudio = try JSONDecoder().decode(RecordAudioRequest.self, from: try JSONEncoder().encode(recordAudio))
        expect(decodedRecordAudio == recordAudio, "RecordAudioRequest should round-trip through JSON")

        let audioVolume = AudioVolumeRequest(headphone: 0.65, speaker: 0.85)
        let decodedAudioVolume = try JSONDecoder().decode(AudioVolumeRequest.self, from: try JSONEncoder().encode(audioVolume))
        expect(decodedAudioVolume == audioVolume, "AudioVolumeRequest should round-trip through JSON")

        let systemVolume = SystemVolumeRequest(outputDeviceID: 83, volume: 0.5)
        let decodedSystemVolume = try JSONDecoder().decode(SystemVolumeRequest.self, from: try JSONEncoder().encode(systemVolume))
        expect(decodedSystemVolume == systemVolume, "SystemVolumeRequest should round-trip through JSON")

        let testTone = HIDAudioTestToneRequest(target: .speaker, enabled: true, durationMs: 3000)
        let decodedTestTone = try JSONDecoder().decode(HIDAudioTestToneRequest.self, from: try JSONEncoder().encode(testTone))
        expect(decodedTestTone == testTone, "HIDAudioTestToneRequest should round-trip through JSON")

        let captureStart = HIDCaptureStartRequest(durationMs: 5000)
        let decodedCaptureStart = try JSONDecoder().decode(HIDCaptureStartRequest.self, from: try JSONEncoder().encode(captureStart))
        expect(decodedCaptureStart == captureStart, "HIDCaptureStartRequest should round-trip through JSON")

        let audioDevices = AudioDevicesResponse(
            inputs: [],
            outputs: [],
            defaultInputID: nil,
            defaultOutputID: nil,
            dualSenseInput: nil,
            dualSenseOutput: nil,
            dualSenseAudioStatus: "no_dualsense_audio_endpoint",
            note: "test"
        )
        let decodedAudioDevices = try JSONDecoder().decode(AudioDevicesResponse.self, from: try JSONEncoder().encode(audioDevices))
        expect(decodedAudioDevices == audioDevices, "AudioDevicesResponse should round-trip through JSON")

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
        mapper.resetPrimary()
        mapper.primaryMoved(x: 0.8, y: 0.8, config: touchpad)
        expect(poster.moves.count == 1, "primary reset should make the next touch seed state")
        mapper.primaryMoved(x: 0.9, y: 0.8, config: touchpad)
        expect(poster.moves.count == 2, "movement after reset seed should post cursor delta")

        let timeoutPoster = RecordingMousePoster()
        let timeoutMapper = TouchpadMouseMapper(mousePoster: timeoutPoster, inactivityInterval: 0.03)
        timeoutMapper.primaryMoved(x: 0.1, y: 0.1, config: touchpad)
        timeoutMapper.primaryMoved(x: 0.2, y: 0.1, config: touchpad)
        expect(timeoutPoster.moves.count == 1, "movement before inactivity timeout should move cursor")
        Thread.sleep(forTimeInterval: 0.05)
        timeoutMapper.primaryMoved(x: 0.8, y: 0.8, config: touchpad)
        expect(timeoutPoster.moves.count == 1, "movement after inactivity timeout should only reseed state")
        timeoutMapper.primaryMoved(x: 0.9, y: 0.8, config: touchpad)
        expect(timeoutPoster.moves.count == 2, "movement after inactivity reseed should move cursor")
        expect(
            BridgeConfig.defaultMappings()[ButtonGesture(button: .touchpadButton, kind: .singleClick)] == [.mouseClick(.left)],
            "touchpad button single click should default to left mouse click"
        )

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
        fullInput[54] = 0x9a
        fullInput[55] = 0x07
        expect(DualSenseHIDService.parseSpecialButtons(report: fullInput) == 0x07, "full input special bits should parse")
        let parsedInput = DualSenseProtocol.parseInputReport(fullInput)
        expect(parsedInput?.motion?.gyroX == 0x1234, "gyro x should parse as little-endian Int16")
        expect(parsedInput?.motion?.gyroY == Int16.min, "gyro y should parse signed Int16")
        expect(parsedInput?.motion?.gyroZ == Int16.max, "gyro z should parse signed Int16")
        expect(parsedInput?.motion?.accelX == -2, "accel x should parse signed Int16")
        expect(parsedInput?.motion?.accelY == 2, "accel y should parse signed Int16")
        expect(parsedInput?.motion?.accelZ == -256, "accel z should parse signed Int16")
        expect(parsedInput?.motion?.timestamp == 0x12345678, "motion timestamp should parse little-endian UInt32")
        expect(parsedInput?.audioStatus?.rawStatus0 == 0x9a, "audio status0 should parse at DualSense status offset")
        expect(parsedInput?.audioStatus?.rawStatus1 == 0x07, "audio status1 should parse at DualSense status offset")
        expect(parsedInput?.audioStatus?.headphoneDetected == true, "headphone detect bit should parse")
        expect(parsedInput?.audioStatus?.microphoneDetected == true, "microphone detect bit should parse")
        expect(parsedInput?.audioStatus?.micMuted == true, "mic mute status bit should parse")
        expect(parsedInput?.audioStatus?.sourceConnection == .bluetooth, "bluetooth input should mark audio status source")

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

        var audioVolumeState = DualSenseOutputState()
        DualSenseProtocol.apply(.audioVolume(headphone: 166, speaker: 217), to: &audioVolumeState)
        let audioVolumeReport = DualSenseProtocol.bluetoothOutputReport(state: audioVolumeState)
        expect((audioVolumeReport[3] & 0x10) != 0, "audio volume report should enable headphone volume flag")
        expect((audioVolumeReport[3] & 0x20) != 0, "audio volume report should enable speaker volume flag")
        expect(audioVolumeReport[7] == 166, "audio volume report should set headphone volume byte")
        expect(audioVolumeReport[8] == 217, "audio volume report should set speaker volume byte")
        expect(audioVolumeReport[5] == 0 && audioVolumeReport[6] == 0, "audio volume report should not set motor bytes")
        expect(audioVolumeReport[46] == 0, "audio volume report should not set player LED bytes")

        let speakerWave = DualSenseProtocol.featureReportCommands(for: .waveOut(target: .speaker, enabled: true), connection: .usb)
        expect(speakerWave.count == 2, "speaker waveout enable should send setup and control commands")
        expect(speakerWave[0].reportID == 0x80, "waveout setup should use test command feature report")
        expect(speakerWave[0].payload.count == DualSenseProtocol.featureReportPayloadSize, "waveout setup payload should use fixed feature report size")
        expect(speakerWave[0].payload[0] == 0x06, "waveout setup should target audio test device")
        expect(speakerWave[0].payload[1] == 0x04, "waveout setup should use calibration verify action")
        expect(speakerWave[0].payload[4] == 0x08, "speaker waveout setup should set speaker parameter")
        expect(speakerWave[1].payload[1] == 0x02, "waveout control should use waveout action")
        expect(speakerWave[1].payload[2] == 0x01, "waveout control should enable test tone")

        let headphoneWave = DualSenseProtocol.featureReportCommands(for: .waveOut(target: .headphone, enabled: true), connection: .usb)
        expect(headphoneWave[0].payload[6] == 0x04, "headphone waveout setup should set headphone parameter 4")
        expect(headphoneWave[0].payload[8] == 0x06, "headphone waveout setup should set headphone parameter 6")

        let stopWave = DualSenseProtocol.featureReportCommands(for: .waveOut(target: .speaker, enabled: false), connection: .bluetooth)
        expect(stopWave.count == 1, "waveout disable should only send control command")
        expect(stopWave[0].payload[1] == 0x02, "waveout disable should use waveout action")
        expect(stopWave[0].payload[2] == 0x00, "waveout disable should clear enable flag")
        let expectedCRC = DualSenseProtocol.crc32(bytes: [0x53, 0x80] + Array(stopWave[0].payload.dropLast(4)))
        let actualCRC = UInt32(stopWave[0].payload[59])
            | (UInt32(stopWave[0].payload[60]) << 8)
            | (UInt32(stopWave[0].payload[61]) << 16)
            | (UInt32(stopWave[0].payload[62]) << 24)
        expect(actualCRC == expectedCRC, "bluetooth feature report should include CRC32")

        _ = AudioService().outputDevices()

        print("SelfTest passed")
    }
}
