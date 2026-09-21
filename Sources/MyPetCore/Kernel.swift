import Foundation

public struct InvariantViolation: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let tick: Int64

    public init(code: String, message: String, tick: Int64) {
        self.code = code
        self.message = message
        self.tick = tick
    }
}

public enum InvariantChecker {
    public static func check(
        _ world: WorldState,
        tick: Int64,
        runningBehaviorIDs: Set<String>? = nil
    ) -> [InvariantViolation] {
        var violations: [InvariantViolation] = []
        var attachmentParents: [EntityID: EntityID] = [:]

        for key in world.slots.keys.sorted() {
            guard let slot = world.slots[key] else { continue }
            if slot.capacity < 1 {
                violations.append(InvariantViolation(code: "slot_capacity_invalid", message: key, tick: tick))
            }
            if slot.occupants.count > slot.capacity {
                violations.append(InvariantViolation(code: "slot_over_capacity", message: key, tick: tick))
            }
            if slot.status == .free, !slot.occupants.isEmpty {
                violations.append(InvariantViolation(code: "free_slot_has_claim", message: key, tick: tick))
            }
            if slot.status == .disabled, !slot.occupants.isEmpty {
                violations.append(InvariantViolation(code: "disabled_slot_has_claim", message: key, tick: tick))
            }
            if slot.status == .occupied, slot.occupants.contains(where: { $0.status != .occupied }) {
                violations.append(InvariantViolation(code: "occupied_slot_has_pending_claim", message: key, tick: tick))
            }
            if Set(slot.occupants.map(\.claimID)).count != slot.occupants.count {
                violations.append(InvariantViolation(code: "duplicate_slot_claim", message: key, tick: tick))
            }
            if Set(slot.occupants.map(\.actorID)).count != slot.occupants.count {
                violations.append(InvariantViolation(code: "duplicate_slot_actor", message: key, tick: tick))
            }
            // A departed window/mech keeps its disabled slot as a stable
            // definition for a later re-entry. Only a non-disabled slot on a
            // dead host is a live-slot invariant violation.
            if !world.isAlive(slot.entityID), slot.status != .disabled {
                violations.append(InvariantViolation(code: "destroyed_window_has_live_slot", message: key, tick: tick))
            }
        }

        for key in world.spatialAttachments.keys.sorted() {
            guard let attachment = world.spatialAttachments[key] else { continue }
            attachmentParents[attachment.childID] = attachment.parentID
            if key != attachment.childID.raw {
                violations.append(InvariantViolation(
                    code: "spatial_attachment_key_mismatch", message: key, tick: tick))
            }
            guard world.isAlive(attachment.childID), world.isAlive(attachment.parentID) else {
                violations.append(InvariantViolation(
                    code: "spatial_attachment_dangling_entity", message: key, tick: tick))
                continue
            }
            guard let slot = world.slots[attachment.slotRef.key], slot.status == .occupied else {
                violations.append(InvariantViolation(
                    code: "spatial_attachment_without_occupied_slot", message: key, tick: tick))
                continue
            }
            guard attachment.socketID == slot.slotID else {
                violations.append(InvariantViolation(
                    code: "spatial_attachment_socket_mismatch", message: key, tick: tick))
                continue
            }
            let hostKind = world.entity(slot.entityID)?.kind
            let matchesOccupant = slot.occupants.contains { occupant in
                guard occupant.status == .occupied else { return false }
                if hostKind == .prop {
                    return attachment.childID == slot.entityID && attachment.parentID == occupant.actorID
                }
                return attachment.childID == occupant.actorID && attachment.parentID == slot.entityID
            }
            if !matchesOccupant {
                violations.append(InvariantViolation(
                    code: "spatial_attachment_occupant_mismatch", message: key, tick: tick))
            }
        }

        // Projection has a recursion guard, but a cycle is still invalid
        // world state. Report it at the invariant boundary instead of letting
        // a malformed snapshot silently fall back to base frames.
        var reportedCycles = Set<String>()
        for start in attachmentParents.keys.sorted(by: { $0.raw < $1.raw }) {
            var path: [EntityID] = []
            var current = start
            while let parent = attachmentParents[current] {
                if let cycleStart = path.firstIndex(of: current) {
                    let cycle = path[cycleStart...]
                        .map(\.raw)
                        .sorted()
                        .joined(separator: "->")
                    if reportedCycles.insert(cycle).inserted {
                        violations.append(InvariantViolation(
                            code: "spatial_attachment_cycle",
                            message: cycle,
                            tick: tick))
                    }
                    break
                }
                path.append(current)
                current = parent
            }
        }

        var claims: [String: String] = [:]
        let behaviorKeys = runningBehaviorIDs?.sorted() ?? world.behaviors.keys.sorted()
        for key in behaviorKeys {
            guard let behavior = world.behaviors[key], behavior.status == .running else { continue }
            guard world.isAlive(behavior.request.actorID) else {
                violations.append(InvariantViolation(code: "dangling_behavior_actor", message: key, tick: tick))
                continue
            }
            for claim in Set(behavior.request.claims) {
                if let previous = claims["\(behavior.request.actorID.raw)/\(claim)"], previous != key {
                    violations.append(InvariantViolation(code: "actor_body_claim_conflict", message: "\(previous),\(key)", tick: tick))
                } else {
                    claims["\(behavior.request.actorID.raw)/\(claim)"] = key
                }
            }
        }

        for key in world.relationValues.keys.sorted() {
            guard let value = world.relationValues[key], (0...1).contains(value) else {
                violations.append(InvariantViolation(code: "relationship_value_out_of_range", message: key, tick: tick))
                continue
            }
        }

        return violations
    }

