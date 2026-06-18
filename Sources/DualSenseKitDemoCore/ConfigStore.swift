import Foundation

final class ConfigStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DualSenseKitDemo.ConfigStore")
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private(set) var current = BridgeConfig()
    let configURL: URL

    init(configURL: URL? = nil) {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DualSenseKitDemo", isDirectory: true)
        self.configURL = configURL ?? supportDirectory.appendingPathComponent("config.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    @discardableResult
    func load() -> BridgeConfig {
        queue.sync {
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                current = BridgeConfig()
                persist(current)
                return current
            }

            do {
                let data = try Data(contentsOf: configURL)
                current = try decoder.decode(BridgeConfig.self, from: data).addingMissingDefaultMappings()
                persist(current)
            } catch {
                current = BridgeConfig()
            }
            return current
        }
    }

    func save(_ config: BridgeConfig) {
        queue.sync {
            current = config
            persist(config)
        }
    }

    private func persist(_ config: BridgeConfig) {
        do {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: [.atomic])
        } catch {
            NSLog("DualSenseKitDemo config save failed: \(error)")
        }
    }
}

private extension BridgeConfig {
    func addingMissingDefaultMappings() -> BridgeConfig {
        var migrated = self
        let physicalTouchpadClick = ButtonGesture(button: .touchpadButton, kind: .singleClick)
        if migrated.mappings[physicalTouchpadClick] == [.mouseClick(.left)] {
            migrated.mappings[physicalTouchpadClick] = nil
        }
        let immediateDefaultMigrations: [(old: ButtonGesture, new: ButtonGesture, actions: [Action])] = [
            (
                ButtonGesture(button: .buttonA, kind: .singleClick),
                ButtonGesture(button: .buttonA, kind: .press),
                [.keyStroke(KeyStroke(keyCode: 36, modifiers: []))]
            ),
            (
                ButtonGesture(button: .buttonX, kind: .singleClick),
                ButtonGesture(button: .buttonX, kind: .press),
                [.keyStroke(KeyStroke(keyCode: 49, modifiers: []))]
            ),
            (
                ButtonGesture(button: .rightShoulder, kind: .singleClick),
                ButtonGesture(button: .rightShoulder, kind: .press),
                [.keyStroke(KeyStroke(keyCode: 48, modifiers: [.command]))]
            ),
            (
                ButtonGesture(button: .leftShoulder, kind: .singleClick),
                ButtonGesture(button: .leftShoulder, kind: .press),
                [.keyStroke(KeyStroke(keyCode: 48, modifiers: [.command, .shift]))]
            ),
            (
                ButtonGesture(button: .leftThumbstickButton, kind: .singleClick),
                ButtonGesture(button: .leftThumbstickButton, kind: .press),
                [.mouseClick(.left)]
            ),
            (
                ButtonGesture(button: .rightThumbstickButton, kind: .singleClick),
                ButtonGesture(button: .rightThumbstickButton, kind: .press),
                [.mouseClick(.right)]
            )
        ]
        for migration in immediateDefaultMigrations where migrated.mappings[migration.old] == migration.actions {
            migrated.mappings[migration.old] = nil
            if migrated.mappings[migration.new] == nil {
                migrated.mappings[migration.new] = migration.actions
            }
        }
        for (gesture, actions) in BridgeConfig.defaultMappings() where migrated.mappings[gesture] == nil {
            migrated.mappings[gesture] = actions
        }
        return migrated
    }
}
