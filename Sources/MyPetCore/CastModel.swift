import Foundation

public struct LocalizedLabel: Codable, Equatable, Sendable {
    public var zhHans: String
    public var en: String

    public var defaultText: String { zhHans.isEmpty ? en : zhHans }
    public var bilingualText: String { zhHans == en || zhHans.isEmpty ? en : "\(zhHans) / \(en)" }

    public init(zhHans: String, en: String) {
        self.zhHans = zhHans
        self.en = en
    }

    public init(_ legacyText: String) {
        self.init(zhHans: legacyText, en: legacyText)
    }

    private enum CodingKeys: String, CodingKey {
        case zhHans = "zh-Hans"
        case en
    }

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.init(text)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            zhHans: try values.decodeIfPresent(String.self, forKey: .zhHans) ?? "",
            en: try values.decode(String.self, forKey: .en)
        )
    }
}

public enum CastMemberKind: String, Codable, Sendable {
    case character
    case mech
}

public enum CastArrivalStyle: String, Codable, Sendable {
    case walk
    case cloud
    case door
    case launch
    case teleport
}

public enum WindowPerchProfile: String, Codable, Sendable {
    case directPerch = "direct_perch"
    case climbPerch = "climb_perch"
    case swingPerch = "swing_perch"
    case leanWindow = "lean_window"
}

public struct CastMember: Codable, Equatable, Sendable {
    public var id: String
    public var kind: CastMemberKind
    public var displayNames: LocalizedLabel
    public var descriptions: LocalizedLabel?
    public var visualPackID: String?
    /// Stable logical-character profile. It is deliberately independent from
    /// visualPackID so a temporary visual fallback cannot replace identity.
    public var profileID: String?
    public var role: String
    public var arrivalStyle: CastArrivalStyle?
    public var entryProfile: CastArrivalStyle?
    public var exitProfile: CastArrivalStyle?
    public var windowPerchProfile: WindowPerchProfile?
    public var capabilities: [String]

    public var displayName: String { displayNames.defaultText }

    public init(
        id: String,
        kind: CastMemberKind,
        displayName: String,
        visualPackID: String? = nil,
        profileID: String? = nil,
        role: String,
        arrivalStyle: CastArrivalStyle? = nil,
        entryProfile: CastArrivalStyle? = nil,
        exitProfile: CastArrivalStyle? = nil,
        windowPerchProfile: WindowPerchProfile? = nil,
        capabilities: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.displayNames = LocalizedLabel(displayName)
        self.descriptions = nil
        self.visualPackID = visualPackID
        self.profileID = profileID
        self.role = role
        self.arrivalStyle = arrivalStyle
        self.entryProfile = entryProfile
        self.exitProfile = exitProfile
        self.windowPerchProfile = windowPerchProfile
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, description, visualPackID, profileID, role, arrivalStyle
        case entryProfile, exitProfile, windowPerchProfile, capabilities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(CastMemberKind.self, forKey: .kind)
        displayNames = try values.decode(LocalizedLabel.self, forKey: .displayName)
        descriptions = try values.decodeIfPresent(LocalizedLabel.self, forKey: .description)
        visualPackID = try values.decodeIfPresent(String.self, forKey: .visualPackID)
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        role = try values.decode(String.self, forKey: .role)
        arrivalStyle = try values.decodeIfPresent(CastArrivalStyle.self, forKey: .arrivalStyle)
        entryProfile = try values.decodeIfPresent(CastArrivalStyle.self, forKey: .entryProfile)
        exitProfile = try values.decodeIfPresent(CastArrivalStyle.self, forKey: .exitProfile)
        windowPerchProfile = try values.decodeIfPresent(WindowPerchProfile.self, forKey: .windowPerchProfile)
        capabilities = try values.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(displayNames, forKey: .displayName)
        try values.encodeIfPresent(descriptions, forKey: .description)
        try values.encodeIfPresent(visualPackID, forKey: .visualPackID)
        try values.encodeIfPresent(profileID, forKey: .profileID)
        try values.encode(role, forKey: .role)
        try values.encodeIfPresent(entryProfile ?? arrivalStyle, forKey: .entryProfile)
        try values.encodeIfPresent(exitProfile ?? arrivalStyle, forKey: .exitProfile)
        try values.encodeIfPresent(windowPerchProfile, forKey: .windowPerchProfile)
        if !capabilities.isEmpty { try values.encode(capabilities, forKey: .capabilities) }
    }
}