    public static func checkTerminal(_ world: WorldState, tick: Int64) -> [InvariantViolation] {
        var violations = check(world, tick: tick)
        for key in world.slots.keys.sorted() {
            if let slot = world.slots[key], slot.status == .claimed {
                violations.append(InvariantViolation(code: "claim_not_released", message: key, tick: tick))
            }
        }
        return violations
    }
}

public struct TraceEntry: Codable, Equatable, Sendable {
    public let tick: Int64
    public let kind: String
    public let detail: String
    public let worldDigest: String

    public init(tick: Int64, kind: String, detail: String, worldDigest: String) {
        self.tick = tick
        self.kind = kind
        self.detail = detail
        self.worldDigest = worldDigest
    }
}

public struct TickReport: Codable, Equatable, Sendable {
    public let tick: Int64
    public let appliedEvents: Int
    public let violations: [InvariantViolation]
    public let worldDigest: String

    public init(tick: Int64, appliedEvents: Int, violations: [InvariantViolation], worldDigest: String) {
        self.tick = tick
        self.appliedEvents = appliedEvents
        self.violations = violations
        self.worldDigest = worldDigest
    }
}

public final class EventInbox {
    private var events: [ScheduledEvent] = []
    private var nextSequence: Int64 = 0

    public init() {}

    public init(events: [ScheduledEvent], nextSequence: Int64) {
        self.events = events
        self.nextSequence = nextSequence
    }

    public func enqueue(_ event: GameEvent, atTick: Int64) {
        events.append(ScheduledEvent(atTick: atTick, sequence: nextSequence, event: event))
        nextSequence += 1
    }

    public func drain(atTick: Int64) -> [ScheduledEvent] {
        let ready = events
            .filter { $0.atTick <= atTick }
            .sorted { lhs, rhs in
                lhs.atTick == rhs.atTick ? lhs.sequence < rhs.sequence : lhs.atTick < rhs.atTick
            }
        let readyIDs = Set(ready.map { $0.sequence })
        events.removeAll { readyIDs.contains($0.sequence) }
        return ready
    }

    public var count: Int { events.count }

    public var pendingEvents: [ScheduledEvent] { events }
    public var sequence: Int64 { nextSequence }
}

public struct KernelSnapshot: Codable, Equatable, Sendable {
    public var clock: SimClock
    public var world: WorldState
    public var pendingEvents: [ScheduledEvent]
    public var nextSequence: Int64
    public var trace: [TraceEntry]
    public var manualViolations: [InvariantViolation]

    public init(
        clock: SimClock,
        world: WorldState,
        pendingEvents: [ScheduledEvent],
        nextSequence: Int64,
        trace: [TraceEntry],
        manualViolations: [InvariantViolation]
    ) {
        self.clock = clock
        self.world = world
        self.pendingEvents = pendingEvents
        self.nextSequence = nextSequence
        self.trace = trace
        self.manualViolations = manualViolations
    }
}

