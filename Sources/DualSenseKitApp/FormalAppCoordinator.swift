import AppKit
import DualSenseKitRuntime
import Foundation

@MainActor
final class FormalAppCoordinator {
    private let configStore = ConfigStore()
    private let eventBus = EventBus()
    private let permissionService = PermissionService()
    private let statusItem = StatusItemController()
    private let appMenu = AppMenuController()
    private let hookStore = HookStore()
    private var eventSubscription: UUID?
    private lazy var actionExecutor = ActionExecutor(permissionService: permissionService)
    private lazy var controllerService = ControllerService(
        eventBus: eventBus,
        configStore: configStore,
        actionExecutor: actionExecutor
    )
    private lazy var lightService = LightService(controllerService: controllerService)
    private lazy var hookService = HookService(
        controllerService: controllerService,
        lightService: lightService
    )
    private lazy var hookHTTPServer = HookHTTPServer(
        hookStore: hookStore,
        hookService: hookService
    )
    private lazy var windowController = MainWindowController(
        configStore: configStore,
        hookStore: hookStore,
        hookService: hookService,
        preferences: AppPreferences.shared,
        onPreferencesChanged: { [weak self] in self?.applyPreferences() }
    )

    func start() {
        _ = configStore.load()
        _ = hookStore.load()
        controllerService.start()
        controllerService.resetEffects()
        hookHTTPServer.start()
        configureMainMenu()
        configureStatusItem()
        subscribeStatusEvents()
        applyPreferences()
        windowController.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func stop() {
        if let eventSubscription {
            eventBus.unsubscribe(eventSubscription)
        }
        hookHTTPServer.stop()
        hookService.stop()
        controllerService.stop()
    }

    private func configureMainMenu() {
        appMenu.onOpenSettings = { [weak self] in self?.showMainWindow() }
        appMenu.onQuit = { NSApplication.shared.terminate(nil) }
        appMenu.install()
    }

    private func configureStatusItem() {
        statusItem.onOpenSettings = { [weak self] in self?.showMainWindow() }
        statusItem.onToggleMouse = { [weak self] in self?.toggleTouchpadMouse() }
        statusItem.onRequestAccessibility = { [weak self] in
            _ = self?.permissionService.requestAccessibilityTrust()
        }
        statusItem.onQuit = { NSApplication.shared.terminate(nil) }
    }

    private func subscribeStatusEvents() {
        eventSubscription = eventBus.subscribe { [weak self] event in
            guard event.type == "controller.connected" || event.type == "controller.disconnected" else { return }
            DispatchQueue.main.async {
                self?.refreshStatus()
            }
        }
    }

    private func applyPreferences() {
        NSApplication.shared.setActivationPolicy(AppPreferences.shared.showDockIcon ? .regular : .accessory)
        if AppPreferences.shared.showStatusItem {
            statusItem.start()
            refreshStatus()
        } else {
            statusItem.stop()
        }
    }

    private func showMainWindow() {
        windowController.reloadFromStore()
        windowController.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