public enum CastSelectionMode: String, Codable, Sendable {
    case manual
    case random
}

/// 用户在设置中选择的“谁可以出现在当前桌面”策略。
/// 当对应的 `all*Enabled` 为 true 时，空的 group/member 列表表示不额外限制；
/// 当 `all*Enabled` 为 false 时，空列表表示用户明确关闭了全部组/人物。
/// 这让新增资源不会被旧设置意外屏蔽，同时允许菜单表达“暂时不显示任何人”。
public struct CastSelection: Codable, Equatable, Sendable {
    public var mode: CastSelectionMode
    public var allGroupsEnabled: Bool
    public var enabledGroupIDs: [String]
    public var allMembersEnabled: Bool
    public var enabledMemberIDs: [String]
    public var randomCount: Int
    public var maxActiveMembers: Int
    public var invitationsEnabled: Bool
    public var automaticArrivalsEnabled: Bool
    /// When enabled, the director replaces a random/ordered participant at a
    /// deterministic tick interval. It is deliberately opt-in so upgrading
    /// does not change the old single-pet behavior.
    public var automaticRotationEnabled: Bool
    public var rotationIntervalTicks: Int64

    /// 默认仍保持旧版“单宠物模式”。只有用户明确切换角色组/角色、随机模式
    /// 或把同时上限调大时，桌面才创建 CastRuntime，避免升级后突然出现一整组角色。
    public var isRuntimeEnabled: Bool {
        mode == .random || !allGroupsEnabled || !allMembersEnabled || maxActiveMembers > 1
    }

    public init(
        mode: CastSelectionMode = .manual,
        allGroupsEnabled: Bool = true,
        enabledGroupIDs: [String] = [],
        allMembersEnabled: Bool = true,
        enabledMemberIDs: [String] = [],
        randomCount: Int = 1,
        maxActiveMembers: Int = 1,
        invitationsEnabled: Bool = true,
        automaticArrivalsEnabled: Bool = true,
        automaticRotationEnabled: Bool = false,
        rotationIntervalTicks: Int64 = 0
    ) {
        self.mode = mode
        self.allGroupsEnabled = allGroupsEnabled
        self.enabledGroupIDs = Self.uniqueSorted(enabledGroupIDs)
        self.allMembersEnabled = allMembersEnabled
        self.enabledMemberIDs = Self.uniqueSorted(enabledMemberIDs)
        self.randomCount = max(1, randomCount)
        self.maxActiveMembers = max(1, maxActiveMembers)
        self.invitationsEnabled = invitationsEnabled
        self.automaticArrivalsEnabled = automaticArrivalsEnabled
        self.automaticRotationEnabled = automaticRotationEnabled
        self.rotationIntervalTicks = max(0, rotationIntervalTicks)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, allGroupsEnabled, enabledGroupIDs, allMembersEnabled
        case enabledMemberIDs, randomCount, maxActiveMembers
        case invitationsEnabled, automaticArrivalsEnabled
        case automaticRotationEnabled, rotationIntervalTicks
    }

