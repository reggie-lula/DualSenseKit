import Foundation
import IOKit.hid
import DualSenseKit

final class DualSenseHIDService: @unchecked Sendable {
    typealias ButtonUpdate = (ControllerButton, Bool, Float) -> Void
    typealias AxisUpdate = (String, Float) -> Void
    typealias TouchUpdate = (String, Float, Float, Bool) -> Void

    private let queue = DispatchQueue(label: "DualSenseKitDemo.DualSenseHIDService")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private let inputBufferSize = 128
    private let buttonUpdate: ButtonUpdate
    private let axisUpdate: AxisUpdate
    private let touchUpdate: TouchUpdate
    private var previousSpecialButtons: UInt8 = 0
    private var previousButtons: [ControllerButton: Bool] = [:]
    private var previousHat: UInt8 = 8
    private var previousAxes: [String: Float] = [:]
    private var previousTouches: [String: (x: Float, y: Float, active: Bool)] = [:]
    private var rawReports: [RawHIDReport] = []
    private let maxRawReports = 60
    private var isOpen = false
    private var statusText = "not_started"
    private var outputSequence: UInt8 = 0
    private var rumbleStopWorkItem: DispatchWorkItem?

    init(
        buttonUpdate: @escaping ButtonUpdate,
        axisUpdate: @escaping AxisUpdate,
        touchUpdate: @escaping TouchUpdate
    ) {
        self.buttonUpdate = buttonUpdate
        self.axisUpdate = axisUpdate
        self.touchUpdate = touchUpdate
    }

    deinit {
        stop()
    }

