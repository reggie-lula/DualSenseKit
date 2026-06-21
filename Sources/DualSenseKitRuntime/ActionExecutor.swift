import AppKit
import CoreGraphics
import Foundation

public final class ActionExecutor: @unchecked Sendable {
    private let permissionService: PermissionService
    private let lock = NSLock()
    private var heldActions: [ControllerButton: [Action]] = [:]

    // (modifier, key code, CGEventFlags)
    private static let modifierEntries: [(KeyModifier, UInt16, CGEventFlags)] = [
        (.command, 55, .maskCommand),
        (.shift,   56, .maskShift),
        (.option,  58, .maskAlternate),
        (.control, 59, .maskControl),
    ]

    public init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    // MARK: - Tap (down+up with full modifier sequence, for singleClick / doubleClick / longPress)

    public func execute(_ actions: [Action], config: BridgeConfig) {
        for action in actions { execute(action, config: config) }
    }

    public func execute(_ action: Action, config: BridgeConfig) {
        switch action {
        case .keyStroke(let stroke):
            guard permissionService.isAccessibilityTrusted() else { return }
            postKeyDown(stroke)
            postKeyUp(stroke)
        case .text(let text):
            pasteText(text)
        case .mouseClick(let button):
            guard permissionService.isAccessibilityTrusted() else { return }
            postMouse(button, down: true)
            postMouse(button, down: false)
        case .scroll(let dx, let dy):
            postScroll(dx: dx, dy: dy)
        case .mediaKey(let code):
            guard permissionService.isAccessibilityTrusted() else { return }
            let stroke = KeyStroke(keyCode: code, modifiers: [])
            postKeyDown(stroke)
            postKeyUp(stroke)
        case .openURL(let rawURL):
            guard let url = URL(string: rawURL) else { return }
            NSWorkspace.shared.open(url)
        case .openApplication(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        case .shell(let command):
            runShell(command, shellConfig: config.shell)
        }
    }

    // MARK: - Hold (modifier keys down on press, up on release)

    public func beginActions(_ actions: [Action], for button: ControllerButton, config: BridgeConfig) {
        endActions(for: button, config: config)
        lock.lock()
        heldActions[button] = actions
        lock.unlock()
        for action in actions { beginAction(action, config: config) }
    }

    public func endActions(for button: ControllerButton, config: BridgeConfig) {
        lock.lock()
        let actions = heldActions.removeValue(forKey: button)
        lock.unlock()
        guard let actions else { return }
        for action in actions { endAction(action, config: config) }
    }

    public func releaseAllHeld(config: BridgeConfig) {
        lock.lock()
        let snapshot = heldActions
        heldActions.removeAll()
        lock.unlock()
        for (_, actions) in snapshot {
            for action in actions { endAction(action, config: config) }
        }
    }

    private func beginAction(_ action: Action, config: BridgeConfig) {
        switch action {
        case .keyStroke(let stroke):
            guard permissionService.isAccessibilityTrusted() else { return }
            postKeyDown(stroke)
        case .mouseClick(let button):
            guard permissionService.isAccessibilityTrusted() else { return }
            postMouse(button, down: true)
        default:
            execute(action, config: config)
        }
    }

    private func endAction(_ action: Action, config: BridgeConfig) {
        switch action {
        case .keyStroke(let stroke):
            guard permissionService.isAccessibilityTrusted() else { return }
            postKeyUp(stroke)
        case .mouseClick(let button):
            guard permissionService.isAccessibilityTrusted() else { return }
            postMouse(button, down: false)
        default:
            break
        }
    }

    // MARK: - Permission

    public func isShellCommandAllowed(_ command: String, shellConfig: ShellConfig) -> Bool {
        guard shellConfig.enabled else { return false }
        if shellConfig.allowedCommands.contains(command) { return true }
        let expanded = NSString(string: command).expandingTildeInPath
        return shellConfig.allowedScriptDirectories.contains { dir in
            let d = NSString(string: dir).expandingTildeInPath
            return expanded.hasPrefix(d.hasSuffix("/") ? d : d + "/")
        }
    }

    // MARK: - Key event helpers

    // If keyCode is itself a modifier key (no main payload), returns its flag.
    private static func standaloneModifierFlag(for keyCode: UInt16) -> CGEventFlags {
        switch keyCode {
        case 55:     return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63:     return .maskSecondaryFn
        default:     return []
        }
    }

    private func makeFlags(_ stroke: KeyStroke) -> CGEventFlags {
        stroke.modifiers.reduce(CGEventFlags()) { f, m in
            var flags = f
            if let entry = Self.modifierEntries.first(where: { $0.0 == m }) { flags.insert(entry.2) }
            return flags
        }
    }

    // Posts events at the HID level (.cghidEventTap) with hardware-origin source
    // (.hidSystemState) so they are indistinguishable from real keystrokes to all
    // software — keyboard testers, input monitors, games, system shortcuts, etc.
    private func postKeyDown(_ stroke: KeyStroke) {
        let src = CGEventSource(stateID: .hidSystemState)
        let standaloneFlag = Self.standaloneModifierFlag(for: stroke.keyCode)

        if !standaloneFlag.isEmpty && stroke.modifiers.isEmpty {
            let e = CGEvent(keyboardEventSource: src, virtualKey: stroke.keyCode, keyDown: true)
            e?.flags = standaloneFlag
            e?.post(tap: .cghidEventTap)
            return
        }

        // Modifier keys first — posting to HID updates the shared key state so the
        // main key event correctly inherits the modifier in the HID stream.
        var accumulated = CGEventFlags()
        for (mod, kc, flag) in Self.modifierEntries where stroke.modifiers.contains(mod) {
            accumulated.insert(flag)
            let e = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)
            e?.flags = accumulated
            e?.post(tap: .cghidEventTap)
        }
        let e = CGEvent(keyboardEventSource: src, virtualKey: stroke.keyCode, keyDown: true)
        e?.flags = makeFlags(stroke)
        e?.post(tap: .cghidEventTap)
    }