    /// Settings are user data, so newly added gameplay switches must decode
    /// safely when an older settings file has no corresponding key.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try values.decodeIfPresent(CastSelectionMode.self, forKey: .mode) ?? .manual,
            allGroupsEnabled: try values.decodeIfPresent(Bool.self, forKey: .allGroupsEnabled) ?? true,
            enabledGroupIDs: try values.decodeIfPresent([String].self, forKey: .enabledGroupIDs) ?? [],
            allMembersEnabled: try values.decodeIfPresent(Bool.self, forKey: .allMembersEnabled) ?? true,
            enabledMemberIDs: try values.decodeIfPresent([String].self, forKey: .enabledMemberIDs) ?? [],
            randomCount: try values.decodeIfPresent(Int.self, forKey: .randomCount) ?? 1,
            maxActiveMembers: try values.decodeIfPresent(Int.self, forKey: .maxActiveMembers) ?? 1,
            invitationsEnabled: try values.decodeIfPresent(Bool.self, forKey: .invitationsEnabled) ?? true,
            automaticArrivalsEnabled: try values.decodeIfPresent(Bool.self, forKey: .automaticArrivalsEnabled) ?? true,
            automaticRotationEnabled: try values.decodeIfPresent(Bool.self, forKey: .automaticRotationEnabled) ?? false,
            rotationIntervalTicks: try values.decodeIfPresent(Int64.self, forKey: .rotationIntervalTicks) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encode(allGroupsEnabled, forKey: .allGroupsEnabled)
        try values.encode(enabledGroupIDs, forKey: .enabledGroupIDs)
        try values.encode(allMembersEnabled, forKey: .allMembersEnabled)
        try values.encode(enabledMemberIDs, forKey: .enabledMemberIDs)
        try values.encode(randomCount, forKey: .randomCount)
        try values.encode(maxActiveMembers, forKey: .maxActiveMembers)
        try values.encode(invitationsEnabled, forKey: .invitationsEnabled)
        try values.encode(automaticArrivalsEnabled, forKey: .automaticArrivalsEnabled)
        try values.encode(automaticRotationEnabled, forKey: .automaticRotationEnabled)
        try values.encode(rotationIntervalTicks, forKey: .rotationIntervalTicks)
    }

    public func normalized(availablePacks: [CastPack]) -> CastSelection {
        let groups = Set(availablePacks.map(\.groupID))
        let members = Set(availablePacks.flatMap { $0.members.map(\.id) })
        var result = self
        result.enabledGroupIDs = allGroupsEnabled
            ? [] : Self.uniqueSorted(enabledGroupIDs.filter { groups.contains($0) })
        result.enabledMemberIDs = allMembersEnabled
            ? [] : Self.uniqueSorted(enabledMemberIDs.filter { members.contains($0) })
        result.randomCount = max(1, min(randomCount, max(1, members.count)))
        result.maxActiveMembers = max(1, min(maxActiveMembers, max(1, members.count)))
        result.rotationIntervalTicks = max(0, rotationIntervalTicks)
        return result
    }

    public func activePacks(from packs: [CastPack]) -> [CastPack] {
        let allowed = Set(enabledGroupIDs)
        return packs.filter { allGroupsEnabled || allowed.contains($0.groupID) }
    }

    public func activeMembers(from packs: [CastPack]) -> [CastMember] {
        let allowed = Set(enabledMemberIDs)
        return activePacks(from: packs).flatMap { pack in
            pack.members.filter { allMembersEnabled || allowed.contains($0.id) }
        }
    }

    public func togglingGroup(_ groupID: String, allGroupIDs: [String]) -> CastSelection {
        var result = self
        let all = Set(allGroupIDs)
        var selected = allGroupsEnabled ? all : Set(enabledGroupIDs)
        if selected.contains(groupID) {
            selected.remove(groupID)
        } else {
            selected.insert(groupID)
        }
        result.allGroupsEnabled = selected == all
        result.enabledGroupIDs = result.allGroupsEnabled ? [] : Self.uniqueSorted(Array(selected))
        return result
    }

    public func togglingMember(_ memberID: String, allMemberIDs: [String]) -> CastSelection {
        var result = self
        let all = Set(allMemberIDs)
        var selected = allMembersEnabled ? all : Set(enabledMemberIDs)
        if selected.contains(memberID) {
            selected.remove(memberID)
        } else {
            selected.insert(memberID)
        }
        result.allMembersEnabled = selected == all
        result.enabledMemberIDs = result.allMembersEnabled ? [] : Self.uniqueSorted(Array(selected))
        return result
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}

public struct CastRelation: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var kind: String
    public var state: [String: Double]

    public init(from: String, to: String, kind: String, state: [String: Double] = [:]) {
        self.from = from
        self.to = to
        self.kind = kind
        self.state = state
    }

    public func worldKey(_ field: String) -> String { "\(from)/\(to)/\(field)" }
}

public struct CastSlot: Codable, Equatable, Sendable {
    public var entityID: String
    public var slotID: String
    public var capacity: Int

    public init(entityID: String, slotID: String, capacity: Int = 1) {
        self.entityID = entityID
        self.slotID = slotID
        self.capacity = max(1, capacity)
    }
}

public struct StoryPrerequisite: Codable, Equatable, Sendable {
    public var relationKey: String?
    public var minimum: Double?
    public var requiredFact: String?

    public init(relationKey: String? = nil, minimum: Double? = nil, requiredFact: String? = nil) {
        self.relationKey = relationKey
        self.minimum = minimum
        self.requiredFact = requiredFact
    }
}