public final class GameKernel {
    public private(set) var clock: SimClock
    public private(set) var world: WorldState
    public let inbox: EventInbox
    /// StoryDirector supplies this policy; direct user actions remain P0.
    public var storyInterruptionPolicy: StoryInterruptionPolicy
    public private(set) var trace: [TraceEntry] = []
    public private(set) var manualViolations: [InvariantViolation] = []
    // Terminal behavior states remain in WorldState for replay/training. This
    // derived index keeps the simulation hot path proportional to live work.
    private var activeBehaviorIDs: Set<String> = []

    public init(
        seed: UInt64 = 0,
        stepMilliseconds: Int64 = 50,
        storyInterruptionPolicy: StoryInterruptionPolicy = StoryInterruptionPolicy()
    ) {
        _ = seed
        self.clock = SimClock(stepMilliseconds: stepMilliseconds)
        self.world = WorldState()
        self.inbox = EventInbox()
        self.storyInterruptionPolicy = storyInterruptionPolicy
    }

    public convenience init(scenario: HarnessScenario) {
        self.init(seed: scenario.seed, stepMilliseconds: scenario.stepMilliseconds)
        for entity in scenario.entities {
            world.entities[entity.id.raw] = entity
            world.planEpochs[entity.id.raw] = 0
        }
        // VirtualDesktop windows occupy the environment side of the seam. A
        // scenario may still provide explicit EntityState/slots when it needs
        // a non-default layout; otherwise the kernel receives ordinary window
        // entities and two stable perch slot definitions.
        for window in scenario.desktop.windows.values.sorted(by: { $0.id.raw < $1.id.raw }) {
            if world.entities[window.id.raw] == nil {
                let entity = EntityState(
                    id: window.id, kind: .window,
                    revision: window.revision, alive: window.alive)
                world.entities[window.id.raw] = entity
                world.planEpochs[window.id.raw] = 0
            }
        }
        for slot in scenario.slots {
            world.slots[slot.key] = slot
        }
        for window in scenario.desktop.windows.values where window.alive {
            for slotID in ["top.left", "top.right"] {
                let key = "\(window.id.raw)/\(slotID)"
                if world.slots[key] == nil {
                    world.slots[key] = InteractionSlot(entityID: window.id, slotID: slotID)
                }
            }
        }
        for scheduled in scenario.events {
            inbox.enqueue(scheduled.event, atTick: scheduled.atTick)
        }
    }

    public init(snapshot: KernelSnapshot) {
        clock = snapshot.clock
        world = snapshot.world
        inbox = EventInbox(events: snapshot.pendingEvents, nextSequence: snapshot.nextSequence)
        storyInterruptionPolicy = StoryInterruptionPolicy()
        trace = snapshot.trace
        manualViolations = snapshot.manualViolations
        activeBehaviorIDs = Set(snapshot.world.behaviors.compactMap { key, value in
            value.status == .running ? key : nil
        })
    }

    /// Running behavior state is the only behavior view used by scheduling
    /// modules. Terminal history is still available through `world.behaviors`.
    public var runningBehaviorStates: [BehaviorState] {
        activeBehaviorIDs.sorted().compactMap { world.behaviors[$0] }
    }

    public func snapshot() -> KernelSnapshot {
        KernelSnapshot(
            clock: clock,
            world: world,
            pendingEvents: inbox.pendingEvents,
            nextSequence: inbox.sequence,
            trace: trace,
            manualViolations: manualViolations)
    }

    public func enqueue(_ event: GameEvent, atTick: Int64? = nil) {
        inbox.enqueue(event, atTick: atTick ?? clock.tick)
    }

    /// 在场景安装阶段注入关系初值；运行开始后仍由 GameEvent/成功效果改变。
    public func seedRelations(_ values: [String: Double]) {
        for (key, value) in values {
            world.relationValues[key] = min(1, max(0, value))
        }
    }

    /// 只给剧情/系统编排器使用的声明式效果提交边界；模型和 UI 不能绕过
    /// BehaviorRequest 自己调用它。
    public func commitStoryEffects(_ effects: [SuccessEffect]) {
        guard !effects.isEmpty else { return }
        apply(effects, tick: clock.tick)
        let summary = effects.map(Self.effectTrace).joined(separator: ",")
        record(kind: "story-effect", detail: summary)
    }

