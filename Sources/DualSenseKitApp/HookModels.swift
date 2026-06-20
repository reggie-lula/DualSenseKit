import Foundation

enum HookCommandKind: String, Codable, CaseIterable {
    case heartbeatRumble
    case playerLEDs
    case solidLightbar
    case breathingLightbar
    case alternatingLightbar
    case stopEffects

    var displayName: String {
        switch self {
        case .heartbeatRumble: return "心跳震动"
        case .playerLEDs: return "Player 状态灯"
        case .solidLightbar: return "固定灯带颜色"
        case .breathingLightbar: return "颜色呼吸灯"
        case .alternatingLightbar: return "两色交替闪烁"
        case .stopEffects: return "停止效果"
        }
    }
}

enum HookStopChannel: String, Codable, CaseIterable {
    case light
    case rumble
    case all

    var displayName: String {
        switch self {
        case .light: return "灯光"
        case .rumble: return "震动"
        case .all: return "全部"
        }
    }
}

struct HookColor: Codable, Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    static let red = HookColor(r: 255, g: 0, b: 0)
    static let blue = HookColor(r: 0, g: 80, b: 255)
    static let green = HookColor(r: 0, g: 220, b: 120)
    static let reflashBlue = HookColor(hueDegrees: 210, saturation: 1, brightness: 1)

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hueDegrees: Double, saturation: Double, brightness: Double) {
        let hue = ((hueDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let rgb: (Double, Double, Double)
        switch hue {
        case 0..<1: rgb = (c, x, 0)
        case 1..<2: rgb = (x, c, 0)
        case 2..<3: rgb = (0, c, x)
        case 3..<4: rgb = (0, x, c)
        case 4..<5: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        self.r = UInt8(clamping: Int((rgb.0 + m) * 255))
        self.g = UInt8(clamping: Int((rgb.1 + m) * 255))
        self.b = UInt8(clamping: Int((rgb.2 + m) * 255))
    }
}

struct HookCommand: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: HookCommandKind
    var colorA: HookColor
    var colorB: HookColor
    var brightness: Float
    var intervalMs: Int
    var durationMs: Int
    var strength: Float
    var playerMask: UInt8
    var playerBrightness: UInt8?
    var stopChannel: HookStopChannel
    var resetOnStop: Bool

    init(
        id: UUID = UUID(),
        kind: HookCommandKind,
        colorA: HookColor = .green,
        colorB: HookColor = .blue,
        brightness: Float = 1,
        intervalMs: Int = 500,
        durationMs: Int = 160,
        strength: Float = 0.75,
        playerMask: UInt8 = 4,
        playerBrightness: UInt8? = nil,
        stopChannel: HookStopChannel = .all,
        resetOnStop: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.colorA = colorA
        self.colorB = colorB
        self.brightness = min(1, max(0, brightness))
        self.intervalMs = max(20, intervalMs)
        self.durationMs = max(20, durationMs)
        self.strength = min(1, max(0, strength))
        self.playerMask = min(playerMask, 31)
        self.playerBrightness = playerBrightness.map { min($0, 2) }
        self.stopChannel = stopChannel
        self.resetOnStop = resetOnStop
    }

    var normalized: HookCommand {
        HookCommand(
            id: id,
            kind: kind,
            colorA: colorA,
            colorB: colorB,
            brightness: brightness,
            intervalMs: intervalMs,
            durationMs: durationMs,
            strength: strength,
            playerMask: playerMask,
            playerBrightness: playerBrightness,
            stopChannel: stopChannel,
            resetOnStop: resetOnStop
        )
    }
}

struct HookDefinition: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var slug: String
    var enabled: Bool
    var commands: [HookCommand]

    init(id: UUID = UUID(), name: String, slug: String, enabled: Bool = true, commands: [HookCommand]) {
        self.id = id
        self.name = name
        self.slug = HookDefinition.sanitizeSlug(slug)
        self.enabled = enabled
        self.commands = commands.map(\.normalized)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case enabled
        case commands
        case kind
        case colorA
        case colorB
        case brightness
        case intervalMs
        case durationMs
        case strength
        case playerMask
        case playerBrightness
        case resetOnStop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        slug = HookDefinition.sanitizeSlug(try container.decode(String.self, forKey: .slug))
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let commands = try container.decodeIfPresent([HookCommand].self, forKey: .commands) {
            self.commands = commands.map(\.normalized)
        } else {
            let legacyRaw = try container.decode(String.self, forKey: .kind)
            guard let legacy = HookLegacyKind(rawValue: legacyRaw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Unknown legacy hook kind: \(legacyRaw)"
                )
            }
            let colorA = try container.decodeIfPresent(HookColor.self, forKey: .colorA) ?? .green
            let colorB = try container.decodeIfPresent(HookColor.self, forKey: .colorB) ?? .blue
            let brightness = try container.decodeIfPresent(Float.self, forKey: .brightness) ?? 1
            let intervalMs = try container.decodeIfPresent(Int.self, forKey: .intervalMs) ?? 500
            let durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs) ?? 160
            let strength = try container.decodeIfPresent(Float.self, forKey: .strength) ?? 0.75
            let playerMask = try container.decodeIfPresent(UInt8.self, forKey: .playerMask) ?? 4
            let playerBrightness = try container.decodeIfPresent(UInt8.self, forKey: .playerBrightness)
            let resetOnStop = try container.decodeIfPresent(Bool.self, forKey: .resetOnStop) ?? true
            commands = legacy.commands(
                colorA: colorA,
                colorB: colorB,
                brightness: brightness,
                intervalMs: intervalMs,
                durationMs: durationMs,
                strength: strength,
                playerMask: playerMask,
                playerBrightness: playerBrightness,
                resetOnStop: resetOnStop
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(commands, forKey: .commands)
    }

    var normalized: HookDefinition {
        HookDefinition(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "hook" : name,
            slug: slug,
            enabled: enabled,
            commands: commands
        )
    }

    static func sanitizeSlug(_ raw: String) -> String {
        let lower = raw.lowercased()
        let allowed = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        let slug = String(allowed).split(separator: "-").joined(separator: "-")
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty ? "hook" : slug
    }
}