/// A declarative prop hand-off between two confirmed story beats.
///
/// The hand-off describes the presentation boundary only; slot ownership still
/// changes through the ordinary release/claim events in `GameKernel`. Keeping
/// the source and destination explicit makes the cue deterministic and avoids
/// asking AppKit to infer a relationship from whichever frame it happens to
/// render.
public struct StoryHandoff: Codable, Equatable, Sendable {
    public var propID: String
    public var fromActorID: String
    public var toActorID: String
    public var fromSlotID: String
    public var toSlotID: String
    public var durationTicks: Int64

    public init(
        propID: String,
        fromActorID: String,
        toActorID: String,
        fromSlotID: String,
        toSlotID: String,
        durationTicks: Int64 = 4
    ) {
        self.propID = propID
        self.fromActorID = fromActorID
        self.toActorID = toActorID
        self.fromSlotID = fromSlotID
        self.toSlotID = toSlotID
        self.durationTicks = max(1, durationTicks)
    }
}

public struct StoryBeat: Codable, Equatable, Sendable {
    public var id: String
    public var actorIDs: [String]
    public var intent: String
    public var durationTicks: Int64
    public var effectsOnSuccess: [SuccessEffect]
    /// Optional cast changes initiated by this beat. Keeping this optional
    /// preserves decoding of existing cast-pack JSON files.
    public var inviteMemberIDs: [String]?
    /// Optional concrete target for character-window/prop/mech interactions.
    public var targetID: String?
    /// Optional slot on targetID, for example `cockpit` or `handle`.
    public var slotID: String?
    /// Additional actor claims used by strong-contact or prop interactions.
    public var claims: [String]?
    public var occupySlotOnSuccess: Bool
    /// Release at the next kernel event boundary. When this beat also keeps a
    /// slot occupied, its own claim is released; when it does not request
    /// occupancy, the beat becomes a release-only action for the explicit
    /// target slot (for example, exiting a cockpit).
    public var releaseSlotOnSuccess: Bool
    /// Optional cross-actor prop transfer emitted at this beat's release
    /// boundary. The following beat must claim the declared destination slot;
    /// otherwise the cue is ignored as an invalid/incomplete hand-off.
    public var handoff: StoryHandoff?

    private enum CodingKeys: String, CodingKey {
        case id, actorIDs, intent, durationTicks, effectsOnSuccess
        case inviteMemberIDs, targetID, slotID, claims, occupySlotOnSuccess
        case releaseSlotOnSuccess, handoff
    }

    public init(
        id: String,
        actorIDs: [String],
        intent: String,
        durationTicks: Int64 = 1,
        effectsOnSuccess: [SuccessEffect] = [],
        inviteMemberIDs: [String]? = nil,
        targetID: String? = nil,
        slotID: String? = nil,
        claims: [String]? = nil,
        occupySlotOnSuccess: Bool = false,
        releaseSlotOnSuccess: Bool = false,
        handoff: StoryHandoff? = nil
    ) {
        self.id = id
        self.actorIDs = actorIDs
        self.intent = intent
        self.durationTicks = max(1, durationTicks)
        self.effectsOnSuccess = effectsOnSuccess
        self.inviteMemberIDs = inviteMemberIDs?.filter { !$0.isEmpty }
        self.targetID = targetID?.isEmpty == true ? nil : targetID
        self.slotID = slotID?.isEmpty == true ? nil : slotID
        self.claims = claims?.filter { !$0.isEmpty }
        self.occupySlotOnSuccess = occupySlotOnSuccess
        self.releaseSlotOnSuccess = releaseSlotOnSuccess
        self.handoff = handoff
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            actorIDs: try values.decode([String].self, forKey: .actorIDs),
            intent: try values.decode(String.self, forKey: .intent),
            durationTicks: try values.decodeIfPresent(Int64.self, forKey: .durationTicks) ?? 1,
            effectsOnSuccess: try values.decodeIfPresent([SuccessEffect].self, forKey: .effectsOnSuccess) ?? [],
            inviteMemberIDs: try values.decodeIfPresent([String].self, forKey: .inviteMemberIDs),
            targetID: try values.decodeIfPresent(String.self, forKey: .targetID),
            slotID: try values.decodeIfPresent(String.self, forKey: .slotID),
            claims: try values.decodeIfPresent([String].self, forKey: .claims),
            occupySlotOnSuccess: try values.decodeIfPresent(Bool.self, forKey: .occupySlotOnSuccess) ?? false,
            releaseSlotOnSuccess: try values.decodeIfPresent(Bool.self, forKey: .releaseSlotOnSuccess) ?? false,
            handoff: try values.decodeIfPresent(StoryHandoff.self, forKey: .handoff))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(actorIDs, forKey: .actorIDs)
        try values.encode(intent, forKey: .intent)
        try values.encode(durationTicks, forKey: .durationTicks)
        try values.encode(effectsOnSuccess, forKey: .effectsOnSuccess)
        try values.encodeIfPresent(inviteMemberIDs, forKey: .inviteMemberIDs)
        try values.encodeIfPresent(targetID, forKey: .targetID)
        try values.encodeIfPresent(slotID, forKey: .slotID)
        try values.encodeIfPresent(claims, forKey: .claims)
        try values.encode(occupySlotOnSuccess, forKey: .occupySlotOnSuccess)
        try values.encode(releaseSlotOnSuccess, forKey: .releaseSlotOnSuccess)
        try values.encodeIfPresent(handoff, forKey: .handoff)
    }
}