    @discardableResult
    public func tick(afterEvents: (() -> Void)? = nil) -> TickReport {
        let currentTick = clock.tick
        let manualViolationStart = manualViolations.count
        let events = inbox.drain(atTick: currentTick)
        for scheduled in events {
            apply(scheduled.event, tick: currentTick)
            record(kind: "event", detail: scheduled.event.traceDetail)
        }
        afterEvents?()
        let lateEvents = inbox.drain(atTick: currentTick)
        for scheduled in lateEvents {
            apply(scheduled.event, tick: currentTick)
            record(kind: "event", detail: scheduled.event.traceDetail)
        }
        let appliedEventCount = events.count + lateEvents.count
        advanceBehaviors(tick: currentTick)
        expireFacts(tick: currentTick)
        expireInputObservations(tick: currentTick)
        let eventViolations = Array(manualViolations.dropFirst(manualViolationStart))
        // 不把 invariant 结果再写回历史：同一个持续状态每个 tick 只在当 tick
        // 报告一次，避免长跑日志重复膨胀，同时 terminalViolations 仍会做最终检查。
        let violations = eventViolations + InvariantChecker.check(
            world, tick: currentTick, runningBehaviorIDs: activeBehaviorIDs)
        let report = TickReport(
            tick: currentTick,
            appliedEvents: appliedEventCount,
            violations: violations,
            worldDigest: world.stableDigest(runningBehaviorIDs: activeBehaviorIDs)
        )
        record(kind: "tick", detail: "events=\(appliedEventCount)")
        clock.advance()
        return report
    }

    @discardableResult
    public func run(ticks: Int64) -> [TickReport] {
        guard ticks > 0 else { return [] }
        return (0..<ticks).map { _ in tick() }
    }

    public func terminalViolations() -> [InvariantViolation] {
        manualViolations + InvariantChecker.checkTerminal(world, tick: clock.tick)
    }

    public func traceJSONL() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for entry in trace {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        return data
    }

