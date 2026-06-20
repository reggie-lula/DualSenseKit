import Carbon.HIToolbox
import DualSenseKitRuntime
import Foundation

struct KeyOption: Hashable {
    let title: String
    let keyCode: UInt16
}

enum KeyCatalog {
    static let tabCode: UInt16 = UInt16(kVK_Tab)

    static let options: [KeyOption] = [
        KeyOption(title: "Tab", keyCode: UInt16(kVK_Tab)),
        KeyOption(title: "Return", keyCode: UInt16(kVK_Return)),
        KeyOption(title: "Space", keyCode: UInt16(kVK_Space)),
        KeyOption(title: "Escape", keyCode: UInt16(kVK_Escape)),
        KeyOption(title: "Delete", keyCode: UInt16(kVK_Delete)),
        KeyOption(title: "Forward Delete", keyCode: UInt16(kVK_ForwardDelete)),
        KeyOption(title: "Home", keyCode: UInt16(kVK_Home)),
        KeyOption(title: "End", keyCode: UInt16(kVK_End)),
        KeyOption(title: "Page Up", keyCode: UInt16(kVK_PageUp)),
        KeyOption(title: "Page Down", keyCode: UInt16(kVK_PageDown)),
        KeyOption(title: "Left Arrow", keyCode: UInt16(kVK_LeftArrow)),
        KeyOption(title: "Right Arrow", keyCode: UInt16(kVK_RightArrow)),
        KeyOption(title: "Up Arrow", keyCode: UInt16(kVK_UpArrow)),
        KeyOption(title: "Down Arrow", keyCode: UInt16(kVK_DownArrow)),
        KeyOption(title: "A", keyCode: UInt16(kVK_ANSI_A)),
        KeyOption(title: "B", keyCode: UInt16(kVK_ANSI_B)),
        KeyOption(title: "C", keyCode: UInt16(kVK_ANSI_C)),
        KeyOption(title: "D", keyCode: UInt16(kVK_ANSI_D)),
        KeyOption(title: "E", keyCode: UInt16(kVK_ANSI_E)),
        KeyOption(title: "F", keyCode: UInt16(kVK_ANSI_F)),
        KeyOption(title: "G", keyCode: UInt16(kVK_ANSI_G)),
        KeyOption(title: "H", keyCode: UInt16(kVK_ANSI_H)),
        KeyOption(title: "I", keyCode: UInt16(kVK_ANSI_I)),
        KeyOption(title: "J", keyCode: UInt16(kVK_ANSI_J)),
        KeyOption(title: "K", keyCode: UInt16(kVK_ANSI_K)),
        KeyOption(title: "L", keyCode: UInt16(kVK_ANSI_L)),
        KeyOption(title: "M", keyCode: UInt16(kVK_ANSI_M)),
        KeyOption(title: "N", keyCode: UInt16(kVK_ANSI_N)),
        KeyOption(title: "O", keyCode: UInt16(kVK_ANSI_O)),
        KeyOption(title: "P", keyCode: UInt16(kVK_ANSI_P)),
        KeyOption(title: "Q", keyCode: UInt16(kVK_ANSI_Q)),
        KeyOption(title: "R", keyCode: UInt16(kVK_ANSI_R)),
        KeyOption(title: "S", keyCode: UInt16(kVK_ANSI_S)),
        KeyOption(title: "T", keyCode: UInt16(kVK_ANSI_T)),
        KeyOption(title: "U", keyCode: UInt16(kVK_ANSI_U)),
        KeyOption(title: "V", keyCode: UInt16(kVK_ANSI_V)),
        KeyOption(title: "W", keyCode: UInt16(kVK_ANSI_W)),
        KeyOption(title: "X", keyCode: UInt16(kVK_ANSI_X)),
        KeyOption(title: "Y", keyCode: UInt16(kVK_ANSI_Y)),
        KeyOption(title: "Z", keyCode: UInt16(kVK_ANSI_Z)),
        KeyOption(title: "0", keyCode: UInt16(kVK_ANSI_0)),
        KeyOption(title: "1", keyCode: UInt16(kVK_ANSI_1)),
        KeyOption(title: "2", keyCode: UInt16(kVK_ANSI_2)),
        KeyOption(title: "3", keyCode: UInt16(kVK_ANSI_3)),
        KeyOption(title: "4", keyCode: UInt16(kVK_ANSI_4)),
        KeyOption(title: "5", keyCode: UInt16(kVK_ANSI_5)),
        KeyOption(title: "6", keyCode: UInt16(kVK_ANSI_6)),
        KeyOption(title: "7", keyCode: UInt16(kVK_ANSI_7)),
        KeyOption(title: "8", keyCode: UInt16(kVK_ANSI_8)),
        KeyOption(title: "9", keyCode: UInt16(kVK_ANSI_9)),
        KeyOption(title: "F1", keyCode: UInt16(kVK_F1)),
        KeyOption(title: "F2", keyCode: UInt16(kVK_F2)),
        KeyOption(title: "F3", keyCode: UInt16(kVK_F3)),
        KeyOption(title: "F4", keyCode: UInt16(kVK_F4)),
        KeyOption(title: "F5", keyCode: UInt16(kVK_F5)),
        KeyOption(title: "F6", keyCode: UInt16(kVK_F6)),
        KeyOption(title: "F7", keyCode: UInt16(kVK_F7)),
        KeyOption(title: "F8", keyCode: UInt16(kVK_F8)),
        KeyOption(title: "F9", keyCode: UInt16(kVK_F9)),
        KeyOption(title: "F10", keyCode: UInt16(kVK_F10)),
        KeyOption(title: "F11", keyCode: UInt16(kVK_F11)),
        KeyOption(title: "F12", keyCode: UInt16(kVK_F12))
    ]

    static func title(for keyCode: UInt16) -> String {
        options.first { $0.keyCode == keyCode }?.title ?? "Key \(keyCode)"
    }

    static func describe(_ stroke: KeyStroke) -> String {
        let modifierTitles = stroke.modifiers.map { modifier -> String in
            switch modifier {
            case .command: return "Command"
            case .option: return "Option"
            case .control: return "Control"
            case .shift: return "Shift"
            }
        }
        return (modifierTitles + [title(for: stroke.keyCode)]).joined(separator: " + ")
    }
}
