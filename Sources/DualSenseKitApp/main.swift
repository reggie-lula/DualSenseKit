import AppKit

let app = NSApplication.shared
let delegate = FormalAppDelegate()
app.delegate = delegate
app.setActivationPolicy(AppPreferences.shared.showDockIcon ? .regular : .accessory)
app.run()

@MainActor
final class FormalAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: FormalAppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = FormalAppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
