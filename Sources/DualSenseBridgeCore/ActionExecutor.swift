import AppKit
import CoreGraphics
import Foundation

final class ActionExecutor: @unchecked Sendable {
    private let permissionService: PermissionService

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    func execute(_ actions: [Action], config: BridgeConfig) {
        for action in actions {
            execute(action, config: config)
        }
    }

    func execute(_ action: Action, config: BridgeConfig) {
        switch action {
        case .keyStroke(let stroke):
            postKeyStroke(stroke)
        case .text(let text):
            pasteText(text)
        case .mouseClick(let button):
            postMouseClick(button)
        case .scroll(let dx, let dy):
            postScroll(dx: dx, dy: dy)
        case .mediaKey(let code):
            postKeyStroke(KeyStroke(keyCode: code, modifiers: []))
        case .openURL(let rawURL):
            guard let url = URL(string: rawURL) else { return }
            NSWorkspace.shared.open(url)
        case .openApplication(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        case .shell(let command):
            runShell(command, shellConfig: config.shell)
        }
    }

    func isShellCommandAllowed(_ command: String, shellConfig: ShellConfig) -> Bool {
        guard shellConfig.enabled else { return false }
        if shellConfig.allowedCommands.contains(command) {
            return true
        }
        let expanded = NSString(string: command).expandingTildeInPath
        return shellConfig.allowedScriptDirectories.contains { directory in
            let expandedDirectory = NSString(string: directory).expandingTildeInPath
            return expanded.hasPrefix(expandedDirectory.hasSuffix("/") ? expandedDirectory : expandedDirectory + "/")
        }
    }

    private func postKeyStroke(_ stroke: KeyStroke) {
        guard permissionService.isAccessibilityTrusted() else { return }
        let flags = stroke.modifiers.reduce(CGEventFlags()) { partial, modifier in
            var flags = partial
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            }
            return flags
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func pasteText(_ text: String) {
        guard permissionService.isAccessibilityTrusted() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postKeyStroke(KeyStroke(keyCode: 9, modifiers: [.command]))
    }

    private func postMouseClick(_ button: MouseButton) {
        guard permissionService.isAccessibilityTrusted() else { return }
        let location = NSEvent.mouseLocation
        let flipped = CGPoint(x: location.x, y: NSScreen.screens.first.map { $0.frame.height - location.y } ?? location.y)
        let cgButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .left:
            cgButton = .left
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            cgButton = .right
            downType = .rightMouseDown
            upType = .rightMouseUp
        case .middle:
            cgButton = .center
            downType = .otherMouseDown
            upType = .otherMouseUp
        }
        CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: flipped, mouseButton: cgButton)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: flipped, mouseButton: cgButton)?.post(tap: .cghidEventTap)
    }

    private func postScroll(dx: Int32, dy: Int32) {
        guard permissionService.isAccessibilityTrusted() else { return }
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    private func runShell(_ command: String, shellConfig: ShellConfig) {
        guard isShellCommandAllowed(command, shellConfig: shellConfig) else {
            NSLog("DualSenseBridge blocked shell command: \(command)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()
        } catch {
            NSLog("DualSenseBridge shell command failed: \(error)")
        }
    }
}
