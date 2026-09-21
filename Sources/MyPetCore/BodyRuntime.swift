import Foundation

public enum BodyExecutionMode: String, Codable, Sendable {
    case headless
    case external
}

public struct BodyCommand: Codable, Equatable, Sendable {
    public var behaviorID: String
    public var actorID: EntityID
    public var intent: String
    public var target: EntityRef?
    public var slot: SlotRef?
    public var durationTicks: Int64
    public var planEpoch: Int64
}

public enum BodyResultOutcome: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

public struct BodyResult: Codable, Equatable, Sendable {
    public var behaviorID: String
    public var outcome: BodyResultOutcome

    public init(behaviorID: String, outcome: BodyResultOutcome) {
        self.behaviorID = behaviorID
        self.outcome = outcome
    }
}

public struct BodyPose: Codable, Equatable, Sendable {
    public var actorID: EntityID
    public var x: Double
    public var yFeet: Double
    public var facingRight: Bool
    public var motion: String
    public var action: String?

    public init(
        actorID: EntityID,
        x: Double,
        yFeet: Double,
        facingRight: Bool,
        motion: String,
        action: String? = nil
    ) {
        self.actorID = actorID
        self.x = x
        self.yFeet = yFeet
        self.facingRight = facingRight
        self.motion = motion
        self.action = action
    }
}

public struct PresentationEntitySnapshot: Codable, Equatable, Sendable {
    public var id: EntityID
    public var kind: EntityKind
    public var alive: Bool
    public var pose: BodyPose?
    public var behaviorID: String?
    public var intent: String?
    public var behaviorStatus: BehaviorStatus?
    public var attachedToID: EntityID?
}

public struct PresentationSnapshot: Codable, Equatable, Sendable {
    public var tick: Int64
    public var entities: [PresentationEntitySnapshot]
    public var attachments: [SpatialAttachment]

    public init(
        tick: Int64,
        entities: [PresentationEntitySnapshot],
        attachments: [SpatialAttachment] = []
    ) {
        self.tick = tick
        self.entities = entities
        self.attachments = attachments
    }
}

public enum PresentationEffectKind: String, Codable, Sendable {
    case behaviorStarted
    case behaviorCompleted
    case behaviorCancelled
}

public struct PresentationEffect: Codable, Equatable, Sendable {
    public var kind: PresentationEffectKind
    public var behaviorID: String
    public var actorID: EntityID
    public var intent: String
}

/// Owns body command/result bookkeeping only. Kernel remains the authority for
/// behavior, claims and attachments; render receives immutable projections.
final class BodyRuntime {
    private struct Active {
        var command: BodyCommand
        var completesAtTick: Int64
    }

    let mode: BodyExecutionMode
    private var active: [String: Active] = [:]
    private var commands: [BodyCommand] = []
    private var effects: [PresentationEffect] = []
    private var poses: [String: BodyPose] = [:]

    init(mode: BodyExecutionMode) {
        self.mode = mode
    }

    func reconcile(world: WorldState, tick: Int64) {
        for behavior in world.behaviors.values.sorted(by: { $0.request.id < $1.request.id })
        where behavior.request.completionMode == .body {
            let id = behavior.request.id
            if behavior.status == .running, active[id] == nil {
                let command = BodyCommand(
                    behaviorID: id,
                    actorID: behavior.request.actorID,
                    intent: behavior.request.intent,
                    target: behavior.request.target,
                    slot: behavior.request.slot,
                    durationTicks: behavior.request.durationTicks,
                    planEpoch: behavior.request.planEpoch)
                active[id] = Active(
                    command: command,
                    completesAtTick: behavior.startedAtTick + behavior.request.durationTicks - 1)
                if mode == .headless { beginHeadless(command) }
                if mode == .external { commands.append(command) }
                appendEffect(PresentationEffect(
                    kind: .behaviorStarted,
                    behaviorID: id,
                    actorID: command.actorID,
                    intent: command.intent))
            } else if behavior.status != .running, let item = active.removeValue(forKey: id) {
                commands.removeAll { $0.behaviorID == id }
                if mode == .headless, behavior.status == .completed {
                    completeHeadless(item.command)
                }
                appendEffect(PresentationEffect(
                    kind: behavior.status == .completed ? .behaviorCompleted : .behaviorCancelled,
                    behaviorID: id,
                    actorID: item.command.actorID,
                    intent: item.command.intent))
            }
        }
    }

