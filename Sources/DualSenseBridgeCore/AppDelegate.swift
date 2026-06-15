import AppKit

private var retainedAppDelegate: AppDelegate?
private var retainedCoordinator: AppCoordinator?

@MainActor
public func runDualSenseBridgeApp() {
    DiagnosticsLog.write("runDualSenseBridgeApp enter args=\(CommandLine.arguments)")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedAppDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let coordinator = AppCoordinator()
    retainedCoordinator = coordinator
    coordinator.start()
    DiagnosticsLog.write("runDualSenseBridgeApp before app.run")
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticsLog.write("applicationDidFinishLaunching")
        if retainedCoordinator == nil {
            let coordinator = AppCoordinator()
            self.coordinator = coordinator
            retainedCoordinator = coordinator
            coordinator.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsLog.write("applicationWillTerminate")
        coordinator?.stop()
        retainedCoordinator?.stop()
    }
}
