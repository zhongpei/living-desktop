import Foundation
import MyPetCore

/// Deterministic 60 Hz body/combat authority. Rendering, AppKit and models are consumers/producers
/// of snapshots and inputs; none of them mutate authoritative body state.
public final class CombatWorld {
    public static let framesPerSecond = 60
    public static let gravityPerFrame = 1600.0 / 3600.0

    public private(set) var frame: Int64 = 0
    private var bodies: [String: CombatBodyState] = [:]
    private var profiles: [String: CombatProfile] = [:]
    private var inputs: [String: FighterInputFrame] = [:]
    private var buffers: [String: CombatInputBuffer] = [:]
    private var dragLast: [String: CombatPoint] = [:]

    public init() {}

    public init(checkpoint: CombatWorldCheckpoint) {
        self.frame = checkpoint.frame
        self.bodies = checkpoint.bodies
        self.profiles = checkpoint.profiles
        self.inputs = checkpoint.inputs
        self.buffers = checkpoint.buffers
    }

    public func checkpoint() -> CombatWorldCheckpoint {
        CombatWorldCheckpoint(
            frame: frame,
            bodies: bodies,
            profiles: profiles,
            inputs: inputs,
            buffers: buffers)
    }

    public func register(actorID: EntityID, profile: CombatProfile = CombatProfile(),
                         x: Double, yFeet: Double, facing: CombatFacing = .right,
                         visualScale: Double = 1) {
        profiles[actorID.raw] = profile
        var body = CombatBodyState(actorID: actorID, x: x, yFeet: yFeet,
                                   hp: profile.maxHP, facing: facing, visualScale: visualScale)
        body.hp = profile.maxHP
        bodies[actorID.raw] = body
        buffers[actorID.raw] = CombatInputBuffer()
        inputs[actorID.raw] = .neutral
    }

    public func unregister(actorID: EntityID) {
        bodies[actorID.raw] = nil
        profiles[actorID.raw] = nil
        inputs[actorID.raw] = nil
        buffers[actorID.raw] = nil
        dragLast[actorID.raw] = nil
    }

    public func setProfile(_ profile: CombatProfile, for actorID: EntityID) {
        profiles[actorID.raw] = profile
        guard var body = bodies[actorID.raw] else { return }
        body.hp = min(max(0, body.hp), profile.maxHP)
        bodies[actorID.raw] = body
    }

    public func setInput(_ input: FighterInputFrame, for actorID: EntityID,
                         authority: CombatControlAuthority? = nil) {
        inputs[actorID.raw] = input
        if let authority, var body = bodies[actorID.raw] {
            body.authority = authority
            bodies[actorID.raw] = body
        }
    }

    public func body(for actorID: EntityID) -> CombatBodyState? { bodies[actorID.raw] }

    /// Synchronizes a legacy/semantic body pose into the unified combat world without
    /// resetting HP, stun, recovery or command history. This is the migration seam used by
    /// non-combat story locomotion until every semantic verb is natively body-driven.
    public func synchronizePose(
        actorID: EntityID,
        x: Double,
        yFeet: Double,
        facing: CombatFacing,
        locomotion: BodyLocomotionState,
        visualScale: Double = 1
    ) {
        guard var body = bodies[actorID.raw] else { return }
        body.position = CombatPoint(x: x, y: yFeet)
        body.facing = facing
        if body.healthState == .active && body.phase != .hitStun && body.phase != .blockStun {
            body.locomotion = locomotion
        }
        body.visualScale = max(0.05, visualScale)
        bodies[actorID.raw] = body
    }

    public func setAuthority(_ authority: CombatControlAuthority, for actorID: EntityID) {
        guard var body = bodies[actorID.raw] else { return }
        body.authority = authority
        bodies[actorID.raw] = body
    }

    public func snapshot() -> CombatWorldSnapshot {
        CombatWorldSnapshot(frame: frame, bodies: Array(bodies.values))
    }

