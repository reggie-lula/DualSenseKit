import Foundation
import IOKit.hid
import DualSenseKit

public final class DualSenseHIDService: @unchecked Sendable {
    public typealias ButtonUpdate = (ControllerButton, Bool, Float) -> Void
    public typealias AxisUpdate = (String, Float) -> Void
    public typealias TouchUpdate = (String, Float, Float, Bool) -> Void
    public typealias MotionUpdate = (DualSenseMotion) -> Void
    public typealias OutputEvent = (BridgeEvent) -> Void

    private let queue = DispatchQueue(label: "DualSenseKitDemo.DualSenseHIDService")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private let inputBufferSize = 128
    private let buttonUpdate: ButtonUpdate
    private let axisUpdate: AxisUpdate
    private let touchUpdate: TouchUpdate
    private let motionUpdate: MotionUpdate
    private let outputEvent: OutputEvent?
    private var previousSpecialButtons: UInt8 = 0
    private var previousButtons: [ControllerButton: Bool] = [:]
    private var previousHat: UInt8 = 8
    private var previousAxes: [String: Float] = [:]
    private var previousTouches: [String: (x: Float, y: Float, active: Bool)] = [:]
    private var rawReports: [RawHIDReport] = []
    private let maxRawReports = 60
    private var isOpen = false
    private var statusText = "not_started"
    private var currentOutputSource = "direct"
    private var controllerName: String?
    private var managerOpenedAt: DispatchTime?
    private var deviceMatchedAt: DispatchTime?
    private var deviceOpenedAt: DispatchTime?
    private var firstInputReportAt: DispatchTime?
    private var outputSequence: UInt8 = 0
    private var outputState = DualSenseOutputState()
    private var rumbleStopWorkItem: DispatchWorkItem?
    private var effectPatternTimer: DispatchSourceTimer?
    private var effectPatternStartedAt: DispatchTime?
    private var heartbeatIntervalMs: Int = 260
    private var heartbeatDurationMs: Int = 160
    private var toneStopWorkItem: DispatchWorkItem?
    private var lastAudioStatus: DualSenseAudioStatus?
    private var captureStartedAt: Date?
    private var captureStoppedAt: Date?
    private var captureReports: [RawHIDReport] = []
    private var captureStopWorkItem: DispatchWorkItem?

    public init(
        buttonUpdate: @escaping ButtonUpdate,
        axisUpdate: @escaping AxisUpdate,
        touchUpdate: @escaping TouchUpdate,
        motionUpdate: @escaping MotionUpdate,
        outputEvent: OutputEvent? = nil
    ) {
        self.buttonUpdate = buttonUpdate
        self.axisUpdate = axisUpdate
        self.touchUpdate = touchUpdate
        self.motionUpdate = motionUpdate
        self.outputEvent = outputEvent
    }

    deinit {
        stop()
    }