    private func apply(_ event: GameEvent, tick: Int64) {
        switch event.kind {
        case .registerEntity:
            guard let entity = event.entity else { return }
            guard world.entities[entity.id.raw] == nil else {
                manualViolations.append(InvariantViolation(code: "entity_id_unique", message: entity.id.raw, tick: tick))
                return
            }
            world.entities[entity.id.raw] = entity
            world.planEpochs[entity.id.raw] = 0
        case .windowChanged:
            guard let id = event.entityID ?? event.entity?.id else { return }
            let incoming = event.entity ?? world.entities[id.raw] ?? EntityState(id: id, kind: .window)
            if var current = world.entities[id.raw] {
                current.revision = max(current.revision, incoming.revision)
                current.alive = incoming.alive
                current.kind = incoming.kind
                world.entities[id.raw] = current
            } else {
                world.entities[id.raw] = incoming
            }
            world.planEpochs[id.raw, default: 0] += 1
            // A moved/resized window changes every derived slot reference. The
            // slot remains a definition, but in-flight plans must not use the
            // old geometry revision.
            for key in world.slots.keys where world.slots[key]?.entityID == id {
                world.slots[key]?.revision += 1
            }
            let affected = activeBehaviorIDs.sorted().compactMap { behaviorID -> String? in
                    guard let behavior = world.behaviors[behaviorID] else { return nil }
                    guard behavior.status == .running else { return nil }
                    return behavior.request.target?.entityID == id || behavior.request.slot?.entityID == id
                        ? behaviorID : nil
                }
            for behaviorID in affected {
                cancelBehavior(behaviorID, tick: tick, reason: "window_changed")
            }
        case .destroyEntity:
            guard let id = event.entityID else { return }
            deactivateEntity(id, tick: tick, reason: "destroyed")
        case .createSlot:
            guard let slot = event.slot else { return }
            guard world.isAlive(slot.entityID) else {
                manualViolations.append(InvariantViolation(code: "slot_entity_missing", message: slot.key, tick: tick))
                return
            }
            world.slots[slot.key] = slot
        case .disableSlot:
            guard let ref = event.slotRef, var slot = world.slots[ref.key] else { return }
            guard slot.revision == ref.revision else { return }
            removeSpatialAttachments(for: slot)
            slot.status = .disabled
            slot.clearClaims()
            world.slots[ref.key] = slot
        case .behaviorRequest:
            guard let request = event.request else { return }
            start(request, tick: tick)
        case .completeBehavior:
            guard let id = event.behaviorID else { return }
            finishBehavior(id, success: event.success ?? true, tick: tick)
        case .cancelBehavior:
            guard let id = event.behaviorID else { return }
            cancelBehavior(id, tick: tick, reason: "cancelled")
        case .releaseSlot:
            guard let ref = event.slotRef, var slot = world.slots[ref.key] else { return }
            guard slot.revision == ref.revision else { return }
            if slot.status != .disabled {
                let removed: [SlotOccupant]
                if let behaviorID = event.behaviorID {
                    removed = slot.occupants.filter { $0.claimID == behaviorID }
                    slot.removeClaim(behaviorID)
                } else if let actorID = event.actorID {
                    removed = slot.occupants.filter { $0.actorID == actorID }
                    slot.removeActor(actorID)
                } else {
                    removed = slot.occupants
                    slot.clearClaims()
                }
                removeSpatialAttachments(for: slot, occupants: removed)
            }
            world.slots[ref.key] = slot
        case .foregroundChanged:
            if let actorID = event.actorID {
                world.planEpochs[actorID.raw, default: 0] += 1
            } else {
                for id in world.planEpochs.keys { world.planEpochs[id, default: 0] += 1 }
            }
            // 前台切换是 P1 抢占：旧的本地脑、环境和剧情行为都必须让位，
            // 但不影响更高优先级的用户直接操作。
            let running = activeBehaviorIDs.sorted().compactMap { behaviorID -> String? in
                guard let behavior = world.behaviors[behaviorID],
                      behavior.status == .running,
                      behavior.request.priority > .urgentReactive else { return nil }
                return storyInterruptionPolicy.foreground || behavior.request.priority != .story
                    ? behaviorID : nil
            }
            for behaviorID in running {
                cancelBehavior(behaviorID, tick: tick, reason: "foreground_preempted")
            }
        case .userInteraction:
            if let actorID = event.actorID {
                world.planEpochs[actorID.raw, default: 0] += 1
            } else {
                for id in world.planEpochs.keys { world.planEpochs[id, default: 0] += 1 }
            }
            let running = activeBehaviorIDs.sorted().compactMap { behaviorID -> String? in
                guard let behavior = world.behaviors[behaviorID],
                      behavior.status == .running,
                      behavior.request.priority > .userDirect else { return nil }
                return event.actorID == nil || behavior.request.actorID == event.actorID
                    ? behaviorID : nil
            }
            for behaviorID in running {
                cancelBehavior(behaviorID, tick: tick, reason: "user_interaction")
            }
        case .permissionChanged:
            // Permission state belongs to the VirtualDesktop seam. The kernel
            // records the event so replay explains a sensor fallback, but it
            // never pretends this is a real macOS permission result.
            break
        case .contentObservation:
            guard let observation = event.inputObservation else { return }
            world.inputObservations[observation.id] = observation
            guard event.inputPreemptive == true else { return }
            // 内容变化只让旧计划失效；是否反应仍由本地决策脑决定。
            for id in world.planEpochs.keys {
                world.planEpochs[id, default: 0] += 1
            }
            let threshold = event.inputPriority ?? .urgentReactive
            let running = activeBehaviorIDs.sorted().compactMap { behaviorID -> String? in
                guard let behavior = world.behaviors[behaviorID],
                      behavior.status == .running,
                      behavior.request.priority > threshold else { return nil }
                return storyInterruptionPolicy.content || behavior.request.priority != .story
                    ? behaviorID : nil
            }
            for behaviorID in running {
                cancelBehavior(behaviorID, tick: tick, reason: "input_preempted")
            }
        case .castInvite:
            // CastDirector schedules the arrival as a separate deterministic event.
            // The invite itself remains in the trace so replay can explain why a guest appeared.
            guard let memberID = event.castMemberID else { return }
            world.facts["cast/invite/\(memberID)"] = StoryFact(value: memberID, createdAtTick: tick, expiresAtTick: tick + 20)
        case .castArrive:
            guard let entity = event.entity else { return }
            if var existing = world.entities[entity.id.raw] {
                guard !existing.alive else {
                    manualViolations.append(InvariantViolation(code: "cast_duplicate_arrival", message: entity.id.raw, tick: tick))
                    return
                }
                existing.alive = true
                existing.kind = entity.kind
                existing.revision += 1
                world.entities[entity.id.raw] = existing
                world.planEpochs[entity.id.raw, default: 0] += 1
            } else {
                world.entities[entity.id.raw] = entity
                world.planEpochs[entity.id.raw] = 0
            }
        case .castDepart:
            guard let id = event.entityID ?? event.entity?.id else { return }
            deactivateEntity(id, tick: tick, reason: "cast_depart")
        }
    }