/// Capability is an authorization boundary, not an asset hint. A visual pack
/// may contain a fallback clip, but that never grants its logical character a
/// combat, window, prop, social, mech, or destruction action.
public enum StoryCapabilityGate {
    public static func requiredCapability(for intent: String) -> String? {
        let normalized = intent.lowercased()
        if ["attack", "fight", "challenge", "combat_ready", "defend", "dodge",
            "hit_react", "victory", "defeat", "retreat", "taunt"].contains(normalized) {
            return "combat"
        }
        if normalized.contains("window") || normalized.contains("sill") ||
            ["climb", "peek", "hang", "pull_up"].contains(normalized) {
            return "window"
        }
        if normalized.contains("cockpit") || normalized.hasPrefix("mech_") ||
            ["activate", "standby"].contains(normalized) {
            return "mech"
        }
        if ["read", "give", "receive", "drink", "eat", "type", "carry", "throw",
            "inspect", "use", "signal"].contains(normalized) {
            return "prop"
        }
        if ["talk", "listen", "comfort", "argue", "greet_other", "face_other",
            "follow", "hug", "play"].contains(normalized) {
            return "social"
        }
        if normalized.contains("destroy") || normalized.contains("break_window") {
            return "destruction"
        }
        return nil
    }

    public static func canExecute(
        _ beat: StoryBeat,
        membersByID: [String: CastMember]
    ) -> Bool {
        guard let required = requiredCapability(for: beat.intent) else { return true }
        return beat.actorIDs.allSatisfy { actorID in
            guard let member = membersByID[actorID] else { return true }
            return member.capabilities.contains(required)
        }
    }
}

public struct StoryBranch: Codable, Equatable, Sendable {
    public var id: String
    public var prerequisites: [StoryPrerequisite]
    public var beats: [StoryBeat]
    /// Larger values win; id is the deterministic tie-breaker.
    public var priority: Int

    public init(
        id: String,
        prerequisites: [StoryPrerequisite] = [],
        beats: [StoryBeat] = [],
        priority: Int = 0
    ) {
        self.id = id
        self.prerequisites = prerequisites
        self.beats = beats
        self.priority = priority
    }
}

public struct StoryEpisode: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var participants: [String]
    public var prerequisites: [StoryPrerequisite]
    public var beats: [StoryBeat]
    public var cooldownTicks: Int64
    /// Optional deterministic branches. Empty keeps the original linear episode.
    public var branches: [StoryBranch]

    private enum CodingKeys: String, CodingKey {
        case id, title, participants, prerequisites, beats, cooldownTicks, branches
    }

    public init(
        id: String,
        title: String,
        participants: [String],
        prerequisites: [StoryPrerequisite] = [],
        beats: [StoryBeat] = [],
        cooldownTicks: Int64 = 0,
        branches: [StoryBranch] = []
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.prerequisites = prerequisites
        self.beats = beats
        self.cooldownTicks = max(0, cooldownTicks)
        self.branches = branches
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            participants: try values.decode([String].self, forKey: .participants),
            prerequisites: try values.decodeIfPresent([StoryPrerequisite].self, forKey: .prerequisites) ?? [],
            beats: try values.decodeIfPresent([StoryBeat].self, forKey: .beats) ?? [],
            cooldownTicks: try values.decodeIfPresent(Int64.self, forKey: .cooldownTicks) ?? 0,
            branches: try values.decodeIfPresent([StoryBranch].self, forKey: .branches) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(participants, forKey: .participants)
        try values.encode(prerequisites, forKey: .prerequisites)
        try values.encode(beats, forKey: .beats)
        try values.encode(cooldownTicks, forKey: .cooldownTicks)
        try values.encode(branches, forKey: .branches)
    }
}

