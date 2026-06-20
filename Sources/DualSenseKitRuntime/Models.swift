import Foundation

public enum ControllerButton: String, Codable, CaseIterable, Hashable, Sendable {
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger
    case leftThumbstickButton
    case rightThumbstickButton
    case buttonMenu
    case buttonOptions
    case buttonHome
    case buttonMicrophoneMute
    case touchpadButton
    case touchpadOneFingerTap
    case touchpadTwoFingerTap
}

public enum PressKind: String, Codable, CaseIterable, Hashable, Sendable {
    case singleClick
    case doubleClick
    case longPress
    case press
    case release
}

public struct ButtonGesture: Codable, Hashable, Sendable {
    public var button: ControllerButton
    public var kind: PressKind

    public init(button: ControllerButton, kind: PressKind) {
        self.button = button
        self.kind = kind
    }
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

public struct KeyStroke: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: [KeyModifier]

    public init(keyCode: UInt16, modifiers: [KeyModifier]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum KeyModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case option
    case control
    case shift
}

public enum Action: Codable, Hashable, Sendable {
    case keyStroke(KeyStroke)
    case text(String)
    case mouseClick(MouseButton)
    case scroll(dx: Int32, dy: Int32)
    case mediaKey(UInt16)
    case openURL(String)
    case openApplication(String)
    case shell(command: String)

    enum CodingKeys: String, CodingKey {
        case type
        case keyStroke
        case text
        case mouseButton
        case dx
        case dy
        case mediaKey
        case url
        case application
        case command
    }

    enum ActionType: String, Codable {
        case keyStroke
        case text
        case mouseClick
        case scroll
        case mediaKey
        case openURL
        case openApplication
        case shell
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)
        switch type {
        case .keyStroke:
            self = .keyStroke(try container.decode(KeyStroke.self, forKey: .keyStroke))
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .mouseClick:
            self = .mouseClick(try container.decode(MouseButton.self, forKey: .mouseButton))
        case .scroll:
            self = .scroll(
                dx: try container.decode(Int32.self, forKey: .dx),
                dy: try container.decode(Int32.self, forKey: .dy)
            )
        case .mediaKey:
            self = .mediaKey(try container.decode(UInt16.self, forKey: .mediaKey))
        case .openURL:
            self = .openURL(try container.decode(String.self, forKey: .url))
        case .openApplication:
            self = .openApplication(try container.decode(String.self, forKey: .application))
        case .shell:
            self = .shell(command: try container.decode(String.self, forKey: .command))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keyStroke(let stroke):
            try container.encode(ActionType.keyStroke, forKey: .type)
            try container.encode(stroke, forKey: .keyStroke)
        case .text(let value):
            try container.encode(ActionType.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case .mouseClick(let button):
            try container.encode(ActionType.mouseClick, forKey: .type)
            try container.encode(button, forKey: .mouseButton)
        case .scroll(let dx, let dy):
            try container.encode(ActionType.scroll, forKey: .type)
            try container.encode(dx, forKey: .dx)
            try container.encode(dy, forKey: .dy)
        case .mediaKey(let code):
            try container.encode(ActionType.mediaKey, forKey: .type)
            try container.encode(code, forKey: .mediaKey)
        case .openURL(let url):
            try container.encode(ActionType.openURL, forKey: .type)
            try container.encode(url, forKey: .url)
        case .openApplication(let path):
            try container.encode(ActionType.openApplication, forKey: .type)
            try container.encode(path, forKey: .application)
        case .shell(let command):
            try container.encode(ActionType.shell, forKey: .type)
            try container.encode(command, forKey: .command)
        }
    }
}

public struct TouchpadConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var leftStickMouseEnabled: Bool = true
    public var rightStickMouseEnabled: Bool = false
    public var sensitivity: Double = 900
    public var scrollSensitivity: Double = 14
    public var invertX: Bool = false
    public var invertY: Bool = true
    public var deadZone: Double = 0.006
    public var accelerationEnabled: Bool = true

