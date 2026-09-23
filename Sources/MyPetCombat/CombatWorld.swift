import Foundation
import MyPetCore
import MyPet2D

/// Deterministic combat rules layered over the authoritative MyPet2D BodyWorld.
/// Rendering, AppKit and models consume snapshots and produce inputs; none mutate body state.
public final class CombatWorld {
    private struct PendingHit {
        let attackerID: String
        let defenderID: String
        let move: CombatMoveDefinition
        let definition: CombatHitDefinition
        let ledgerKey: String
        let guarding: Bool
    }

    private struct ActiveAttack {
        let actor: CombatBodyState
        let move: CombatMoveDefinition
        let definition: CombatHitDefinition
        let rects: [CombatRect]
    }

    public static let framesPerSecond = BodyWorld.framesPerSecond

    public private(set) var frame: Int64 = 0
    private let bodyWorld: BodyWorld
    private var rules: [String: CombatRuleState] = [:]
    private var profiles: [String: CombatProfile] = [:]
    private var inputs: [String: FighterInputFrame] = [:]
    private var buffers: [String: CombatInputBuffer] = [:]
    public private(set) var session: CombatSession?

    public init(bodyWorld: BodyWorld = BodyWorld()) {
        self.bodyWorld = bodyWorld
    }

    public init(checkpoint: CombatWorldCheckpoint) {
        self.frame = checkpoint.frame
        self.bodyWorld = BodyWorld(checkpoint: checkpoint.bodyWorld)
        self.rules = checkpoint.rules
        self.profiles = checkpoint.profiles
        self.inputs = checkpoint.inputs
        self.buffers = checkpoint.buffers
        self.session = checkpoint.session
    }

    public func checkpoint() -> CombatWorldCheckpoint {
        CombatWorldCheckpoint(
            frame: frame,
            bodyWorld: bodyWorld.checkpoint(),
            rules: rules,
            profiles: profiles,
            inputs: inputs,
            buffers: buffers,
            session: session)
    }

    @discardableResult
    public func beginSession(id: String, participants: [EntityID]) -> Bool {
        let unique = Array(Set(participants)).sorted { $0.raw < $1.raw }
        guard unique.count >= 2,
              unique.allSatisfy({ rules[$0.raw] != nil }) else { return false }
        if let session, session.state == .active,
           session.id == id, session.participantIDs == unique { return true }
        session = CombatSession(id: id, participants: unique, startedAtFrame: frame)
        return true
    }

    public func endSession(cancelled: Bool = false) {
        guard var active = session, active.state == .active else { return }
        active.state = cancelled ? .cancelled : .completed
        active.endedAtFrame = frame
        session = active
        for id in active.participantIDs {
            inputs[id.raw] = .neutral
            buffers[id.raw] = CombatInputBuffer()
        }
    }

    public func register(actorID: EntityID, profile: CombatProfile = CombatProfile(),
                         x: Double, yFeet: Double, facing: CombatFacing = .right,
                         visualScale: Double = 1) {
        profiles[actorID.raw] = profile
        let definition = BodyDefinition(
            entityID: actorID, pushRadius: profile.pushRadius, visualScale: visualScale)
        if bodyWorld.state(for: actorID) == nil {
            bodyWorld.register(
                definition,
                state: BodyState(
                    entityID: actorID,
                    position: Vec2(x: x, y: yFeet),
                    facing: facing))
        } else {
            bodyWorld.setDefinition(definition)
        }
        rules[actorID.raw] = CombatRuleState(
            actorID: actorID, hp: profile.maxHP, visualScale: visualScale)
        buffers[actorID.raw] = CombatInputBuffer()
        inputs[actorID.raw] = .neutral
    }

    public func unregister(actorID: EntityID) {
        if session?.state == .active,
           session?.participantIDs.contains(actorID) == true {
            endSession(cancelled: true)
        }
        bodyWorld.unregister(actorID)
        rules[actorID.raw] = nil
        profiles[actorID.raw] = nil
        inputs[actorID.raw] = nil
        buffers[actorID.raw] = nil
    }