    public func start() {
        var matchedDevice: IOHIDDevice?
        queue.sync {
            guard manager == nil else { return }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matches: [[String: Any]] = [
                match(productID: 0x0CE6),
                match(productID: 0x0DF2)
            ]
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatched, Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            self.statusText = result == kIOReturnSuccess ? "scanning" : "manager_open_failed_\(String(format: "%08x", result))"
            self.managerOpenedAt = result == kIOReturnSuccess ? .now() : nil
            DiagnosticsLog.write(event: "hid.manager.open", [
                "appMs": "\(DiagnosticsLog.millisecondsSinceAppStart())",
                "result": String(format: "%08x", result),
                "status": self.statusText
            ])
            if result == kIOReturnSuccess,
               let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
                matchedDevice = devices.first
            }
        }
        if let matchedDevice {
            attach(matchedDevice)
        }
    }

    public func stop() {
        queue.sync {
            if let device {
                IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            if let manager {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            inputBuffer?.deallocate()
            inputBuffer = nil
            device = nil
            manager = nil
            isOpen = false
            currentOutputSource = "direct"
            controllerName = nil
            managerOpenedAt = nil
            deviceMatchedAt = nil
            deviceOpenedAt = nil
            firstInputReportAt = nil
            rumbleStopWorkItem?.cancel()
            rumbleStopWorkItem = nil
            effectPatternTimer?.cancel()
            effectPatternTimer = nil
            effectPatternStartedAt = nil
            toneStopWorkItem?.cancel()
            toneStopWorkItem = nil
            captureStopWorkItem?.cancel()
            captureStopWorkItem = nil
            captureStartedAt = nil
            captureStoppedAt = nil
            captureReports.removeAll()
            statusText = "stopped"
        }
    }

    public func diagnostics() -> HIDDiagnostics {
        queue.sync {
            HIDDiagnostics(
                connected: device != nil,
                writable: isOpen,
                product: stringProperty(kIOHIDProductKey),
                vendorID: intProperty(kIOHIDVendorIDKey),
                productID: intProperty(kIOHIDProductIDKey),
                transport: stringProperty(kIOHIDTransportKey),
                status: statusText
            )
        }
    }

    public func recentRawReports(limit: Int = 20) -> [RawHIDReport] {
        queue.sync {
            Array(rawReports.suffix(max(0, min(limit, maxRawReports))))
        }
    }

    public func setControllerContext(name: String?) {
        queue.sync {
            controllerName = name
        }
    }

    public func setOutputSource(_ source: String?) {
        queue.sync {
            currentOutputSource = source?.isEmpty == false ? source! : "direct"
        }
    }

    public func hidAudioStatus() -> HIDAudioStatusResponse {
        queue.sync {
            let diagnostics = HIDDiagnostics(
                connected: device != nil,
                writable: isOpen,
                product: stringProperty(kIOHIDProductKey),
                vendorID: intProperty(kIOHIDVendorIDKey),
                productID: intProperty(kIOHIDProductIDKey),
                transport: stringProperty(kIOHIDTransportKey),
                status: statusText
            )
            let reliability = audioStatusReliability(transport: diagnostics.transport, status: lastAudioStatus)
            return HIDAudioStatusResponse(
                hidConnected: diagnostics.connected,
                hidWritable: diagnostics.writable,
                transport: diagnostics.transport,
                headphoneDetected: lastAudioStatus?.headphoneDetected,
                microphoneDetected: lastAudioStatus?.microphoneDetected,
                micMuted: lastAudioStatus?.micMuted,
                rawStatus0: lastAudioStatus.map { String(format: "%02x", $0.rawStatus0) },
                rawStatus1: lastAudioStatus.map { String(format: "%02x", $0.rawStatus1) },
                sourceConnection: lastAudioStatus.map { "\($0.sourceConnection)" },
                reliability: reliability,
                message: audioStatusMessage(reliability: reliability)
            )
        }
    }

    @discardableResult
    public func setPlayerLEDs(mask: UInt8, brightness: UInt8? = nil) -> Bool {
        let safeMask = mask & 0x1f
        let safeBrightness = brightness.map { min($0, 2) }
        return queue.sync {
            guard let device, isOpen else {
                stageOutputLocked(.playerLEDs(mask: safeMask, brightness: safeBrightness), reason: "hid_not_open")
                statusText = "hid_not_open"
                return false
            }
            let firstResult = sendReport(.playerLEDs(mask: safeMask, brightness: safeBrightness), device: device)
            if firstResult == kIOReturnSuccess {
                statusText = "player_leds_set_\(safeMask)"
                return true
            }
            reopenDevice(device)
            let secondResult = sendReport(.playerLEDs(mask: safeMask, brightness: safeBrightness), device: device)
            statusText = secondResult == kIOReturnSuccess
                ? "player_leds_set_\(safeMask)"
                : "set_report_failed_\(String(format: "%08x", secondResult))_after_reopen_first_\(String(format: "%08x", firstResult))"
            return secondResult == kIOReturnSuccess
        }
    }

    @discardableResult
    public func setRumble(left: Float, right: Float, durationMs: Int?) -> Bool {
        let safeLeft = UInt8(clamping: Int(clamp01(left) * 255))
        let safeRight = UInt8(clamping: Int(clamp01(right) * 255))
        let safeDuration = max(0, min(durationMs ?? 0, 5000))
        let ok = queue.sync {
            cancelEffectPatternLocked()
            rumbleStopWorkItem?.cancel()
            rumbleStopWorkItem = nil
            guard let device, isOpen else {
                statusText = "hid_not_open"
                return false
            }
            let result = sendReport(.rumble(leftMotor: safeLeft, rightMotor: safeRight), device: device)
            statusText = result == kIOReturnSuccess
                ? "rumble_set_left_\(safeLeft)_right_\(safeRight)"
                : "rumble_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
        if ok, safeDuration > 0, (safeLeft > 0 || safeRight > 0) {
            let workItem = DispatchWorkItem { [weak self] in
                _ = self?.setRumble(left: 0, right: 0, durationMs: nil)
            }
            queue.sync { rumbleStopWorkItem = workItem }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(safeDuration),
                execute: workItem
            )
        }
        return ok
    }

    @discardableResult
    public func startPoliceHeartbeatPattern(brightness: UInt8? = nil, intervalMs: Int = 260, durationMs: Int = 160) -> Bool {
        queue.sync {
            guard device != nil, isOpen else {
                statusText = "hid_not_open"
                return false
            }
            cancelEffectPatternLocked()
            rumbleStopWorkItem?.cancel()
            rumbleStopWorkItem = nil
            heartbeatIntervalMs = max(20, intervalMs)
            heartbeatDurationMs = max(20, durationMs)
            effectPatternStartedAt = .now()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(40), leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in
                self?.sendPoliceHeartbeatFrameLocked(brightness: brightness)
            }
            effectPatternTimer = timer
            timer.resume()
            statusText = "police_heartbeat_started"
            sendPoliceHeartbeatFrameLocked(brightness: brightness)
            return true
        }
    }

    @discardableResult
    public func stopEffectPattern() -> Bool {
        queue.sync {
            cancelEffectPatternLocked()
            guard let device, isOpen else {
                statusText = "hid_not_open"
                return false
            }
            let result = sendReport(.combined(
                lightbar: nil,
                rumble: (leftMotor: 0, rightMotor: 0)
            ), device: device)
            statusText = result == kIOReturnSuccess
                ? "effect_pattern_stopped"
                : "effect_pattern_stop_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    @discardableResult
    public func setAudioVolume(headphone: Float?, speaker: Float?) -> Bool {
        let safeHeadphone = headphone.map { UInt8(clamping: Int(clamp01($0) * 255)) }
        let safeSpeaker = speaker.map { UInt8(clamping: Int(clamp01($0) * 255)) }
        return queue.sync {
            guard let device, isOpen else {
                statusText = "hid_not_open"
                return false
            }
            let result = sendReport(.audioVolume(headphone: safeHeadphone, speaker: safeSpeaker), device: device)
            statusText = result == kIOReturnSuccess
                ? "audio_volume_headphone_\(safeHeadphone.map(String.init) ?? "unchanged")_speaker_\(safeSpeaker.map(String.init) ?? "unchanged")"
                : "audio_volume_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    @discardableResult
    public func setHIDTestTone(target: HIDAudioTarget, enabled: Bool, durationMs: Int?) -> Bool {
        let safeDuration = max(0, min(durationMs ?? 0, 10_000))
        let sdkTarget: DualSenseAudioOutputTarget = target == .speaker ? .speaker : .headphone
        let ok = queue.sync {
            toneStopWorkItem?.cancel()
            toneStopWorkItem = nil
            guard let device, isOpen else {
                statusText = "hid_not_open"
                return false
            }
            let connection = connectionType()
            let commands = DualSenseProtocol.featureReportCommands(
                for: .waveOut(target: sdkTarget, enabled: enabled),
                connection: connection
            )
            var lastResult: IOReturn = kIOReturnSuccess
            for command in commands {
                lastResult = sendFeatureReport(command, device: device)
                guard lastResult == kIOReturnSuccess else {
                    statusText = "hid_test_tone_failed_\(String(format: "%08x", lastResult))"
                    return false
                }
            }
            statusText = enabled ? "hid_test_tone_\(target.rawValue)_on" : "hid_test_tone_off"
            return true
        }
        if ok, enabled, safeDuration > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                _ = self?.setHIDTestTone(target: target, enabled: false, durationMs: nil)
            }
            queue.sync { toneStopWorkItem = workItem }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(safeDuration),
                execute: workItem
            )
        }
        return ok
    }

    public func startCapture(durationMs: Int?) -> HIDCaptureResponse {
        let safeDuration = max(0, min(durationMs ?? 0, 30_000))
        let response = queue.sync {
            captureStopWorkItem?.cancel()
            captureStartedAt = Date()
            captureStoppedAt = nil
            captureReports.removeAll()
            statusText = "hid_capture_started"
            return captureResponse(active: true, message: "HID capture started.")
        }
        if safeDuration > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                _ = self?.stopCapture()
            }
            queue.sync { captureStopWorkItem = workItem }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .milliseconds(safeDuration),
                execute: workItem
            )
        }
        return response
    }

    public func stopCapture() -> HIDCaptureResponse {
        queue.sync {
            captureStopWorkItem?.cancel()
            captureStopWorkItem = nil
            if captureStartedAt != nil, captureStoppedAt == nil {
                captureStoppedAt = Date()
            }
            statusText = "hid_capture_stopped"
            return captureResponse(active: false, message: "HID capture stopped. No PCM conclusion is assumed from this snapshot.")
        }
    }

    @discardableResult
    public func setMicMuteLED(on: Bool) -> Bool {
        setMicMuteLED(control: on ? 1 : 0)
    }

    @discardableResult
    public func setMicMuteLED(control: UInt8) -> Bool {
        let safeControl = min(control, 2)
        return queue.sync {
            guard let device, isOpen else {
                statusText = "hid_not_open"
                return false
            }
            let result = sendReport(.micMuteLED(control: safeControl), device: device)
            statusText = result == kIOReturnSuccess
                ? "mic_mute_led_\(safeControl)"
                : "mic_mute_led_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    @discardableResult
    public func setLightbar(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8?) -> Bool {
        queue.sync {
            cancelEffectPatternLocked()
            guard let device, isOpen else {
                stageOutputLocked(.lightbar(red: red, green: green, blue: blue, brightness: brightness), reason: "hid_not_open")
                statusText = "hid_not_open"
                return false
            }
            let result = sendReport(.lightbar(red: red, green: green, blue: blue, brightness: brightness), device: device)
            statusText = result == kIOReturnSuccess
                ? "lightbar_set"
                : "lightbar_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    private func cancelEffectPatternLocked() {
        effectPatternTimer?.cancel()
        effectPatternTimer = nil
        effectPatternStartedAt = nil
    }

    private func heartbeatStrength(at position: UInt64, intervalMs: Int, durationMs: Int) -> (leftMotor: UInt8, rightMotor: UInt8) {
        let dur = Double(durationMs)
        // Strong beat: attack 25% → sustain 25% → decay 50%
        if position < UInt64(durationMs) {
            let t = Double(position)
            let attackEnd = dur * 0.25
            let sustainEnd = dur * 0.50
            let env: Double
            if t < attackEnd {
                env = t / attackEnd                            // attack 0→1
            } else if t < sustainEnd {
                env = 1.0                                      // sustain peak
            } else {
                env = 1.0 - (t - sustainEnd) / (dur * 0.50)    // decay 1→0
            }
            let left = UInt8(env * 224)
            return (left, UInt8(env * 40))
        }
        // Weak beat: attack 25% → decay 75%, no sustain
        let weakStart = UInt64(intervalMs)
        if position >= weakStart && position < weakStart + UInt64(durationMs) {
            let t = Double(position - weakStart)
            let attackEnd = dur * 0.25
            let env: Double
            if t < attackEnd {
                env = t / attackEnd                            // attack 0→1
            } else {
                env = 1.0 - (t - attackEnd) / (dur * 0.75)     // decay 1→0
            }
            let left = UInt8(env * 112)
            return (left, UInt8(env * 20))
        }
        return (0, 0)
    }

    private func sendPoliceHeartbeatFrameLocked(brightness: UInt8?) {
        guard let device, isOpen else {
            statusText = "hid_not_open"
            cancelEffectPatternLocked()
            return
        }
        let elapsedMs: UInt64
        if let effectPatternStartedAt {
            elapsedMs = DispatchTime.now().uptimeNanoseconds >= effectPatternStartedAt.uptimeNanoseconds
                ? (DispatchTime.now().uptimeNanoseconds - effectPatternStartedAt.uptimeNanoseconds) / 1_000_000
                : 0
        } else {
            elapsedMs = 0
        }
        let intervalMs = heartbeatIntervalMs
        let durationMs = heartbeatDurationMs
        let totalCycle = max(UInt64(intervalMs + durationMs), 800)
        let cycle = elapsedMs % totalCycle
        let rumble = heartbeatStrength(at: cycle, intervalMs: intervalMs, durationMs: durationMs)
        let lightbar: (red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8?)
        if cycle < UInt64(intervalMs) {
            lightbar = (red: 255, green: 0, blue: 0, brightness: brightness)
        } else {
            lightbar = (red: 0, green: 0, blue: 255, brightness: brightness)
        }
        let result = sendReport(.combined(lightbar: lightbar, rumble: rumble), device: device)
        statusText = result == kIOReturnSuccess
            ? "police_heartbeat_frame"
            : "police_heartbeat_failed_\(String(format: "%08x", result))"
    }

    @discardableResult
    public func setAdaptiveTrigger(side: DualSenseTriggerSide, mode: UInt8, params: [UInt8]) -> Bool {
        queue.sync {
            guard let device, isOpen else {
                statusText = "hid_not_open"
                return false
            }
            let result = sendReport(.adaptiveTrigger(side: side, mode: mode, params: params), device: device)
            statusText = result == kIOReturnSuccess
                ? "hid_trigger_set"
                : "hid_trigger_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    public static func parseSpecialButtons(report: Data) -> UInt8? {
        DualSenseProtocol.specialButtonsByte(from: report)
    }

    public static func parseAudioStatus(report: Data) -> DualSenseAudioStatus? {
        DualSenseProtocol.parseAudioStatus(from: report)
    }

    fileprivate static func parseInputReport(_ report: Data) -> DualSenseInputReport? {
        DualSenseProtocol.parseInputReport(report)
    }

    public static func pressedSpecialButtons(from value: UInt8) -> [(ControllerButton, Bool)] {
        [
            (.buttonHome, (value & 0x01) != 0),
            (.touchpadButton, (value & 0x02) != 0),
            (.buttonMicrophoneMute, (value & 0x04) != 0)
        ]
    }

    public static func hatButtons(_ hat: UInt8) -> Set<ControllerButton> {
        Set(DualSenseProtocol.dpadButtons(from: hat).compactMap(Self.controllerButton))
    }

    public static func bluetoothOutputReport(playerLEDMask: UInt8, sequence: UInt8 = 0) -> Data {
        bluetoothOutputReport(effect: .playerLEDs(mask: playerLEDMask, brightness: nil), sequence: sequence)
    }

    public static func bluetoothOutputReport(leftMotor: UInt8, rightMotor: UInt8, sequence: UInt8 = 0) -> Data {
        bluetoothOutputReport(effect: .rumble(leftMotor: leftMotor, rightMotor: rightMotor), sequence: sequence)
    }

    private static func bluetoothOutputReport(effect: HIDOutputEffect, sequence: UInt8) -> Data {
        var state = DualSenseOutputState()
        switch effect {
        case .playerLEDs(let mask, let brightness):
            DualSenseProtocol.apply(.playerLEDs(mask: mask, brightness: brightness), to: &state)
        case .rumble(let leftMotor, let rightMotor):
            DualSenseProtocol.apply(.rumble(leftMotor: leftMotor, rightMotor: rightMotor), to: &state)
        case .micMuteLED(let control):
            DualSenseProtocol.apply(.micMuteLED(control: control), to: &state)
        case .lightbar(let red, let green, let blue, let brightness):
            DualSenseProtocol.apply(.lightbar(red: red, green: green, blue: blue, brightness: brightness), to: &state)
        case .adaptiveTrigger(let side, let mode, let params):
            DualSenseProtocol.apply(.adaptiveTrigger(side: side, mode: mode, params: params), to: &state)
        case .audioVolume(let headphone, let speaker):
            DualSenseProtocol.apply(.audioVolume(headphone: headphone, speaker: speaker), to: &state)
        case .combined(let lightbar, let rumble):
            if let lightbar {
                DualSenseProtocol.apply(
                    .lightbar(red: lightbar.red, green: lightbar.green, blue: lightbar.blue, brightness: lightbar.brightness),
                    to: &state
                )
            }
            if let rumble {
                DualSenseProtocol.apply(.rumble(leftMotor: rumble.leftMotor, rightMotor: rumble.rightMotor), to: &state)
            }
        }
        return DualSenseProtocol.bluetoothOutputReport(state: state, sequence: sequence)
    }

    fileprivate func attach(_ matchedDevice: IOHIDDevice) {
        queue.sync {
            guard device == nil else { return }
            deviceMatchedAt = .now()
            device = matchedDevice
            DiagnosticsLog.write(event: "hid.device.matched", diagnosticPayloadLocked())
            let result = IOHIDDeviceOpen(matchedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            isOpen = result == kIOReturnSuccess
            deviceOpenedAt = isOpen ? .now() : nil
            statusText = isOpen ? "open" : "device_open_failed_\(String(format: "%08x", result))"
            var payload = diagnosticPayloadLocked()
            payload["result"] = String(format: "%08x", result)
            DiagnosticsLog.write(event: "hid.device.open", payload)
            IOHIDDeviceScheduleWithRunLoop(matchedDevice, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
            inputBuffer?.initialize(repeating: 0, count: inputBufferSize)
            if let inputBuffer {
                IOHIDDeviceRegisterInputReportCallback(
                    matchedDevice,
                    inputBuffer,
                    inputBufferSize,
                    inputReportReceived,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
            if isOpen {
                sendInitializationReportLocked(device: matchedDevice)
            }
        }
    }

    private func sendInitializationReportLocked(device: IOHIDDevice) {
        var initState = DualSenseOutputState()
        // validFlag1 defaults to 0xf7 — claims control of all LED/motor features
        initState.lightbarSetup = 0x02  // take lightbar from system player-color scheme
        let sequence = nextOutputSequence()
        let btReport = DualSenseProtocol.bluetoothOutputReport(state: initState, sequence: sequence)
        let usbReport = DualSenseProtocol.usbOutputReport(state: initState)
        let btPayload = Data(btReport.dropFirst())
        let attempts: [(IOHIDReportType, CFIndex, Data, String)] = [
            (kIOHIDReportTypeOutput, CFIndex(btReport[0]), btReport, "init_bt_full"),
            (kIOHIDReportTypeOutput, CFIndex(btReport[0]), btPayload, "init_bt_payload"),
            (kIOHIDReportTypeOutput, 0, btReport, "init_bt_zero"),
            (kIOHIDReportTypeOutput, CFIndex(usbReport[0]), usbReport, "init_usb_full"),
            (kIOHIDReportTypeOutput, 0, usbReport, "init_usb_zero")
        ]
        var lastResult: IOReturn = kIOReturnError
        var usedAttempt = "none"
        for (type, reportID, data, name) in attempts {
            let result = data.withUnsafeBytes { buffer -> IOReturn in
                guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
                return IOHIDDeviceSetReport(device, type, reportID, base.assumingMemoryBound(to: UInt8.self), data.count)
            }
            lastResult = result
            if result == kIOReturnSuccess {
                usedAttempt = name
                break
            }
        }
        statusText = lastResult == kIOReturnSuccess ? "initialized_via_\(usedAttempt)" : "init_report_failed"
        var payload = diagnosticPayloadLocked()
        payload["result"] = String(format: "%08x", lastResult)
        payload["attempt"] = usedAttempt
        DiagnosticsLog.write(event: "hid.device.init", payload)
    }

    fileprivate func handleInputReport(data: Data) {
        let reportID = data.first ?? 0
        if firstInputReportAt == nil {
            firstInputReportAt = .now()
            var payload = diagnosticPayloadLocked()
            payload["reportID"] = String(format: "%02x", reportID)
            payload["length"] = "\(data.count)"
            payload["reportBytesHexPrefix"] = data.hexPrefix(count: 24)
            DiagnosticsLog.write(event: "hid.input.firstReport", payload)
        }
        rawReports.append(RawHIDReport(
            reportID: reportID,
            length: data.count,
            hex: data.map { String(format: "%02x", $0) }.joined(separator: " "),
            timestamp: Date()
        ))
        if rawReports.count > maxRawReports {
            rawReports.removeFirst(rawReports.count - maxRawReports)
        }
        if captureStartedAt != nil, captureStoppedAt == nil {
            captureReports.append(RawHIDReport(
                reportID: reportID,
                length: data.count,
                hex: data.map { String(format: "%02x", $0) }.joined(separator: " "),
                timestamp: Date()
            ))
            if captureReports.count > 300 {
                captureReports.removeFirst(captureReports.count - 300)
            }
        }
        guard let parsed = Self.parseInputReport(data) else { return }
        emitAudioStatus(parsed)
        emitAxes(parsed)
        emitMotion(parsed)
        emitButtons(parsed)
        emitTouch(parsed)
    }

    private func emitAudioStatus(_ report: DualSenseInputReport) {
        guard let status = report.audioStatus else { return }
        let old = lastAudioStatus
        lastAudioStatus = status
        guard old != status else { return }
        outputEvent?(BridgeEvent(type: "hid.audio.status", payload: [
            "headphoneDetected": "\(status.headphoneDetected)",
            "microphoneDetected": "\(status.microphoneDetected)",
            "micMuted": "\(status.micMuted)",
            "rawStatus0": String(format: "%02x", status.rawStatus0),
            "rawStatus1": String(format: "%02x", status.rawStatus1),
            "sourceConnection": "\(status.sourceConnection)",
            "reliability": audioStatusReliability(transport: stringProperty(kIOHIDTransportKey), status: status)
        ]))
    }

    private func emitAxes(_ report: DualSenseInputReport) {
        for (name, value) in report.axes {
            let old = previousAxes[name] ?? -1
            guard abs(old - value) >= 0.01 else { continue }
            previousAxes[name] = value
            axisUpdate(name, value)
        }
    }

    private func emitMotion(_ report: DualSenseInputReport) {
        guard let motion = report.motion else { return }
        motionUpdate(motion)
    }

    private func emitButtons(_ report: DualSenseInputReport) {
        let hatButtons = Self.hatButtons(report.hat)
        for button in [ControllerButton.dpadUp, .dpadDown, .dpadLeft, .dpadRight] {
            let pressed = hatButtons.contains(button)
            emitButtonIfChanged(button, pressed: pressed)
        }
        previousHat = report.hat

        for (button, pressed) in report.buttons {
            guard let mappedButton = Self.controllerButton(button) else { continue }
            emitButtonIfChanged(mappedButton, pressed: pressed)
        }
    }

    private func emitButtonIfChanged(_ button: ControllerButton, pressed: Bool) {
        let old = previousButtons[button] ?? false
        guard old != pressed else { return }
        previousButtons[button] = pressed
        buttonUpdate(button, pressed, pressed ? 1 : 0)
    }

    private func emitTouch(_ report: DualSenseInputReport) {
        for (index, point) in report.touchPoints.enumerated() {
            let name = index == 0 ? "primary" : "secondary"
            let old = previousTouches[name]
            let moved = old.map {
                abs($0.x - point.x) >= 0.005 || abs($0.y - point.y) >= 0.005
            } ?? true
            let activeChanged = old?.active != point.active
            guard activeChanged || (point.active && moved) else { continue }
            previousTouches[name] = (point.x, point.y, point.active)
            touchUpdate(name, point.x, point.y, point.active)
        }
    }

    private func stageOutputLocked(_ effect: HIDOutputEffect, reason: String) {
        applyOutputEffect(effect, to: &outputState)
        let sequence = nextOutputSequence()
        var payload = diagnosticPayloadLocked()
        payload["intent"] = effect.intentName
        payload["source"] = currentOutputSource
        payload["sequence"] = "\(sequence)"
        payload["reason"] = reason
        payload["validFlag0"] = String(format: "%02x", outputState.validFlag0)
        payload["validFlag1"] = String(format: "%02x", outputState.validFlag1)
        payload["validFlag2"] = String(format: "%02x", outputState.validFlag2)
        DiagnosticsLog.write(event: "hid.output.staged", payload)
    }

    private func applyOutputEffect(_ effect: HIDOutputEffect, to state: inout DualSenseOutputState) {
        switch effect {
        case .playerLEDs(let mask, let brightness):
            DualSenseProtocol.apply(.playerLEDs(mask: mask, brightness: brightness), to: &state)
        case .rumble(let leftMotor, let rightMotor):
            DualSenseProtocol.apply(.rumble(leftMotor: leftMotor, rightMotor: rightMotor), to: &state)
        case .micMuteLED(let control):
            DualSenseProtocol.apply(.micMuteLED(control: control), to: &state)
        case .lightbar(let red, let green, let blue, let brightness):
            DualSenseProtocol.apply(.lightbar(red: red, green: green, blue: blue, brightness: brightness), to: &state)
        case .adaptiveTrigger(let side, let mode, let params):
            DualSenseProtocol.apply(.adaptiveTrigger(side: side, mode: mode, params: params), to: &state)
        case .audioVolume(let headphone, let speaker):
            DualSenseProtocol.apply(.audioVolume(headphone: headphone, speaker: speaker), to: &state)
        case .combined(let lightbar, let rumble):
            if let lightbar {
                DualSenseProtocol.apply(
                    .lightbar(red: lightbar.red, green: lightbar.green, blue: lightbar.blue, brightness: lightbar.brightness),
                    to: &state
                )
            }
            if let rumble {
                DualSenseProtocol.apply(.rumble(leftMotor: rumble.leftMotor, rightMotor: rumble.rightMotor), to: &state)
            }
        }
    }

    private func sendReport(_ effect: HIDOutputEffect, device: IOHIDDevice) -> IOReturn {
        applyOutputEffect(effect, to: &outputState)
        var reportState = outputState
        reportState.validFlag0 = 0
        reportState.validFlag1 = 0
        reportState.validFlag2 = 0
        switch effect {
        case .playerLEDs(let mask, let brightness):
            DualSenseProtocol.apply(.playerLEDs(mask: mask, brightness: brightness), to: &reportState)
        case .rumble(let leftMotor, let rightMotor):
            DualSenseProtocol.apply(.rumble(leftMotor: leftMotor, rightMotor: rightMotor), to: &reportState)
        case .micMuteLED(let control):
            DualSenseProtocol.apply(.micMuteLED(control: control), to: &reportState)
        case .lightbar(let red, let green, let blue, let brightness):
            DualSenseProtocol.apply(.lightbar(red: red, green: green, blue: blue, brightness: brightness), to: &reportState)
        case .adaptiveTrigger(let side, let mode, let params):
            DualSenseProtocol.apply(.adaptiveTrigger(side: side, mode: mode, params: params), to: &reportState)
        case .audioVolume(let headphone, let speaker):
            DualSenseProtocol.apply(.audioVolume(headphone: headphone, speaker: speaker), to: &reportState)
        case .combined(let lightbar, let rumble):
            if let lightbar {
                DualSenseProtocol.apply(
                    .lightbar(red: lightbar.red, green: lightbar.green, blue: lightbar.blue, brightness: lightbar.brightness),
                    to: &reportState
                )
            }
            if let rumble {
                DualSenseProtocol.apply(.rumble(leftMotor: rumble.leftMotor, rightMotor: rumble.rightMotor), to: &reportState)
            }
        }
        let sequence = nextOutputSequence()
        let report = DualSenseProtocol.bluetoothOutputReport(state: reportState, sequence: sequence)
        outputEvent?(BridgeEvent(type: "hid.output.request", payload: [
            "intent": effect.intentName,
            "source": currentOutputSource,
            "sequence": "\(sequence)",
            "reportID": String(format: "%02x", report.first ?? 0),
            "reportLength": "\(report.count)",
            "reportBytesHexPrefix": report.hexPrefix(count: 24),
            "validFlag0": String(format: "%02x", reportState.validFlag0),
            "validFlag1": String(format: "%02x", reportState.validFlag1),
            "validFlag2": String(format: "%02x", reportState.validFlag2)
        ]))
        var requestPayload = diagnosticPayloadLocked()
        requestPayload["intent"] = effect.intentName
        requestPayload["source"] = currentOutputSource
        requestPayload["sequence"] = "\(sequence)"
        requestPayload["reportID"] = String(format: "%02x", report.first ?? 0)
        requestPayload["reportLength"] = "\(report.count)"
        requestPayload["reportBytesHexPrefix"] = report.hexPrefix(count: 24)
        requestPayload["validFlag0"] = String(format: "%02x", reportState.validFlag0)
        requestPayload["validFlag1"] = String(format: "%02x", reportState.validFlag1)
        requestPayload["validFlag2"] = String(format: "%02x", reportState.validFlag2)
        DiagnosticsLog.write(event: "hid.output.request", requestPayload)
        let payloadWithoutReportID = Data(report.dropFirst())
        let attempts: [(IOHIDReportType, CFIndex, Data, String)] = [
            (kIOHIDReportTypeOutput, CFIndex(report[0]), report, "output_full"),
            (kIOHIDReportTypeOutput, CFIndex(report[0]), payloadWithoutReportID, "output_payload"),
            (kIOHIDReportTypeOutput, 0, report, "output_zero_full")
        ]
        var lastResult: IOReturn = kIOReturnError
        var failures: [String] = []
        for (type, reportID, data, name) in attempts {
            let result = data.withUnsafeBytes { buffer -> IOReturn in
                guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
                return IOHIDDeviceSetReport(
                    device,
                    type,
                    reportID,
                    base.assumingMemoryBound(to: UInt8.self),
                    data.count
                )
            }
            if result == kIOReturnSuccess {
                statusText = "report_sent_via_\(name)"
                outputEvent?(BridgeEvent(type: "hid.output.success", payload: [
                    "intent": effect.intentName,
                    "source": currentOutputSource,
                    "sequence": "\(sequence)",
                    "attempt": name,
                    "reportID": "\(reportID)",
                    "length": "\(data.count)",
                    "result": String(format: "%08x", result),
                    "ok": "true",
                    "status": statusText
                ]))
                var payload = requestPayload
                payload["attempt"] = name
                payload["attemptReportID"] = "\(reportID)"
                payload["attemptLength"] = "\(data.count)"
                payload["result"] = String(format: "%08x", result)
                payload["status"] = statusText
                DiagnosticsLog.write(event: "hid.output.success", payload)
                return result
            }
            failures.append("\(name)=\(String(format: "%08x", result))")
            lastResult = result
        }
        statusText = "set_report_failed_\(failures.joined(separator: ","))"
        outputEvent?(BridgeEvent(type: "hid.output.failure", payload: [
            "intent": effect.intentName,
            "source": currentOutputSource,
            "sequence": "\(sequence)",
            "failures": failures.joined(separator: ","),
            "lastResult": String(format: "%08x", lastResult),
            "ok": "false",
            "status": statusText
        ]))
        var payload = requestPayload
        payload["failures"] = failures.joined(separator: ",")
        payload["lastResult"] = String(format: "%08x", lastResult)
        payload["status"] = statusText
        DiagnosticsLog.write(event: "hid.output.failure", payload)
        return lastResult
    }

    private func sendFeatureReport(_ command: DualSenseFeatureReportCommand, device: IOHIDDevice) -> IOReturn {
        outputEvent?(BridgeEvent(type: "hid.feature.request", payload: [
            "intent": "audioTestTone",
            "command": command.name,
            "reportID": String(format: "%02x", command.reportID),
            "reportLength": "\(command.payload.count)",
            "reportBytesHexPrefix": command.payload.hexPrefix(count: 24)
        ]))
        var fullReport = Data([command.reportID])
        fullReport.append(command.payload)
        let attempts: [(IOHIDReportType, CFIndex, Data, String)] = [
            (kIOHIDReportTypeFeature, CFIndex(command.reportID), command.payload, "feature_payload"),
            (kIOHIDReportTypeFeature, CFIndex(command.reportID), fullReport, "feature_full"),
            (kIOHIDReportTypeFeature, 0, fullReport, "feature_zero_full")
        ]
        var lastResult: IOReturn = kIOReturnError
        var failures: [String] = []
        for (type, reportID, data, name) in attempts {
            let result = data.withUnsafeBytes { buffer -> IOReturn in
                guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
                return IOHIDDeviceSetReport(
                    device,
                    type,
                    reportID,
                    base.assumingMemoryBound(to: UInt8.self),
                    data.count
                )
            }
            if result == kIOReturnSuccess {
                statusText = "feature_report_sent_via_\(name)"
                outputEvent?(BridgeEvent(type: "hid.feature.success", payload: [
                    "intent": "audioTestTone",
                    "command": command.name,
                    "attempt": name,
                    "reportID": "\(reportID)",
                    "length": "\(data.count)",
                    "result": String(format: "%08x", result),
                    "ok": "true",
                    "status": statusText
                ]))
                return result
            }
            failures.append("\(name)=\(String(format: "%08x", result))")
            lastResult = result
        }
        statusText = "feature_report_failed_\(failures.joined(separator: ","))"
        outputEvent?(BridgeEvent(type: "hid.feature.failure", payload: [
            "intent": "audioTestTone",
            "command": command.name,
            "failures": failures.joined(separator: ","),
            "lastResult": String(format: "%08x", lastResult),
            "ok": "false",
            "status": statusText
        ]))
        return lastResult
    }

    private func nextOutputSequence() -> UInt8 {
        let current = outputSequence & 0x0f
        outputSequence = (outputSequence + 1) & 0x0f
        return current
    }

    private func reopenDevice(_ device: IOHIDDevice) {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = result == kIOReturnSuccess
        deviceOpenedAt = isOpen ? .now() : deviceOpenedAt
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        if result != kIOReturnSuccess {
            statusText = "device_reopen_failed_\(String(format: "%08x", result))"
        }
        var payload = diagnosticPayloadLocked()
        payload["result"] = String(format: "%08x", result)
        DiagnosticsLog.write(event: "hid.device.reopen", payload)
    }

    private func match(productID: Int) -> [String: Any] {
        [
            kIOHIDVendorIDKey as String: 0x054c,
            kIOHIDProductIDKey as String: productID,
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_GamePad
        ]
    }

    private func stringProperty(_ key: String) -> String? {
        guard let device,
              let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return value as? String
    }

    private func intProperty(_ key: String) -> Int? {
        guard let device,
              let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func connectionType() -> DualSenseConnection {
        let transport = stringProperty(kIOHIDTransportKey)?.lowercased() ?? ""
        return transport.contains("bluetooth") ? .bluetooth : .usb
    }

    private func diagnosticPayloadLocked() -> [String: String] {
        [
            "appMs": "\(DiagnosticsLog.millisecondsSinceAppStart())",
            "controller": controllerName ?? "none",
            "hidConnected": "\(device != nil)",
            "hidWritable": "\(isOpen)",
            "transport": stringProperty(kIOHIDTransportKey) ?? "unknown",
            "productID": intProperty(kIOHIDProductIDKey).map { String(format: "%04x", $0) } ?? "unknown",
            "status": statusText,
            "managerOpenMs": "\(DiagnosticsLog.milliseconds(since: managerOpenedAt))",
            "deviceMatchedMs": "\(DiagnosticsLog.milliseconds(since: deviceMatchedAt))",
            "deviceOpenMs": "\(DiagnosticsLog.milliseconds(since: deviceOpenedAt))",
            "firstInputMs": "\(DiagnosticsLog.milliseconds(since: firstInputReportAt))"
        ]
    }

    private func audioStatusReliability(transport: String?, status: DualSenseAudioStatus?) -> String {
        guard status != nil else { return "waiting_for_input_report" }
        let transportValue = (transport ?? "").lowercased()
        if transportValue.contains("usb") { return "usb_status_bits" }
        if transportValue.contains("bluetooth") { return "bluetooth_status_bits_experimental" }
        return "unknown_transport_experimental"
    }

    private func audioStatusMessage(reliability: String) -> String {
        switch reliability {
        case "usb_status_bits":
            return "USB status bits are available for jack and microphone diagnostics."
        case "bluetooth_status_bits_experimental":
            return "Bluetooth status bits are parsed for diagnostics only; they do not prove microphone PCM transport."
        case "waiting_for_input_report":
            return "Waiting for a DualSense HID input report before audio status can be shown."
        default:
            return "Audio status is experimental on this transport."
        }
    }

    private func captureResponse(active: Bool, message: String) -> HIDCaptureResponse {
        let reports = captureReports
        let uniqueIDs = Array(Set(reports.map(\.reportID))).sorted()
        return HIDCaptureResponse(
            active: active,
            startedAt: captureStartedAt,
            stoppedAt: captureStoppedAt,
            reportCount: reports.count,
            uniqueReportIDs: uniqueIDs,
            byteChangeSummary: byteChangeSummary(reports: reports),
            pcmEvidence: pcmEvidence(reports: reports),
            message: message,
            reports: Array(reports.suffix(30))
        )
    }

    private func byteChangeSummary(reports: [RawHIDReport]) -> [String] {
        guard reports.count >= 2 else { return [] }
        let parsedReports = reports.map { $0.hex.split(separator: " ").compactMap { UInt8($0, radix: 16) } }
        let maxLength = parsedReports.map(\.count).max() ?? 0
        var summaries: [String] = []
        for index in 0..<maxLength {
            let values = Set(parsedReports.compactMap { index < $0.count ? $0[index] : nil })
            if values.count > 1 {
                let sample = values.sorted().prefix(8).map { String(format: "%02x", $0) }.joined(separator: "/")
                summaries.append("[\(index)]=\(sample)")
            }
            if summaries.count >= 40 { break }
        }
        return summaries
    }

    private func pcmEvidence(reports: [RawHIDReport]) -> String {
        guard reports.count >= 10 else { return "insufficient_reports" }
        let lengths = Set(reports.map(\.length))
        if lengths.count == 1, let length = lengths.first, length <= inputBufferSize {
            return "no_large_audio_payload_detected"
        }
        return "unknown_requires_manual_review"
    }

    private func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }

    private static func controllerButton(_ button: DualSenseButton) -> ControllerButton? {
        switch button {
        case .square: return .buttonX
        case .cross: return .buttonA
        case .circle: return .buttonB
        case .triangle: return .buttonY
        case .dpadUp: return .dpadUp
        case .dpadDown: return .dpadDown
        case .dpadLeft: return .dpadLeft
        case .dpadRight: return .dpadRight
        case .l1: return .leftShoulder
        case .r1: return .rightShoulder
        case .l2: return nil  // triggers handled via GameController analog values to avoid double-fire
        case .r2: return nil  // triggers handled via GameController analog values to avoid double-fire
        case .create: return .buttonMenu
        case .options: return .buttonOptions
        case .l3: return .leftThumbstickButton
        case .r3: return .rightThumbstickButton
        case .ps: return .buttonHome
        case .touchpad: return .touchpadButton
        case .microphoneMute: return .buttonMicrophoneMute
        }
    }
}

private enum HIDOutputEffect {
    case playerLEDs(mask: UInt8, brightness: UInt8?)
    case rumble(leftMotor: UInt8, rightMotor: UInt8)
    case micMuteLED(control: UInt8)
    case lightbar(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8?)
    case adaptiveTrigger(side: DualSenseTriggerSide, mode: UInt8, params: [UInt8])
    case audioVolume(headphone: UInt8?, speaker: UInt8?)
    case combined(
        lightbar: (red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8?)?,
        rumble: (leftMotor: UInt8, rightMotor: UInt8)?
    )

    public var intentName: String {
        switch self {
        case .playerLEDs: return "playerLEDs"
        case .rumble: return "rumble"
        case .micMuteLED: return "micMuteLED"
        case .lightbar: return "lightbar"
        case .adaptiveTrigger: return "adaptiveTrigger"
        case .audioVolume: return "audioVolume"
        case .combined: return "combined"
        }
    }
}

private extension Data {
    func hexPrefix(count: Int) -> String {
        prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

private func deviceMatched(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice?) {
    guard result == kIOReturnSuccess, let context, let device else { return }
    let service = Unmanaged<DualSenseHIDService>.fromOpaque(context).takeUnretainedValue()
    service.attach(device)
}

private func inputReportReceived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: Int
) {
    guard result == kIOReturnSuccess, let context, reportLength > 0 else { return }
    let service = Unmanaged<DualSenseHIDService>.fromOpaque(context).takeUnretainedValue()
    service.handleInputReport(data: Data(bytes: report, count: reportLength))
}
