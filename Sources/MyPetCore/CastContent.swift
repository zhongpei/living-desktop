import Foundation

public struct CharacterCategory: Codable, Equatable, Sendable {
    public var id: String
    public var displayNames: LocalizedLabel
    public var order: Int

    public init(id: String, displayNames: LocalizedLabel, order: Int = 0) {
        self.id = id
        self.displayNames = displayNames
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayNames = "displayName", order
    }
}

public struct CharacterCategoryCatalog: Codable, Equatable, Sendable {
    public var categories: [CharacterCategory]
    public init(categories: [CharacterCategory]) { self.categories = categories }
}

public struct CharacterPersonality: Codable, Equatable, Sendable {
    public var social: Int
    public var curiosity: Int
    public var playfulness: Int
    public var diligence: Int
    public var empathy: Int
    public var independence: Int
    public var teasing: Int

    public init(
        social: Int = 60, curiosity: Int = 60, playfulness: Int = 50,
        diligence: Int = 50, empathy: Int = 60, independence: Int = 50,
        teasing: Int = 50
    ) {
        self.social = social
        self.curiosity = curiosity
        self.playfulness = playfulness
        self.diligence = diligence
        self.empathy = empathy
        self.independence = independence
        self.teasing = teasing
    }

    var values: [String: Int] {
        ["social": social, "curiosity": curiosity, "playfulness": playfulness,
         "diligence": diligence, "empathy": empathy, "independence": independence,
         "teasing": teasing]
    }
}

public struct CharacterAptitudes: Codable, Equatable, Sendable {
    public var mobility: Int
    public var handling: Int
    public var focus: Int
    public var presence: Int
    public var impact: Int

    public init(
        mobility: Int = 50, handling: Int = 50, focus: Int = 50,
        presence: Int = 50, impact: Int = 50
    ) {
        self.mobility = mobility
        self.handling = handling
        self.focus = focus
        self.presence = presence
        self.impact = impact
    }

    var values: [String: Int] {
        ["mobility": mobility, "handling": handling, "focus": focus,
         "presence": presence, "impact": impact]
    }
}

public struct CharacterSignatureBehavior: Codable, Equatable, Sendable {
    public var label: String
    public var intensity: String
    public var actionCandidates: [String]

    public init(label: String, intensity: String, actionCandidates: [String] = []) {
        self.label = label
        self.intensity = intensity
        self.actionCandidates = actionCandidates
    }
}

/// Human-facing character language retained beside the compiled numeric projection.
public struct CharacterSemanticProfile: Codable, Equatable, Sendable {
    public var personality: [String: String]
    public var aptitudes: [String: String]
    public var personalityTypes: [String]
    public var signatureBehaviors: [String: CharacterSignatureBehavior]
    public var playCapabilities: [String: String]

    public init(
        personality: [String: String] = [:], aptitudes: [String: String] = [:],
        personalityTypes: [String] = [],
        signatureBehaviors: [String: CharacterSignatureBehavior] = [:],
        playCapabilities: [String: String] = [:]
    ) {
        self.personality = personality
        self.aptitudes = aptitudes
        self.personalityTypes = personalityTypes
        self.signatureBehaviors = signatureBehaviors
        self.playCapabilities = playCapabilities
    }
}