    @discardableResult
    public func step(environment: CombatEnvironment) -> [CombatEvent] {
        var events: [CombatEvent] = []
        let ids = bodies.keys.sorted()

        for id in ids {
            guard var body = bodies[id], let profile = profiles[id] else { continue }
            let input = inputs[id] ?? .neutral
            var buffer = buffers[id] ?? CombatInputBuffer()
            buffer.push(input)
            buffers[id] = buffer

            syncAttachedSurface(&body, environment: environment, profile: profile)
            if body.invulnerabilityFrames > 0 { body.invulnerabilityFrames -= 1 }

            if body.hitStopFrames > 0 {
                body.hitStopFrames -= 1
                bodies[id] = body
                continue
            }

            advanceHealth(&body, profile: profile, events: &events)
            advanceStun(&body)
            if body.healthState == .active {
                acceptControl(&body, profile: profile, input: input, buffer: buffer, events: &events)
                advanceMove(&body, profile: profile)
            }
            integrate(&body, profile: profile, environment: environment)
            bodies[id] = body
        }

        resolvePushboxes()
        resolveHits(events: &events)
        // A KO becomes downed only after its physical knockback has actually landed.
        for id in ids {
            guard var body = bodies[id], let profile = profiles[id] else { continue }
            if body.healthState == .knockedOut && body.locomotion == .grounded {
                body.healthState = .downed
                body.recoveryFramesRemaining = profile.downedRecoveryFrames
                body.phase = .neutral
                events.append(CombatEvent(frame: frame, kind: .downed, actorID: body.actorID))
                bodies[id] = body
            }
        }

        frame += 1
        return events
    }

    public func beginDrag(actorID: EntityID, x: Double, y: Double) {
        guard var body = bodies[actorID.raw] else { return }
        body.locomotion = .dragged
        body.currentSurfaceID = nil
        body.surfaceFraction = nil
        body.currentMoveID = nil
        body.moveFrame = 0
        body.phase = .neutral
        body.velocity = CombatPoint()
        dragLast[actorID.raw] = CombatPoint(x: x, y: y)
        bodies[actorID.raw] = body
    }

    public func drag(actorID: EntityID, x: Double, y: Double, elapsedSeconds: Double) {
        guard var body = bodies[actorID.raw], body.locomotion == .dragged else { return }
        let previous = dragLast[actorID.raw] ?? body.position
        let dt = max(1.0 / 240.0, elapsedSeconds)
        let sampleVX = (x - previous.x) / dt / 60.0
        let sampleVY = (y - previous.y) / dt / 60.0
        body.velocity.x += (sampleVX - body.velocity.x) * 0.35
        body.velocity.y += (sampleVY - body.velocity.y) * 0.35
        body.position = CombatPoint(x: x, y: y)
        dragLast[actorID.raw] = body.position
        bodies[actorID.raw] = body
    }

    public func endDrag(actorID: EntityID, wasClick: Bool) {
        guard var body = bodies[actorID.raw], body.locomotion == .dragged else { return }
        dragLast[actorID.raw] = nil
        if wasClick {
            body.locomotion = .airborne
            body.velocity.y = min(body.velocity.y, -4.0)
        } else {
            body.locomotion = .tossed
            body.velocity.x = min(43, max(-43, body.velocity.x))
            body.velocity.y = min(43, max(-43, body.velocity.y))
        }
        bodies[actorID.raw] = body
    }

