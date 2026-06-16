import Foundation

public enum DualSenseConnection: Sendable {
    case usb
    case bluetooth
}

public enum DualSenseButton: String, CaseIterable, Hashable, Sendable {
    case square
    case cross
    case circle
    case triangle
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case l1
    case r1
    case l2
    case r2
    case create
    case options
    case l3
    case r3
    case ps
    case touchpad
    case microphoneMute
}

public struct DualSenseTouchPoint: Equatable, Sendable {
    public var id: UInt8
    public var x: Float
    public var y: Float
    public var active: Bool

    public init(id: UInt8, x: Float, y: Float, active: Bool) {
        self.id = id
        self.x = x
        self.y = y
        self.active = active
    }
}

public struct DualSenseInputReport: Sendable {
    public var axes: [String: Float]
    public var hat: UInt8
    public var buttons: [(DualSenseButton, Bool)]
    public var touchPoints: [DualSenseTouchPoint]

    public init(
        axes: [String: Float],
        hat: UInt8,
        buttons: [(DualSenseButton, Bool)],
        touchPoints: [DualSenseTouchPoint]
    ) {
        self.axes = axes
        self.hat = hat
        self.buttons = buttons
        self.touchPoints = touchPoints
    }
}

public struct DualSenseOutputState: Equatable, Sendable {
    public var validFlag0: UInt8 = 0
    public var validFlag1: UInt8 = 0xf7
    public var rightMotor: UInt8 = 0
    public var leftMotor: UInt8 = 0
    public var headphoneVolume: UInt8 = 0
    public var speakerVolume: UInt8 = 0
    public var microphoneVolume: UInt8 = 0
    public var audioControl: UInt8 = 0
    public var muteLEDControl: UInt8 = 0
    public var powerSaveMuteControl: UInt8 = 0
    public var rightTriggerMode: UInt8 = 0
    public var rightTriggerParams: [UInt8] = Array(repeating: 0, count: 10)
    public var leftTriggerMode: UInt8 = 0
    public var leftTriggerParams: [UInt8] = Array(repeating: 0, count: 10)
    public var hapticVolume: UInt8 = 0
    public var audioControl2: UInt8 = 0
    public var validFlag2: UInt8 = 0
    public var lightbarSetup: UInt8 = 0
    public var ledBrightness: UInt8 = 0
    public var playerIndicator: UInt8 = 0
    public var lightbarRed: UInt8 = 0
    public var lightbarGreen: UInt8 = 0
    public var lightbarBlue: UInt8 = 0

    public init() {}

    public var payload: Data {
        var bytes: [UInt8] = [
            validFlag0, validFlag1, rightMotor, leftMotor,
            headphoneVolume, speakerVolume, microphoneVolume, audioControl,
            muteLEDControl, powerSaveMuteControl, rightTriggerMode
        ]
        bytes.append(contentsOf: Array(rightTriggerParams.prefix(10)).padding(to: 10))
        bytes.append(leftTriggerMode)
        bytes.append(contentsOf: Array(leftTriggerParams.prefix(10)).padding(to: 10))
        bytes.append(contentsOf: [0, 0, 0, 0, hapticVolume, audioControl2, validFlag2, 0, 0])
        bytes.append(contentsOf: [lightbarSetup, ledBrightness, playerIndicator, lightbarRed, lightbarGreen, lightbarBlue])
        return Data(bytes)
    }
}

public enum DualSenseOutputIntent: Equatable, Sendable {
    case playerLEDs(mask: UInt8, brightness: UInt8? = nil)
    case micMuteLED(control: UInt8)
    case rumble(leftMotor: UInt8, rightMotor: UInt8)
    case lightbar(red: UInt8, green: UInt8, blue: UInt8, brightness: UInt8? = nil)
    case adaptiveTrigger(side: DualSenseTriggerSide, mode: UInt8, params: [UInt8])
    case resetEffects
}

public enum DualSenseTriggerSide: Sendable {
    case left
    case right
}

public enum DualSenseProtocol {
    public static let sonyVendorID = 0x054c
    public static let dualSenseProductID = 0x0ce6
    public static let dualSenseEdgeProductID = 0x0df2
    public static let bluetoothOutputReportID: UInt8 = 0x31
    public static let usbOutputReportID: UInt8 = 0x02