    public func setProfile(_ profile: CombatProfile, for actorID: EntityID) {
        profiles[actorID.raw] = profile
        guard var rule = rules[actorID.raw] else { return }
        rule.hp = min(max(0, rule.hp), profile.maxHP)
        rules[actorID.raw] = rule
        let scale = rule.visualScale
        bodyWorld.setDefinition(BodyDefinition(
            entityID: actorID, pushRadius: profile.pushRadius,
            visualScale: scale, pushEnabled: rule.healthState == .active))
    }

    public func setInput(_ input: FighterInputFrame, for actorID: EntityID,
                         authority: CombatControlAuthority? = nil) {
        inputs[actorID.raw] = input
        if let authority, var rule = rules[actorID.raw] {
            rule.authority = authority
            rules[actorID.raw] = rule
        }
    }

    public func body(for actorID: EntityID) -> CombatBodyState? {
        guard let body = bodyWorld.state(for: actorID), let rule = rules[actorID.raw] else { return nil }
        return CombatBodyState(body: body, rules: rule)
    }

    public func setAuthority(_ authority: CombatControlAuthority, for actorID: EntityID) {
        guard var rule = rules[actorID.raw] else { return }
        rule.authority = authority
        rules[actorID.raw] = rule
    }

    public func snapshot() -> CombatWorldSnapshot {
        CombatWorldSnapshot(frame: frame, bodies: rules.keys.sorted().compactMap {
            body(for: EntityID($0))
        })
    }

    @discardableResult
    public func step(environment: CombatEnvironment) -> [CombatEvent] {
        var events: [CombatEvent] = []
        let ids = rules.keys.sorted()
        let frameSnapshot = Dictionary(uniqueKeysWithValues: snapshot().bodies.map {
            ($0.actorID.raw, $0)
        })

        for id in ids {
            let actorID = EntityID(id)
            guard var body = body(for: actorID), let profile = profiles[id] else { continue }
            let input = inputs[id] ?? .neutral
            var buffer = buffers[id] ?? CombatInputBuffer()
            buffer.push(input)
            buffers[id] = buffer

            if body.invulnerabilityFrames > 0 { body.invulnerabilityFrames -= 1 }

            if body.hitStopFrames > 0 {
                body.hitStopFrames -= 1
                save(body)
                bodyWorld.setDefinition(BodyDefinition(
                    entityID: actorID,
                    pushRadius: profile.pushRadius,
                    visualScale: body.visualScale,
                    pushEnabled: body.healthState == .active,
                    simulationEnabled: false))
                continue
            }

            advanceHealth(&body, profile: profile, events: &events)
            advanceStun(&body)
            orientTowardNearestOpponent(&body, snapshot: frameSnapshot)
            if body.healthState == .active {
                acceptControl(&body, profile: profile, input: input, buffer: buffer, events: &events)
                advanceMove(&body, profile: profile)
            }
            if body.healthState == .knockedOut && body.locomotion == .grounded {
                body.locomotion = .airborne
            }
            body.body.landingHorizontalVelocityRetention = body.healthState == .knockedOut ? 0.75 : 0
            save(body)
            bodyWorld.setDefinition(BodyDefinition(
                entityID: actorID,
                pushRadius: profile.pushRadius,
                visualScale: body.visualScale,
                pushEnabled: body.healthState == .active,
                simulationEnabled: true))
        }

        bodyWorld.advance(environment)
        resolveHits(events: &events)
        // A KO becomes downed only after its physical knockback has actually landed.
        for id in ids {
            guard var body = body(for: EntityID(id)), let profile = profiles[id] else { continue }
            if body.healthState == .knockedOut && body.locomotion == .grounded {
                body.healthState = .downed
                body.recoveryFramesRemaining = profile.downedRecoveryFrames
                body.phase = .neutral
                events.append(CombatEvent(frame: frame, kind: .downed, actorID: body.actorID))
                save(body)
            }
        }

        frame += 1
        return events
    }

    public func beginDrag(actorID: EntityID, x: Double, y: Double) {
        guard var rule = rules[actorID.raw] else { return }
        rule.phase = .neutral
        rules[actorID.raw] = rule
        bodyWorld.update(actorID) { $0.actionTimeline = nil }
        bodyWorld.beginDrag(entityID: actorID, position: Vec2(x: x, y: y))
    }