    public init(
        enabled: Bool = true,
        leftStickMouseEnabled: Bool = true,
        rightStickMouseEnabled: Bool = false,
        sensitivity: Double = 900,
        scrollSensitivity: Double = 14,
        invertX: Bool = false,
        invertY: Bool = true,
        deadZone: Double = 0.006,
        accelerationEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.leftStickMouseEnabled = leftStickMouseEnabled
        self.rightStickMouseEnabled = rightStickMouseEnabled
        self.sensitivity = sensitivity
        self.scrollSensitivity = scrollSensitivity
        self.invertX = invertX
        self.invertY = invertY
        self.deadZone = deadZone
        self.accelerationEnabled = accelerationEnabled
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case leftStickMouseEnabled
        case rightStickMouseEnabled
        case sensitivity
        case scrollSensitivity
        case invertX
        case invertY
        case deadZone
        case accelerationEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        leftStickMouseEnabled = try container.decodeIfPresent(Bool.self, forKey: .leftStickMouseEnabled) ?? true
        rightStickMouseEnabled = try container.decodeIfPresent(Bool.self, forKey: .rightStickMouseEnabled) ?? false
        sensitivity = try container.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 900
        scrollSensitivity = try container.decodeIfPresent(Double.self, forKey: .scrollSensitivity) ?? 14
        invertX = try container.decodeIfPresent(Bool.self, forKey: .invertX) ?? false
        invertY = try container.decodeIfPresent(Bool.self, forKey: .invertY) ?? true
        deadZone = try container.decodeIfPresent(Double.self, forKey: .deadZone) ?? 0.006
        accelerationEnabled = try container.decodeIfPresent(Bool.self, forKey: .accelerationEnabled) ?? true
    }
}

public struct GestureTimingConfig: Codable, Equatable, Sendable {
    public var doubleClickWindowMilliseconds: Int = 300
    public var longPressMilliseconds: Int = 600
    public var triggerPressThreshold: Float = 0.55
    public var triggerReleaseThreshold: Float = 0.35

    public init(doubleClickWindowMilliseconds: Int = 300, longPressMilliseconds: Int = 600, triggerPressThreshold: Float = 0.55, triggerReleaseThreshold: Float = 0.35) {
        self.doubleClickWindowMilliseconds = doubleClickWindowMilliseconds
        self.longPressMilliseconds = longPressMilliseconds
        self.triggerPressThreshold = triggerPressThreshold
        self.triggerReleaseThreshold = triggerReleaseThreshold
    }
}

public struct ShellConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var allowedCommands: [String] = []
    public var allowedScriptDirectories: [String] = []

    public init(enabled: Bool = false, allowedCommands: [String] = [], allowedScriptDirectories: [String] = []) {
        self.enabled = enabled
        self.allowedCommands = allowedCommands
        self.allowedScriptDirectories = allowedScriptDirectories
    }
}

public struct ServerConfig: Codable, Equatable, Sendable {
    public var host: String = "127.0.0.1"
    public var port: UInt16 = 17395

    public init(host: String = "127.0.0.1", port: UInt16 = 17395) {
        self.host = host
        self.port = port
    }
}

public struct BridgeConfig: Codable, Equatable, Sendable {
    public var touchpad = TouchpadConfig()
    public var gestures = GestureTimingConfig()
    public var shell = ShellConfig()
    public var server = ServerConfig()
    public var mappings: [ButtonGesture: [Action]] = BridgeConfig.defaultMappings()

    public init(touchpad: TouchpadConfig = TouchpadConfig(), gestures: GestureTimingConfig = GestureTimingConfig(), shell: ShellConfig = ShellConfig(), server: ServerConfig = ServerConfig(), mappings: [ButtonGesture: [Action]] = BridgeConfig.defaultMappings()) {
        self.touchpad = touchpad
        self.gestures = gestures
        self.shell = shell
        self.server = server
        self.mappings = mappings
    }

