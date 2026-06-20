import AppKit

@MainActor
final class AppMenuController: NSObject {
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    func install() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu(title: "DualSenseKit")
        appItem.submenu = appMenu

        let settings = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出 DualSenseKit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
