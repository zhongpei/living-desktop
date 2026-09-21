import Foundation

public enum WindowDamageKind: String, Codable, CaseIterable, Sendable {
    case crack = "window_crack"
    case bulletHole = "window_bullet_hole"
    case impactFlash = "window_impact_flash"
    case shards = "window_shards"
    case smoke = "window_smoke"
}

/// A replayable request to decorate MyPet's overlay. It never mutates the external window.
public struct WindowDamageEvent: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: WindowDamageKind
    public var targetWindowID: String
    public var normalizedX: Double
    public var normalizedY: Double
    public var intensity: Double
    public var tick: Int

    public init(
        id: UUID = UUID(),
        kind: WindowDamageKind,
        targetWindowID: String,
        normalizedX: Double,
        normalizedY: Double,
        intensity: Double = 1,
        tick: Int
    ) {
        self.id = id
        self.kind = kind
        self.targetWindowID = targetWindowID
        self.normalizedX = min(max(normalizedX, 0), 1)
        self.normalizedY = min(max(normalizedY, 0), 1)
        self.intensity = min(max(intensity, 0), 1)
        self.tick = tick
    }
}

public enum EffectAnchor: String, Codable, Sendable {
    case impactPoint = "impact_point"
    case windowSurface = "window_surface"
}

public enum EffectFallback: String, Codable, Sendable {
    case none
    case geometry
    case particles
}

public struct EffectDefinition: Codable, Equatable, Sendable {
    public var id: WindowDamageKind
    public var displayNames: LocalizedLabel
    public var descriptions: LocalizedLabel
    public var anchor: EffectAnchor
    public var ttlSeconds: Double
    public var maxStack: Int
    public var clickThrough: Bool
    public var asset: String?
    public var fallback: EffectFallback

    public var displayName: String { displayNames.defaultText }

    private enum CodingKeys: String, CodingKey {
        case id, displayNames = "displayName", descriptions = "description"
        case anchor, ttlSeconds, maxStack, clickThrough, asset, fallback
    }
}

public struct EffectCatalog: Codable, Equatable, Sendable {
    public var effects: [EffectDefinition]

    public init(effects: [EffectDefinition]) {
        self.effects = effects
    }

    public func definition(for event: WindowDamageEvent) -> EffectDefinition? {
        effects.first { $0.id == event.kind }
    }

    public var configurationErrors: [String] {
        var errors: [String] = []
        let duplicateIDs = Dictionary(grouping: effects, by: \.id)
            .filter { $0.value.count > 1 }
            .keys
            .map(\.rawValue)
            .sorted()
        if !duplicateIDs.isEmpty {
            errors.append("duplicate effect ids: \(duplicateIDs.joined(separator: ", "))")
        }
        for effect in effects {
            if effect.displayNames.zhHans.isEmpty || effect.displayNames.en.isEmpty {
                errors.append("\(effect.id.rawValue) requires zh-Hans and en displayName")
            }
            if effect.descriptions.zhHans.isEmpty || effect.descriptions.en.isEmpty {
                errors.append("\(effect.id.rawValue) requires zh-Hans and en description")
            }
            if effect.ttlSeconds <= 0 || effect.maxStack <= 0 {
                errors.append("\(effect.id.rawValue) requires positive ttlSeconds and maxStack")
            }
            if [.crack, .bulletHole].contains(effect.id), effect.asset == nil {
                errors.append("\(effect.id.rawValue) requires an independent asset")
            }
        }
        return errors
    }
}