    public static func defaultMappings() -> [ButtonGesture: [Action]] {
        let tabKeyCode: UInt16 = 48
        let enterKeyCode: UInt16 = 36
        let spaceKeyCode: UInt16 = 49
        let mappings: [ButtonGesture: [Action]] = [
            ButtonGesture(button: .buttonA, kind: .press): [
                .keyStroke(KeyStroke(keyCode: enterKeyCode, modifiers: []))
            ],
            ButtonGesture(button: .buttonX, kind: .press): [
                .keyStroke(KeyStroke(keyCode: spaceKeyCode, modifiers: []))
            ],
            ButtonGesture(button: .rightShoulder, kind: .press): [
                .keyStroke(KeyStroke(keyCode: tabKeyCode, modifiers: [.command]))
            ],
            ButtonGesture(button: .leftShoulder, kind: .press): [
                .keyStroke(KeyStroke(keyCode: tabKeyCode, modifiers: [.command, .shift]))
            ],
            ButtonGesture(button: .leftThumbstickButton, kind: .press): [.mouseClick(.left)],
            ButtonGesture(button: .rightThumbstickButton, kind: .press): [.mouseClick(.right)],
            ButtonGesture(button: .touchpadButton, kind: .press): [.mouseClick(.left)],
            ButtonGesture(button: .touchpadOneFingerTap, kind: .singleClick): [.mouseClick(.left)],
            ButtonGesture(button: .touchpadTwoFingerTap, kind: .singleClick): [.mouseClick(.right)]
        ]
        return mappings
    }
}

public struct RGBColorRequest: Codable, Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public struct PlayerLEDRequest: Codable, Equatable, Sendable {
    public var mask: UInt8
    public var brightness: UInt8? = nil

    public init(mask: UInt8, brightness: UInt8? = nil) {
        self.mask = mask
        self.brightness = brightness
    }
}

public struct MicMuteLEDRequest: Codable, Equatable, Sendable {
    public var on: Bool? = nil
    public var mode: MicMuteLEDMode? = nil

    public init(on: Bool? = nil, mode: MicMuteLEDMode? = nil) {
        self.on = on
        self.mode = mode
    }
}

public enum MicMuteLEDMode: String, Codable, Equatable, Sendable {
    case off
    case on
    case breathe
}

public struct LightbarRequest: Codable, Equatable, Sendable {
    public var r: UInt8? = nil
    public var g: UInt8? = nil
    public var b: UInt8? = nil
    public var brightness: Float? = nil

    public init(r: UInt8? = nil, g: UInt8? = nil, b: UInt8? = nil, brightness: Float? = nil) {
        self.r = r
        self.g = g
        self.b = b
        self.brightness = brightness
    }
}

public struct HeartbeatRequest: Codable, Equatable, Sendable {
    public var intervalMs: Int? = nil
    public var durationMs: Int? = nil
    public var brightness: Float? = nil

    public init(intervalMs: Int? = nil, durationMs: Int? = nil, brightness: Float? = nil) {
        self.intervalMs = intervalMs
        self.durationMs = durationMs
        self.brightness = brightness
    }
}

public struct RumbleRequest: Codable, Equatable, Sendable {
    public var left: Float? = nil
    public var right: Float? = nil
    public var heavy: Float? = nil
    public var light: Float? = nil
    public var durationMs: Int? = nil

    public init(left: Float? = nil, right: Float? = nil, heavy: Float? = nil, light: Float? = nil, durationMs: Int? = nil) {
        self.left = left
        self.right = right
        self.heavy = heavy
        self.light = light
        self.durationMs = durationMs
    }
}

public enum TriggerMode: String, Codable, Equatable, Sendable {
    case off
    case feedback
    case weapon
    case vibration
    case slopeFeedback
}

public struct TriggerSideRequest: Codable, Equatable, Sendable {
    public var mode: TriggerMode
    public var startPosition: Float? = nil
    public var endPosition: Float? = nil
    public var strength: Float? = nil
    public var endStrength: Float? = nil
    public var amplitude: Float? = nil
    public var frequency: Float? = nil

    public init(mode: TriggerMode, startPosition: Float? = nil, endPosition: Float? = nil, strength: Float? = nil, endStrength: Float? = nil, amplitude: Float? = nil, frequency: Float? = nil) {
        self.mode = mode
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.strength = strength
        self.endStrength = endStrength
        self.amplitude = amplitude
        self.frequency = frequency
    }
}

