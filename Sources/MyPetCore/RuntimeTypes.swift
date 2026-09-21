import Foundation

public struct EntityID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var description: String { raw }
}

public struct EntityRef: Codable, Hashable, Sendable, Equatable {
    public let entityID: EntityID
    public let revision: Int

    public init(entityID: EntityID, revision: Int) {
        self.entityID = entityID
        self.revision = revision
    }
}

public struct SlotRef: Codable, Hashable, Sendable, Equatable {
    public let entityID: EntityID
    public let slotID: String
    public let revision: Int

    public init(entityID: EntityID, slotID: String, revision: Int) {
        self.entityID = entityID
        self.slotID = slotID
        self.revision = revision
    }

    public var key: String { "\(entityID.raw)/\(slotID)" }
}

public enum EntityKind: String, Codable, Sendable {
    case actor
    case window
    case prop
    case mech
    case surface
}

public struct EntityState: Codable, Sendable, Equatable {
    public var id: EntityID
    public var kind: EntityKind
    public var revision: Int
    public var alive: Bool

    public init(id: EntityID, kind: EntityKind, revision: Int = 0, alive: Bool = true) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.alive = alive
    }

    public var ref: EntityRef { EntityRef(entityID: id, revision: revision) }
}

public enum PriorityBand: Int, Codable, Comparable, CaseIterable, Sendable {
    case userDirect = 0
    case urgentReactive = 1
    case brainReactive = 2
    case ambient = 3
    case story = 4