    public static func parseInputReport(_ report: Data) -> DualSenseInputReport? {
        let bytes = [UInt8](report)
        let offset: Int
        if bytes.count >= 78, bytes.first == 0x31 {
            offset = 2
        } else if bytes.count >= 64, bytes.first == 0x01 {
            offset = 1
        } else {
            return nil
        }
        guard bytes.count > offset + 39 else { return nil }

        let buttons0 = bytes[offset + 7]
        let buttons1 = bytes[offset + 8]
        let buttons2 = bytes[offset + 9]
        let leftTriggerValue = Float(bytes[offset + 4]) / 255
        let rightTriggerValue = Float(bytes[offset + 5]) / 255
        let buttons: [(DualSenseButton, Bool)] = [
            (.square, (buttons0 & 0x10) != 0),
            (.cross, (buttons0 & 0x20) != 0),
            (.circle, (buttons0 & 0x40) != 0),
            (.triangle, (buttons0 & 0x80) != 0),
            (.l1, (buttons1 & 0x01) != 0),
            (.r1, (buttons1 & 0x02) != 0),
            (.l2, leftTriggerValue >= 0.55 || (buttons1 & 0x04) != 0),
            (.r2, rightTriggerValue >= 0.55 || (buttons1 & 0x08) != 0),
            (.create, (buttons1 & 0x10) != 0),
            (.options, (buttons1 & 0x20) != 0),
            (.l3, (buttons1 & 0x40) != 0),
            (.r3, (buttons1 & 0x80) != 0),
            (.ps, (buttons2 & 0x01) != 0),
            (.touchpad, (buttons2 & 0x02) != 0),
            (.microphoneMute, (buttons2 & 0x04) != 0)
        ]
        var touchPoints: [DualSenseTouchPoint] = []
        let touchStart = offset + 32
        if bytes.count > touchStart + 7 {
            touchPoints.append(parseTouchPoint(bytes, offset: touchStart))
            touchPoints.append(parseTouchPoint(bytes, offset: touchStart + 4))
        }
        return DualSenseInputReport(
            axes: [
                "leftStickX": normalizeThumbStickAxis(bytes[offset + 0]),
                "leftStickY": normalizeThumbStickAxis(bytes[offset + 1]),
                "rightStickX": normalizeThumbStickAxis(bytes[offset + 2]),
                "rightStickY": normalizeThumbStickAxis(bytes[offset + 3]),
                "leftTriggerAnalog": leftTriggerValue,
                "rightTriggerAnalog": rightTriggerValue
            ],
            hat: buttons0 & 0x0f,
            buttons: buttons,
            touchPoints: touchPoints
        )
    }

    public static func specialButtonsByte(from report: Data) -> UInt8? {
        guard let parsed = parseInputReport(report) else { return nil }
        var value: UInt8 = 0
        for (button, pressed) in parsed.buttons where pressed {
            switch button {
            case .ps: value |= 0x01
            case .touchpad: value |= 0x02
            case .microphoneMute: value |= 0x04
            default: break
            }
        }
        return value
    }

    public static func dpadButtons(from hat: UInt8) -> Set<DualSenseButton> {
        switch hat {
        case 0: return [.dpadUp]
        case 1: return [.dpadUp, .dpadRight]
        case 2: return [.dpadRight]
        case 3: return [.dpadRight, .dpadDown]
        case 4: return [.dpadDown]
        case 5: return [.dpadDown, .dpadLeft]
        case 6: return [.dpadLeft]
        case 7: return [.dpadLeft, .dpadUp]
        default: return []
        }
    }

