import Foundation
import GameController
import DualSenseKit

public final class ControllerService: @unchecked Sendable {
    private let eventBus: EventBus
    private let configStore: ConfigStore
    private let actionExecutor: ActionExecutor
    private let touchpadMapper = TouchpadMouseMapper()
    private let stickMouseMapper = StickMouseMapper()
    private let stateQueue = DispatchQueue(label: "DualSenseKitDemo.ControllerState")
    private lazy var hidService = DualSenseHIDService(
        buttonUpdate: { [weak self] button, pressed, value in
            self?.updateButton(button, value: value, pressed: pressed)
        },
        axisUpdate: { [weak self] name, value in
            self?.handleHIDAxis(name: name, value: value)
        },
        touchUpdate: { [weak self] name, x, y, active in
            self?.handleHIDTouch(name: name, x: x, y: y, active: active)
        },
        motionUpdate: { [weak self] motion in
            self?.handleHIDMotion(motion)
        },
        outputEvent: { [weak self] event in
            self?.eventBus.publish(event)
        }
    )
    private var buttonStates: [ControllerButton: ControllerButtonState] = Dictionary(
        uniqueKeysWithValues: ControllerButton.allCases.map {
            ($0, ControllerButtonState(button: $0, pressed: false, value: 0))
        }
    )
    private var leftStickX: Float = 0
    private var leftStickY: Float = 0
    private var leftStickTimer: DispatchSourceTimer?
    private var rightStickX: Float = 0
    private var rightStickY: Float = 0
    private var rightStickTimer: DispatchSourceTimer?
    private var primaryTouchTapStart: (date: Date, x: Float, y: Float, maxDistance: Double)?
    private lazy var recognizer = ButtonGestureRecognizer(
        configProvider: { [weak self] in self?.configStore.current.gestures ?? GestureTimingConfig() },
        emit: { [weak self] gesture in self?.handleGesture(gesture) }
    )

    private(set) var connectedController: GCController?
    public var connectedControllerName: String? { connectedController?.vendorName }

    public func diagnostics() -> ControllerDiagnostics {
        let controller = connectedController
        return ControllerDiagnostics(
            connectedController: controller?.vendorName,
            productCategory: controller?.productCategory,
            supportsLight: controller?.light != nil,
            isDualSenseProfile: controller?.extendedGamepad is GCDualSenseGamepad,
            hid: hidService.diagnostics(),
            buttons: stateQueue.sync { buttonStates.values.sorted { $0.button.rawValue < $1.button.rawValue } }
        )
    }

    public func recentRawHIDReports(limit: Int = 20) -> [RawHIDReport] {
        hidService.recentRawReports(limit: limit)
    }

    public func hidAudioStatus() -> HIDAudioStatusResponse {
        hidService.hidAudioStatus()
    }

    public init(eventBus: EventBus, configStore: ConfigStore, actionExecutor: ActionExecutor) {
        self.eventBus = eventBus
        self.configStore = configStore
        self.actionExecutor = actionExecutor
    }

