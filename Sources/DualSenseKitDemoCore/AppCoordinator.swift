import AppKit
import Foundation

@MainActor
final class AppCoordinator {
    private let configStore = ConfigStore()
    private let tokenService = TokenService()
    private let statusItem = StatusItemController()
    private let permissionService = PermissionService()
    private let eventBus = EventBus()
    private lazy var actionExecutor = ActionExecutor(permissionService: permissionService)
    private lazy var controllerService = ControllerService(
        eventBus: eventBus,
        configStore: configStore,
        actionExecutor: actionExecutor
    )
    private lazy var lightService = LightService(controllerService: controllerService, eventBus: eventBus)
    private lazy var audioService = AudioService()
    private lazy var apiServer = APIServer(
        configStore: configStore,
        controllerService: controllerService,
        lightService: lightService,
        audioService: audioService,
        actionExecutor: actionExecutor,
        eventBus: eventBus,
        tokenService: tokenService
    )

    func start() {
        DiagnosticsLog.write("AppCoordinator.start begin")
        _ = configStore.load()
        DiagnosticsLog.write("config loaded")
        _ = tokenService.token()
        DiagnosticsLog.write("token ready")
        controllerService.start()
        DiagnosticsLog.write("controller service started")
        apiServer.start()
        DiagnosticsLog.write("api server start requested")
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onToggleMouse = { [weak self] in self?.toggleTouchpadMouse() }
        statusItem.onRequestAccessibility = { [weak self] in
            _ = self?.permissionService.requestAccessibilityTrust()
        }
        statusItem.onQuit = { NSApplication.shared.terminate(nil) }
        statusItem.start()
        DiagnosticsLog.write("status item started")
        refreshStatus()
        DiagnosticsLog.write("AppCoordinator.start complete")
    }

    func stop() {
        DiagnosticsLog.write("AppCoordinator.stop")
        apiServer.stop()
        controllerService.stop()
    }

    private func openSettings() {
        SettingsWindowController.shared.show(configStore: configStore)
    }

    private func toggleTouchpadMouse() {
        var config = configStore.current
        config.touchpad.enabled.toggle()
        configStore.save(config)
        refreshStatus()
    }

    private func refreshStatus() {
        statusItem.update(
            connected: controllerService.connectedControllerName,
            touchpadEnabled: configStore.current.touchpad.enabled,
            accessibilityTrusted: permissionService.isAccessibilityTrusted()
        )
    }
}