public struct TriggerRequest: Codable, Equatable, Sendable {
    public var left: TriggerSideRequest? = nil
    public var right: TriggerSideRequest? = nil

    public init(left: TriggerSideRequest? = nil, right: TriggerSideRequest? = nil) {
        self.left = left
        self.right = right
    }
}

public struct StatusResponse: Codable, Equatable, Sendable {
    public var connectedController: String?
    public var accessibilityTrusted: Bool
    public var touchpadEnabled: Bool
    public var audioCapability: AudioCapability
    public var dualSenseAudioOutput: String?
    public var hidConnected: Bool
    public var hidWritable: Bool
    public var hidStatus: String
    public var serverHost: String
    public var serverPort: UInt16
    public var tokenFile: String

    public init(connectedController: String?, accessibilityTrusted: Bool, touchpadEnabled: Bool, audioCapability: AudioCapability, dualSenseAudioOutput: String?, hidConnected: Bool, hidWritable: Bool, hidStatus: String, serverHost: String, serverPort: UInt16, tokenFile: String) {
        self.connectedController = connectedController
        self.accessibilityTrusted = accessibilityTrusted
        self.touchpadEnabled = touchpadEnabled
        self.audioCapability = audioCapability
        self.dualSenseAudioOutput = dualSenseAudioOutput
        self.hidConnected = hidConnected
        self.hidWritable = hidWritable
        self.hidStatus = hidStatus
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.tokenFile = tokenFile
    }
}

public struct ControllerButtonState: Codable, Equatable, Sendable {
    public var button: ControllerButton
    public var pressed: Bool
    public var value: Float

    public init(button: ControllerButton, pressed: Bool, value: Float) {
        self.button = button
        self.pressed = pressed
        self.value = value
    }
}

public struct ControllerDiagnostics: Codable, Equatable, Sendable {
    public var connectedController: String?
    public var productCategory: String?
    public var supportsLight: Bool
    public var isDualSenseProfile: Bool
    public var hid: HIDDiagnostics
    public var buttons: [ControllerButtonState]

    public init(connectedController: String?, productCategory: String?, supportsLight: Bool, isDualSenseProfile: Bool, hid: HIDDiagnostics, buttons: [ControllerButtonState]) {
        self.connectedController = connectedController
        self.productCategory = productCategory
        self.supportsLight = supportsLight
        self.isDualSenseProfile = isDualSenseProfile
        self.hid = hid
        self.buttons = buttons
    }
}

public struct HIDDiagnostics: Codable, Equatable, Sendable {
    public var connected: Bool
    public var writable: Bool
    public var product: String?
    public var vendorID: Int?
    public var productID: Int?
    public var transport: String?
    public var status: String

    public init(connected: Bool, writable: Bool, product: String?, vendorID: Int?, productID: Int?, transport: String?, status: String) {
        self.connected = connected
        self.writable = writable
        self.product = product
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
        self.status = status
    }
}

public struct RawHIDReport: Codable, Equatable, Sendable {
    public var reportID: UInt8
    public var length: Int
    public var hex: String
    public var timestamp: Date

    public init(reportID: UInt8, length: Int, hex: String, timestamp: Date) {
        self.reportID = reportID
        self.length = length
        self.hex = hex
        self.timestamp = timestamp
    }
}

public struct AudioOutputDevice: Codable, Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var uid: String?

    public init(id: UInt32, name: String, uid: String?) {
        self.id = id
        self.name = name
        self.uid = uid
    }
}

public struct AudioDeviceInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var uid: String?
    public var hasInput: Bool
    public var hasOutput: Bool
    public var isDefaultInput: Bool
    public var isDefaultOutput: Bool
    public var isDualSenseCandidate: Bool

    public init(id: UInt32, name: String, uid: String?, hasInput: Bool, hasOutput: Bool, isDefaultInput: Bool, isDefaultOutput: Bool, isDualSenseCandidate: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
        self.isDualSenseCandidate = isDualSenseCandidate
    }
}