    private func acceptControl(_ body: inout CombatBodyState, profile: CombatProfile,
                               input: FighterInputFrame, buffer: CombatInputBuffer,
                               events: inout [CombatEvent]) {
        guard body.locomotion != .dragged && body.locomotion != .tossed else { return }
        if body.currentMoveID != nil { return }

        if let move = profile.moves.first(where: {
            CombatCommandRecognizer.matches($0.command, buffer: buffer, facing: body.facing)
        }) {
            body.currentMoveID = move.id
            body.moveFrame = 0
            body.hitTargets.removeAll()
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
        guard let move = profile.move(id: body.currentMoveID) else {
            body.currentMoveID = nil
            if body.stunFrames == 0 { body.phase = .neutral }
            return
        }
        let activeStart = move.startupFrames
        let recoveryStart = activeStart + move.activeFrames
        if body.moveFrame < activeStart { body.phase = .startup }
        else if body.moveFrame < recoveryStart { body.phase = .active }
        else { body.phase = .recovery }
        body.moveFrame += 1
        if body.moveFrame >= move.totalFrames {
            body.currentMoveID = nil
            body.moveFrame = 0
            body.hitTargets.removeAll()
            body.phase = .neutral
        }
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
            body.velocity.x = 0
            body.velocity.y = 0
            if body.recoveryFramesRemaining > 0 { body.recoveryFramesRemaining -= 1 }
            if body.recoveryFramesRemaining == 0 {
                body.healthState = .gettingUp
                body.recoveryFramesRemaining = profile.getUpFrames
                events.append(CombatEvent(frame: frame, kind: .recoveryStarted, actorID: body.actorID))
            }
        case .gettingUp:
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

    private func syncAttachedSurface(_ body: inout CombatBodyState, environment: CombatEnvironment,
                                     profile: CombatProfile) {
        guard body.locomotion == .grounded, let id = body.currentSurfaceID else { return }
        guard let surface = environment.surface(id: id) else {
            body.currentSurfaceID = nil
            body.surfaceFraction = nil
            body.locomotion = .airborne
            return
        }
        body.position.y = surface.y
        if let fraction = body.surfaceFraction {
            let margin = profile.pushRadius
            let usable = max(1, (surface.right - surface.left) - margin * 2)
            body.position.x = surface.left + margin + min(1, max(0, fraction)) * usable
        }
    }

    private func integrate(_ body: inout CombatBodyState, profile: CombatProfile,
                           environment: CombatEnvironment) {
        guard body.locomotion != .dragged && body.locomotion != .sleeping else { return }
        let previousY = body.position.y

        if body.locomotion == .grounded {
            body.position.x += body.velocity.x
            if let surface = environment.surface(id: body.currentSurfaceID) {
                let margin = profile.pushRadius * 0.6
                if !surface.contains(x: body.position.x, margin: margin) {
                    body.currentSurfaceID = nil
                    body.surfaceFraction = nil
                    body.locomotion = .airborne
                    body.position.y += 0.01
                } else if surface.right - surface.left > margin * 2 {
                    body.surfaceFraction = (body.position.x - surface.left - margin) /
                        max(1, surface.right - surface.left - margin * 2)
                }
            }
        }

        if body.locomotion == .airborne || body.locomotion == .tossed ||
           body.healthState == .knockedOut {
            body.velocity.y += Self.gravityPerFrame
            body.position.x += body.velocity.x
            body.position.y += body.velocity.y

            if body.velocity.y >= 0,
               let landing = environment.landingSurface(
                    x: body.position.x, previousFeetY: previousY, nextFeetY: body.position.y) {
                body.position.y = landing.y
                body.currentSurfaceID = landing.id
                let margin = profile.pushRadius
                let usable = max(1, landing.right - landing.left - margin * 2)
                body.surfaceFraction = min(1, max(0,
                    (body.position.x - landing.left - margin) / usable))
                if body.locomotion == .tossed && abs(body.velocity.y) > 4.5 {
                    body.velocity.y = -abs(body.velocity.y) * 0.28
                    body.velocity.x *= 0.72
                } else {
                    body.locomotion = .grounded
                    body.velocity.y = 0
                    body.velocity.x *= body.healthState == .knockedOut ? 0.75 : 0
                }
            }
        }

        body.position.x = min(environment.bounds.maxX, max(environment.bounds.minX, body.position.x))
        body.position.y = min(environment.bounds.maxY, max(environment.bounds.minY, body.position.y))
    }

    private func resolvePushboxes() {
        let ids = bodies.keys.sorted()
        guard ids.count > 1 else { return }
        for i in 0..<(ids.count - 1) {
            for j in (i + 1)..<ids.count {
                guard var a = bodies[ids[i]], var b = bodies[ids[j]],
                      let ap = profiles[ids[i]], let bp = profiles[ids[j]],
                      a.healthState == .active, b.healthState == .active,
                      a.locomotion == .grounded, b.locomotion == .grounded,
                      abs(a.position.y - b.position.y) < 8 else { continue }
                let required = ap.pushRadius + bp.pushRadius
                let dx = b.position.x - a.position.x
                let overlap = required - abs(dx)
                guard overlap > 0 else { continue }
                let sign = dx >= 0 ? 1.0 : -1.0
                a.position.x -= sign * overlap * 0.5
                b.position.x += sign * overlap * 0.5
                bodies[ids[i]] = a
                bodies[ids[j]] = b
            }
        }
    }

    private func resolveHits(events: inout [CombatEvent]) {
        let ids = bodies.keys.sorted()
        for attackerID in ids {
            guard var attacker = bodies[attackerID],
                  attacker.phase == .active,
                  let attackerProfile = profiles[attackerID],
                  let move = attackerProfile.move(id: attacker.currentMoveID) else { continue }
            let attackRects = move.hit.attackBoxes.map {
                $0.placed(at: attacker.position, facing: attacker.facing, scale: attacker.visualScale)
            }
            for defenderID in ids where defenderID != attackerID {
                guard !attacker.hitTargets.contains(defenderID),
                      var defender = bodies[defenderID],
                      defender.invulnerabilityFrames == 0,
                      defender.healthState == .active,
                      let defenderProfile = profiles[defenderID] else { continue }
                let hurtRects = defenderProfile.hurtBoxes.map {
                    $0.placed(at: defender.position, facing: defender.facing, scale: defender.visualScale)
                }
                guard attackRects.contains(where: { hit in hurtRects.contains(where: hit.overlaps) }) else {
                    continue
                }

                let input = inputs[defenderID] ?? .neutral
                let attackerIsRight = attacker.position.x > defender.position.x
                let guarding = defender.locomotion == .grounded &&
                    (attackerIsRight ? input.left : input.right) &&
                    defender.currentMoveID == nil
                attacker.hitTargets.insert(defenderID)
                attacker.hitStopFrames = max(attacker.hitStopFrames, move.hit.hitStopFrames)

                if guarding {
                    defender.hp = max(0, defender.hp - move.hit.chipDamage)
                    defender.phase = .blockStun
                    defender.stunFrames = move.hit.blockStunFrames
                    defender.hitStopFrames = max(defender.hitStopFrames, move.hit.hitStopFrames)
                    defender.velocity.x = move.hit.knockbackX * attacker.facing.sign * 0.35
                    events.append(CombatEvent(frame: frame, kind: .blocked,
                                              actorID: attacker.actorID, targetID: defender.actorID,
                                              moveID: move.id, amount: move.hit.chipDamage))
                } else {
                    defender.hp = max(0, defender.hp - move.hit.damage)
                    defender.currentMoveID = nil
                    defender.moveFrame = 0
                    defender.hitTargets.removeAll()
                    defender.phase = .hitStun
                    defender.stunFrames = move.hit.hitStunFrames
                    defender.hitStopFrames = max(defender.hitStopFrames, move.hit.hitStopFrames)
                    defender.velocity.x = move.hit.knockbackX * attacker.facing.sign
                    defender.velocity.y = move.hit.knockbackY
                    if move.hit.knockbackY < 0 {
                        defender.currentSurfaceID = nil
                        defender.surfaceFraction = nil
                        defender.locomotion = .airborne
                    }
                    events.append(CombatEvent(frame: frame, kind: .hit,
                                              actorID: attacker.actorID, targetID: defender.actorID,
                                              moveID: move.id, amount: move.hit.damage))
                    if defender.hp == 0 {
                        defender.healthState = .knockedOut
                        defender.phase = .hitStun
                        defender.currentSurfaceID = move.hit.knockbackY < 0 ? nil : defender.currentSurfaceID
                        events.append(CombatEvent(frame: frame, kind: .knockedOut,
                                                  actorID: defender.actorID,
                                                  targetID: attacker.actorID, moveID: move.id))
                    }
                }
                bodies[defenderID] = defender
            }
            bodies[attackerID] = attacker
        }
    }
}

public struct CombatFrameClock: Codable, Equatable, Sendable {
    private var remainder: Double = 0
    public init() {}

    public mutating func advance(elapsedSeconds: Double) -> Int {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return 0 }
        remainder += min(elapsedSeconds, 0.25)
        let step = 1.0 / Double(CombatWorld.framesPerSecond)
        let count = Int((remainder + 1e-12) / step)
        remainder -= Double(count) * step
        return count
    }
}