    private func deactivateEntity(_ id: EntityID, tick: Int64, reason: String) {
        guard var entity = world.entities[id.raw], entity.alive else { return }
        entity.alive = false
        entity.revision += 1
        world.entities[id.raw] = entity
        world.planEpochs[id.raw, default: 0] += 1
        for key in world.slots.keys where world.slots[key]?.entityID == id {
            if let slot = world.slots[key] { removeSpatialAttachments(for: slot) }
            world.slots[key]?.status = .disabled
            world.slots[key]?.clearClaims()
        }
        for key in world.slots.keys where world.slots[key]?.entityID != id {
            if let slot = world.slots[key] {
                removeSpatialAttachments(
                    for: slot,
                    occupants: slot.occupants.filter { $0.actorID == id })
            }
            world.slots[key]?.removeActor(id)
        }
        removeSpatialAttachments(forEntity: id)
        for key in activeBehaviorIDs.sorted() {
            guard let behavior = world.behaviors[key], behavior.status == .running else { continue }
            if behavior.request.actorID == id || behavior.request.target?.entityID == id {
                cancelBehavior(key, tick: tick, reason: reason)
            }
        }
    }

    private func start(_ request: BehaviorRequest, tick: Int64) {
        guard world.isAlive(request.actorID) else {
            reject(request, tick: tick, reason: "actor_missing")
            return
        }
        guard world.planEpochs[request.actorID.raw, default: 0] == request.planEpoch else {
            reject(request, tick: tick, reason: "stale_plan")
            return
        }
        if let target = request.target,
           world.entities[target.entityID.raw]?.revision != target.revision || !world.isAlive(target.entityID) {
            reject(request, tick: tick, reason: "stale_target")
            return
        }
        if world.behaviors[request.id] != nil {
            reject(request, tick: tick, reason: "duplicate_behavior")
            return
        }
        var active = runningBehaviorStates.filter { $0.request.actorID == request.actorID }
        for current in active.sorted(by: { $0.request.id < $1.request.id }) {
            if request.priority < current.request.priority {
                cancelBehavior(current.request.id, tick: tick, reason: "preempted")
            } else {
                reject(request, tick: tick, reason: "claim_conflict")
                return
            }
        }
        active = runningBehaviorStates.filter { $0.request.actorID == request.actorID }
        let requestedClaims = Set(request.claims)
        if active.contains(where: { !requestedClaims.isDisjoint(with: Set($0.request.claims)) }) {
            reject(request, tick: tick, reason: "claim_conflict")
            return
        }
        if let ref = request.slot {
            guard var slot = world.slots[ref.key], slot.revision == ref.revision else {
                reject(request, tick: tick, reason: "stale_slot")
                return
            }
            guard slot.status != .disabled, !slot.isFull else {
                reject(request, tick: tick, reason: "slot_occupied")
                return
            }
            guard !slot.contains(actorID: request.actorID) else {
                reject(request, tick: tick, reason: "slot_actor_duplicate")
                return
            }
            slot.addClaim(request.id, actorID: request.actorID)
            world.slots[ref.key] = slot
        }
        world.behaviors[request.id] = BehaviorState(request: request, startedAtTick: tick)
        activeBehaviorIDs.insert(request.id)
    }

    private func advanceBehaviors(tick: Int64) {
        let running = activeBehaviorIDs.sorted()
        for id in running {
            guard var behavior = world.behaviors[id], behavior.status == .running else { continue }
            behavior.remainingTicks -= 1
            world.behaviors[id] = behavior
            if behavior.remainingTicks <= 0 {
                finishBehavior(id, success: true, tick: tick)
            }
        }
    }

    private func finishBehavior(_ id: String, success: Bool, tick: Int64) {
        guard var behavior = world.behaviors[id], behavior.status == .running else { return }
        behavior.status = success ? .completed : .cancelled
        behavior.endedAtTick = tick
        world.behaviors[id] = behavior
        activeBehaviorIDs.remove(id)
        guard let slotRef = behavior.request.slot, var slot = world.slots[slotRef.key], slot.contains(claimID: id) else {
            if success { apply(behavior.request.effectsOnSuccess, tick: tick) }
            return
        }
        slot.finishClaim(id, occupy: success && behavior.request.occupySlotOnSuccess)
        world.slots[slot.key] = slot
        if success,
           behavior.request.occupySlotOnSuccess,
           let occupant = slot.occupants.first(where: { $0.claimID == id && $0.status == .occupied }) {
            installSpatialAttachment(for: slot, occupant: occupant)
        }
        if success { apply(behavior.request.effectsOnSuccess, tick: tick) }
    }