public struct AudioDevicesResponse: Codable, Equatable, Sendable {
    public var inputs: [AudioDeviceInfo]
    public var outputs: [AudioDeviceInfo]
    public var defaultInputID: UInt32?
    public var defaultOutputID: UInt32?
    public var dualSenseInput: AudioDeviceInfo?
    public var dualSenseOutput: AudioDeviceInfo?
    public var dualSenseAudioStatus: String
    public var note: String

    public init(inputs: [AudioDeviceInfo], outputs: [AudioDeviceInfo], defaultInputID: UInt32?, defaultOutputID: UInt32?, dualSenseInput: AudioDeviceInfo?, dualSenseOutput: AudioDeviceInfo?, dualSenseAudioStatus: String, note: String) {
        self.inputs = inputs
        self.outputs = outputs
        self.defaultInputID = defaultInputID
        self.defaultOutputID = defaultOutputID
        self.dualSenseInput = dualSenseInput
        self.dualSenseOutput = dualSenseOutput
        self.dualSenseAudioStatus = dualSenseAudioStatus
        self.note = note
    }
}

public enum AudioCapability: String, Codable, Equatable, Sendable {
    case dualSenseOutputAvailable
    case unsupported
    case macFallback
}

public enum AudioOperationStatus: String, Codable, Equatable, Sendable {
    case played
    case macFallback
    case unsupported
    case fileNotFound
    case outputNotFound
    case noDualSenseOutput
    case noDualSenseInput
    case inputNotFound
    case recording
    case notRecording
    case stopped
    case volumeSet
    case failed
}

public struct PlayAudioRequest: Codable, Equatable, Sendable {
    public var path: String?
    public var systemSoundName: String?
    public var useMacFallback: Bool?
    public var outputDeviceID: UInt32? = nil

    public init(path: String?, systemSoundName: String?, useMacFallback: Bool?, outputDeviceID: UInt32? = nil) {
        self.path = path
        self.systemSoundName = systemSoundName
        self.useMacFallback = useMacFallback
        self.outputDeviceID = outputDeviceID
    }
}

public struct PlayAudioResult: Codable, Equatable, Sendable {
    public var status: AudioOperationStatus
    public var capability: AudioCapability
    public var outputDeviceID: UInt32?
    public var outputDeviceName: String?
    public var path: String?
    public var message: String

    public init(status: AudioOperationStatus, capability: AudioCapability, outputDeviceID: UInt32?, outputDeviceName: String?, path: String?, message: String) {
        self.status = status
        self.capability = capability
        self.outputDeviceID = outputDeviceID
        self.outputDeviceName = outputDeviceName
        self.path = path
        self.message = message
    }
}

public struct AudioVolumeRequest: Codable, Equatable, Sendable {
    public var headphone: Float? = nil
    public var speaker: Float? = nil

    public init(headphone: Float? = nil, speaker: Float? = nil) {
        self.headphone = headphone
        self.speaker = speaker
    }
}

public struct SystemVolumeRequest: Codable, Equatable, Sendable {
    public var outputDeviceID: UInt32? = nil
    public var volume: Float

    public init(outputDeviceID: UInt32? = nil, volume: Float) {
        self.outputDeviceID = outputDeviceID
        self.volume = volume
    }
}

public struct AudioVolumeState: Codable, Equatable, Sendable {
    public var hidHeadphone: Float
    public var hidSpeaker: Float
    public var outputDeviceID: UInt32?
    public var outputDeviceName: String?
    public var systemVolume: Float?
    public var systemVolumeWritable: Bool
    public var status: AudioOperationStatus
    public var message: String

    public init(hidHeadphone: Float, hidSpeaker: Float, outputDeviceID: UInt32?, outputDeviceName: String?, systemVolume: Float?, systemVolumeWritable: Bool, status: AudioOperationStatus, message: String) {
        self.hidHeadphone = hidHeadphone
        self.hidSpeaker = hidSpeaker
        self.outputDeviceID = outputDeviceID
        self.outputDeviceName = outputDeviceName
        self.systemVolume = systemVolume
        self.systemVolumeWritable = systemVolumeWritable
        self.status = status
        self.message = message
    }
}

public enum HIDAudioTarget: String, Codable, Equatable, Sendable {
    case speaker
    case headphone
}

