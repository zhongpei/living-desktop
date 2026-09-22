import Foundation
import MyPetCore

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
    private var nextExecutionToken: Int64 = 0

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
                    executionToken: nextExecutionToken,
                    actorID: behavior.request.actorID,
                    intent: behavior.request.intent,
                    target: behavior.request.target,
                    slot: behavior.request.slot,
                    durationTicks: behavior.request.durationTicks,
                    planEpoch: behavior.request.planEpoch)
                nextExecutionToken += 1
                active[id] = Active(
                    command: command,
                    // The command becomes observable only after this tick.
                    // Preserve authored multi-tick timing, but never finish
                    // a one-tick body before an external adapter could reply.
                    completesAtTick: behavior.startedAtTick
                        + max(1, behavior.request.durationTicks - 1))
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
            .map { BodyResult(
                behaviorID: $0.command.behaviorID,
                executionToken: $0.command.executionToken,
                outcome: .completed) }
    }

    func event(for result: BodyResult) -> GameEvent? {
        guard let command = active[result.behaviorID]?.command,
              command.executionToken == result.executionToken else {
            return nil
        }
        switch result.outcome {
        case .completed:
            return GameEvent(
                kind: .completeBehavior, behaviorID: result.behaviorID, success: true,
                propCommand: propCommand(for: command))
        case .failed:
            return GameEvent(kind: .completeBehavior, behaviorID: result.behaviorID, success: false)
        case .cancelled:
            return GameEvent(kind: .cancelBehavior, behaviorID: result.behaviorID)
        }
    }

    private func propCommand(for body: BodyCommand) -> PropCommand? {
        let pose = poses[body.actorID.raw]
        switch body.intent {
        case let intent where intent.hasPrefix("spawn_prop:"):
            return PropCommand(.spawnHeld, propID: String(intent.dropFirst("spawn_prop:".count)))
        case "clear_props": return PropCommand(.clear)
        case "put_down":
            let side = pose?.facingRight == false ? -1.0 : 1.0
            return PropCommand(
                .putDown,
                x: (pose?.x ?? 0) + side * (pose?.displayHeight ?? 110) * 0.30,
                y: pose?.yFeet ?? 0)
        case "pick_up":
            return PropCommand(.pickUp, x: pose?.x ?? 0, y: pose?.yFeet ?? 0, within: 90)
        case "leave_scene": return PropCommand(.despawn)
        default: return nil
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

    func checkpoint() -> BodyRuntimeSnapshot {
        BodyRuntimeSnapshot(
            mode: mode,
            nextExecutionToken: nextExecutionToken,
            active: active.mapValues {
                BodyRuntimeSnapshot.ActiveCommand(
                    command: $0.command, completesAtTick: $0.completesAtTick)
            },
            commands: commands,
            effects: effects,
            poses: poses)
    }

    func restore(_ snapshot: BodyRuntimeSnapshot) {
        precondition(snapshot.mode == mode, "body execution mode must match checkpoint")
        nextExecutionToken = max(
            snapshot.nextExecutionToken,
            (snapshot.active.values.map(\.command.executionToken).max() ?? -1) + 1)
        var restored: [String: Active] = [:]
        for id in snapshot.active.keys.sorted() {
            guard let item = snapshot.active[id] else { continue }
            var command = item.command
            command.executionToken = nextExecutionToken
            nextExecutionToken += 1
            restored[id] = Active(command: command, completesAtTick: item.completesAtTick)
        }
        active = restored
        // An external adapter is not part of the Core checkpoint. Reissue all
        // active commands with fresh tokens; any callback from before restore
        // is rejected by `event(for:)`.
        commands = mode == .external
            ? restored.values.map(\.command).sorted { $0.behaviorID < $1.behaviorID }
            : []
        effects = snapshot.effects
        poses = snapshot.poses
    }
}
