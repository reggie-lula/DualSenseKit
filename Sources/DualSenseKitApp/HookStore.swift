import Foundation

final class HookStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DualSenseKitApp.HookStore")
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private(set) var hooks: [HookDefinition] = []
    let hooksURL: URL

    init(hooksURL: URL? = nil) {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DualSenseKit", isDirectory: true)
        self.hooksURL = hooksURL ?? supportDirectory.appendingPathComponent("hooks.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    @discardableResult
    func load() -> [HookDefinition] {
        queue.sync {
            guard FileManager.default.fileExists(atPath: hooksURL.path) else {
                hooks = Self.unique(HookDefinition.defaults)
                persist(hooks)
                return hooks
            }
            do {
                let data = try Data(contentsOf: hooksURL)
                let decoded = try decoder.decode([HookDefinition].self, from: data)
                hooks = Self.unique(decoded.isEmpty ? HookDefinition.defaults : decoded.map(\.normalized))
                persist(hooks)
            } catch {
                hooks = Self.unique(HookDefinition.defaults)
                persist(hooks)
            }
            return hooks
        }
    }

    func save(_ hooks: [HookDefinition]) {
        queue.sync {
            self.hooks = Self.unique(hooks.map(\.normalized))
            persist(self.hooks)
        }
    }

    func hook(slug: String) -> HookDefinition? {
        queue.sync {
            hooks.first { $0.enabled && $0.slug == HookDefinition.sanitizeSlug(slug) }
        }
    }

    private func persist(_ hooks: [HookDefinition]) {
        do {
            try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(hooks)
            try data.write(to: hooksURL, options: [.atomic])
        } catch {
            NSLog("DualSenseKit hook save failed: \(error)")
        }
    }

    private static func unique(_ hooks: [HookDefinition]) -> [HookDefinition] {
        var seen: [String: Int] = [:]
        return hooks.map { hook in
            var copy = hook.normalized
            let base = copy.slug
            let count = seen[base, default: 0]
            seen[base] = count + 1
            if count > 0 {
                copy.slug = "\(base)-\(count + 1)"
            }
            return copy
        }
    }
}
