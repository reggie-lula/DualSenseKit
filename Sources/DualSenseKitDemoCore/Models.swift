import Foundation

enum ControllerButton: String, Codable, CaseIterable, Hashable, Sendable {
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

enum PressKind: String, Codable, CaseIterable, Hashable, Sendable {
    case singleClick
    case doubleClick
    case longPress
    case press
    case release
}

struct ButtonGesture: Codable, Hashable, Sendable {
    var button: ControllerButton
    var kind: PressKind
}

enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

struct KeyStroke: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: [KeyModifier]
}

enum KeyModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case option
    case control
    case shift
}

enum Action: Codable, Hashable, Sendable {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct TouchpadConfig: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var sensitivity: Double = 900
    var scrollSensitivity: Double = 14
    var invertX: Bool = false
    var invertY: Bool = true
    var deadZone: Double = 0.006
    var accelerationEnabled: Bool = true
}

struct GestureTimingConfig: Codable, Equatable, Sendable {
    var doubleClickWindowMilliseconds: Int = 300
    var longPressMilliseconds: Int = 600
    var triggerPressThreshold: Float = 0.55
    var triggerReleaseThreshold: Float = 0.35
}

struct ShellConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var allowedCommands: [String] = []
    var allowedScriptDirectories: [String] = []
}

struct ServerConfig: Codable, Equatable, Sendable {
    var host: String = "127.0.0.1"
    var port: UInt16 = 17395
}

struct BridgeConfig: Codable, Equatable, Sendable {
    var touchpad = TouchpadConfig()
    var gestures = GestureTimingConfig()
    var shell = ShellConfig()
    var server = ServerConfig()
    var mappings: [ButtonGesture: [Action]] = BridgeConfig.defaultMappings()

    static func defaultMappings() -> [ButtonGesture: [Action]] {
        let tabKeyCode: UInt16 = 48
        let enterKeyCode: UInt16 = 36
        let mappings: [ButtonGesture: [Action]] = [
            ButtonGesture(button: .buttonA, kind: .singleClick): [
                .keyStroke(KeyStroke(keyCode: enterKeyCode, modifiers: []))
            ],
            ButtonGesture(button: .rightShoulder, kind: .singleClick): [
                .keyStroke(KeyStroke(keyCode: tabKeyCode, modifiers: [.command]))
            ],
            ButtonGesture(button: .leftShoulder, kind: .singleClick): [
                .keyStroke(KeyStroke(keyCode: tabKeyCode, modifiers: [.command, .shift]))
            ],
            ButtonGesture(button: .leftThumbstickButton, kind: .singleClick): [.mouseClick(.left)],
            ButtonGesture(button: .rightThumbstickButton, kind: .singleClick): [.mouseClick(.right)],
            ButtonGesture(button: .touchpadButton, kind: .press): [.mouseClick(.left)],
            ButtonGesture(button: .touchpadOneFingerTap, kind: .singleClick): [.mouseClick(.left)],
            ButtonGesture(button: .touchpadTwoFingerTap, kind: .singleClick): [.mouseClick(.right)]
        ]
        return mappings
    }
}

struct RGBColorRequest: Codable, Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

struct PlayerLEDRequest: Codable, Equatable, Sendable {
    var mask: UInt8
    var brightness: UInt8? = nil
}

struct MicMuteLEDRequest: Codable, Equatable, Sendable {
    var on: Bool? = nil
    var mode: MicMuteLEDMode? = nil
}

enum MicMuteLEDMode: String, Codable, Equatable, Sendable {
    case off
    case on
    case breathe
}

struct LightbarRequest: Codable, Equatable, Sendable {
    var r: UInt8? = nil
    var g: UInt8? = nil
    var b: UInt8? = nil
    var brightness: Float? = nil
}

struct RumbleRequest: Codable, Equatable, Sendable {
    var left: Float? = nil
    var right: Float? = nil
    var heavy: Float? = nil
    var light: Float? = nil
    var durationMs: Int? = nil
}

enum TriggerMode: String, Codable, Equatable, Sendable {
    case off
    case feedback
    case weapon
    case vibration
    case slopeFeedback
}

struct TriggerSideRequest: Codable, Equatable, Sendable {
    var mode: TriggerMode
    var startPosition: Float? = nil
    var endPosition: Float? = nil
    var strength: Float? = nil
    var endStrength: Float? = nil
    var amplitude: Float? = nil
    var frequency: Float? = nil
}

struct TriggerRequest: Codable, Equatable, Sendable {
    var left: TriggerSideRequest? = nil
    var right: TriggerSideRequest? = nil
}

struct StatusResponse: Codable, Equatable, Sendable {
    var connectedController: String?
    var accessibilityTrusted: Bool
    var touchpadEnabled: Bool
    var audioCapability: AudioCapability
    var dualSenseAudioOutput: String?
    var hidConnected: Bool
    var hidWritable: Bool
    var hidStatus: String
    var serverHost: String
    var serverPort: UInt16
    var tokenFile: String
}