    public static func apply(_ intent: DualSenseOutputIntent, to state: inout DualSenseOutputState) {
        switch intent {
        case .playerLEDs(let mask, let brightness):
            state.playerIndicator = mask & 0x1f
            if let brightness {
                state.ledBrightness = brightness
                state.validFlag2 |= 0x01
            }
            state.validFlag1 |= 0x10
            state.validFlag1 &= ~0x08
        case .micMuteLED(let control):
            state.muteLEDControl = min(control, 2)
            state.validFlag1 |= 0x01
            state.validFlag1 &= ~0x08
        case .rumble(let leftMotor, let rightMotor):
            state.leftMotor = leftMotor
            state.rightMotor = rightMotor
            state.validFlag0 |= 0x03
        case .lightbar(let red, let green, let blue, let brightness):
            let scale = brightnessScale(brightness)
            state.lightbarRed = red
            state.lightbarGreen = green
            state.lightbarBlue = blue
            if scale < 1 {
                state.lightbarRed = UInt8(Float(red) * scale)
                state.lightbarGreen = UInt8(Float(green) * scale)
                state.lightbarBlue = UInt8(Float(blue) * scale)
            }
            state.validFlag1 |= 0x04
            state.validFlag1 &= ~0x08
        case .adaptiveTrigger(let side, let mode, let params):
            let padded = Array(params.prefix(10)).padding(to: 10)
            switch side {
            case .left:
                state.leftTriggerMode = mode
                state.leftTriggerParams = padded
                state.validFlag0 |= 0x08
            case .right:
                state.rightTriggerMode = mode
                state.rightTriggerParams = padded
                state.validFlag0 |= 0x04
            }
        case .resetEffects:
            state.leftMotor = 0
            state.rightMotor = 0
            state.leftTriggerMode = 0
            state.rightTriggerMode = 0
            state.leftTriggerParams = Array(repeating: 0, count: 10)
            state.rightTriggerParams = Array(repeating: 0, count: 10)
            state.playerIndicator = 0
            state.validFlag0 |= 0x0f
            state.validFlag1 |= 0x10
            state.validFlag1 &= ~0x08
        }
    }

    public static func bluetoothOutputReport(
        state: DualSenseOutputState,
        sequence: UInt8 = 0
    ) -> Data {
        var report = Data(repeating: 0, count: 78)
        report[0] = bluetoothOutputReportID
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x10
        report.replaceSubrange(3..<(3 + state.payload.count), with: state.payload)
        writeBluetoothCRC(to: &report)
        return report
    }

    public static func usbOutputReport(state: DualSenseOutputState) -> Data {
        var report = Data(repeating: 0, count: 48)
        report[0] = usbOutputReportID
        report.replaceSubrange(1..<(1 + state.payload.count), with: state.payload)
        return report
    }

    public static func normalizeThumbStickAxis(_ value: UInt8) -> Float {
        (2 * Float(value)) / 255 - 1
    }

    public static func crc32(bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
            }
        }
        return crc ^ 0xffffffff
    }

    private static func parseTouchPoint(_ bytes: [UInt8], offset: Int) -> DualSenseTouchPoint {
        let contact = bytes[offset]
        let active = (contact & 0x80) == 0
        let id = contact & 0x7f
        let xRaw = UInt16(bytes[offset + 1]) | (UInt16(bytes[offset + 2] & 0x0f) << 8)
        let yRaw = UInt16(bytes[offset + 2] >> 4) | (UInt16(bytes[offset + 3]) << 4)
        return DualSenseTouchPoint(
            id: id,
            x: min(1, Float(xRaw) / 1920),
            y: min(1, Float(yRaw) / 1080),
            active: active
        )
    }

    private static func writeBluetoothCRC(to report: inout Data) {
        let crc = crc32(bytes: [0xa2] + report.dropLast(4))
        let crcOffset = report.count - 4
        report[crcOffset] = UInt8(crc & 0xff)
        report[crcOffset + 1] = UInt8((crc >> 8) & 0xff)
        report[crcOffset + 2] = UInt8((crc >> 16) & 0xff)
        report[crcOffset + 3] = UInt8((crc >> 24) & 0xff)
    }

    private static func brightnessScale(_ brightness: UInt8?) -> Float {
        guard let brightness else { return 1 }
        switch brightness {
        case 0: return 1
        case 1: return 0.45
        case 2: return 0.18
        default: return 1
        }
    }
}

private extension Array where Element == UInt8 {
    func padding(to count: Int) -> [UInt8] {
        if self.count >= count { return Array(prefix(count)) }
        return self + Array(repeating: 0, count: count - self.count)
    }
}
