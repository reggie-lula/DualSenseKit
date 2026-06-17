import AppKit
import AVFoundation
import CoreAudio
import Foundation

final class AudioService: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let queue = DispatchQueue(label: "DualSenseKitDemo.AudioService")
    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private var recordStartedAt: Date?
    private var recordInputDeviceID: AudioDeviceID?
    private var recordInputDeviceName: String?
    private var recordOutputURL: URL?
    private var recordPreviousDefaultInput: AudioDeviceID?
    private var restoreOutputWorkItem: DispatchWorkItem?

    func capability() -> AudioCapability {
        if dualSenseOutputDevice() != nil {
            return .dualSenseOutputAvailable
        }
        return .unsupported
    }

    func devices() -> AudioDevicesResponse {
        let defaultInput = defaultInputDeviceID()
        let defaultOutput = defaultOutputDeviceID()
        let allDevices = audioDeviceIDs().map { deviceInfo(deviceID: $0, defaultInput: defaultInput, defaultOutput: defaultOutput) }
        let inputs = allDevices.filter(\.hasInput)
        let outputs = allDevices.filter(\.hasOutput)
        let dualSenseInput = inputs.first(where: \.isDualSenseCandidate)
        let dualSenseOutput = outputs.first(where: \.isDualSenseCandidate)
        let status: String
        if dualSenseInput != nil && dualSenseOutput != nil {
            status = "dualsense_input_output_available"
        } else if dualSenseInput != nil {
            status = "dualsense_input_only"
        } else if dualSenseOutput != nil {
            status = "dualsense_output_only"
        } else {
            status = "no_dualsense_audio_endpoint"
        }
        let defaultInputID = defaultInput.map { UInt32($0) }
        let defaultOutputID = defaultOutput.map { UInt32($0) }
        let note = "DualSense audio uses macOS CoreAudio endpoints only. Bluetooth HID is not treated as a PCM audio transport."
        return AudioDevicesResponse(
            inputs: inputs,
            outputs: outputs,
            defaultInputID: defaultInputID,
            defaultOutputID: defaultOutputID,
            dualSenseInput: dualSenseInput,
            dualSenseOutput: dualSenseOutput,
            dualSenseAudioStatus: status,
            note: note
        )
    }

    func dualSenseOutputDevice() -> AudioOutputDevice? {
        devices().outputs.first(where: \.isDualSenseCandidate).map {
            AudioOutputDevice(id: $0.id, name: $0.name, uid: $0.uid)
        }
    }

    func outputDevices() -> [AudioOutputDevice] {
        devices().outputs.map { AudioOutputDevice(id: $0.id, name: $0.name, uid: $0.uid) }
    }

    func play(_ request: PlayAudioRequest) -> PlayAudioResult {
        let audioDevices = devices()
        let requestedOutput = request.outputDeviceID.flatMap { id in
            audioDevices.outputs.first { $0.id == id }
        }
        if request.outputDeviceID != nil, requestedOutput == nil {
            return PlayAudioResult(
                status: .outputNotFound,
                capability: capability(),
                outputDeviceID: request.outputDeviceID,
                outputDeviceName: nil,
                path: request.path,
                message: "Requested output device was not found."
            )
        }
        let targetOutput = requestedOutput ?? audioDevices.dualSenseOutput
        let usingDualSense = targetOutput?.isDualSenseCandidate == true
        if targetOutput == nil, request.useMacFallback != true {
            return PlayAudioResult(
                status: .noDualSenseOutput,
                capability: capability(),
                outputDeviceID: nil,
                outputDeviceName: nil,
                path: request.path,
                message: "No DualSense output endpoint is visible to CoreAudio."
            )
        }
        guard let path = request.path, !path.isEmpty else {
            NSSound.beep()
            return PlayAudioResult(
                status: request.useMacFallback == true ? .macFallback : .unsupported,
                capability: capability(),
                outputDeviceID: targetOutput?.id,
                outputDeviceName: targetOutput?.name,
                path: nil,
                message: "No file path was provided; played system beep when fallback was allowed."
            )
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PlayAudioResult(
                status: .fileNotFound,
                capability: capability(),
                outputDeviceID: targetOutput?.id,
                outputDeviceName: targetOutput?.name,
                path: url.path,
                message: "Audio file was not found."
            )
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let previousDefault: AudioDeviceID?
            if let targetOutput {
                previousDefault = defaultOutputDeviceID()
                setDefaultOutputDevice(AudioDeviceID(targetOutput.id))
            } else {
                previousDefault = nil
            }
            player.prepareToPlay()
            self.player = player
            player.play()
            if let previousDefault {
                restoreDefaultOutput(previousDefault, after: player.duration + 0.25)
            }
            return PlayAudioResult(
                status: usingDualSense ? .played : .macFallback,
                capability: usingDualSense ? .dualSenseOutputAvailable : .macFallback,
                outputDeviceID: targetOutput?.id,
                outputDeviceName: targetOutput?.name,
                path: url.path,
                message: usingDualSense ? "Playing through the selected DualSense CoreAudio endpoint." : "Playing through macOS fallback output."
            )
        } catch {
            NSLog("DualSenseKitDemo audio play failed: \(error)")
            return PlayAudioResult(
                status: .failed,
                capability: capability(),
                outputDeviceID: targetOutput?.id,
                outputDeviceName: targetOutput?.name,
                path: url.path,
                message: "Audio playback failed: \(error.localizedDescription)"
            )
        }
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

    func startRecording(_ request: RecordAudioRequest) -> RecordAudioStatus {
        queue.sync {
            if recorder?.isRecording == true {
                return currentRecordStatus(message: "Recording is already active.")
            }
            let audioDevices = devices()
            let requestedInput = request.inputDeviceID.flatMap { id in
                audioDevices.inputs.first { $0.id == id }
            }
            if request.inputDeviceID != nil, requestedInput == nil {
                return RecordAudioStatus(
                    status: .inputNotFound,
                    inputDeviceID: request.inputDeviceID,
                    inputDeviceName: nil,
                    outputPath: nil,
                    startedAt: nil,
                    elapsedMs: nil,
                    message: "Requested input device was not found."
                )
            }
            let targetInput = requestedInput ?? audioDevices.dualSenseInput
            if targetInput == nil, request.useMacFallback != true {
                return RecordAudioStatus(
                    status: .noDualSenseInput,
                    inputDeviceID: nil,
                    inputDeviceName: nil,
                    outputPath: nil,
                    startedAt: nil,
                    elapsedMs: nil,
                    message: "No DualSense input endpoint is visible to CoreAudio."
                )
            }
            let actualInput = targetInput ?? audioDevices.inputs.first { $0.isDefaultInput } ?? audioDevices.inputs.first
            guard let actualInput else {
                return RecordAudioStatus(
                    status: .inputNotFound,
                    inputDeviceID: nil,
                    inputDeviceName: nil,
                    outputPath: nil,
                    startedAt: nil,
                    elapsedMs: nil,
                    message: "No CoreAudio input devices are available."
                )
            }
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("DualSenseKit-recording-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            do {
                let previousInput = defaultInputDeviceID()
                setDefaultInputDevice(AudioDeviceID(actualInput.id))
                let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
                recorder.prepareToRecord()
                guard recorder.record() else {
                    setDefaultInputDevice(previousInput)
                    return RecordAudioStatus(
                        status: .failed,
                        inputDeviceID: actualInput.id,
                        inputDeviceName: actualInput.name,
                        outputPath: outputURL.path,
                        startedAt: nil,
                        elapsedMs: nil,
                        message: "AVAudioRecorder refused to start."
                    )
                }
                self.recorder = recorder
                self.recordStartedAt = Date()
                self.recordInputDeviceID = AudioDeviceID(actualInput.id)
                self.recordInputDeviceName = actualInput.name
                self.recordOutputURL = outputURL
                self.recordPreviousDefaultInput = previousInput
                if let durationMs = request.durationMs, durationMs > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(min(durationMs, 60_000))) { [weak self] in
                        _ = self?.stopRecording()
                    }
                }
                return currentRecordStatus(
                    message: actualInput.isDualSenseCandidate
                        ? "Recording from the selected DualSense CoreAudio endpoint."
                        : "Recording through macOS fallback input."
                )
            } catch {
                NSLog("DualSenseKitDemo audio record failed: \(error)")
                return RecordAudioStatus(
                    status: .failed,
                    inputDeviceID: actualInput.id,
                    inputDeviceName: actualInput.name,
                    outputPath: outputURL.path,
                    startedAt: nil,
                    elapsedMs: nil,
                    message: "Audio recording failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func stopRecording() -> RecordAudioStatus {
        queue.sync {
            guard let recorder else {
                return currentRecordStatus(message: "No recording is active.")
            }
            recorder.stop()
            self.recorder = nil
            if let previous = recordPreviousDefaultInput {
                setDefaultInputDevice(previous)
            }
            recordPreviousDefaultInput = nil
            return currentRecordStatus(status: .stopped, message: "Recording stopped.")
        }
    }

    func recordingStatus() -> RecordAudioStatus {
        queue.sync {
            currentRecordStatus(message: recorder?.isRecording == true ? "Recording is active." : "No recording is active.")
        }
    }

    private func currentRecordStatus(status forcedStatus: AudioOperationStatus? = nil, message: String) -> RecordAudioStatus {
        let elapsed: Int?
        if let recordStartedAt {
            elapsed = Int(Date().timeIntervalSince(recordStartedAt) * 1000)
        } else {
            elapsed = nil
        }
        return RecordAudioStatus(
            status: forcedStatus ?? (recorder?.isRecording == true ? .recording : .notRecording),
            inputDeviceID: recordInputDeviceID.map { UInt32($0) },
            inputDeviceName: recordInputDeviceName,
            outputPath: recordOutputURL?.path,
            startedAt: recordStartedAt,
            elapsedMs: elapsed,
            message: message
        )
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

    private func deviceInfo(
        deviceID: AudioDeviceID,
        defaultInput: AudioDeviceID?,
        defaultOutput: AudioDeviceID?
    ) -> AudioDeviceInfo {
        let name = deviceName(deviceID: deviceID)
        let uid = deviceUID(deviceID: deviceID)
        return AudioDeviceInfo(
            id: UInt32(deviceID),
            name: name,
            uid: uid,
            hasInput: hasStreams(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput),
            hasOutput: hasStreams(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput),
            isDefaultInput: defaultInput == deviceID,
            isDefaultOutput: defaultOutput == deviceID,
            isDualSenseCandidate: isDualSenseCandidate(name: name, uid: uid)
        )
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
            return play(PlayAudioRequest(path: url.path, systemSoundName: nil, useMacFallback: false, outputDeviceID: nil)).capability
        } catch {
            NSLog("DualSenseKitDemo say failed: \(error)")
            return .unsupported
        }
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private func setDefaultInputDevice(_ deviceID: AudioDeviceID?) {
        guard let deviceID else { return }
        setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func setDefaultDevice(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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
        restoreOutputWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.setDefaultOutputDevice(deviceID)
        }
        restoreOutputWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
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

    private func isDualSenseCandidate(name: String, uid: String?) -> Bool {
        let lowerName = name.lowercased()
        let lowerUID = uid?.lowercased() ?? ""
        return lowerName.contains("dualsense")
            || lowerName.contains("wireless controller")
            || lowerName.contains("sony")
            || lowerUID.contains("dualsense")
            || lowerUID.contains("wireless controller")
            || lowerUID.contains("sony")
    }
}
