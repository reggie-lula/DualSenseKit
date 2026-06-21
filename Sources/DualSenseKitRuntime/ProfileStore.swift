import Foundation

public final class ProfileStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DualSenseKitDemo.ProfileStore")
    private let activeLock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let profilesURL: URL

    public private(set) var profiles: [MappingProfile] = []

    private var _activeProfileID: UUID?
    private var _activeMappings: [ButtonGesture: [Action]] = [:]

    public var activeProfileID: UUID? {
        activeLock.lock()
        defer { activeLock.unlock() }
        return _activeProfileID
    }

    public var activeMappings: [ButtonGesture: [Action]] {
        activeLock.lock()
        defer { activeLock.unlock() }
        return _activeMappings
    }

    public init(profilesURL: URL? = nil) {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DualSenseKitDemo", isDirectory: true)
        self.profilesURL = profilesURL ?? supportDirectory.appendingPathComponent("profiles.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
    }

    @discardableResult
    public func loadOrSeed(from seedMappings: [ButtonGesture: [Action]]) -> [MappingProfile] {
        queue.sync {
            guard FileManager.default.fileExists(atPath: profilesURL.path) else {
                let def = MappingProfile(name: "默认", isDefault: true, mappings: seedMappings)
                profiles = [def]
                persist(ProfileDocument(profiles: profiles))
                updateActiveSnapshot(def)
                return profiles
            }

            do {
                let data = try Data(contentsOf: profilesURL)
                var doc = try decoder.decode(ProfileDocument.self, from: data)
                fixDefaultInvariant(&doc.profiles)
                for i in doc.profiles.indices {
                    migrateToImmediateActions(&doc.profiles[i].mappings)
                }
                profiles = doc.profiles
                persist(ProfileDocument(profiles: profiles))
                let def = profiles.first(where: { $0.isDefault }) ?? profiles[0]
                updateActiveSnapshot(def)
            } catch {
                let ts = Int(Date().timeIntervalSince1970)
                let corrupt = profilesURL.deletingLastPathComponent()
                    .appendingPathComponent("profiles.corrupt-\(ts).json")
                try? FileManager.default.moveItem(at: profilesURL, to: corrupt)
                NSLog("ProfileStore: decode failed (%@), renamed to %@, re-seeding", "\(error)", corrupt.lastPathComponent)
                let def = MappingProfile(name: "默认", isDefault: true, mappings: seedMappings)
                profiles = [def]
                persist(ProfileDocument(profiles: profiles))
                updateActiveSnapshot(def)
            }
            return profiles
        }
    }

    // Migrate any .singleClick keystroke/mouse bindings to .press so they fire immediately
    // (same pattern as ConfigStore's immediateDefaultMigrations).
    private func migrateToImmediateActions(_ mappings: inout [ButtonGesture: [Action]]) {
        var toAdd: [(ButtonGesture, [Action])] = []
        var toRemove: [ButtonGesture] = []
        for (gesture, actions) in mappings where gesture.kind == .singleClick {
            guard actions.allSatisfy({ action in
                switch action {
                case .keyStroke, .mouseClick: return true
                default: return false
                }
            }) else { continue }
            let pressGesture = ButtonGesture(button: gesture.button, kind: .press)
            guard mappings[pressGesture] == nil else { continue }
            toRemove.append(gesture)
            toAdd.append((pressGesture, actions))
        }
        for g in toRemove { mappings.removeValue(forKey: g) }
        for (g, a) in toAdd { mappings[g] = a }
    }

    public func upsert(_ profile: MappingProfile) {
        queue.sync {
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            persist(ProfileDocument(profiles: profiles))
            if profile.id == _activeProfileID {
                updateActiveSnapshot(profile)
            }
        }
    }

    public func deleteProfile(id: UUID) {
        queue.sync {
            guard let profile = profiles.first(where: { $0.id == id }), !profile.isDefault else { return }
            profiles.removeAll { $0.id == id }
            persist(ProfileDocument(profiles: profiles))
        }
    }

    public func defaultProfile() -> MappingProfile {
        queue.sync {
            profiles.first(where: { $0.isDefault }) ?? profiles.first ?? MappingProfile(name: "默认", isDefault: true)
        }
    }

    public func activate(bundleIdentifier: String?) {
        queue.sync {
            guard !profiles.isEmpty else { return }
            let match: MappingProfile
            if let bid = bundleIdentifier, !bid.isEmpty,
               let found = profiles.first(where: { $0.bundleIdentifier == bid }) {
                match = found
            } else {
                match = profiles.first(where: { $0.isDefault }) ?? profiles[0]
            }
            updateActiveSnapshot(match)
        }
    }

    public func activate(profileID: UUID) {
        queue.sync {
            guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
            updateActiveSnapshot(profile)
        }
    }

    // Must be called from within the queue context.
    private func updateActiveSnapshot(_ profile: MappingProfile) {
        activeLock.lock()
        _activeProfileID = profile.id
        _activeMappings = profile.mappings
        activeLock.unlock()
    }

    private func fixDefaultInvariant(_ ps: inout [MappingProfile]) {
        guard !ps.isEmpty else { return }
        let defaults = ps.indices.filter { ps[$0].isDefault }
        if defaults.isEmpty {
            ps[0].isDefault = true
        } else if defaults.count > 1 {
            for i in defaults.dropFirst() { ps[i].isDefault = false }
        }
        for i in ps.indices where ps[i].isDefault {
            ps[i].bundleIdentifier = nil
        }
    }

    private func persist(_ doc: ProfileDocument) {
        do {
            try FileManager.default.createDirectory(
                at: profilesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(doc)
            try data.write(to: profilesURL, options: [.atomic])
        } catch {
            NSLog("ProfileStore: save failed: %@", "\(error)")
        }
    }
}