extension HookDefinition {
    static let defaults: [HookDefinition] = [
        HookDefinition(
            name: "reflash",
            slug: "reflash",
            commands: [
                HookCommand(kind: .solidLightbar, colorA: .reflashBlue, brightness: 1),
                HookCommand(kind: .playerLEDs, playerMask: 4)
            ]
        ),
        HookDefinition(
            name: "heartbeat",
            slug: "heartbeat",
            commands: [
                HookCommand(kind: .heartbeatRumble, intervalMs: 1250, durationMs: 160, strength: 0.9)
            ]
        ),
        HookDefinition(
            name: "player",
            slug: "player",
            commands: [
                HookCommand(kind: .playerLEDs, playerMask: 4)
            ]
        ),
        HookDefinition(
            name: "police",
            slug: "police",
            commands: [
                HookCommand(kind: .alternatingLightbar, colorA: .red, colorB: .blue, brightness: 1, intervalMs: 260),
                HookCommand(kind: .heartbeatRumble, intervalMs: 260, durationMs: 160, strength: 1)
            ]
        )
    ]
}

private enum HookLegacyKind: String {
    case heartbeatRumble
    case playerLEDs
    case solidLightbar
    case breathingLightbar
    case alternatingLightbar
    case policeHeartbeat
    case stopEffects

    func commands(
        colorA: HookColor,
        colorB: HookColor,
        brightness: Float,
        intervalMs: Int,
        durationMs: Int,
        strength: Float,
        playerMask: UInt8,
        playerBrightness: UInt8?,
        resetOnStop: Bool
    ) -> [HookCommand] {
        switch self {
        case .heartbeatRumble:
            return [HookCommand(kind: .heartbeatRumble, intervalMs: intervalMs, durationMs: durationMs, strength: strength)]
        case .playerLEDs:
            return [HookCommand(kind: .playerLEDs, playerMask: playerMask, playerBrightness: playerBrightness)]
        case .solidLightbar:
            return [HookCommand(kind: .solidLightbar, colorA: colorA, brightness: brightness)]
        case .breathingLightbar:
            return [HookCommand(kind: .breathingLightbar, colorA: colorA, brightness: brightness, intervalMs: intervalMs)]
        case .alternatingLightbar:
            return [HookCommand(kind: .alternatingLightbar, colorA: colorA, colorB: colorB, brightness: brightness, intervalMs: intervalMs, durationMs: durationMs, strength: strength)]
        case .policeHeartbeat:
            return [
                HookCommand(kind: .alternatingLightbar, colorA: colorA, colorB: colorB, brightness: brightness, intervalMs: intervalMs),
                HookCommand(kind: .heartbeatRumble, intervalMs: intervalMs, durationMs: durationMs, strength: strength)
            ]
        case .stopEffects:
            return [HookCommand(kind: .stopEffects, stopChannel: .all, resetOnStop: resetOnStop)]
        }
    }
}