    public func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        GCController.controllers().forEach { attach($0) }
        hidService.start()
    }

    public func stop() {
        stopLeftStickMouseTimer()
        stopRightStickMouseTimer()
        hidService.stop()
        GCController.stopWirelessControllerDiscovery()
        NotificationCenter.default.removeObserver(self)
    }

    public func setPlayerLEDs(mask: UInt8, brightness: UInt8? = nil) -> Bool {
        hidService.setPlayerLEDs(mask: mask, brightness: brightness)
    }

    public func setRumble(_ request: RumbleRequest) -> Bool {
        let heavy = request.heavy ?? request.left ?? 0
        let light = request.light ?? request.right ?? 0
        return hidService.setRumble(left: heavy, right: light, durationMs: request.durationMs)
    }

    public func startPoliceHeartbeatPattern(brightness: Float? = nil, intervalMs: Int = 260, durationMs: Int = 160) -> Bool {
        let safeBrightness = brightness.map { UInt8(clamping: Int(clamp01($0) * 2)) }
        return hidService.startPoliceHeartbeatPattern(brightness: safeBrightness, intervalMs: intervalMs, durationMs: durationMs)
    }

    public func stopEffectPattern() -> Bool {
        hidService.stopEffectPattern()
    }

    public func setAudioVolume(_ request: AudioVolumeRequest) -> Bool {
        hidService.setAudioVolume(headphone: request.headphone, speaker: request.speaker)
    }

    public func setHIDAudioTestTone(_ request: HIDAudioTestToneRequest) -> Bool {
        hidService.setHIDTestTone(
            target: request.target,
            enabled: request.enabled,
            durationMs: request.durationMs
        )
    }

    public func startHIDCapture(_ request: HIDCaptureStartRequest) -> HIDCaptureResponse {
        hidService.startCapture(durationMs: request.durationMs)
    }

    public func stopHIDCapture() -> HIDCaptureResponse {
        hidService.stopCapture()
    }

    public func setMicMuteLED(on: Bool) -> Bool {
        hidService.setMicMuteLED(on: on)
    }

    public func setMicMuteLED(_ request: MicMuteLEDRequest) -> Bool {
        if let mode = request.mode {
            switch mode {
            case .off: return hidService.setMicMuteLED(control: 0)
            case .on: return hidService.setMicMuteLED(control: 1)
            case .breathe: return hidService.setMicMuteLED(control: 2)
            }
        }
        return hidService.setMicMuteLED(on: request.on ?? false)
    }

    public func setLightbar(_ request: LightbarRequest) -> Bool {
        let brightness = request.brightness.map { UInt8(clamping: Int(clamp01($0) * 2)) }
        return hidService.setLightbar(
            red: request.r ?? 0,
            green: request.g ?? 0,
            blue: request.b ?? 0,
            brightness: brightness
        )
    }

    public func setTriggers(_ request: TriggerRequest) -> Bool {
        let dualSense = connectedController?.extendedGamepad as? GCDualSenseGamepad
        var hidOK = false
        if let left = request.left {
            if let dualSense {
                applyTrigger(left, to: dualSense.leftTrigger)
            }
            hidOK = applyHIDTrigger(left, side: .left) || hidOK
        }
        if let right = request.right {
            if let dualSense {
                applyTrigger(right, to: dualSense.rightTrigger)
            }
            hidOK = applyHIDTrigger(right, side: .right) || hidOK
        }
        return dualSense != nil || hidOK
    }

    public func resetEffects() {
        _ = hidService.setRumble(left: 0, right: 0, durationMs: nil)
        _ = hidService.setPlayerLEDs(mask: 0)
        guard let dualSense = connectedController?.extendedGamepad as? GCDualSenseGamepad else { return }
        dualSense.leftTrigger.setModeOff()
        dualSense.rightTrigger.setModeOff()
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        attach(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        if controller === connectedController {
            connectedController = nil
            stopLeftStickMouseTimer()
            eventBus.publish(BridgeEvent(type: "controller.disconnected", payload: [:]))
        }
    }

    private func attach(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }
        connectedController = controller
        eventBus.publish(BridgeEvent(type: "controller.connected", payload: [
            "name": controller.vendorName ?? "Unknown Controller"
        ]))
        wireExtendedGamepad(controller)
        wireDualSense(controller)
    }

    private func wireExtendedGamepad(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            guard let self else { return }
            self.handleStandardButtons(gamepad: gamepad, changedElement: element)
            self.updateLeftStickMouse(x: gamepad.leftThumbstick.xAxis.value, y: -gamepad.leftThumbstick.yAxis.value)
            self.updateRightStickMouse(x: gamepad.rightThumbstick.xAxis.value, y: -gamepad.rightThumbstick.yAxis.value)
        }
    }

    private func wireDualSense(_ controller: GCController) {
        guard let dualSense = controller.extendedGamepad as? GCDualSenseGamepad else { return }
        dualSense.touchpadPrimary.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            self.touchpadMapper.primaryMoved(x: x, y: y, config: self.configStore.current.touchpad)
            self.eventBus.publish(BridgeEvent(type: "touchpad.primary", payload: ["x": "\(x)", "y": "\(y)"]))
        }
        dualSense.touchpadSecondary.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            self.touchpadMapper.secondaryMoved(x: x, y: y, config: self.configStore.current.touchpad)
            self.eventBus.publish(BridgeEvent(type: "touchpad.secondary", payload: ["x": "\(x)", "y": "\(y)"]))
        }
        dualSense.touchpadButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.updateButton(.touchpadButton, value: pressed ? 1 : 0, pressed: pressed)
        }
    }

    private func handleStandardButtons(gamepad: GCExtendedGamepad, changedElement: GCControllerElement) {
        let pairs: [(GCControllerButtonInput?, ControllerButton)] = [
            (gamepad.buttonA, .buttonA),
            (gamepad.buttonB, .buttonB),
            (gamepad.buttonX, .buttonX),
            (gamepad.buttonY, .buttonY),
            (gamepad.dpad.up, .dpadUp),
            (gamepad.dpad.down, .dpadDown),
            (gamepad.dpad.left, .dpadLeft),
            (gamepad.dpad.right, .dpadRight),
            (gamepad.leftShoulder, .leftShoulder),
            (gamepad.rightShoulder, .rightShoulder),
            (gamepad.leftTrigger, .leftTrigger),
            (gamepad.rightTrigger, .rightTrigger),
            (gamepad.leftThumbstickButton, .leftThumbstickButton),
            (gamepad.rightThumbstickButton, .rightThumbstickButton),
            (gamepad.buttonMenu, .buttonMenu),
            (gamepad.buttonOptions, .buttonOptions),
            (gamepad.buttonHome, .buttonHome)
        ]

        for (input, button) in pairs {
            guard input != nil else { continue }
            updateButton(button, value: input?.value ?? 0)
        }
    }

    private func updateButton(_ button: ControllerButton, value: Float, pressed explicitPressed: Bool? = nil) {
        let config = configStore.current.gestures
        let oldState = stateQueue.sync {
            buttonStates[button] ?? ControllerButtonState(button: button, pressed: false, value: 0)
        }
        let pressed: Bool
        if let explicitPressed {
            pressed = explicitPressed
        } else if button == .leftTrigger || button == .rightTrigger {
            pressed = oldState.pressed
                ? value > config.triggerReleaseThreshold
                : value >= config.triggerPressThreshold
        } else {
            pressed = value >= 0.5
        }

        let newState = ControllerButtonState(button: button, pressed: pressed, value: value)
        stateQueue.sync {
            buttonStates[button] = newState
        }

        if oldState.pressed != pressed || abs(oldState.value - value) > 0.001 {
            eventBus.publish(BridgeEvent(type: "button.value", payload: [
                "button": button.rawValue,
                "pressed": "\(pressed)",
                "value": "\(value)"
            ]))
        }
        recognizer.update(button: button, pressed: pressed, value: value)
    }

    private func handleGesture(_ gesture: ButtonGesture) {
        eventBus.publish(BridgeEvent(type: "button.\(gesture.kind.rawValue)", payload: [
            "button": gesture.button.rawValue
        ]))
        let config = configStore.current
        if let actions = config.mappings[gesture] {
            actionExecutor.execute(actions, config: config)
        }
    }

    private func handleHIDAxis(name: String, value: Float) {
        switch name {
        case "leftStickX":
            updateLeftStickMouse(x: value, y: leftStickY)
        case "leftStickY":
            updateLeftStickMouse(x: leftStickX, y: value)
        case "rightStickX":
            updateRightStickMouse(x: value, y: rightStickY)
        case "rightStickY":
            updateRightStickMouse(x: rightStickX, y: value)
        default:
            break
        }
        eventBus.publish(BridgeEvent(type: "hid.axis", payload: [
            "axis": name,
            "value": "\(value)"
        ]))
    }

    private func updateLeftStickMouse(x: Float, y: Float) {
        leftStickX = x
        leftStickY = y
        if leftStickMagnitudeExceedsDeadZone(x: x, y: y) {
            startLeftStickMouseTimer()
        } else {
            stopLeftStickMouseTimer()
        }
    }

    private func leftStickMagnitudeExceedsDeadZone(x: Float, y: Float) -> Bool {
        abs(x) > 0.15 || abs(y) > 0.15
    }

    private func updateRightStickMouse(x: Float, y: Float) {
        rightStickX = x
        rightStickY = y
        if leftStickMagnitudeExceedsDeadZone(x: x, y: y) {
            startRightStickMouseTimer()
        } else {
            stopRightStickMouseTimer()
        }
    }

    private func startLeftStickMouseTimer() {
        guard leftStickTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let x = self.leftStickX
            let y = self.leftStickY
            guard self.leftStickMagnitudeExceedsDeadZone(x: x, y: y) else {
                self.stopLeftStickMouseTimer()
                return
            }
            _ = self.stickMouseMapper.move(leftStickX: x, leftStickY: y, config: self.configStore.current.touchpad)
        }
        leftStickTimer = timer
        timer.resume()
    }

    private func stopLeftStickMouseTimer() {
        leftStickTimer?.cancel()
        leftStickTimer = nil
    }

    private func startRightStickMouseTimer() {
        guard rightStickTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let x = self.rightStickX
            let y = self.rightStickY
            guard self.leftStickMagnitudeExceedsDeadZone(x: x, y: y) else {
                self.stopRightStickMouseTimer()
                return
            }
            _ = self.stickMouseMapper.move(rightStickX: x, rightStickY: y, config: self.configStore.current.touchpad)
        }
        rightStickTimer = timer
        timer.resume()
    }

    private func stopRightStickMouseTimer() {
        rightStickTimer?.cancel()
        rightStickTimer = nil
    }

    private func handleHIDTouch(name: String, x: Float, y: Float, active: Bool) {
        switch name {
        case "primary":
            if active {
                beginOrUpdatePrimaryTapCandidate(x: x, y: y)
                touchpadMapper.primaryMoved(x: x, y: y, config: configStore.current.touchpad)
            } else {
                finishPrimaryTapCandidate(x: x, y: y)
                touchpadMapper.resetPrimary()
            }
        case "secondary":
            if active {
                primaryTouchTapStart = nil
                touchpadMapper.secondaryMoved(x: x, y: y, config: configStore.current.touchpad)
            } else {
                touchpadMapper.resetSecondary()
            }
        default:
            break
        }
        eventBus.publish(BridgeEvent(type: "hid.touch", payload: [
            "point": name,
            "x": "\(x)",
            "y": "\(y)",
            "active": "\(active)"
        ]))
    }

    private func beginOrUpdatePrimaryTapCandidate(x: Float, y: Float) {
        if primaryTouchTapStart == nil {
            primaryTouchTapStart = (Date(), x, y, 0)
            return
        }
        guard var start = primaryTouchTapStart else { return }
        let dx = Double(x - start.x)
        let dy = Double(y - start.y)
        start.maxDistance = max(start.maxDistance, sqrt(dx * dx + dy * dy))
        primaryTouchTapStart = start
    }

    private func finishPrimaryTapCandidate(x: Float, y: Float) {
        defer { primaryTouchTapStart = nil }
        guard let start = primaryTouchTapStart else { return }
        let duration = Date().timeIntervalSince(start.date)
        let dx = Double(x - start.x)
        let dy = Double(y - start.y)
        let distance = max(start.maxDistance, sqrt(dx * dx + dy * dy))
        guard duration <= 0.22, distance <= 0.035 else { return }
        handleGesture(ButtonGesture(button: .touchpadOneFingerTap, kind: .singleClick))
    }

    private func handleHIDMotion(_ motion: DualSenseMotion) {
        var payload: [String: String] = [
            "gyroX": "\(motion.gyroX)",
            "gyroY": "\(motion.gyroY)",
            "gyroZ": "\(motion.gyroZ)",
            "accelX": "\(motion.accelX)",
            "accelY": "\(motion.accelY)",
            "accelZ": "\(motion.accelZ)"
        ]
        if let timestamp = motion.timestamp {
            payload["timestamp"] = "\(timestamp)"
        }
        eventBus.publish(BridgeEvent(type: "hid.motion", payload: payload))
    }

    private func applyTrigger(_ request: TriggerSideRequest, to trigger: GCDualSenseAdaptiveTrigger) {
        switch request.mode {
        case .off:
            trigger.setModeOff()
        case .feedback:
            trigger.setModeFeedbackWithStartPosition(
                clamp01(request.startPosition ?? 0),
                resistiveStrength: clamp01(request.strength ?? 0)
            )
        case .weapon:
            trigger.setModeWeaponWithStartPosition(
                clamp01(request.startPosition ?? 0.1),
                endPosition: clamp01(request.endPosition ?? 0.8),
                resistiveStrength: clamp01(request.strength ?? 1)
            )
        case .vibration:
            trigger.setModeVibrationWithStartPosition(
                clamp01(request.startPosition ?? 0.1),
                amplitude: clamp01(request.amplitude ?? request.strength ?? 1),
                frequency: clampFrequency(request.frequency ?? 10)
            )
        case .slopeFeedback:
            trigger.setModeSlopeFeedback(
                startPosition: clamp01(request.startPosition ?? 0.1),
                endPosition: clamp01(request.endPosition ?? 0.9),
                startStrength: clamp01(request.strength ?? 0.2),
                endStrength: clamp01(request.endStrength ?? request.strength ?? 1)
            )
        }
    }

    private func applyHIDTrigger(_ request: TriggerSideRequest, side: DualSenseTriggerSide) -> Bool {
        let byte = { (value: Float?, fallback: Float) -> UInt8 in
            UInt8(clamping: Int(self.clamp01(value ?? fallback) * 255))
        }
        switch request.mode {
        case .off:
            return hidService.setAdaptiveTrigger(side: side, mode: 0x00, params: [])
        case .feedback:
            return hidService.setAdaptiveTrigger(side: side, mode: 0x01, params: [
                byte(request.startPosition, 0.15),
                byte(request.strength, 0.8)
            ])
        case .weapon:
            return hidService.setAdaptiveTrigger(side: side, mode: 0x02, params: [
                byte(request.startPosition, 0.10),
                byte(request.endPosition, 0.45),
                byte(request.strength, 1)
            ])
        case .vibration:
            return hidService.setAdaptiveTrigger(side: side, mode: 0x06, params: [
                UInt8(clamping: Int(clampFrequency(request.frequency ?? 10))),
                byte(request.amplitude ?? request.strength, 1),
                byte(request.startPosition, 0.1)
            ])
        case .slopeFeedback:
            return hidService.setAdaptiveTrigger(side: side, mode: 0x01, params: [
                byte(request.startPosition, 0.1),
                byte(request.strength, 0.4)
            ])
        }
    }

    private func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }

    private func clampFrequency(_ value: Float) -> Float {
        min(30, max(0, value))
    }
}