    func dueResults(at tick: Int64) -> [BodyResult] {
        guard mode == .headless else { return [] }
        return active.values
            .filter { $0.completesAtTick <= tick }
            .sorted { $0.command.behaviorID < $1.command.behaviorID }
            .map { BodyResult(behaviorID: $0.command.behaviorID, outcome: .completed) }
    }

    func event(for result: BodyResult) -> GameEvent? {
        switch result.outcome {
        case .completed:
            guard active[result.behaviorID] != nil else { return nil }
            return GameEvent(kind: .completeBehavior, behaviorID: result.behaviorID, success: true)
        case .failed:
            guard active[result.behaviorID] != nil else { return nil }
            return GameEvent(kind: .completeBehavior, behaviorID: result.behaviorID, success: false)
        case .cancelled:
            return GameEvent(kind: .cancelBehavior, behaviorID: result.behaviorID)
        }
    }

    func drainCommands(actorID: EntityID? = nil) -> [BodyCommand] {
        guard let actorID else {
            defer { commands.removeAll(keepingCapacity: true) }
            return commands
        }
        let result = commands.filter { $0.actorID == actorID }
        commands.removeAll { $0.actorID == actorID }
        return result
    }

    func takeCommand(behaviorID: String) -> BodyCommand? {
        guard let index = commands.firstIndex(where: { $0.behaviorID == behaviorID }) else { return nil }
        return commands.remove(at: index)
    }

    func update(_ pose: BodyPose) { poses[pose.actorID.raw] = pose }

    func snapshot(world: WorldState, tick: Int64) -> PresentationSnapshot {
        let attachments = world.spatialAttachments.values.sorted { $0.childID.raw < $1.childID.raw }
        let activeByActor = Dictionary(
            world.behaviors.values
                .filter { $0.status == .running }
                .sorted { $0.request.id < $1.request.id }
                .map { ($0.request.actorID.raw, $0) },
            uniquingKeysWith: { first, _ in first })
        let entities = world.entities.values.sorted { $0.id.raw < $1.id.raw }.map { entity in
            let behavior = activeByActor[entity.id.raw]
            return PresentationEntitySnapshot(
                id: entity.id,
                kind: entity.kind,
                alive: entity.alive,
                pose: poses[entity.id.raw],
                behaviorID: behavior?.request.id,
                intent: behavior?.request.intent,
                behaviorStatus: behavior?.status,
                attachedToID: world.spatialAttachments[entity.id.raw]?.parentID)
        }
        return PresentationSnapshot(tick: tick, entities: entities, attachments: attachments)
    }

    func drainEffects() -> [PresentationEffect] {
        defer { effects.removeAll(keepingCapacity: true) }
        return effects
    }

    private func appendEffect(_ effect: PresentationEffect) {
        effects.append(effect)
        if effects.count > 1_024 {
            effects.removeFirst(effects.count - 1_024)
        }
    }

    private func beginHeadless(_ command: BodyCommand) {
        var pose = poses[command.actorID.raw] ?? BodyPose(
            actorID: command.actorID,
            x: 0,
            yFeet: 0,
            facingRight: true,
            motion: "grounded")
        if command.intent.hasPrefix("perform:") {
            pose.action = String(command.intent.dropFirst("perform:".count))
        } else if command.intent == "sleep" {
            pose.motion = "asleep"
        } else if command.intent == "hop" || command.intent == "drop_off" {
            pose.motion = "airborne"
        } else if command.intent.hasPrefix("move_to") || command.intent == "walk_along" {
            pose.motion = "walking"
        }
        poses[command.actorID.raw] = pose
    }

    private func completeHeadless(_ command: BodyCommand) {
        guard var pose = poses[command.actorID.raw] else { return }
        if command.intent.hasPrefix("move_to_point:"),
           let target = Double(command.intent.dropFirst("move_to_point:".count)) {
            pose.facingRight = target >= pose.x
            pose.x = target
        }
        if command.intent.hasPrefix("perform:") { pose.action = nil }
        if command.intent != "sleep" { pose.motion = "grounded" }
        poses[command.actorID.raw] = pose
    }

    func reset() {
        active.removeAll()
        commands.removeAll()
        effects.removeAll()
        poses.removeAll()
    }
}