struct ControllerButtonState: Codable, Equatable, Sendable {
    var button: ControllerButton
    var pressed: Bool
    var value: Float
}

struct ControllerDiagnostics: Codable, Equatable, Sendable {
    var connectedController: String?
    var productCategory: String?
    var supportsLight: Bool
    var isDualSenseProfile: Bool
    var hid: HIDDiagnostics
    var buttons: [ControllerButtonState]
}

struct HIDDiagnostics: Codable, Equatable, Sendable {
    var connected: Bool
    var writable: Bool
    var product: String?
    var vendorID: Int?
    var productID: Int?
    var transport: String?
    var status: String
}

struct RawHIDReport: Codable, Equatable, Sendable {
    var reportID: UInt8
    var length: Int
    var hex: String
    var timestamp: Date
}

struct AudioOutputDevice: Codable, Equatable, Sendable {
    var id: UInt32
    var name: String
    var uid: String?
}

struct AudioDeviceInfo: Codable, Equatable, Sendable {
    var id: UInt32
    var name: String
    var uid: String?
    var hasInput: Bool
    var hasOutput: Bool
    var isDefaultInput: Bool
    var isDefaultOutput: Bool
    var isDualSenseCandidate: Bool
}

struct AudioDevicesResponse: Codable, Equatable, Sendable {
    var inputs: [AudioDeviceInfo]
    var outputs: [AudioDeviceInfo]
    var defaultInputID: UInt32?
    var defaultOutputID: UInt32?
    var dualSenseInput: AudioDeviceInfo?
    var dualSenseOutput: AudioDeviceInfo?
    var dualSenseAudioStatus: String
    var note: String
}

enum AudioCapability: String, Codable, Equatable, Sendable {
    case dualSenseOutputAvailable
    case unsupported
    case macFallback
}

enum AudioOperationStatus: String, Codable, Equatable, Sendable {
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

struct PlayAudioRequest: Codable, Equatable, Sendable {
    var path: String?
    var systemSoundName: String?
    var useMacFallback: Bool?
    var outputDeviceID: UInt32? = nil
}

struct PlayAudioResult: Codable, Equatable, Sendable {
    var status: AudioOperationStatus
    var capability: AudioCapability
    var outputDeviceID: UInt32?
    var outputDeviceName: String?
    var path: String?
    var message: String
}

struct AudioVolumeRequest: Codable, Equatable, Sendable {
    var headphone: Float? = nil
    var speaker: Float? = nil
}

struct SystemVolumeRequest: Codable, Equatable, Sendable {
    var outputDeviceID: UInt32? = nil
    var volume: Float
}

struct AudioVolumeState: Codable, Equatable, Sendable {
    var hidHeadphone: Float
    var hidSpeaker: Float
    var outputDeviceID: UInt32?
    var outputDeviceName: String?
    var systemVolume: Float?
    var systemVolumeWritable: Bool
    var status: AudioOperationStatus
    var message: String
}

enum HIDAudioTarget: String, Codable, Equatable, Sendable {
    case speaker
    case headphone
}

struct HIDAudioTestToneRequest: Codable, Equatable, Sendable {
    var target: HIDAudioTarget
    var enabled: Bool
    var durationMs: Int? = nil
}

struct HIDAudioStatusResponse: Codable, Equatable, Sendable {
    var hidConnected: Bool
    var hidWritable: Bool
    var transport: String?
    var headphoneDetected: Bool?
    var microphoneDetected: Bool?
    var micMuted: Bool?
    var rawStatus0: String?
    var rawStatus1: String?
    var sourceConnection: String?
    var reliability: String
    var message: String
}

struct HIDCaptureStartRequest: Codable, Equatable, Sendable {
    var durationMs: Int? = nil
}

struct HIDCaptureResponse: Codable, Equatable, Sendable {
    var active: Bool
    var startedAt: Date?
    var stoppedAt: Date?
    var reportCount: Int
    var uniqueReportIDs: [UInt8]
    var byteChangeSummary: [String]
    var pcmEvidence: String
    var message: String
    var reports: [RawHIDReport]
}

struct RecordAudioRequest: Codable, Equatable, Sendable {
    var inputDeviceID: UInt32? = nil
    var useMacFallback: Bool? = nil
    var durationMs: Int? = nil
}

struct RecordAudioStatus: Codable, Equatable, Sendable {
    var status: AudioOperationStatus
    var inputDeviceID: UInt32?
    var inputDeviceName: String?
    var outputPath: String?
    var startedAt: Date?
    var elapsedMs: Int?
    var message: String
}

struct SayAudioRequest: Codable, Equatable, Sendable {
    var text: String
    var voiceIdentifier: String?
    var useMacFallback: Bool?
}