    func start() {
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
            IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemoved, Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            self.statusText = result == kIOReturnSuccess ? "scanning" : "manager_open_failed_\(String(format: "%08x", result))"
            if result == kIOReturnSuccess,
               let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
                matchedDevice = devices.first
            }
        }
        if let matchedDevice {
            attach(matchedDevice)
        }
    }

    func stop() {
        queue.sync {
            closeCurrentDevice()
            if let manager {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            rumbleStopWorkItem?.cancel()
            rumbleStopWorkItem = nil
            manager = nil
            statusText = "stopped"
        }
    }

    func diagnostics() -> HIDDiagnostics {
        queue.sync {
            if !isOpen {
                refreshSelectedDeviceIfNeeded()
            }
            return HIDDiagnostics(
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

    func recentRawReports(limit: Int = 20) -> [RawHIDReport] {
        queue.sync {
            Array(rawReports.suffix(max(0, min(limit, maxRawReports))))
        }
    }

    @discardableResult
    func setPlayerLEDs(mask: UInt8, brightness: UInt8? = nil) -> Bool {
        let safeMask = mask & 0x1f
        let safeBrightness = brightness.map { min($0, 2) }
        return queue.sync {
            guard let device = writableDevice() else { return false }
            let result = sendReportWithReopen(.playerLEDs(mask: safeMask, brightness: safeBrightness), device: device)
            statusText = result == kIOReturnSuccess
                ? "player_leds_set_\(safeMask)"
                : "player_leds_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    @discardableResult
    func setRumble(left: Float, right: Float, durationMs: Int?) -> Bool {
        let safeLeft = UInt8(clamping: Int(clamp01(left) * 255))
        let safeRight = UInt8(clamping: Int(clamp01(right) * 255))
        let safeDuration = max(0, min(durationMs ?? 0, 5000))
        let ok = queue.sync {
            rumbleStopWorkItem?.cancel()
            rumbleStopWorkItem = nil
            guard let device = writableDevice() else { return false }
            let result = sendReportWithReopen(.rumble(leftMotor: safeLeft, rightMotor: safeRight), device: device)
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
    func setMicMuteLED(on: Bool) -> Bool {
        setMicMuteLED(control: on ? 1 : 0)
    }

    @discardableResult
    func setMicMuteLED(control: UInt8) -> Bool {
        let safeControl = min(control, 2)
        return queue.sync {
            guard let device = writableDevice() else { return false }
            let result = sendReportWithReopen(.micMuteLED(control: safeControl), device: device)
            statusText = result == kIOReturnSuccess
                ? "mic_mute_led_\(safeControl)"
                : "mic_mute_led_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    @discardableResult
    func setLightbar(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8?) -> Bool {
        queue.sync {
            guard let device = writableDevice() else { return false }
            let result = sendReportWithReopen(.lightbar(red: red, green: green, blue: blue, brightness: brightness), device: device)
            statusText = result == kIOReturnSuccess
                ? "lightbar_set"
                : "lightbar_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    @discardableResult
    func setAdaptiveTrigger(side: DualSenseTriggerSide, mode: UInt8, params: [UInt8]) -> Bool {
        queue.sync {
            guard let device = writableDevice() else { return false }
            let result = sendReportWithReopen(.adaptiveTrigger(side: side, mode: mode, params: params), device: device)
            statusText = result == kIOReturnSuccess
                ? "hid_trigger_set"
                : "hid_trigger_failed_\(String(format: "%08x", result))"
            return result == kIOReturnSuccess
        }
    }

    static func parseSpecialButtons(report: Data) -> UInt8? {
        DualSenseProtocol.specialButtonsByte(from: report)
    }

    fileprivate static func parseInputReport(_ report: Data) -> DualSenseInputReport? {
        DualSenseProtocol.parseInputReport(report)
    }

    static func pressedSpecialButtons(from value: UInt8) -> [(ControllerButton, Bool)] {
        [
            (.buttonHome, (value & 0x01) != 0),
            (.touchpadButton, (value & 0x02) != 0),
            (.buttonMicrophoneMute, (value & 0x04) != 0)
        ]
    }

    static func hatButtons(_ hat: UInt8) -> Set<ControllerButton> {
        Set(DualSenseProtocol.dpadButtons(from: hat).compactMap(Self.controllerButton))
    }

    static func bluetoothOutputReport(playerLEDMask: UInt8, sequence: UInt8 = 0) -> Data {
        bluetoothOutputReport(effect: .playerLEDs(mask: playerLEDMask, brightness: nil), sequence: sequence)
    }

    static func bluetoothOutputReport(leftMotor: UInt8, rightMotor: UInt8, sequence: UInt8 = 0) -> Data {
        bluetoothOutputReport(effect: .rumble(leftMotor: leftMotor, rightMotor: rightMotor), sequence: sequence)
    }

    private static func bluetoothOutputReport(effect: HIDOutputEffect, sequence: UInt8) -> Data {
        let state = outputState(for: effect)
        return DualSenseProtocol.bluetoothOutputReport(state: state, sequence: sequence)
    }

    fileprivate func attach(_ matchedDevice: IOHIDDevice) {
        queue.sync {
            if let device, CFEqual(device, matchedDevice), isOpen {
                return
            }
            if device != nil, isOpen {
                DiagnosticsLog.write(
                    "hid matched ignored currentTransport=\(stringProperty(kIOHIDTransportKey) ?? "unknown") newTransport=\(stringProperty(kIOHIDTransportKey, device: matchedDevice) ?? "unknown")"
                )
                return
            }
            _ = activateDevice(matchedDevice, reason: "matched")
        }
    }

    fileprivate func remove(_ removedDevice: IOHIDDevice) {
        queue.sync {
            guard let device, CFEqual(device, removedDevice) else { return }
            DiagnosticsLog.write(
                "hid device removed transport=\(stringProperty(kIOHIDTransportKey) ?? "unknown") product=\(stringProperty(kIOHIDProductKey) ?? "unknown")"
            )
            closeCurrentDevice()
            statusText = "device_removed"
            refreshSelectedDeviceIfNeeded()
        }
    }

    fileprivate func handleInputReport(data: Data) {
        let reportID = data.first ?? 0
        rawReports.append(RawHIDReport(
            reportID: reportID,
            length: data.count,
            hex: data.map { String(format: "%02x", $0) }.joined(separator: " "),
            timestamp: Date()
        ))
        if rawReports.count > maxRawReports {
            rawReports.removeFirst(rawReports.count - maxRawReports)
        }
        guard let parsed = Self.parseInputReport(data) else { return }
        emitAxes(parsed)
        emitButtons(parsed)
        emitTouch(parsed)
    }

    private func emitAxes(_ report: DualSenseInputReport) {
        for (name, value) in report.axes {
            let old = previousAxes[name] ?? -1
            guard abs(old - value) >= 0.01 else { continue }
            previousAxes[name] = value
            axisUpdate(name, value)
        }
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

    private func sendReportWithReopen(_ effect: HIDOutputEffect, device: IOHIDDevice) -> IOReturn {
        let firstResult = sendReport(effect, device: device)
        guard firstResult != kIOReturnSuccess else { return firstResult }
        DiagnosticsLog.write(
            "hid reopen after failed output effect=\(effect.logName) firstResult=\(String(format: "%08x", firstResult))"
        )
        reopenDevice(device)
        guard isOpen else { return firstResult }
        let secondResult = sendReport(effect, device: device)
        if secondResult != kIOReturnSuccess {
            statusText = "set_report_failed_\(String(format: "%08x", secondResult))_after_reopen_first_\(String(format: "%08x", firstResult))"
        }
        return secondResult
    }

    private func sendReport(_ effect: HIDOutputEffect, device: IOHIDDevice) -> IOReturn {
        let reportState = Self.outputState(for: effect)
        let transport = stringProperty(kIOHIDTransportKey) ?? "unknown"
        let report = Self.outputReport(
            state: reportState,
            transport: transport,
            sequence: nextOutputSequenceIfBluetooth(transport: transport)
        )
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
            DiagnosticsLog.write(
                "hid output transport=\(transport) effect=\(effect.logName) attempt=\(name) reportID=\(reportID) length=\(data.count) result=\(String(format: "%08x", result)) bytes=\(data.hexString)"
            )
            if result == kIOReturnSuccess {
                statusText = "report_sent_via_\(name)"
                return result
            }
            failures.append("\(name)=\(String(format: "%08x", result))")
            lastResult = result
        }
        statusText = "set_report_failed_\(failures.joined(separator: ","))"
        return lastResult
    }

    private func nextOutputSequenceIfBluetooth(transport: String) -> UInt8? {
        guard Self.isBluetoothTransport(transport) else { return nil }
        let current = outputSequence & 0x0f
        outputSequence = (outputSequence + 1) & 0x0f
        return current
    }

    private static func outputState(for effect: HIDOutputEffect) -> DualSenseOutputState {
        var state = DualSenseOutputState()
        state.validFlag0 = 0
        state.validFlag1 = 0
        state.validFlag2 = 0
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
        }
        return state
    }

    static func outputReport(
        state: DualSenseOutputState,
        transport: String?,
        sequence: UInt8? = nil
    ) -> Data {
        if isBluetoothTransport(transport) {
            return DualSenseProtocol.bluetoothOutputReport(state: state, sequence: sequence ?? 0)
        }
        return DualSenseProtocol.usbOutputReport(state: state)
    }

    static func isBluetoothTransport(_ transport: String?) -> Bool {
        transport?.localizedCaseInsensitiveContains("bluetooth") == true
    }

    private func reopenDevice(_ device: IOHIDDevice) {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = result == kIOReturnSuccess
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        if result != kIOReturnSuccess {
            statusText = "device_reopen_failed_\(String(format: "%08x", result))"
        }
    }

    private func writableDevice() -> IOHIDDevice? {
        refreshSelectedDeviceIfNeeded()
        guard let device else {
            statusText = "hid_not_connected"
            return nil
        }
        if isOpen {
            return device
        }
        reopenDevice(device)
        if isOpen {
            statusText = "device_reopened"
            return device
        }
        statusText = "hid_not_open"
        return nil
    }

    private func refreshSelectedDeviceIfNeeded() {
        guard !isOpen, let manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard !devices.isEmpty else {
            closeCurrentDevice()
            statusText = "hid_not_connected"
            return
        }
        let candidates = sortedCandidates(devices)
        for candidate in candidates where activateDevice(candidate, reason: "refresh") {
            return
        }
        statusText = "hid_not_open"
    }

    private func sortedCandidates(_ devices: Set<IOHIDDevice>) -> [IOHIDDevice] {
        devices.sorted { lhs, rhs in
            if let device {
                let lhsIsCurrent = CFEqual(lhs, device)
                let rhsIsCurrent = CFEqual(rhs, device)
                if lhsIsCurrent != rhsIsCurrent {
                    return lhsIsCurrent
                }
            }
            let lhsBluetooth = Self.isBluetoothTransport(stringProperty(kIOHIDTransportKey, device: lhs))
            let rhsBluetooth = Self.isBluetoothTransport(stringProperty(kIOHIDTransportKey, device: rhs))
            if lhsBluetooth != rhsBluetooth {
                return lhsBluetooth
            }
            return (stringProperty(kIOHIDTransportKey, device: lhs) ?? "") < (stringProperty(kIOHIDTransportKey, device: rhs) ?? "")
        }
    }

    @discardableResult
    private func activateDevice(_ nextDevice: IOHIDDevice, reason: String) -> Bool {
        let sameDevice = device.map { CFEqual($0, nextDevice) } ?? false
        if !sameDevice {
            closeCurrentDevice()
            device = nextDevice
        } else if inputBuffer != nil {
            IOHIDDeviceUnscheduleFromRunLoop(nextDevice, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(nextDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            inputBuffer?.deallocate()
            inputBuffer = nil
            isOpen = false
        }

        let result = IOHIDDeviceOpen(nextDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = result == kIOReturnSuccess
        if isOpen {
            IOHIDDeviceScheduleWithRunLoop(nextDevice, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
            inputBuffer?.initialize(repeating: 0, count: inputBufferSize)
            if let inputBuffer {
                IOHIDDeviceRegisterInputReportCallback(
                    nextDevice,
                    inputBuffer,
                    inputBufferSize,
                    inputReportReceived,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
            statusText = "open"
        } else {
            statusText = "device_open_failed_\(String(format: "%08x", result))"
        }
        DiagnosticsLog.write(
            "hid device activate reason=\(reason) transport=\(stringProperty(kIOHIDTransportKey, device: nextDevice) ?? "unknown") product=\(stringProperty(kIOHIDProductKey, device: nextDevice) ?? "unknown") result=\(String(format: "%08x", result))"
        )
        return isOpen
    }

    private func closeCurrentDevice() {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        inputBuffer?.deallocate()
        inputBuffer = nil
        device = nil
        isOpen = false
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
        guard let device else { return nil }
        return stringProperty(key, device: device)
    }

    private func stringProperty(_ key: String, device: IOHIDDevice) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return value as? String
    }

    private func intProperty(_ key: String) -> Int? {
        guard let device,
              let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
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
        case .l2: return .leftTrigger
        case .r2: return .rightTrigger
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
}

private extension HIDOutputEffect {
    var logName: String {
        switch self {
        case .playerLEDs: return "playerLEDs"
        case .rumble: return "rumble"
        case .micMuteLED: return "micMuteLED"
        case .lightbar: return "lightbar"
        case .adaptiveTrigger: return "adaptiveTrigger"
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

private func deviceMatched(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice?) {
    guard result == kIOReturnSuccess, let context, let device else { return }
    let service = Unmanaged<DualSenseHIDService>.fromOpaque(context).takeUnretainedValue()
    service.attach(device)
}

private func deviceRemoved(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice?) {
    guard result == kIOReturnSuccess, let context, let device else { return }
    let service = Unmanaged<DualSenseHIDService>.fromOpaque(context).takeUnretainedValue()
    service.remove(device)
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