    public static func < (lhs: PriorityBand, rhs: PriorityBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 剧情是否让位于外界抢占的策略。用户设置只影响 story 优先级的行为；
/// userDirect 和更高优先级的直接交互始终可以打断角色动作。
public struct StoryInterruptionPolicy: Codable, Equatable, Sendable {
    public var foreground: Bool
    public var content: Bool

    public init(foreground: Bool = true, content: Bool = true) {
        self.foreground = foreground
        self.content = content
    }
}

public enum SlotStatus: String, Codable, Sendable {
    case free
    case claimed
    case occupied
    case disabled
}

public struct SlotOccupant: Codable, Sendable, Equatable {
    public var claimID: String
    public var actorID: EntityID
    public var status: SlotStatus

    public init(claimID: String, actorID: EntityID, status: SlotStatus = .claimed) {
        self.claimID = claimID
        self.actorID = actorID
        self.status = status == .occupied ? .occupied : .claimed
    }
}

public struct InteractionSlot: Codable, Sendable, Equatable {
    public var entityID: EntityID
    public var slotID: String
    public var capacity: Int
    public var status: SlotStatus
    /// All claims currently using this slot. The old claimID/actorID fields are
    /// kept as a Codable/source-compatibility view of the first occupant.
    public private(set) var occupants: [SlotOccupant]
    public var claimID: String?
    public var actorID: EntityID?
    public var revision: Int

    public init(
        entityID: EntityID,
        slotID: String,
        capacity: Int = 1,
        status: SlotStatus = .free,
        claimID: String? = nil,
        actorID: EntityID? = nil,
        occupants: [SlotOccupant] = [],
        revision: Int = 0
    ) {
        self.entityID = entityID
        self.slotID = slotID
        self.capacity = max(1, capacity)
        let legacyOccupant = occupants.isEmpty
            ? (claimID.flatMap { claim in actorID.map { SlotOccupant(claimID: claim, actorID: $0, status: status) } })
            : nil
        self.occupants = occupants.isEmpty ? legacyOccupant.map { [$0] } ?? [] : occupants
        self.status = status == .free && !self.occupants.isEmpty ? Self.aggregateStatus(self.occupants) : status
        self.claimID = self.occupants.first?.claimID
        self.actorID = self.occupants.first?.actorID
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case entityID, slotID, capacity, status, occupants, claimID, actorID, revision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try values.decode(EntityID.self, forKey: .entityID)
        slotID = try values.decode(String.self, forKey: .slotID)
        capacity = max(1, try values.decodeIfPresent(Int.self, forKey: .capacity) ?? 1)
        status = try values.decodeIfPresent(SlotStatus.self, forKey: .status) ?? .free
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        let decoded = try values.decodeIfPresent([SlotOccupant].self, forKey: .occupants) ?? []
        let oldClaim = try values.decodeIfPresent(String.self, forKey: .claimID)
        let oldActor = try values.decodeIfPresent(EntityID.self, forKey: .actorID)
        if decoded.isEmpty, let oldClaim, let oldActor {
            occupants = [SlotOccupant(claimID: oldClaim, actorID: oldActor, status: status)]
        } else {
            occupants = decoded
        }
        claimID = occupants.first?.claimID
        actorID = occupants.first?.actorID
        if status == .free && !occupants.isEmpty { status = Self.aggregateStatus(occupants) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entityID, forKey: .entityID)
        try values.encode(slotID, forKey: .slotID)
        try values.encode(capacity, forKey: .capacity)
        try values.encode(status, forKey: .status)
        try values.encode(occupants, forKey: .occupants)
        try values.encodeIfPresent(occupants.first?.claimID, forKey: .claimID)
        try values.encodeIfPresent(occupants.first?.actorID, forKey: .actorID)
        try values.encode(revision, forKey: .revision)
    }

    public var ref: SlotRef {
        SlotRef(entityID: entityID, slotID: slotID, revision: revision)
    }

    public var key: String { ref.key }

    public var isFull: Bool { occupants.count >= capacity }

    public func contains(actorID: EntityID) -> Bool {
        occupants.contains { $0.actorID == actorID }
    }

    public func contains(claimID: String) -> Bool {
        occupants.contains { $0.claimID == claimID }
    }

    public mutating func addClaim(_ claimID: String, actorID: EntityID) {
        guard !isFull, !contains(claimID: claimID), !contains(actorID: actorID) else { return }
        occupants.append(SlotOccupant(claimID: claimID, actorID: actorID))
        refreshStatus()
    }

    public mutating func finishClaim(_ claimID: String, occupy: Bool) {
        guard let index = occupants.firstIndex(where: { $0.claimID == claimID }) else { return }
        if occupy {
            occupants[index].status = .occupied
        } else {
            occupants.remove(at: index)
        }
        refreshStatus()
    }

    public mutating func removeClaim(_ claimID: String) {
        occupants.removeAll { $0.claimID == claimID }
        refreshStatus()
    }

    public mutating func removeActor(_ actorID: EntityID) {
        occupants.removeAll { $0.actorID == actorID }
        refreshStatus()
    }

    public mutating func clearClaims() {
        occupants.removeAll()
        refreshStatus()
    }

    private mutating func refreshStatus() {
        if status == .disabled {
            occupants.removeAll()
        } else {
            status = Self.aggregateStatus(occupants)
        }
        claimID = occupants.first?.claimID
        actorID = occupants.first?.actorID
    }

    private static func aggregateStatus(_ occupants: [SlotOccupant]) -> SlotStatus {
        occupants.isEmpty ? .free : (occupants.contains { $0.status == .claimed } ? .claimed : .occupied)
    }
}

/// A confirmed spatial parent/child relationship created by a successful
/// interaction-slot occupancy.  `InteractionSlot` remains the authority for
/// capacity and ownership; this value is the SceneGraph-facing spatial fact
/// that lets a prop follow a character or a pilot follow a mech.
public struct SpatialAttachment: Codable, Sendable, Equatable {
    public var childID: EntityID
    public var parentID: EntityID
    public var socketID: String
    public var slotRef: SlotRef

    public init(
        childID: EntityID,
        parentID: EntityID,
        socketID: String,
        slotRef: SlotRef
    ) {
        self.childID = childID
        self.parentID = parentID
        self.socketID = socketID
        self.slotRef = slotRef
    }
}

public enum BehaviorStatus: String, Codable, Sendable {
    case running
    case completed
    case cancelled
    case rejected
}

public enum SuccessEffectKind: String, Codable, Sendable {
    case relationDelta
    case setFact
}

public struct SuccessEffect: Codable, Sendable, Equatable {
    public var kind: SuccessEffectKind
    public var relationKey: String?
    public var delta: Double?
    public var fact: String?
    public var factTTL: Int64?

    public init(
        kind: SuccessEffectKind,
        relationKey: String? = nil,
        delta: Double? = nil,
        fact: String? = nil,
        factTTL: Int64? = nil
    ) {
        self.kind = kind
        self.relationKey = relationKey
        self.delta = delta
        self.fact = fact
        self.factTTL = factTTL
    }

    public static func relationDelta(_ key: String, _ delta: Double) -> SuccessEffect {
        SuccessEffect(kind: .relationDelta, relationKey: key, delta: delta)
    }

    public static func setFact(_ fact: String, ttl: Int64? = nil) -> SuccessEffect {
        SuccessEffect(kind: .setFact, fact: fact, factTTL: ttl)
    }
}

public enum BehaviorCompletionMode: String, Codable, Sendable {
    case timed
    case body
}

public struct BehaviorRequest: Codable, Sendable, Equatable {
    public var id: String
    public var actorID: EntityID
    public var intent: String
    public var priority: PriorityBand
    public var planEpoch: Int64
    public var target: EntityRef?
    public var slot: SlotRef?
    public var claims: [String]
    public var durationTicks: Int64
    /// Optional on the wire so existing recordings keep their timed behavior.
    public var completionMode: BehaviorCompletionMode?
    /// A body-managed behavior fails closed when its adapter never replies.
    public var timeoutTicks: Int64?
    public var occupySlotOnSuccess: Bool
    public var effectsOnSuccess: [SuccessEffect]
    public var observationID: String?

    public init(
        id: String,
        actorID: EntityID,
        intent: String,
        priority: PriorityBand,
        planEpoch: Int64 = 0,
        target: EntityRef? = nil,
        slot: SlotRef? = nil,
        claims: [String] = ["body"],
        completionMode: BehaviorCompletionMode = .timed,
        durationTicks: Int64 = 1,
        timeoutTicks: Int64? = nil,
        occupySlotOnSuccess: Bool = false,
        effectsOnSuccess: [SuccessEffect] = [],
        observationID: String? = nil
    ) {
        self.id = id
        self.actorID = actorID
        self.intent = intent
        self.priority = priority
        self.planEpoch = planEpoch
        self.target = target
        self.slot = slot
        self.claims = claims
        self.completionMode = completionMode
        self.durationTicks = max(1, durationTicks)
        self.timeoutTicks = timeoutTicks.map { max(1, $0) }
        self.occupySlotOnSuccess = occupySlotOnSuccess
        self.effectsOnSuccess = effectsOnSuccess
        self.observationID = observationID
    }
}

public struct BehaviorState: Codable, Sendable, Equatable {
    public var request: BehaviorRequest
    public var status: BehaviorStatus
    public var startedAtTick: Int64
    public var endedAtTick: Int64?
    public var remainingTicks: Int64

    public init(request: BehaviorRequest, startedAtTick: Int64) {
        self.request = request
        self.status = .running
        self.startedAtTick = startedAtTick
        self.endedAtTick = nil
        self.remainingTicks = request.completionMode == .body
            ? (request.timeoutTicks ?? max(400, request.durationTicks))
            : request.durationTicks
    }
}

public struct StoryFact: Codable, Sendable, Equatable {
    public var value: String
    public var createdAtTick: Int64
    public var expiresAtTick: Int64?

    public init(value: String, createdAtTick: Int64, expiresAtTick: Int64? = nil) {
        self.value = value
        self.createdAtTick = createdAtTick
        self.expiresAtTick = expiresAtTick
    }

    public func isValid(at tick: Int64) -> Bool {
        expiresAtTick.map { tick < $0 } ?? true
    }
}

public struct WorldState: Codable, Sendable, Equatable {
    public var entities: [String: EntityState]
    public var slots: [String: InteractionSlot]
    /// Keyed by child entity. This is derived only through kernel events, not
    /// a second relationship graph or an AppKit-local ownership table.
    public var spatialAttachments: [String: SpatialAttachment]
    public var behaviors: [String: BehaviorState]
    public var inputObservations: [String: InputObservation]
    public var relationValues: [String: Double]
    public var facts: [String: StoryFact]
    public var planEpochs: [String: Int64]

    public init(
        entities: [String: EntityState] = [:],
        slots: [String: InteractionSlot] = [:],
        spatialAttachments: [String: SpatialAttachment] = [:],
        behaviors: [String: BehaviorState] = [:],
        inputObservations: [String: InputObservation] = [:],
        relationValues: [String: Double] = [:],
        facts: [String: StoryFact] = [:],
        planEpochs: [String: Int64] = [:]
    ) {
        self.entities = entities
        self.slots = slots
        self.spatialAttachments = spatialAttachments
        self.behaviors = behaviors
        self.inputObservations = inputObservations
        self.relationValues = relationValues
        self.facts = facts
        self.planEpochs = planEpochs
    }

    private enum CodingKeys: String, CodingKey {
        case entities, slots, spatialAttachments, behaviors, inputObservations
        case relationValues, facts, planEpochs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entities: try values.decodeIfPresent([String: EntityState].self, forKey: .entities) ?? [:],
            slots: try values.decodeIfPresent([String: InteractionSlot].self, forKey: .slots) ?? [:],
            spatialAttachments: try values.decodeIfPresent(
                [String: SpatialAttachment].self, forKey: .spatialAttachments) ?? [:],
            behaviors: try values.decodeIfPresent([String: BehaviorState].self, forKey: .behaviors) ?? [:],
            inputObservations: try values.decodeIfPresent(
                [String: InputObservation].self, forKey: .inputObservations) ?? [:],
            relationValues: try values.decodeIfPresent(
                [String: Double].self, forKey: .relationValues) ?? [:],
            facts: try values.decodeIfPresent([String: StoryFact].self, forKey: .facts) ?? [:],
            planEpochs: try values.decodeIfPresent([String: Int64].self, forKey: .planEpochs) ?? [:])
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entities, forKey: .entities)
        try values.encode(slots, forKey: .slots)
        try values.encode(spatialAttachments, forKey: .spatialAttachments)
        try values.encode(behaviors, forKey: .behaviors)
        try values.encode(inputObservations, forKey: .inputObservations)
        try values.encode(relationValues, forKey: .relationValues)
        try values.encode(facts, forKey: .facts)
        try values.encode(planEpochs, forKey: .planEpochs)
    }