    private func cancelBehavior(_ id: String, tick: Int64, reason: String) {
        guard var behavior = world.behaviors[id], behavior.status == .running else { return }
        behavior.status = .cancelled
        behavior.endedAtTick = tick
        world.behaviors[id] = behavior
        activeBehaviorIDs.remove(id)
        if let ref = behavior.request.slot, var slot = world.slots[ref.key], slot.contains(claimID: id) {
            slot.removeClaim(id)
            world.slots[ref.key] = slot
        }
        record(kind: "cancel", detail: "\(id):\(reason)")
    }

    private func reject(_ request: BehaviorRequest, tick: Int64, reason: String) {
        var state = BehaviorState(request: request, startedAtTick: tick)
        state.status = .rejected
        state.endedAtTick = tick
        world.behaviors[request.id] = state
        record(kind: "reject", detail: "\(request.id):\(reason)")
    }

    private func apply(_ effects: [SuccessEffect], tick: Int64) {
        for effect in effects {
            switch effect.kind {
            case .relationDelta:
                guard let key = effect.relationKey, let delta = effect.delta else { continue }
                let current = world.relationValues[key, default: 0]
                world.relationValues[key] = min(1, max(0, current + delta))
            case .setFact:
                guard let fact = effect.fact else { continue }
                let expiration = effect.factTTL.map { tick + max(0, $0) }
                world.facts[fact] = StoryFact(value: fact, createdAtTick: tick, expiresAtTick: expiration)
            }
        }
    }

    private static func effectTrace(_ effect: SuccessEffect) -> String {
        switch effect.kind {
        case .relationDelta:
            return "relation:\(effect.relationKey ?? "-"):+\(effect.delta ?? 0)"
        case .setFact:
            return "fact:\(effect.fact ?? "-"):ttl=\(effect.factTTL.map(String.init) ?? "-")"
        }
    }

    private func expireFacts(tick: Int64) {
        world.facts = world.facts.filter { $0.value.isValid(at: tick) }
    }

    private func expireInputObservations(tick: Int64) {
        world.inputObservations = world.inputObservations.filter { $0.value.isValid(at: tick) }
    }

    private func attachmentParticipants(
        for slot: InteractionSlot,
        occupant: SlotOccupant
    ) -> (childID: EntityID, parentID: EntityID)? {
        guard let host = world.entity(slot.entityID) else { return nil }
        if host.kind == .prop {
            return (slot.entityID, occupant.actorID)
        }
        return (occupant.actorID, slot.entityID)
    }

    private func installSpatialAttachment(for slot: InteractionSlot, occupant: SlotOccupant) {
        guard let participants = attachmentParticipants(for: slot, occupant: occupant),
              world.isAlive(participants.childID),
              world.isAlive(participants.parentID) else { return }
        world.spatialAttachments[participants.childID.raw] = SpatialAttachment(
            childID: participants.childID,
            parentID: participants.parentID,
            socketID: slot.slotID,
            slotRef: slot.ref)
    }

    private func removeSpatialAttachments(
        for slot: InteractionSlot,
        occupants: [SlotOccupant]? = nil
    ) {
        let candidates = occupants ?? slot.occupants
        for occupant in candidates {
            guard let participants = attachmentParticipants(for: slot, occupant: occupant),
                  let current = world.spatialAttachments[participants.childID.raw],
                  current.slotRef.key == slot.key else { continue }
            world.spatialAttachments.removeValue(forKey: participants.childID.raw)
        }
    }

    private func removeSpatialAttachments(forEntity id: EntityID) {
        world.spatialAttachments = world.spatialAttachments.filter {
            $0.value.childID != id && $0.value.parentID != id
        }
    }

    private func record(kind: String, detail: String) {
        trace.append(TraceEntry(
            tick: clock.tick,
            kind: kind,
            detail: detail,
            worldDigest: world.stableDigest(runningBehaviorIDs: activeBehaviorIDs)))
    }
}