/// A cast-owned world object. It is intentionally separate from CastMember:
/// props can be targets and slot hosts, but they are never eligible as actors
/// for automatic cast rotation.
public struct CastProp: Codable, Equatable, Sendable {
    public var id: String
    public var displayNames: LocalizedLabel
    public var descriptions: LocalizedLabel?
    public var visualPackID: String?

    public var displayName: String { displayNames.defaultText }

    public init(id: String, displayName: String, visualPackID: String? = nil) {
        self.id = id
        self.displayNames = LocalizedLabel(displayName)
        self.descriptions = nil
        self.visualPackID = visualPackID
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, description, visualPackID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayNames = try values.decode(LocalizedLabel.self, forKey: .displayName)
        descriptions = try values.decodeIfPresent(LocalizedLabel.self, forKey: .description)
        visualPackID = try values.decodeIfPresent(String.self, forKey: .visualPackID)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayNames, forKey: .displayName)
        try values.encodeIfPresent(descriptions, forKey: .description)
        try values.encodeIfPresent(visualPackID, forKey: .visualPackID)
    }
}

public struct CastPack: Codable, Equatable, Sendable {
    public var id: String
    public var groupID: String
    public var categoryID: String
    public var displayNames: LocalizedLabel
    public var descriptions: LocalizedLabel
    public var members: [CastMember]
    public var relations: [CastRelation]
    public var slots: [CastSlot]
    /// Read-only compatibility for cast JSON authored before stories were separate.
    /// New cast JSON never encodes this field.
    public var episodes: [StoryEpisode]
    /// Optional for backwards-compatible cast-pack JSON.
    public var props: [CastProp]?

    public var displayName: String { displayNames.defaultText }
    public var summary: String { descriptions.defaultText }

    public init(
        id: String,
        groupID: String,
        categoryID: String? = nil,
        displayName: String,
        summary: String,
        members: [CastMember],
        relations: [CastRelation] = [],
        slots: [CastSlot] = [],
        episodes: [StoryEpisode] = [],
        props: [CastProp]? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.categoryID = categoryID ?? groupID
        self.displayNames = LocalizedLabel(displayName)
        self.descriptions = LocalizedLabel(summary)
        self.members = members
        self.relations = relations
        self.slots = slots
        self.episodes = episodes
        self.props = props
    }

    private enum CodingKeys: String, CodingKey {
        case id, categoryID, groupID, displayName, description, summary
        case members, relations, slots, episodes, props
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let decodedCategory = try values.decodeIfPresent(String.self, forKey: .categoryID)
        groupID = try values.decodeIfPresent(String.self, forKey: .groupID)
            ?? decodedCategory
            ?? ""
        categoryID = decodedCategory ?? groupID
        displayNames = try values.decode(LocalizedLabel.self, forKey: .displayName)
        descriptions = try values.decodeIfPresent(LocalizedLabel.self, forKey: .description)
            ?? values.decodeIfPresent(LocalizedLabel.self, forKey: .summary)
            ?? LocalizedLabel("")
        members = try values.decode([CastMember].self, forKey: .members)
        relations = try values.decodeIfPresent([CastRelation].self, forKey: .relations) ?? []
        slots = try values.decodeIfPresent([CastSlot].self, forKey: .slots) ?? []
        episodes = try values.decodeIfPresent([StoryEpisode].self, forKey: .episodes) ?? []
        props = try values.decodeIfPresent([CastProp].self, forKey: .props)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(groupID, forKey: .groupID)
        try values.encode(categoryID, forKey: .categoryID)
        try values.encode(displayNames, forKey: .displayName)
        try values.encode(descriptions, forKey: .description)
        try values.encode(members, forKey: .members)
        try values.encode(relations, forKey: .relations)
        try values.encode(slots, forKey: .slots)
        try values.encodeIfPresent(props, forKey: .props)
    }