    public func drag(actorID: EntityID, x: Double, y: Double, elapsedSeconds: Double) {
        bodyWorld.drag(
            entityID: actorID,
            position: Vec2(x: x, y: y),
            elapsedSeconds: elapsedSeconds)
    }

    public func endDrag(actorID: EntityID, wasClick: Bool) {
        bodyWorld.endDrag(entityID: actorID, wasClick: wasClick)
    }

    private func acceptControl(_ body: inout CombatBodyState, profile: CombatProfile,
                               input: FighterInputFrame, buffer: CombatInputBuffer,
                               events: inout [CombatEvent]) {
        guard body.authority != .scripted else { return }
        guard body.locomotion != .dragged && body.locomotion != .tossed else { return }
        if body.actionTimeline != nil { return }

        if let move = profile.moves.first(where: {
            CombatCommandRecognizer.matches($0.command, buffer: buffer, facing: body.facing)
        }) {
            let instanceID = body.rules.actionSequence ?? 0
            body.rules.actionSequence = instanceID + 1
            body.actionTimeline = ActionTimeline(
                instanceID: instanceID,
                definition: move.actionDefinition)
            body.hitTargets.removeAll()
            body.hitLedger.removeAll()
            body.phase = .startup
            events.append(CombatEvent(frame: frame, kind: .moveStarted,
                                      actorID: body.actorID, moveID: move.id))
            return
        }

        if body.locomotion == .grounded && input.up {
            body.currentSurfaceID = nil
            body.surfaceFraction = nil
            body.locomotion = .airborne
            body.velocity.y = profile.jumpVelocity
        }

        guard body.locomotion == .grounded else { return }
        if input.left != input.right {
            let direction = input.right ? 1.0 : -1.0
            body.velocity.x = direction * profile.walkSpeed
            body.facing = direction > 0 ? .right : .left
        } else {
            body.velocity.x = 0
        }
    }

    private func advanceMove(_ body: inout CombatBodyState, profile: CombatProfile) {
        guard var timeline = body.actionTimeline else {
            if body.stunFrames == 0 { body.phase = .neutral }
            return
        }
        guard timeline.definition.domain == .combat else { return }
        guard profile.move(id: timeline.definition.actionID) != nil else {
            body.actionTimeline = nil
            if body.stunFrames == 0 { body.phase = .neutral }
            return
        }
        switch timeline.phase {
        case .startup: body.phase = .startup
        case .active: body.phase = .active
        case .recovery: body.phase = .recovery
        case .finished, .cancelled:
            body.actionTimeline = nil
            body.hitTargets.removeAll()
            body.hitLedger.removeAll()
            body.phase = .neutral
            return
        }
        // Keep the terminal cursor through hit resolution. A one-frame active
        // action must still own that frame; it is cleared on the next step.
        _ = timeline.advance()
        body.actionTimeline = timeline
    }

    private func advanceStun(_ body: inout CombatBodyState) {
        guard body.stunFrames > 0 else { return }
        body.stunFrames -= 1
        if body.stunFrames == 0 && body.healthState == .active {
            body.phase = .neutral
        }
    }

    private func advanceHealth(_ body: inout CombatBodyState, profile: CombatProfile,
                               events: inout [CombatEvent]) {
        switch body.healthState {
        case .active, .knockedOut:
            break
        case .downed:
            if body.locomotion == .grounded {
                body.velocity.x = 0
                body.velocity.y = 0
                if body.recoveryFramesRemaining > 0 { body.recoveryFramesRemaining -= 1 }
                if body.recoveryFramesRemaining == 0 {
                    body.healthState = .gettingUp
                    body.recoveryFramesRemaining = profile.getUpFrames
                    events.append(CombatEvent(frame: frame, kind: .recoveryStarted, actorID: body.actorID))
                }
            }
        case .gettingUp:
            guard body.locomotion == .grounded else { return }
            if body.recoveryFramesRemaining > 0 { body.recoveryFramesRemaining -= 1 }
            if body.recoveryFramesRemaining == 0 {
                body.healthState = .active
                body.hp = max(1, Int(Double(profile.maxHP) * profile.revivedHPFraction))
                body.invulnerabilityFrames = profile.reviveInvulnerabilityFrames
                body.phase = .neutral
                events.append(CombatEvent(frame: frame, kind: .recovered,
                                          actorID: body.actorID, amount: body.hp))
            }
        }
    }

