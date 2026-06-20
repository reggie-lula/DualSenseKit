import AppKit
import Foundation

@MainActor
public final class StatusItemController {
    private var statusItem: NSStatusItem?
    public var onOpenSettings: (() -> Void)?
    public var onToggleMouse: (() -> Void)?
    public var onRequestAccessibility: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init() {}

    public func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "DS"
        item.menu = buildMenu(connected: nil, touchpadEnabled: true, accessibilityTrusted: false)
        statusItem = item
    }

    public func stop() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    public func update(connected: String?, touchpadEnabled: Bool, accessibilityTrusted: Bool) {
        statusItem?.button?.title = connected == nil ? "DS" : "DS●"
        statusItem?.menu = buildMenu(
            connected: connected,
            touchpadEnabled: touchpadEnabled,
            accessibilityTrusted: accessibilityTrusted
        )
    }

    private func buildMenu(connected: String?, touchpadEnabled: Bool, accessibilityTrusted: Bool) -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: connected.map { "已连接: \($0)" } ?? "未连接 DualSense", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: touchpadEnabled ? "关闭触摸板鼠标" : "开启触摸板鼠标", action: #selector(toggleMouse), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let permission = NSMenuItem(
            title: accessibilityTrusted ? "辅助功能权限已开启" : "开启辅助功能权限...",
            action: #selector(requestAccessibility),
            keyEquivalent: ""
        )
        permission.target = self
        permission.isEnabled = !accessibilityTrusted
        menu.addItem(permission)

        let settings = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func toggleMouse() { onToggleMouse?() }
    @objc private func requestAccessibility() { onRequestAccessibility?() }
    @objc private func quit() { onQuit?() }
}