public struct HIDAudioTestToneRequest: Codable, Equatable, Sendable {
    public var target: HIDAudioTarget
    public var enabled: Bool
    public var durationMs: Int? = nil

    public init(target: HIDAudioTarget, enabled: Bool, durationMs: Int? = nil) {
        self.target = target
        self.enabled = enabled
        self.durationMs = durationMs
    }
}

public struct HIDAudioStatusResponse: Codable, Equatable, Sendable {
    public var hidConnected: Bool
    public var hidWritable: Bool
    public var transport: String?
    public var headphoneDetected: Bool?
    public var microphoneDetected: Bool?
    public var micMuted: Bool?
    public var rawStatus0: String?
    public var rawStatus1: String?
    public var sourceConnection: String?
    public var reliability: String
    public var message: String

    public init(hidConnected: Bool, hidWritable: Bool, transport: String?, headphoneDetected: Bool?, microphoneDetected: Bool?, micMuted: Bool?, rawStatus0: String?, rawStatus1: String?, sourceConnection: String?, reliability: String, message: String) {
        self.hidConnected = hidConnected
        self.hidWritable = hidWritable
        self.transport = transport
        self.headphoneDetected = headphoneDetected
        self.microphoneDetected = microphoneDetected
        self.micMuted = micMuted
        self.rawStatus0 = rawStatus0
        self.rawStatus1 = rawStatus1
        self.sourceConnection = sourceConnection
        self.reliability = reliability
        self.message = message
    }
}

public struct HIDCaptureStartRequest: Codable, Equatable, Sendable {
    public var durationMs: Int? = nil

    public init(durationMs: Int? = nil) {
        self.durationMs = durationMs
    }
}

public struct HIDCaptureResponse: Codable, Equatable, Sendable {
    public var active: Bool
    public var startedAt: Date?
    public var stoppedAt: Date?
    public var reportCount: Int
    public var uniqueReportIDs: [UInt8]
    public var byteChangeSummary: [String]
    public var pcmEvidence: String
    public var message: String
    public var reports: [RawHIDReport]

    public init(active: Bool, startedAt: Date?, stoppedAt: Date?, reportCount: Int, uniqueReportIDs: [UInt8], byteChangeSummary: [String], pcmEvidence: String, message: String, reports: [RawHIDReport]) {
        self.active = active
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.reportCount = reportCount
        self.uniqueReportIDs = uniqueReportIDs
        self.byteChangeSummary = byteChangeSummary
        self.pcmEvidence = pcmEvidence
        self.message = message
        self.reports = reports
    }
}

public struct RecordAudioRequest: Codable, Equatable, Sendable {
    public var inputDeviceID: UInt32? = nil
    public var useMacFallback: Bool? = nil
    public var durationMs: Int? = nil

    public init(inputDeviceID: UInt32? = nil, useMacFallback: Bool? = nil, durationMs: Int? = nil) {
        self.inputDeviceID = inputDeviceID
        self.useMacFallback = useMacFallback
        self.durationMs = durationMs
    }
}

public struct RecordAudioStatus: Codable, Equatable, Sendable {
    public var status: AudioOperationStatus
    public var inputDeviceID: UInt32?
    public var inputDeviceName: String?
    public var outputPath: String?
    public var startedAt: Date?
    public var elapsedMs: Int?
    public var message: String

    public init(status: AudioOperationStatus, inputDeviceID: UInt32?, inputDeviceName: String?, outputPath: String?, startedAt: Date?, elapsedMs: Int?, message: String) {
        self.status = status
        self.inputDeviceID = inputDeviceID
        self.inputDeviceName = inputDeviceName
        self.outputPath = outputPath
        self.startedAt = startedAt
        self.elapsedMs = elapsedMs
        self.message = message
    }
}

public struct SayAudioRequest: Codable, Equatable, Sendable {
    public var text: String
    public var voiceIdentifier: String?
    public var useMacFallback: Bool?

    public init(text: String, voiceIdentifier: String?, useMacFallback: Bool?) {
        self.text = text
        self.voiceIdentifier = voiceIdentifier
        self.useMacFallback = useMacFallback
    }
}