    public func entity(_ id: EntityID) -> EntityState? { entities[id.raw] }

    public func isAlive(_ id: EntityID) -> Bool {
        entities[id.raw]?.alive == true
    }

    /// Builds a deterministic digest. The kernel may pass its derived running
    /// set so terminal behavior history stays in the record without entering
    /// the per-tick hot path.
    public func stableDigest(runningBehaviorIDs: Set<String>? = nil) -> String {
        var parts: [String] = []
        for key in entities.keys.sorted() {
            guard let item = entities[key] else { continue }
            parts.append("e:\(key):\(item.kind.rawValue):\(item.revision):\(item.alive)")
        }
        for key in slots.keys.sorted() {
            guard let item = slots[key] else { continue }
            let occupants = item.occupants
                .map { "\($0.claimID):\($0.actorID.raw):\($0.status.rawValue)" }
                .joined(separator: ",")
            parts.append("s:\(key):\(item.status.rawValue):\(occupants):\(item.revision)")
        }
        for key in spatialAttachments.keys.sorted() {
            guard let attachment = spatialAttachments[key] else { continue }
            parts.append(
                "a:\(key):\(attachment.parentID.raw):\(attachment.socketID):\(attachment.slotRef.key):\(attachment.slotRef.revision)")
        }
        let behaviorKeys = runningBehaviorIDs?.sorted() ?? behaviors.keys.sorted()
        for key in behaviorKeys {
            guard let item = behaviors[key] else { continue }
            if runningBehaviorIDs != nil, item.status != .running { continue }
            parts.append("b:\(key):\(item.status.rawValue):\(item.remainingTicks):\(item.request.planEpoch)")
        }
        for key in inputObservations.keys.sorted() {
            guard let item = inputObservations[key] else { continue }
            let expiry = item.expiresAtTick.map(String.init) ?? "-"
            parts.append("i:\(key):\(item.pluginID):\(item.channel.rawValue):\(item.fingerprint):\(expiry)")
        }
        for key in relationValues.keys.sorted() {
            parts.append("r:\(key):\(relationValues[key] ?? 0)")
        }
        for key in facts.keys.sorted() {
            guard let item = facts[key], item.isValid(at: item.createdAtTick) else { continue }
            let expiration = item.expiresAtTick.map(String.init) ?? "-"
            parts.append("f:\(key):\(item.value):\(item.createdAtTick):\(expiration)")
        }
        for key in planEpochs.keys.sorted() {
            parts.append("p:\(key):\(planEpochs[key] ?? 0)")
        }
        return parts.joined(separator: "|")
    }
}