public struct CharacterDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var displayNames: LocalizedLabel
    public var background: LocalizedLabel
    public var personality: CharacterPersonality
    public var aptitudes: CharacterAptitudes
    public var semanticProfile: CharacterSemanticProfile?
    public var performancePrompt: LocalizedLabel
    public var dialogue: DialogueProfile?
    public var capabilities: [String]

    public var displayName: String { displayNames.defaultText }

    public init(
        id: String,
        displayNames: LocalizedLabel,
        background: LocalizedLabel,
        personality: CharacterPersonality,
        aptitudes: CharacterAptitudes,
        semanticProfile: CharacterSemanticProfile? = nil,
        performancePrompt: LocalizedLabel,
        dialogue: DialogueProfile? = nil,
        capabilities: [String] = []
    ) {
        self.id = id
        self.displayNames = displayNames
        self.background = background
        self.personality = personality
        self.aptitudes = aptitudes
        self.semanticProfile = semanticProfile
        self.performancePrompt = performancePrompt
        self.dialogue = dialogue
        self.capabilities = Array(Set(capabilities)).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayNames = "displayName", background, personality, aptitudes, semanticProfile
        case performancePrompt = "performance_prompt", dialogue, capabilities
    }

    public var configurationErrors: [String] {
        var errors: [String] = []
        if id.isEmpty { errors.append("character id must not be empty") }
        if displayNames.zhHans.isEmpty || displayNames.en.isEmpty {
            errors.append("character \(id) requires bilingual displayName")
        }
        if background.zhHans.isEmpty || background.en.isEmpty {
            errors.append("character \(id) requires bilingual background")
        }
        if performancePrompt.zhHans.isEmpty || performancePrompt.en.isEmpty {
            errors.append("character \(id) requires bilingual performance_prompt")
        }
        errors.append(contentsOf: dialogue?.configurationErrors(characterID: id) ?? [])
        for (name, value) in personality.values where !(0...100).contains(value) {
            errors.append("character \(id) personality \(name) must be 0...100")
        }
        for (name, value) in aptitudes.values where !(0...100).contains(value) {
            errors.append("character \(id) aptitude \(name) must be 0...100")
        }
        return errors
    }
}

public struct LocalizedStringList: Codable, Equatable, Sendable {
    public var zhHans: [String]
    public var en: [String]

    public init(zhHans: [String], en: [String]) {
        self.zhHans = zhHans
        self.en = en
    }

    private enum CodingKeys: String, CodingKey { case zhHans = "zh-Hans", en }
}

public struct DialogueFewShot: Codable, Equatable, Sendable {
    public var speechActID: String
    public var knownFacts: LocalizedLabel
    public var assistant: LocalizedLabel

    public init(speechActID: String, knownFacts: LocalizedLabel, assistant: LocalizedLabel) {
        self.speechActID = speechActID
        self.knownFacts = knownFacts
        self.assistant = assistant
    }
}

public struct DialogueProfile: Codable, Equatable, Sendable {
    public var dialogueStyle: LocalizedLabel
    public var selfReference: LocalizedLabel
    public var preferredPhrases: LocalizedStringList
    public var forbiddenStyles: LocalizedStringList
    public var fewShots: [DialogueFewShot]
    public var fallbackLines: [String: LocalizedStringList]

    public init(
        dialogueStyle: LocalizedLabel,
        selfReference: LocalizedLabel,
        preferredPhrases: LocalizedStringList,
        forbiddenStyles: LocalizedStringList,
        fewShots: [DialogueFewShot],
        fallbackLines: [String: LocalizedStringList]
    ) {
        self.dialogueStyle = dialogueStyle
        self.selfReference = selfReference
        self.preferredPhrases = preferredPhrases
        self.forbiddenStyles = forbiddenStyles
        self.fewShots = fewShots
        self.fallbackLines = fallbackLines
    }

    public func fewShot(for speechActID: String) -> DialogueFewShot? {
        fewShots.first { $0.speechActID == speechActID }
    }

    public func configurationErrors(characterID: String) -> [String] {
        let required = Set(["greet", "comment_activity", "tease", "complain", "chatter"])
        var errors: [String] = []
        if dialogueStyle.zhHans.isEmpty || dialogueStyle.en.isEmpty {
            errors.append("character \(characterID) dialogueStyle must be bilingual")
        }
        if selfReference.zhHans.isEmpty || selfReference.en.isEmpty {
            errors.append("character \(characterID) selfReference must be bilingual")
        }
        let ids = fewShots.map(\.speechActID)
        if Set(ids) != required || Set(ids).count != ids.count {
            errors.append("character \(characterID) requires exactly one few-shot per SpeechIntent")
        }
        if Set(fallbackLines.keys) != required || fallbackLines.values.contains(where: {
            $0.zhHans.isEmpty || $0.en.isEmpty
        }) {
            errors.append("character \(characterID) requires bilingual fallback lines per SpeechIntent")
        }
        for shot in fewShots where shot.knownFacts.zhHans.isEmpty || shot.knownFacts.en.isEmpty ||
            shot.assistant.zhHans.isEmpty || shot.assistant.en.isEmpty {
            errors.append("character \(characterID) few-shot \(shot.speechActID) must be bilingual")
        }
        return errors
    }
}

