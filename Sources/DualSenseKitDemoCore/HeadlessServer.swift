import Foundation

@MainActor
public func runDualSenseKitDemoHeadlessServer() {
    let configStore = ConfigStore()
    let tokenService = TokenService()
    let eventBus = EventBus()
    let permissionService = PermissionService()
    let actionExecutor = ActionExecutor(permissionService: permissionService)
    let controllerService = ControllerService(
        eventBus: eventBus,
        configStore: configStore,
        actionExecutor: actionExecutor
    )
    let lightService = LightService(controllerService: controllerService)
    let audioService = AudioService()
    let apiServer = APIServer(
        configStore: configStore,
        controllerService: controllerService,
        lightService: lightService,
        audioService: audioService,
        actionExecutor: actionExecutor,
        eventBus: eventBus,
        tokenService: tokenService
    )

    _ = configStore.load()
    _ = tokenService.token()
    controllerService.start()
    controllerService.resetEffects()
    apiServer.start()
    print("DualSenseKitDemo headless server listening on \(configStore.current.server.host):\(configStore.current.server.port)")
    RunLoop.main.run()
}