    private func postKeyUp(_ stroke: KeyStroke) {
        let src = CGEventSource(stateID: .hidSystemState)
        let standaloneFlag = Self.standaloneModifierFlag(for: stroke.keyCode)

        if !standaloneFlag.isEmpty && stroke.modifiers.isEmpty {
            let e = CGEvent(keyboardEventSource: src, virtualKey: stroke.keyCode, keyDown: false)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
            return
        }

        let allFlags = makeFlags(stroke)
        let e = CGEvent(keyboardEventSource: src, virtualKey: stroke.keyCode, keyDown: false)
        e?.flags = allFlags
        e?.post(tap: .cghidEventTap)

        var remaining = allFlags
        for (mod, kc, flag) in Self.modifierEntries.reversed() where stroke.modifiers.contains(mod) {
            remaining.remove(flag)
            let e2 = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)
            e2?.flags = remaining
            e2?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Mouse

    private func postMouse(_ button: MouseButton, down: Bool) {
        let location = NSEvent.mouseLocation
        let flipped = CGPoint(
            x: location.x,
            y: NSScreen.screens.first.map { $0.frame.height - location.y } ?? location.y
        )
        let cgButton: CGMouseButton
        let eventType: CGEventType
        switch (button, down) {
        case (.left,   true):  cgButton = .left;   eventType = .leftMouseDown
        case (.left,   false): cgButton = .left;   eventType = .leftMouseUp
        case (.right,  true):  cgButton = .right;  eventType = .rightMouseDown
        case (.right,  false): cgButton = .right;  eventType = .rightMouseUp
        case (.middle, true):  cgButton = .center; eventType = .otherMouseDown
        case (.middle, false): cgButton = .center; eventType = .otherMouseUp
        }
        CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: flipped, mouseButton: cgButton)?
            .post(tap: .cgSessionEventTap)
    }

    // MARK: - Other

    private func postScroll(dx: Int32, dy: Int32) {
        guard permissionService.isAccessibilityTrusted() else { return }
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cgSessionEventTap)
    }

    private func pasteText(_ text: String) {
        guard permissionService.isAccessibilityTrusted() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        postKeyDown(KeyStroke(keyCode: 9, modifiers: [.command]))
        postKeyUp(KeyStroke(keyCode: 9, modifiers: [.command]))
    }

    private func runShell(_ command: String, shellConfig: ShellConfig) {
        guard isShellCommandAllowed(command, shellConfig: shellConfig) else {
            NSLog("DualSenseKitDemo blocked shell command: \(command)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do { try process.run() } catch { NSLog("DualSenseKitDemo shell command failed: \(error)") }
    }
}