public struct CharacterCatalog: Codable, Equatable, Sendable {
    public var characters: [CharacterDefinition]
    public init(characters: [CharacterDefinition]) { self.characters = characters }
}

public enum RelationshipDirection: String, Codable, Sendable {
    case directed
    case symmetric
}

public struct RelationshipKindDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var displayNames: LocalizedLabel
    public var descriptions: LocalizedLabel
    public var direction: RelationshipDirection
    public var allowedStateFields: [String]

    public init(
        id: String,
        displayNames: LocalizedLabel,
        descriptions: LocalizedLabel,
        direction: RelationshipDirection,
        allowedStateFields: [String]
    ) {
        self.id = id
        self.displayNames = displayNames
        self.descriptions = descriptions
        self.direction = direction
        self.allowedStateFields = allowedStateFields
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayNames = "displayName", descriptions = "description"
        case direction, allowedStateFields
    }
}

public struct RelationshipKindCatalog: Codable, Equatable, Sendable {
    public var kinds: [RelationshipKindDefinition]
    public init(kinds: [RelationshipKindDefinition]) { self.kinds = kinds }
}

public struct CharacterGroup: Codable, Equatable, Sendable {
    public var id: String
    public var categoryID: String
    public var displayNames: LocalizedLabel
    public var descriptions: LocalizedLabel
    public var memberIDs: [String]
    public var entityIDs: [String]
    public var baseRelations: [CastRelation]
    public var defaultCastPackID: String?

    public var displayName: String { displayNames.defaultText }

    public init(
        id: String,
        categoryID: String,
        displayNames: LocalizedLabel,
        descriptions: LocalizedLabel,
        memberIDs: [String],
        entityIDs: [String] = [],
        baseRelations: [CastRelation] = [],
        defaultCastPackID: String? = nil
    ) {
        self.id = id
        self.categoryID = categoryID
        self.displayNames = displayNames
        self.descriptions = descriptions
        self.memberIDs = memberIDs
        self.entityIDs = entityIDs
        self.baseRelations = baseRelations
        self.defaultCastPackID = defaultCastPackID
    }

    private enum CodingKeys: String, CodingKey {
        case id, categoryID, displayNames = "displayName", descriptions = "description"
        case memberIDs, entityIDs, baseRelations, defaultCastPackID
    }
}

public struct ResolvedCastPack: Equatable, Sendable {
    public var pack: CastPack
    public var group: CharacterGroup
    public var characters: [String: CharacterDefinition]
}

public struct CastContentCatalog: Equatable, Sendable {
    public var categories: [CharacterCategory]
    public var characters: [CharacterDefinition]
    public var groups: [CharacterGroup]
    public var relationshipKinds: RelationshipKindCatalog

    public init(
        categories: [CharacterCategory] = [],
        characters: [CharacterDefinition],
        groups: [CharacterGroup],
        relationshipKinds: RelationshipKindCatalog
    ) {
        self.categories = categories
        self.characters = characters
        self.groups = groups
        self.relationshipKinds = relationshipKinds
    }

