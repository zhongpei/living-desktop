import Foundation

/// 角色语言行为的用户覆盖。`chance == nil` 表示继续由角色人格推导；0 表示静音，
/// 1 表示每次合法机会都尝试说话。强交互（用户直接聊天、连续戳）不经过这里。
struct CharacterSpeechSettings: Codable, Equatable {
    var chance: Double?
    var minimumInterval: TimeInterval?
    var ambientEnabled: Bool
    var characterEnabled: Bool
    var windowEnabled: Bool
    var environmentEnabled: Bool
    var propEnabled: Bool

    init(
        chance: Double? = nil,
        minimumInterval: TimeInterval? = nil,
        ambientEnabled: Bool = true,
        characterEnabled: Bool = true,
        windowEnabled: Bool = true,
        environmentEnabled: Bool = true,
        propEnabled: Bool = true
    ) {
        self.chance = chance.map { min(1, max(0, $0)) }
        self.minimumInterval = minimumInterval.map { max(0, $0) }
        self.ambientEnabled = ambientEnabled
        self.characterEnabled = characterEnabled
        self.windowEnabled = windowEnabled
        self.environmentEnabled = environmentEnabled
        self.propEnabled = propEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case chance, minimumInterval, ambientEnabled, characterEnabled
        case windowEnabled, environmentEnabled, propEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            chance: try values.decodeIfPresent(Double.self, forKey: .chance),
            minimumInterval: try values.decodeIfPresent(Double.self, forKey: .minimumInterval),
            ambientEnabled: try values.decodeIfPresent(Bool.self, forKey: .ambientEnabled) ?? true,
            characterEnabled: try values.decodeIfPresent(Bool.self, forKey: .characterEnabled) ?? true,
            windowEnabled: try values.decodeIfPresent(Bool.self, forKey: .windowEnabled) ?? true,
            environmentEnabled: try values.decodeIfPresent(Bool.self, forKey: .environmentEnabled) ?? true,
            propEnabled: try values.decodeIfPresent(Bool.self, forKey: .propEnabled) ?? true)
    }
}

enum SpeechOpportunityKind: String, Codable, CaseIterable {
    case ambient
    case character
    case window
    case environment
    case prop
}

struct SpeechBehaviorProfile: Equatable {
    var baseChance: Double
    var minimumInterval: TimeInterval
    var ambientEnabled: Bool
    var characterEnabled: Bool
    var windowEnabled: Bool
    var environmentEnabled: Bool
    var propEnabled: Bool

    static func resolve(
        personality: Personality,
        override: CharacterSpeechSettings?
    ) -> SpeechBehaviorProfile {
        // 社交、好奇和玩性提高主动表达；独立、矜持（chattiness > 1）降低频率。
        // 这是机会概率而不是固定台词频率，实际仍受事件、冷却和模型忙碌状态约束。
        let inferred = (0.16
            + personality.social * 0.28
            + personality.curiosity * 0.08
            + personality.playfulness * 0.10
            + personality.teasing * 0.04
            - personality.independence * 0.10) / max(0.55, personality.chattiness)
        let chance = override?.chance ?? min(0.75, max(0.08, inferred))
        let interval = override?.minimumInterval
            ?? min(30, max(8, 17 + personality.independence * 8 - personality.social * 7))
        return SpeechBehaviorProfile(
            baseChance: chance,
            minimumInterval: interval,
            ambientEnabled: override?.ambientEnabled ?? true,
            characterEnabled: override?.characterEnabled ?? true,
            windowEnabled: override?.windowEnabled ?? true,
            environmentEnabled: override?.environmentEnabled ?? true,
            propEnabled: override?.propEnabled ?? true)
    }

    func isEnabled(_ kind: SpeechOpportunityKind) -> Bool {
        switch kind {
        case .ambient: ambientEnabled
        case .character: characterEnabled
        case .window: windowEnabled
        case .environment: environmentEnabled
        case .prop: propEnabled
        }
    }

    func chance(for kind: SpeechOpportunityKind) -> Double {
        let multiplier: Double
        switch kind {
        case .ambient: multiplier = 0.55
        case .character: multiplier = 1.15
        case .window: multiplier = 0.80
        case .environment: multiplier = 0.70
        case .prop: multiplier = 1.0
        }
        return min(1, baseChance * multiplier)
    }
}

struct SpeechOpportunity: Equatable {
    var kind: SpeechOpportunityKind
    var actorID: String
    var intent: SpeechIntent
    var confirmedContext: String
    var noveltyKey: String
    var now: TimeInterval
}

/// 唯一的自动说话仲裁入口。它只决定是否允许一次语言机会，不生成动作、坐标或世界效果。
final class SpeechDirector {
    private var lastAcceptedAt: [String: TimeInterval] = [:]
    private var lastNoveltyAt: [String: TimeInterval] = [:]
    private var lastNonDialogueAcceptedAt: TimeInterval?

    func accept(
        _ opportunity: SpeechOpportunity,
        profile: SpeechBehaviorProfile,
        roll: Double
    ) -> SpeechOpportunity? {
        guard profile.isEnabled(opportunity.kind) else { return nil }
        guard roll < profile.chance(for: opportunity.kind) else { return nil }
        if opportunity.kind != .character,
           let last = lastNonDialogueAcceptedAt,
           opportunity.now - last < 1.5 {
            return nil
        }
        if let last = lastAcceptedAt[opportunity.actorID],
           opportunity.now - last < profile.minimumInterval {
            return nil
        }
        let noveltyID = "\(opportunity.actorID):\(opportunity.noveltyKey)"
        if let last = lastNoveltyAt[noveltyID],
           opportunity.now - last <= max(60, profile.minimumInterval * 4) {
            return nil
        }
        lastAcceptedAt[opportunity.actorID] = opportunity.now
        lastNoveltyAt[noveltyID] = opportunity.now
        if opportunity.kind != .character {
            lastNonDialogueAcceptedAt = opportunity.now
        }
        return opportunity
    }

    func reset(actorID: String) {
        lastAcceptedAt.removeValue(forKey: actorID)
        lastNoveltyAt = lastNoveltyAt.filter { !$0.key.hasPrefix("\(actorID):") }
    }
}