public enum GameEventKind: String, Codable, Sendable {
    case registerEntity
    case windowChanged
    case destroyEntity
    case createSlot
    case disableSlot
    case behaviorRequest
    case completeBehavior
    case cancelBehavior
    case releaseSlot
    case foregroundChanged
    case userInteraction
    case permissionChanged
    case contentObservation
    case castInvite
    case castArrive
    case castDepart
}

public struct GameEvent: Codable, Sendable, Equatable {
    public var kind: GameEventKind
    public var entity: EntityState?
    public var slot: InteractionSlot?
    public var request: BehaviorRequest?
    public var behaviorID: String?
    public var actorID: EntityID?
    public var entityID: EntityID?
    public var slotRef: SlotRef?
    public var success: Bool?
    public var observationID: String?
    public var inputObservation: InputObservation?
    /// Optional on the wire so old scenario JSON remains decodable.
    public var inputPreemptive: Bool?
    public var inputPriority: PriorityBand?
    public var castMemberID: String?
    public var sourceActorID: EntityID?
    public var arrivalStyle: CastArrivalStyle?
    public var userAction: String?
    public var userText: String?
    public var permissionDomain: String?
    public var permissionAvailable: Bool?

    public init(
        kind: GameEventKind,
        entity: EntityState? = nil,
        slot: InteractionSlot? = nil,
        request: BehaviorRequest? = nil,
        behaviorID: String? = nil,
        actorID: EntityID? = nil,
        entityID: EntityID? = nil,
        slotRef: SlotRef? = nil,
        success: Bool? = nil,
        observationID: String? = nil,
        inputObservation: InputObservation? = nil,
        inputPreemptive: Bool = false,
        inputPriority: PriorityBand? = nil,
        castMemberID: String? = nil,
        sourceActorID: EntityID? = nil,
        arrivalStyle: CastArrivalStyle? = nil,
        userAction: String? = nil,
        userText: String? = nil,
        permissionDomain: String? = nil,
        permissionAvailable: Bool? = nil
    ) {
        self.kind = kind
        self.entity = entity
        self.slot = slot
        self.request = request
        self.behaviorID = behaviorID
        self.actorID = actorID
        self.entityID = entityID
        self.slotRef = slotRef
        self.success = success
        self.observationID = observationID
        self.inputObservation = inputObservation
        self.inputPreemptive = inputPreemptive
        self.inputPriority = inputPriority
        self.castMemberID = castMemberID
        self.sourceActorID = sourceActorID
        self.arrivalStyle = arrivalStyle
        self.userAction = userAction
        self.userText = userText
        self.permissionDomain = permissionDomain
        self.permissionAvailable = permissionAvailable
    }

