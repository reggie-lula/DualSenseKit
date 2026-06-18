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
        for (gesture, actions) in BridgeConfig.defaultMappings() where migrated.mappings[gesture] == nil {
            migrated.mappings[gesture] = actions
        }
        return migrated
    }
}
