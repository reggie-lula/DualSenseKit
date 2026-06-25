import Foundation

public struct MappingProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var bundleIdentifier: String?
    public var isDefault: Bool
    public var mappings: [ButtonGesture: [Action]]
    public var directKeyMappings: [ControllerButton: KeyStroke]

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String? = nil,
        isDefault: Bool = false,
        mappings: [ButtonGesture: [Action]] = [:],
        directKeyMappings: [ControllerButton: KeyStroke] = [:]
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isDefault = isDefault
        self.mappings = mappings
        self.directKeyMappings = directKeyMappings
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case bundleIdentifier
        case isDefault
        case mappings
        case directKeyMappings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "默认"
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        mappings = try container.decodeIfPresent([ButtonGesture: [Action]].self, forKey: .mappings) ?? [:]
        directKeyMappings = try container.decodeIfPresent([ControllerButton: KeyStroke].self, forKey: .directKeyMappings) ?? [:]
    }
}

public struct ProfileDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var profiles: [MappingProfile]
    public var activeProfileID: UUID?

    public init(version: Int = 1, profiles: [MappingProfile], activeProfileID: UUID? = nil) {
        self.version = version
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    enum CodingKeys: String, CodingKey {
        case version
        case profiles
        case activeProfileID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try container.decodeIfPresent([MappingProfile].self, forKey: .profiles) ?? []
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
    }
}
