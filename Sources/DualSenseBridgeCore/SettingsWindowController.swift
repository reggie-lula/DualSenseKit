import AppKit
import Foundation

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private var textView: NSTextView?
    private weak var configStore: ConfigStore?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DualSenseBridge 设置"
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(configStore: ConfigStore) {
        self.configStore = configStore
        if textView == nil {
            buildContent()
        }
        reloadText()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let window else { return }
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 62, width: 728, height: 542))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width, .height]
        scroll.documentView = text
        container.addSubview(scroll)
        textView = text

        let save = NSButton(frame: NSRect(x: 16, y: 18, width: 120, height: 30))
        save.title = "保存 JSON"
        save.target = self
        save.action = #selector(saveJSON)
        container.addSubview(save)

        let reload = NSButton(frame: NSRect(x: 148, y: 18, width: 120, height: 30))
        reload.title = "重新载入"
        reload.target = self
        reload.action = #selector(reloadText)
        container.addSubview(reload)

        window.contentView = container
    }

    @objc private func reloadText() {
        guard let configStore else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(configStore.current) {
            textView?.string = String(data: data, encoding: .utf8) ?? ""
        }
    }

    @objc private func saveJSON() {
        guard let configStore, let data = textView?.string.data(using: .utf8) else { return }
        do {
            let config = try JSONDecoder().decode(BridgeConfig.self, from: data)
            configStore.save(config)
        } catch {
            NSSound.beep()
        }
    }
}