    public var traceDetail: String {
        switch kind {
        case .castInvite:
            return "\(kind.rawValue):\(castMemberID ?? "-"):from=\(sourceActorID?.raw ?? "-")"
        case .castArrive:
            return "\(kind.rawValue):\(castMemberID ?? entity?.id.raw ?? "-"):style=\(arrivalStyle?.rawValue ?? "walk")"
        case .castDepart:
            return "\(kind.rawValue):\(castMemberID ?? entityID?.raw ?? "-")"
        case .windowChanged:
            return "\(kind.rawValue):\(entityID?.raw ?? entity?.id.raw ?? "-")"
        case .userInteraction:
            return "\(kind.rawValue):\(userAction ?? "-"):actor=\(actorID?.raw ?? "-"):text=\(userText ?? "")"
        case .permissionChanged:
            return "\(kind.rawValue):\(permissionDomain ?? "-"):\(permissionAvailable == true ? "granted" : "denied")"
        case .contentObservation:
            guard let observation = inputObservation else { return kind.rawValue }
            return "\(kind.rawValue):\(observation.pluginID):\(observation.channel.rawValue):app=\(observation.appName):window=\(observation.windowTitle):text=\(observation.text):preempt=\(inputPreemptive == true)"
        case .releaseSlot:
            return "\(kind.rawValue):\(slotRef?.key ?? "-"):scope=\(behaviorID ?? actorID?.raw ?? "all")"
        default:
            return kind.rawValue
        }
    }

}

public struct ScheduledEvent: Codable, Sendable, Equatable {
    public var atTick: Int64
    public var sequence: Int64
    public var event: GameEvent

    public init(atTick: Int64, sequence: Int64 = 0, event: GameEvent) {
        self.atTick = atTick
        self.sequence = sequence
        self.event = event
    }
}

public struct SimClock: Codable, Sendable, Equatable {
    public private(set) var tick: Int64
    public let stepMilliseconds: Int64

    public init(stepMilliseconds: Int64 = 50) {
        self.tick = 0
        self.stepMilliseconds = max(1, stepMilliseconds)
    }

    public mutating func advance() {
        tick += 1
    }

    public func seconds(forTicks count: Int64) -> Double {
        Double(max(0, count)) * Double(stepMilliseconds) / 1_000
    }
}

/// Samples a display timer without making its refresh rate the game clock.
/// ponytail: cap catch-up at 250 ms so a stalled main run loop cannot freeze
/// AppKit while replaying seconds of overdue ticks; missed real time is a pause.
public struct FixedStepClock {
    private let stepSeconds: Double
    private var remainder = 0.0

    public init(stepMilliseconds: Int64) {
        stepSeconds = Double(max(1, stepMilliseconds)) / 1_000
    }

    public mutating func advance(elapsedSeconds: Double) -> Int {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return 0 }
        remainder += min(elapsedSeconds, 0.25)
        let steps = Int((remainder + 1e-9) / stepSeconds)
        remainder -= Double(steps) * stepSeconds
        return steps
    }
}