    public func initialEntities() -> [EntityState] {
        members.map {
            EntityState(
                id: EntityID($0.id),
                kind: $0.kind == .mech ? .mech : .actor
            )
        } + (props ?? []).map {
            EntityState(id: EntityID($0.id), kind: .prop)
        }
    }

    public func initialSlots() -> [InteractionSlot] {
        slots.compactMap { slot in
            guard members.contains(where: { $0.id == slot.entityID }) ||
                    (props ?? []).contains(where: { $0.id == slot.entityID }) else { return nil }
            return InteractionSlot(entityID: EntityID(slot.entityID), slotID: slot.slotID, capacity: slot.capacity)
        }
    }

    public func initialRelationValues() -> [String: Double] {
        relations.reduce(into: [:]) { result, relation in
            for (field, value) in relation.state {
                result[relation.worldKey(field)] = min(1, max(0, value))
            }
        }
    }
}

public enum StoryCatalog {
    public static func prerequisitesSatisfied(
        _ prerequisites: [StoryPrerequisite],
        world: WorldState,
        tick: Int64
    ) -> Bool {
        prerequisites.allSatisfy { requirement in
            if let key = requirement.relationKey {
                guard let minimum = requirement.minimum else { return world.relationValues[key] != nil }
                guard let value = world.relationValues[key] else { return false }
                guard value >= minimum else { return false }
            }
            if let fact = requirement.requiredFact {
                guard let value = world.facts[fact], value.isValid(at: tick) else { return false }
            }
            return true
        }
    }

    public static func branch(
        for episode: StoryEpisode,
        world: WorldState,
        tick: Int64,
        availableMembers: Set<String>
    ) -> StoryBranch? {
        episode.branches
            .filter { branch in
                !branch.beats.isEmpty &&
                    prerequisitesSatisfied(branch.prerequisites, world: world, tick: tick) &&
                    branch.beats.allSatisfy {
                        !$0.actorIDs.isEmpty && Set($0.actorIDs).isSubset(of: availableMembers)
                    }
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.id < $1.id
            }
            .first
    }

    public static func eligible(
        episodes: [StoryEpisode],
        world: WorldState,
        tick: Int64,
        availableMembers: Set<String>
    ) -> [StoryEpisode] {
        episodes.filter { episode in
            guard Set(episode.participants).isSubset(of: availableMembers) else { return false }
            guard prerequisitesSatisfied(episode.prerequisites, world: world, tick: tick) else { return false }
            let beatSets = [episode.beats] + episode.branches.map(\.beats)
            return beatSets.contains { beats in
                !beats.isEmpty && beats.allSatisfy { beat in
                    !beat.actorIDs.isEmpty && Set(beat.actorIDs).isSubset(of: availableMembers)
                }
            }
        }
    }

    /// A transiently occupied first slot makes an episode not runnable yet;
    /// selecting it anyway only creates a guaranteed kernel rejection and a
    /// false story interruption. Later beats may legitimately depend on a
    /// release performed by an earlier beat, so this check is intentionally
    /// limited to the entry beat.
    public static func firstBeatCanStart(
        _ beat: StoryBeat,
        world: WorldState,
        availableMembers: Set<String>
    ) -> Bool {
        guard !beat.actorIDs.isEmpty,
              Set(beat.actorIDs).count == beat.actorIDs.count,
              Set(beat.actorIDs).isSubset(of: availableMembers) else { return false }

        var requestedActorsBySlot: [String: Set<String>] = [:]
        for actorID in beat.actorIDs {
            let targetID: String? = beat.targetID ?? {
                guard beat.actorIDs.count == 2 else { return nil }
                return beat.actorIDs.first { $0 != actorID }
            }()
            if let targetID, !world.isAlive(EntityID(targetID)) { return false }
            guard world.isAlive(EntityID(actorID)) else { return false }
            guard let slotID = beat.slotID, let targetID else { continue }
            guard let slot = world.slots["\(targetID)/\(slotID)"], slot.status != .disabled else {
                return false
            }
            if beat.releaseSlotOnSuccess && !beat.occupySlotOnSuccess { continue }
            let key = slot.key
            let requested = requestedActorsBySlot[key, default: []]
            guard !slot.contains(actorID: EntityID(actorID)),
                  slot.occupants.count + requested.count < slot.capacity else { return false }
            requestedActorsBySlot[key, default: []].insert(actorID)
        }
        return true
    }
}