    public var charactersByID: [String: CharacterDefinition] {
        Dictionary(characters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var groupsByID: [String: CharacterGroup] {
        Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var configurationErrors: [String] {
        var errors = characters.flatMap(\.configurationErrors)
        let characterIDs = Set(characters.map(\.id))
        let kindByID = Dictionary(
            relationshipKinds.kinds.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        errors += duplicateErrors(characters.map(\.id), label: "character")
        errors += duplicateErrors(categories.map(\.id), label: "category")
        errors += duplicateErrors(groups.map(\.id), label: "group")
        errors += duplicateErrors(relationshipKinds.kinds.map(\.id), label: "relationship kind")
        for group in groups {
            if !categories.isEmpty && !categories.contains(where: { $0.id == group.categoryID }) {
                errors.append("group \(group.id) references unknown category \(group.categoryID)")
            }
            for memberID in group.memberIDs where !characterIDs.contains(memberID) {
                errors.append("group \(group.id) references unknown member \(memberID)")
            }
            let participantIDs = Set(group.memberIDs + group.entityIDs)
            for relation in group.baseRelations {
                if !participantIDs.contains(relation.from) {
                    errors.append("group \(group.id) relation references unknown participant \(relation.from)")
                }
                if !participantIDs.contains(relation.to) {
                    errors.append("group \(group.id) relation references unknown participant \(relation.to)")
                }
                guard let kind = kindByID[relation.kind] else {
                    errors.append("group \(group.id) uses unknown relationship kind \(relation.kind)")
                    continue
                }
                let allowed = Set(kind.allowedStateFields)
                for field in relation.state.keys where !allowed.contains(field) {
                    errors.append("group \(group.id) relation \(relation.kind) uses unsupported state \(field)")
                }
            }
        }
        return errors.sorted()
    }

    public func resolve(_ packs: [CastPack]) throws -> [ResolvedCastPack] {
        let errors = configurationErrors
        guard errors.isEmpty else { throw CastContentError.invalidConfiguration(errors) }
        let groupsByID = groupsByID
        let charactersByID = charactersByID
        let relationshipKindsByID = Dictionary(
            relationshipKinds.kinds.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return try packs.map { source in
            guard let group = groupsByID[source.groupID] else {
                throw CastContentError.unknownGroup(packID: source.id, groupID: source.groupID)
            }
            let allowedMembers = Set(group.memberIDs + group.entityIDs)
            for member in source.members where member.kind == .character {
                guard let visualPackID = member.visualPackID,
                      !visualPackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CastContentError.invalidPack(
                        packID: source.id,
                        reason: "character \(member.id) requires visualPackID")
                }
            }
            for member in source.members where
                !allowedMembers.contains(member.profileID ?? member.id) &&
                !allowedMembers.contains(member.id) {
                throw CastContentError.memberOutsideGroup(
                    packID: source.id, memberID: member.id, groupID: group.id)
            }
            let resolvedMembers = source.members.map { member in
                guard let definition = charactersByID[member.profileID ?? member.id] else {
                    return member
                }
                var resolved = member
                resolved.displayNames = definition.displayNames
                resolved.capabilities = definition.capabilities
                return resolved
            }
            let memberByID = Dictionary(
                resolvedMembers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let participantIDs = Set(source.members.map(\.id) + (source.props ?? []).map(\.id))
            for relation in source.relations {
                guard participantIDs.contains(relation.from), participantIDs.contains(relation.to) else {
                    throw CastContentError.invalidPack(
                        packID: source.id,
                        reason: "relation \(relation.kind) references unknown participant")
                }
                guard let kind = relationshipKindsByID[relation.kind] else {
                    throw CastContentError.invalidPack(
                        packID: source.id, reason: "unknown relationship kind \(relation.kind)")
                }
                let unsupported = Set(relation.state.keys).subtracting(kind.allowedStateFields)
                guard unsupported.isEmpty else {
                    throw CastContentError.invalidPack(
                        packID: source.id,
                        reason: "relation \(relation.kind) uses unsupported state \(unsupported.sorted().joined(separator: ","))")
                }
            }
            for episode in source.episodes {
                guard Set(episode.participants).isSubset(of: participantIDs) else {
                    throw CastContentError.invalidPack(
                        packID: source.id, reason: "episode \(episode.id) references unknown participant")
                }
                for beat in episode.beats + episode.branches.flatMap(\.beats) {
                    guard StoryCapabilityGate.canExecute(beat, membersByID: memberByID) else {
                        throw CastContentError.invalidPack(
                            packID: source.id, reason: "beat \(beat.id) fails capability gate")
                    }
                }
            }
            var pack = source
            pack.categoryID = group.categoryID
            pack.members = resolvedMembers
            pack.relations = mergeRelations(base: group.baseRelations, overrides: source.relations)
            let definitions = Dictionary(uniqueKeysWithValues: source.members.compactMap { member in
                let profileID = member.profileID ?? member.id
                return charactersByID[profileID].map { (member.id, $0) }
            })
            return ResolvedCastPack(pack: pack, group: group, characters: definitions)
        }
    }

    /// Validate standalone narratives against resolved cast facts. A story may
    /// reference members and props of its target group, but never add them.
    public func resolveStories(_ stories: [StoryPack],
                               for casts: [ResolvedCastPack]) throws -> [StoryPack] {
        let castsByGroup = Dictionary(grouping: casts, by: { $0.pack.groupID })
        var seen = Set<String>()
        return try stories.sorted { $0.id < $1.id }.map { story in
            guard seen.insert(story.id).inserted else {
                throw CastContentError.invalidPack(packID: story.id, reason: "duplicate story pack ID")
            }
            guard let cast = castsByGroup[story.groupID]?.first else {
                throw CastContentError.unknownGroup(packID: story.id, groupID: story.groupID)
            }
            let actors = Set(cast.pack.members.map(\.id))
            let entities = actors.union((cast.pack.props ?? []).map(\.id))
            let members = Dictionary(cast.pack.members.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
            let slots = Set(cast.pack.slots.map { "\($0.entityID)/\($0.slotID)" })
            var episodeIDs = Set<String>()
            for episode in story.episodes {
                guard episodeIDs.insert(episode.id).inserted else {
                    throw CastContentError.invalidPack(
                        packID: story.id, reason: "duplicate episode \(episode.id)")
                }
                guard Set(episode.participants).isSubset(of: entities) else {
                    throw CastContentError.invalidPack(
                        packID: story.id, reason: "episode \(episode.id) references unknown participant")
                }
                for beat in episode.beats + episode.branches.flatMap(\.beats) {
                    guard !beat.actorIDs.isEmpty, Set(beat.actorIDs).isSubset(of: actors) else {
                        throw CastContentError.invalidPack(
                            packID: story.id, reason: "beat \(beat.id) references unknown actor")
                    }
                    if let target = beat.targetID, !entities.contains(target) {
                        throw CastContentError.invalidPack(
                            packID: story.id, reason: "beat \(beat.id) references unknown target")
                    }
                    if let slot = beat.slotID, let target = beat.targetID,
                       !slots.contains("\(target)/\(slot)") {
                        throw CastContentError.invalidPack(
                            packID: story.id, reason: "beat \(beat.id) references unknown slot")
                    }
                    guard StoryCapabilityGate.canExecute(beat, membersByID: members) else {
                        throw CastContentError.invalidPack(
                            packID: story.id, reason: "beat \(beat.id) fails capability gate")
                    }
                }
            }
            return story
        }
    }

    private func mergeRelations(base: [CastRelation], overrides: [CastRelation]) -> [CastRelation] {
        var merged = Dictionary(uniqueKeysWithValues: base.map { (relationID($0), $0) })
        for override in overrides {
            let key = relationID(override)
            guard var existing = merged[key] else {
                merged[key] = override
                continue
            }
            existing.state.merge(override.state) { _, replacement in replacement }
            merged[key] = existing
        }
        return merged.values.sorted { relationID($0) < relationID($1) }
    }

    private func relationID(_ relation: CastRelation) -> String {
        "\(relation.from)/\(relation.to)/\(relation.kind)"
    }

    private func duplicateErrors(_ ids: [String], label: String) -> [String] {
        Dictionary(grouping: ids, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted().map { "duplicate \(label) id \($0)" }
    }
}

public enum CastContentError: Error, Equatable {
    case invalidConfiguration([String])
    case unknownGroup(packID: String, groupID: String)
    case memberOutsideGroup(packID: String, memberID: String, groupID: String)
    case invalidPack(packID: String, reason: String)
}
