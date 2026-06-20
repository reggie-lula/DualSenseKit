import AppKit
import Foundation

@MainActor
final class AppPreferences {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let launchAtLogin = "formal.launchAtLogin"
        static let showDockIcon = "formal.showDockIcon"
        static let showStatusItem = "formal.showStatusItem"
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var showDockIcon: Bool {
        get { defaults.object(forKey: Key.showDockIcon) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showDockIcon) }
    }

    var showStatusItem: Bool {
        get { defaults.object(forKey: Key.showStatusItem) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showStatusItem) }
    }

    private init() {}
}