    private func orientTowardNearestOpponent(
        _ body: inout CombatBodyState,
        snapshot: [String: CombatBodyState]
    ) {
        guard body.authority == .manual || body.authority == .autonomous,
              body.healthState == .active,
              body.currentMoveID == nil,
              body.phase == .neutral,
              body.locomotion == .grounded else { return }
        guard let target = snapshot.values
            .filter({ $0.actorID != body.actorID && $0.healthState == .active })
            .min(by: {
                abs($0.position.x - body.position.x) <
                abs($1.position.x - body.position.x)
            }) else { return }
        if abs(target.position.x - body.position.x) > 0.001 {
            body.facing = target.position.x >= body.position.x ? .right : .left
        }
    }

    private func save(_ body: CombatBodyState) {
        rules[body.actorID.raw] = body.rules
        bodyWorld.update(body.actorID) { $0 = body.body }
    }

    private func resolveHits(events: inout [CombatEvent]) {
        // Detect against one immutable frame snapshot first. Resolution happens only
        // after every legal contact is known, so A<->B trades are independent of
        // actor iteration order.
        let snapshot = Dictionary(uniqueKeysWithValues: self.snapshot().bodies.map {
            ($0.actorID.raw, $0)
        })
        let ids = snapshot.keys.sorted()
        var pending: [PendingHit] = []
        var attacks: [String: ActiveAttack] = [:]

        for attackerID in ids {
            guard let attacker = snapshot[attackerID],
                  attacker.phase == .active,
                  let attackerProfile = profiles[attackerID],
                  let move = attackerProfile.move(id: attacker.currentMoveID) else { continue }
            let definition = move.hit
            let attackRects = definition.attackBoxes.map {
                $0.placed(at: attacker.position, facing: attacker.facing, scale: attacker.visualScale)
            }
            attacks[attackerID] = ActiveAttack(
                actor: attacker, move: move, definition: definition, rects: attackRects)
        }

        var clashedDirections: Set<String> = []
        for (offset, firstID) in ids.enumerated() {
            guard let first = attacks[firstID], first.definition.clashLevel > 0 else { continue }
            for secondID in ids.dropFirst(offset + 1) {
                guard session?.permits(first.actor.actorID, EntityID(secondID)) == true,
                      let second = attacks[secondID],
                      second.definition.clashLevel == first.definition.clashLevel,
                      first.rects.contains(where: { lhs in second.rects.contains(where: lhs.overlaps) })
                else { continue }
                clashedDirections.insert("\(firstID)>\(secondID)")
                clashedDirections.insert("\(secondID)>\(firstID)")
                events.append(CombatEvent(
                    frame: frame, kind: .clash,
                    actorID: first.actor.actorID, targetID: second.actor.actorID,
                    moveID: first.move.id))
            }
        }

        for attackerID in ids {
            guard let attack = attacks[attackerID] else { continue }
            for defenderID in ids where defenderID != attackerID {
                let timelineID = attack.actor.actionTimeline?.instanceID ?? -1
                let ledgerKey = "\(timelineID)|\(attack.definition.hitGroup)|\(defenderID)"
                let lastHitFrame = attack.actor.hitLedger[ledgerKey]
                let canRehit = lastHitFrame == nil || attack.definition.rehitFrames.map {
                    frame - (lastHitFrame ?? frame) >= Int64($0)
                } == true
                guard session?.permits(attack.actor.actorID, EntityID(defenderID)) == true,
                      !clashedDirections.contains("\(attackerID)>\(defenderID)"),
                      canRehit,
                      let defender = snapshot[defenderID],
                      defender.invulnerabilityFrames == 0,
                      defender.healthState == .active,
                      defender.locomotion != .dragged,
                      let defenderProfile = profiles[defenderID] else { continue }
                let hurtRects = defenderProfile.hurtBoxes.map {
                    $0.placed(at: defender.position, facing: defender.facing, scale: defender.visualScale)
                }
                guard attack.rects.contains(where: { hit in
                    hurtRects.contains(where: hit.overlaps)
                }) else { continue }

                let input = inputs[defenderID] ?? .neutral
                let attackerIsRight = attack.actor.position.x > defender.position.x
                let holdingBack = attackerIsRight ? input.left : input.right
                let guarding = guardMatches(
                    attack.definition.attackHeight,
                    input: input,
                    holdingBack: holdingBack,
                    defender: defender)
                pending.append(PendingHit(
                    attackerID: attackerID,
                    defenderID: defenderID,
                    move: attack.move,
                    definition: attack.definition,
                    ledgerKey: ledgerKey,
                    guarding: guarding))
            }
        }

        // Mark every attacker's contact before mutating defenders. This preserves
        // per-move hit de-duplication even when multiple actors trade on one frame.
        for hit in pending {
            guard var attacker = body(for: EntityID(hit.attackerID)) else { continue }
            attacker.hitTargets.insert(hit.defenderID)
            attacker.hitLedger[hit.ledgerKey] = frame
            attacker.hitStopFrames = max(attacker.hitStopFrames, hit.definition.hitStopFrames)
            save(attacker)
        }

        for hit in pending.sorted(by: {
            $0.defenderID == $1.defenderID
                ? $0.attackerID < $1.attackerID
                : $0.defenderID < $1.defenderID
        }) {
            guard let attackerAtDetection = snapshot[hit.attackerID],
                  var defender = body(for: EntityID(hit.defenderID)) else { continue }
            let definition = hit.definition
            let defenderWasAlive = defender.hp > 0

            if hit.guarding {
                defender.hp = max(0, defender.hp - definition.chipDamage)
                defender.phase = .blockStun
                defender.stunFrames = max(defender.stunFrames, definition.blockStunFrames)
                defender.hitStopFrames = max(defender.hitStopFrames, definition.hitStopFrames)
                defender.velocity.x = definition.knockbackX * attackerAtDetection.facing.sign * 0.35
                events.append(CombatEvent(
                    frame: frame, kind: .blocked,
                    actorID: attackerAtDetection.actorID, targetID: defender.actorID,
                    moveID: hit.move.id, amount: definition.chipDamage))
            } else {
                defender.hp = max(0, defender.hp - definition.damage)
                defender.actionTimeline = nil
                defender.hitTargets.removeAll()
                defender.phase = .hitStun
                defender.stunFrames = max(defender.stunFrames, definition.hitStunFrames)
                defender.hitStopFrames = max(defender.hitStopFrames, definition.hitStopFrames)
                defender.velocity.x = definition.knockbackX * attackerAtDetection.facing.sign
                defender.velocity.y = definition.knockbackY
                if definition.knockbackY < 0 {
                    defender.currentSurfaceID = nil
                    defender.surfaceFraction = nil
                    defender.locomotion = .airborne
                }
                events.append(CombatEvent(
                    frame: frame, kind: .hit,
                    actorID: attackerAtDetection.actorID, targetID: defender.actorID,
                    moveID: hit.move.id, amount: definition.damage))
            }

            if defenderWasAlive && defender.hp == 0 {
                defender.healthState = .knockedOut
                defender.phase = .hitStun
                if definition.knockbackY < 0 { defender.currentSurfaceID = nil }
                events.append(CombatEvent(
                    frame: frame, kind: .knockedOut,
                    actorID: defender.actorID,
                    targetID: attackerAtDetection.actorID,
                    moveID: hit.move.id))
            }
            save(defender)
        }
    }

    private func guardMatches(_ height: CombatAttackHeight, input: FighterInputFrame,
                              holdingBack: Bool, defender: CombatBodyState) -> Bool {
        guard defender.locomotion == .grounded,
              defender.currentMoveID == nil,
              holdingBack else { return false }
        switch height {
        case .throwAttack:
            return false
        case .low:
            return input.down
        case .high, .air:
            return !input.down
        case .mid:
            return true
        }
    }
}

/// Compatibility adapter for the transitional AppKit combat runner. New
/// runtime code owns `BodyFrameAccumulator` through `GameRuntime` directly.
public struct CombatFrameClock: Codable, Equatable, Sendable {
    private var accumulator = BodyFrameAccumulator()
    public init() {}

    public mutating func advance(elapsedSeconds: Double) -> Int {
        accumulator.consume(elapsedSeconds: elapsedSeconds).count
    }
}
