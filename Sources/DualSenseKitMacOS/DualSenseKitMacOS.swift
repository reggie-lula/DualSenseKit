import Foundation

public enum DualSenseInputEvent: Equatable, Sendable {
    case controllerConnected(name: String)
    case controllerDisconnected
    case buttonValue(button: String, pressed: Bool, value: Float)
    case buttonGesture(button: String, kind: String)
    case touchpad(name: String, x: Float, y: Float, active: Bool)
    case axis(name: String, value: Float)
}

public struct DualSenseDeviceDiagnostics: Equatable, Sendable {
    public var connectedController: String?
    public var productCategory: String?
    public var supportsLight: Bool
    public var isDualSenseProfile: Bool
    public var hidConnected: Bool
    public var hidWritable: Bool
    public var hidStatus: String
}

public struct DualSenseLighting: Equatable, Sendable {
    public var lightbarRed: UInt8
    public var lightbarGreen: UInt8
    public var lightbarBlue: UInt8
    public var lightbarBrightness: Float
    public var playerLEDMask: UInt8
    public var micLEDMode: String
}

@MainActor
public final class DualSenseDeviceManager {
    private let configStore = ConfigStore()
    private let eventBus = EventBus()
    private let permissionService = PermissionService()
    private lazy var actionExecutor = ActionExecutor(permissionService: permissionService)
    private lazy var controllerService = ControllerService(
        eventBus: eventBus,
        configStore: configStore,
        actionExecutor: actionExecutor
    )
    private lazy var lightService = LightService(controllerService: controllerService, eventBus: eventBus)
    private lazy var audioService = AudioService()
    private lazy var managedDevice = DualSenseDevice(
        controllerService: controllerService,
        lightService: lightService,
        audioService: audioService
    )

    public init() {}

    public func start() {
        _ = configStore.load()
        controllerService.start()
    }

    public func stop() {
        controllerService.stop()
    }

    public func device() -> DualSenseDevice {
        managedDevice
    }

    public func subscribeInputEvents(_ handler: @escaping @Sendable (DualSenseInputEvent) -> Void) {
        eventBus.subscribe { event in
            guard let inputEvent = Self.inputEvent(from: event) else { return }
            handler(inputEvent)
        }
    }

    private static func inputEvent(from event: BridgeEvent) -> DualSenseInputEvent? {
        switch event.type {
        case "controller.connected":
            return .controllerConnected(name: event.payload["name"] ?? "Unknown Controller")
        case "controller.disconnected":
            return .controllerDisconnected
        case "button.value":
            return .buttonValue(
                button: event.payload["button"] ?? "",
                pressed: event.payload["pressed"] == "true",
                value: Float(event.payload["value"] ?? "0") ?? 0
            )
        case let type where type.hasPrefix("button."):
            return .buttonGesture(
                button: event.payload["button"] ?? "",
                kind: String(type.dropFirst("button.".count))
            )
        case "touchpad.primary", "touchpad.secondary":
            return .touchpad(
                name: String(event.type.dropFirst("touchpad.".count)),
                x: Float(event.payload["x"] ?? "0") ?? 0,
                y: Float(event.payload["y"] ?? "0") ?? 0,
                active: true
            )
        case "hid.touch":
            return .touchpad(
                name: event.payload["name"] ?? "",
                x: Float(event.payload["x"] ?? "0") ?? 0,
                y: Float(event.payload["y"] ?? "0") ?? 0,
                active: event.payload["active"] == "true"
            )
        case "hid.axis":
            return .axis(
                name: event.payload["name"] ?? "",
                value: Float(event.payload["value"] ?? "0") ?? 0
            )
        default:
            return nil
        }
    }
}

public final class DualSenseDevice: @unchecked Sendable {
    private let controllerService: ControllerService
    private let lightService: LightService
    private let audioService: AudioService

    init(
        controllerService: ControllerService,
        lightService: LightService,
        audioService: AudioService
    ) {
        self.controllerService = controllerService
        self.lightService = lightService
        self.audioService = audioService
    }

    public func diagnostics() -> DualSenseDeviceDiagnostics {
        let diagnostics = controllerService.diagnostics()
        return DualSenseDeviceDiagnostics(
            connectedController: diagnostics.connectedController,
            productCategory: diagnostics.productCategory,
            supportsLight: diagnostics.supportsLight,
            isDualSenseProfile: diagnostics.isDualSenseProfile,
            hidConnected: diagnostics.hid.connected,
            hidWritable: diagnostics.hid.writable,
            hidStatus: diagnostics.hid.status
        )
    }

    public func lighting() -> DualSenseLighting {
        let state = lightService.state()
        return DualSenseLighting(
            lightbarRed: state.lightbar.r,
            lightbarGreen: state.lightbar.g,
            lightbarBlue: state.lightbar.b,
            lightbarBrightness: state.lightbar.brightness,
            playerLEDMask: state.playerLEDs.mask,
            micLEDMode: state.micLED.mode.rawValue
        )
    }

    @discardableResult
    public func setLightbar(red: UInt8, green: UInt8, blue: UInt8, brightness: Float = 1) -> Bool {
        lightService.setLightbar(LightbarRequest(r: red, g: green, b: blue, brightness: brightness))
    }

    @discardableResult
    public func setPlayerLEDs(mask: UInt8) -> Bool {
        lightService.setPlayerLEDs(PlayerLEDRequest(mask: mask & 0x1f, brightness: nil))
    }

    @discardableResult
    public func setMicMuteLED(enabled: Bool) -> Bool {
        lightService.setMicLED(MicMuteLEDRequest(on: enabled, mode: nil))
    }

    @discardableResult
    public func setRumble(heavy: Float, light: Float, durationMs: Int? = nil) -> Bool {
        controllerService.setRumble(RumbleRequest(heavy: heavy, light: light, durationMs: durationMs))
    }

    public func resetEffects() {
        lightService.resetEffects()
        controllerService.resetEffects()
    }

    public func audioCapability() -> String {
        audioService.capability().rawValue
    }

    public func dualSenseAudioOutputName() -> String? {
        audioService.dualSenseOutputDevice()?.name
    }
}
