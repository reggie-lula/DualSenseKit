import AppKit
import AVFoundation
import CoreAudio
import Foundation

final class AudioService: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    func capability() -> AudioCapability {
        if dualSenseOutputDevice() != nil {
            return .dualSenseOutputAvailable
        }
        return .unsupported
    }

    func dualSenseOutputDevice() -> AudioOutputDevice? {
        outputDevices().first { device in
            isDualSenseAudio(name: device.name, uid: device.uid)
        }
    }

    func outputDevices() -> [AudioOutputDevice] {
        audioDeviceIDs()
            .filter { hasOutputStreams(deviceID: $0) }
            .map { AudioOutputDevice(id: $0, name: deviceName(deviceID: $0), uid: deviceUID(deviceID: $0)) }
    }

    func inputDevices() -> [AudioInputDevice] {
        audioDeviceIDs()
            .filter { hasInputStreams(deviceID: $0) }
            .map { AudioInputDevice(id: $0, name: deviceName(deviceID: $0), uid: deviceUID(deviceID: $0)) }
    }

    func dualSenseInputDevice() -> AudioInputDevice? {
        inputDevices().first { device in
            isDualSenseAudio(name: device.name, uid: device.uid)
        }
    }

    func devices() -> AudioDevicesResponse {
        AudioDevicesResponse(
            outputs: outputDevices(),
            inputs: inputDevices(),
            dualSenseOutput: dualSenseOutputDevice(),
            dualSenseInput: dualSenseInputDevice(),
            virtualDriver: driverStatus()
        )
    }

    func driverStatus() -> AudioDriverStatus {
        let outputPresent = outputDevices().contains { $0.name == "DualSenseKit Speaker" }
        let inputPresent = inputDevices().contains { $0.name == "DualSenseKit Microphone" }
        let installed = outputPresent || inputPresent
        let hasTransport = dualSenseOutputDevice() != nil || dualSenseInputDevice() != nil
        return AudioDriverStatus(
            installed: installed,
            active: installed && hasTransport,
            authorizationRequired: !installed,
            outputDeviceName: "DualSenseKit Speaker",
            inputDeviceName: "DualSenseKit Microphone",
            bridgeStatus: hasTransport ? "dualSense_audio_transport_available" : "no_dualsense_audio_transport",
            note: "Virtual audio requires an AudioDriverKit/System Extension target, signing, and user approval. The demo reports status but does not silently install a driver."
        )
    }

    func driverInstallGuide() -> AudioDriverInstallGuide {
        AudioDriverInstallGuide(
            title: "DualSenseKit virtual audio driver",
            steps: [
                "Create a DriverKit AudioDriverKit extension that publishes DualSenseKit Speaker and DualSenseKit Microphone.",
                "Sign the containing app and driver extension with the required Apple Developer entitlements.",
                "Install through the containing app and let macOS request System Extension approval.",
                "After approval, verify the devices in System Settings > Sound and reconnect the DualSense over USB if no real audio transport is available."
            ],
            requirements: [
                "Apple Developer account with DriverKit/System Extension capabilities.",
                "AudioDriverKit implementation for virtual input and output streams.",
                "User approval in macOS Privacy & Security.",
                "A real DualSense audio transport, expected to be USB-only unless macOS exposes Bluetooth audio endpoints."
            ],
            warning: "A normal user-space Swift process cannot create a real system-wide speaker or microphone device without a driver/system extension."
        )
    }

    func play(_ request: PlayAudioRequest) -> AudioCapability {
        let capability = capability()
        guard capability == .dualSenseOutputAvailable || request.useMacFallback == true else {
            return .unsupported
        }
        if let path = request.path {
            return playFile(path: path, preferDualSense: capability == .dualSenseOutputAvailable)
        }
        guard capability == .unsupported else { return .unsupported }
        NSSound.beep()
        return .macFallback
    }

    func say(_ request: SayAudioRequest) -> AudioCapability {
        let capability = capability()
        guard capability == .dualSenseOutputAvailable || request.useMacFallback == true else {
            return .unsupported
        }
        if capability == .dualSenseOutputAvailable {
            return sayThroughDualSense(request)
        }
        let utterance = AVSpeechUtterance(string: request.text)
        if let voiceIdentifier = request.voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        }
        synthesizer.speak(utterance)
        return .macFallback
    }

    private func audioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty,
              AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &devices) == noErr else {
            return []
        }
        return devices
    }

    private func playFile(path: String, preferDualSense: Bool) -> AudioCapability {
        do {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let player = try AVAudioPlayer(contentsOf: url)
            let previousDefault = preferDualSense ? routeDefaultOutputToDualSense() : nil
            self.player = player
            player.play()
            if let previousDefault {
                restoreDefaultOutput(previousDefault, after: player.duration + 0.25)
                return .dualSenseOutputAvailable
            }
            return .macFallback
        } catch {
            NSLog("DualSenseKitDemo audio play failed: \(error)")
            return .unsupported
        }
    }

    private func sayThroughDualSense(_ request: SayAudioRequest) -> AudioCapability {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualSenseKitDemo-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var arguments = ["-o", url.path]
        if let voiceIdentifier = request.voiceIdentifier {
            arguments += ["-v", voiceIdentifier]
        }
        arguments.append(request.text)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return .unsupported
            }
            return playFile(path: url.path, preferDualSense: true)
        } catch {
            NSLog("DualSenseKitDemo say failed: \(error)")
            return .unsupported
        }
    }

    private func routeDefaultOutputToDualSense() -> AudioDeviceID? {
        guard let output = dualSenseOutputDevice(),
              let previous = defaultOutputDeviceID() else {
            return nil
        }
        setDefaultOutputDevice(AudioDeviceID(output.id))
        return previous
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else {
            return nil
        }
        return deviceID
    }

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &mutableDeviceID
        )
    }

    private func restoreDefaultOutput(_ deviceID: AudioDeviceID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.setDefaultOutputDevice(deviceID)
        }
    }

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private func deviceName(deviceID: AudioDeviceID) -> String {
        stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? "Audio Device \(deviceID)"
    }

    private func deviceUID(deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr,
              let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private func isDualSenseAudio(name: String, uid: String?) -> Bool {
        let lowerName = name.lowercased()
        let lowerUID = uid?.lowercased() ?? ""
        return lowerName.contains("dualsense")
            || lowerName.contains("wireless controller")
            || lowerUID.contains("dualsense")
            || lowerUID.contains("wireless controller")
    }
}
