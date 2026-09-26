import Foundation
import MyPetCore
import MyPet2D

/// Deterministic combat rules layered over the authoritative MyPet2D BodyWorld.
/// Rendering, AppKit and models consume snapshots and produce inputs; none mutate body state.
public final class CombatWorld {
    private struct PendingHit {
        let attackerID: String
        let defenderID: String
        let moveID: String
        let definition: CombatHitDefinition
        let ledgerKey: String
        let guarding: Bool
        let projectileID: String?
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
    public var authoritativeBodyWorld: BodyWorld { bodyWorld }
    private var rules: [String: CombatRuleState] = [:]
    private var profiles: [String: CombatProfile] = [:]
    private var inputs: [String: FighterInputFrame] = [:]
    private var buffers: [String: CombatInputBuffer] = [:]
    private var projectiles: [String: CombatProjectileState] = [:]
    private var teams: [String: TeamCombatState] = [:]
    private var escalation = CombatEscalationState(policy: .flatArena)
    private var combatReadiness: [String: Bool] = [:]
    private var featurePolicy = CombatFeaturePolicy()
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
        self.projectiles = checkpoint.projectiles ?? [:]
        self.teams = checkpoint.teams ?? [:]
        self.escalation = checkpoint.escalation ?? CombatEscalationState(policy: .flatArena)
        self.combatReadiness = checkpoint.combatReadiness ??
            Dictionary(uniqueKeysWithValues: checkpoint.rules.keys.map { ($0, true) })
        self.featurePolicy = checkpoint.featurePolicy ?? CombatFeaturePolicy()
    }

    public func checkpoint() -> CombatWorldCheckpoint {
        CombatWorldCheckpoint(
            frame: frame,
            bodyWorld: bodyWorld.checkpoint(),
            rules: rules,
            profiles: profiles,
            inputs: inputs,
            buffers: buffers,
            session: session,
            projectiles: projectiles,
            teams: teams,
            escalation: escalation,
            combatReadiness: combatReadiness,
            featurePolicy: featurePolicy)
    }

    @discardableResult
    public func beginSession(
        id: String, participants: [EntityID],
        roundRules: CombatRoundRules = .desktop
    ) -> Bool {
        let unique = Array(Set(participants)).sorted { $0.raw < $1.raw }
        guard unique.count >= 2,
              unique.allSatisfy({ rules[$0.raw] != nil }) else { return false }
        if let session, session.state == .active,
           session.id == id, session.participantIDs == unique { return true }
        session = CombatSession(
            id: id, participants: unique, startedAtFrame: frame,
            roundRules: roundRules)
        for actorID in unique where teamID(for: actorID) == nil {
            guard var rule = rules[actorID.raw] else { continue }
            rule.participation = .rosterParticipant(teamID: "solo:\(actorID.raw)")
            rules[actorID.raw] = rule
        }
        return true
    }

    public func endSession(cancelled: Bool = false) {
        guard var active = session, active.state == .active else { return }
        active.complete(
            at: frame, winners: [],
            reason: cancelled ? .cancelled : .completed)
        session = active
        for id in active.participantIDs {
            inputs[id.raw] = .neutral
            buffers[id.raw] = CombatInputBuffer()
            if var rule = rules[id.raw] {
                var combo = rule.combo ?? ComboState()
                combo.end(reason: .sessionEnded)
                rule.combo = combo
                if teamID(for: id) == nil { rule.participation = .uninvolved }
                rules[id.raw] = rule
            }
        }
    }

    @discardableResult
    public func addParticipants(_ participants: [EntityID]) -> Bool {
        guard var active = session, active.state == .active else { return false }
        let unique = Array(Set(active.participantIDs + participants)).sorted { $0.raw < $1.raw }
        guard unique.count >= 2,
              unique.allSatisfy({ rules[$0.raw] != nil }) else { return false }
        active.participantIDs = unique
        session = active
        for actorID in unique where teamID(for: actorID) == nil {
            guard var rule = rules[actorID.raw] else { continue }
            rule.participation = .rosterParticipant(teamID: "solo:\(actorID.raw)")
            rules[actorID.raw] = rule
        }
        return true
    }

    public func configureTeam(
        teamID: String, activeID: EntityID, benchID: EntityID,
        rules teamRules: TeamCombatRules = .standard
    ) {
        guard rules[activeID.raw] != nil, rules[benchID.raw] != nil,
              activeID != benchID else { return }
        teams[teamID] = TeamCombatState(
            teamID: teamID, activeID: activeID, benchID: benchID, rules: teamRules)
        if var active = rules[activeID.raw] {
            active.rosterRole = .active
            active.participation = .rosterParticipant(teamID: teamID)
            rules[activeID.raw] = active
        }
        if var bench = rules[benchID.raw] {
            bench.rosterRole = .bench
            bench.participation = .rosterParticipant(teamID: teamID)
            rules[benchID.raw] = bench
        }
        setRosterRole(.active, actorID: activeID)
        setRosterRole(.bench, actorID: benchID)
    }

    public func setEscalationPolicy(_ policy: NeutralEscalationPolicy) {
        escalation = CombatEscalationState(policy: policy)
    }

    public func setFeaturePolicy(_ policy: CombatFeaturePolicy) {
        featurePolicy = policy
    }

    public var currentFeaturePolicy: CombatFeaturePolicy { featurePolicy }

    public func teamState(_ teamID: String) -> TeamCombatState? { teams[teamID] }
    public func teamState(for actorID: EntityID) -> TeamCombatState? {
        teams.values.first { $0.activeID == actorID || $0.benchID == actorID }
    }
    public var escalationState: CombatEscalationState { escalation }

    public func register(actorID: EntityID, profile: CombatProfile = CombatProfile(),
                         x: Double, yFeet: Double, facing: CombatFacing = .right,
                         visualScale: Double = 1,
                         realCombatReady: Bool = true) {
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
        combatReadiness[actorID.raw] = realCombatReady
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
        combatReadiness[actorID.raw] = nil
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

    public func profile(for actorID: EntityID) -> CombatProfile? {
        profiles[actorID.raw]
    }

    public func isCombatReady(_ actorID: EntityID) -> Bool {
        combatReadiness[actorID.raw] ?? false
    }

    public func setAuthority(_ authority: CombatControlAuthority, for actorID: EntityID) {
        guard var rule = rules[actorID.raw] else { return }
        rule.authority = authority
        rules[actorID.raw] = rule
    }

    public func setGameplayEnergy(_ current: Int, for actorID: EntityID) {
        guard var rule = rules[actorID.raw] else { return }
        var energy = rule.gameplayEnergy ?? GameplayEnergyState()
        energy = GameplayEnergyState(
            current: current, maximum: energy.maximum,
            regenPerFrame: energy.regenPerFrame,
            regenDelayFrames: energy.regenDelayFrames)
        rule.gameplayEnergy = energy
        rules[actorID.raw] = rule
    }

    @discardableResult
    public func authorizeWindowInteraction(
        _ action: WindowGameplayAction,
        for actorID: EntityID,
        policy: inout WindowInteractionPolicy,
        userActive: Bool,
        targetIsForeground: Bool
    ) -> WindowAuthorization {
        guard var rule = rules[actorID.raw] else { return .disabled }
        var energy = rule.gameplayEnergy ?? GameplayEnergyState(current: 0)
        let authorization = policy.authorize(
            action, energy: &energy, frame: frame,
            userActive: userActive,
            targetIsForeground: targetIsForeground)
        if authorization == .allowed {
            rule.gameplayEnergy = energy
            rules[actorID.raw] = rule
        }
        return authorization
    }

    public func snapshot() -> CombatWorldSnapshot {
        CombatWorldSnapshot(
            frame: frame,
            bodies: rules.keys.sorted().compactMap { body(for: EntityID($0)) },
            projectiles: projectiles.keys.sorted().compactMap { id in
                guard let projectile = projectiles[id],
                      let body = bodyWorld.state(for: projectile.entityID) else { return nil }
                return CombatProjectileSnapshot(
                    entityID: projectile.entityID,
                    ownerID: projectile.ownerID,
                    definitionID: projectile.definition.id,
                    position: body.position,
                    velocity: body.velocity,
                    spawnedAtFrame: projectile.spawnedAtFrame,
                    visualResourceID: projectile.definition.visualResourceID)
            })
    }

    @discardableResult
    public func step(environment: CombatEnvironment) -> [CombatEvent] {
        var events: [CombatEvent] = []
        advanceTeams(events: &events)
        let ids = rules.keys.sorted()
        let frameSnapshot = Dictionary(uniqueKeysWithValues: snapshot().bodies.map {
            ($0.actorID.raw, $0)
        })

        for id in ids {
            let actorID = EntityID(id)
            guard var body = body(for: actorID), let profile = profiles[id] else { continue }
            let input = inputs[id] ?? .neutral
            var buffer = buffers[id] ?? CombatInputBuffer()
            let previousInput = buffer.newest ?? .neutral
            buffer.push(input)
            buffers[id] = buffer

            if body.invulnerabilityFrames > 0 { body.invulnerabilityFrames -= 1 }
            if body.powerUpFrames > 0 {
                body.powerUpFrames -= 1
                if body.powerUpFrames == 0 {
                    events.append(CombatEvent(
                        frame: frame, kind: .powerUpEnded, actorID: body.actorID))
                }
            }
            var combo = body.combo
            _ = combo.expireIfNeeded(frame: frame)
            body.combo = combo
            var energy = body.gameplayEnergy
            energy.advance(
                frame: frame,
                regenerationAllowed: body.healthState == .active &&
                    projectiles.values.contains(where: { $0.ownerID == actorID }) == false,
                regenerationScale: featurePolicy.energyEnabled
                    ? featurePolicy.energyRecoveryScale : 0)
            body.gameplayEnergy = energy

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

            advanceHealth(
                &body, profile: profile, input: input,
                previousInput: previousInput, events: &events)
            advanceStun(&body)
            orientTowardNearestOpponent(&body, snapshot: frameSnapshot)
            if body.healthState == .active && body.rosterRole != .bench {
                if body.authority != .scripted,
                   let timeline = body.actionTimeline,
                   timeline.definition.domain != .combat {
                    // Combat authority is a takeover boundary. A target can
                    // still carry an indefinite semantic walk/presentation
                    // timeline from the life loop; leaving it in place makes
                    // acceptControl reject every CPU frame forever. Scripted
                    // bodies keep their authored presentation timelines, and
                    // combat timelines are never touched here.
                    RuntimeLogger.shared.debug(
                        "combat.control",
                        "frame=\(frame) actor=\(body.actorID.raw) takeover cleared domain=\(timeline.definition.domain.rawValue) action=\(timeline.definition.actionID)")
                    body.actionTimeline = nil
                    if body.stunFrames == 0 { body.phase = .neutral }
                }
                acceptControl(
                    &body, profile: profile, input: input, buffer: buffer,
                    environment: environment, events: &events)
                advanceMove(&body, profile: profile, events: &events)
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
                pushEnabled: body.healthState == .active && body.rosterRole != .bench,
                simulationEnabled: body.rosterRole != .bench))
        }

        bodyWorld.advance(environment)
        // Touching any traversable surface replenishes the full jump chain.
        for id in ids {
            guard let physical = bodyWorld.state(for: EntityID(id)),
                  physical.locomotion == .grounded,
                  var rule = rules[id],
                  (rule.airJumpsUsed ?? 0) != 0 else { continue }
            rule.airJumpsUsed = 0
            rules[id] = rule
        }
        clampProjectilesToAuthoredRange()
        resolveHits(environment: environment, events: &events)
        expireProjectiles(environment: environment, events: &events)
        advanceEscalation(events: &events)
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

        advanceSession(events: &events)

        frame += 1
        return events
    }

    private func advanceSession(events: inout [CombatEvent]) {
        guard var active = session, active.state == .active else { return }
        let participants = active.participantIDs.compactMap(body(for:))
        let grouped = Dictionary(grouping: participants) { body in
            teamID(for: body.actorID) ?? "solo:\(body.actorID.raw)"
        }
        let defeatedTeams = Set(grouped.compactMap { key, members in
            members.allSatisfy { $0.hp == 0 } ? key : nil
        })
        let shouldEndForKO = active.roundRules.endOnKnockout && !defeatedTeams.isEmpty
        let timedOut = active.roundRules.durationFrames > 0 &&
            frame - active.startedAtFrame + 1 >= Int64(active.roundRules.durationFrames)
        guard shouldEndForKO || timedOut else { return }

        let reason: CombatSessionEndReason
        let winners: [EntityID]
        if shouldEndForKO {
            let winningTeams = Set(grouped.keys).subtracting(defeatedTeams)
            winners = participants.filter {
                winningTeams.contains(teamID(for: $0.actorID) ?? "solo:\($0.actorID.raw)")
            }.map(\.actorID)
            reason = winningTeams.isEmpty ? .doubleKnockout : .knockout
        } else {
            let teamHP = grouped.mapValues { members in members.reduce(0) { $0 + $1.hp } }
            let bestHP = teamHP.values.max() ?? 0
            let winningTeams = Set(teamHP.compactMap { $0.value == bestHP ? $0.key : nil })
            winners = participants.filter {
                winningTeams.contains(teamID(for: $0.actorID) ?? "solo:\($0.actorID.raw)")
            }.map(\.actorID)
            reason = .timeout
        }
        active.complete(at: frame, winners: winners, reason: reason)
        session = active
        for id in active.participantIDs {
            inputs[id.raw] = .neutral
            buffers[id.raw] = CombatInputBuffer()
            if var rule = rules[id.raw] {
                var combo = rule.combo ?? ComboState()
                combo.end(reason: .sessionEnded)
                rule.combo = combo
                rules[id.raw] = rule
            }
        }
        events.append(CombatEvent(
            frame: frame, kind: .roundEnded,
            actorID: winners.first ?? active.participantIDs[0],
            moveID: reason.rawValue, amount: winners.count))
    }

    private func advanceTeams(events: inout [CombatEvent]) {
        guard featurePolicy.teamsEnabled else { return }
        for teamID in teams.keys.sorted() {
            guard var team = teams[teamID] else { continue }
            let activeInput = inputs[team.activeID.raw] ?? .neutral
            let previousInput = buffers[team.activeID.raw]?.newest ?? .neutral
            if featurePolicy.assistsEnabled,
               activeInput.systemControls.contains(.assist),
               !previousInput.systemControls.contains(.assist) {
                _ = team.requestAssist(frame: frame)
            }
            if featurePolicy.freeTagEnabled,
               activeInput.systemControls.contains(.tag),
               !previousInput.systemControls.contains(.tag),
               body(for: team.activeID)?.canAcceptAction == true {
                _ = team.requestTag(frame: frame)
            }
            let teamEvents = team.advance(frame: frame)
            teams[teamID] = team
            for event in teamEvents {
                switch event.kind {
                case .assistEntered:
                    setRosterRole(.assist, actorID: event.actorID)
                    if let active = body(for: team.activeID) {
                        bodyWorld.update(event.actorID) {
                            $0.position = Vec2(
                                x: active.position.x - 36 * active.facing.sign,
                                y: active.position.y)
                            $0.facing = active.facing
                        }
                    }
                    inputs[event.actorID.raw] = FighterInputFrame(
                        systemControls: [.assist])
                case .assistExited:
                    inputs[event.actorID.raw] = .neutral
                    setRosterRole(.bench, actorID: event.actorID)
                case .tagHandoff:
                    setRosterRole(.active, actorID: team.activeID)
                    setRosterRole(.bench, actorID: team.benchID)
                case .tagStarted, .tagCompleted: break
                }
                let kind: CombatEventKind
                switch event.kind {
                case .assistEntered: kind = .assistEntered
                case .assistExited: kind = .assistExited
                case .tagStarted: kind = .tagStarted
                case .tagHandoff: kind = .tagHandoff
                case .tagCompleted: kind = .tagCompleted
                }
                events.append(CombatEvent(
                    frame: frame, kind: kind, actorID: event.actorID,
                    moveID: event.teamID))
            }
        }
    }

    private func setRosterRole(_ role: CombatRosterRole, actorID: EntityID) {
        guard var rule = rules[actorID.raw], let profile = profiles[actorID.raw] else { return }
        rule.rosterRole = role
        if role == .bench {
            rule.phase = .neutral
            rule.hitTargets.removeAll()
            rule.hitLedger = [:]
            bodyWorld.update(actorID) { $0.actionTimeline = nil }
        }
        rules[actorID.raw] = rule
        bodyWorld.setDefinition(BodyDefinition(
            entityID: actorID, pushRadius: profile.pushRadius,
            visualScale: rule.visualScale,
            pushEnabled: role == .active || role == .incidental,
            simulationEnabled: role != .bench))
    }

    private func advanceEscalation(events: inout [CombatEvent]) {
        let escalationEvents = escalation.advance(
            frame: frame,
            combatReady: Set(rules.values.filter {
                combatReadiness[$0.actorID.raw] == true
            }.map(\.actorID)))
        for event in escalationEvents {
            if var rule = rules[event.actorID.raw] {
                rule.participation = escalation.participation[event.actorID]
                if event.kind == .joined { rule.rosterRole = .incidental }
                rules[event.actorID.raw] = rule
            }
            events.append(CombatEvent(
                frame: frame,
                kind: event.kind == .joined ? .neutralJoined :
                    (event.kind == .withdrew ? .neutralWithdrew : .neutralAlerted),
                actorID: event.actorID, targetID: event.offenderID))
        }
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
                               environment: BodyEnvironment,
                               events: inout [CombatEvent]) {
        guard body.authority != .scripted else { return }
        guard body.locomotion != .dragged && body.locomotion != .tossed else { return }
        if (body.phase == .hitStun || body.phase == .blockStun),
           let burst = profile.moves.first(where: {
               featurePolicy.permits($0) &&
               $0.systemControl == .defensiveBurst &&
                   buffer.containsSystemControlPress(
                       .defensiveBurst, withinLast: 16)
           }), startMove(burst, body: &body, events: &events) {
            body.stunFrames = 0
            body.invulnerabilityFrames = max(body.invulnerabilityFrames, 12)
            return
        }
        if let timeline = body.actionTimeline,
           timeline.canCancel,
           let current = profile.move(id: body.currentMoveID),
           let allowed = current.cancelInto {
            let candidates = profile.moves.filter { candidate in
                allowed.contains(candidate.id) &&
                    featurePolicy.permits(candidate) &&
                    candidate.effectiveUseState.permits(body.locomotion) &&
                    ((candidate.systemControl.map(buffer.isSystemControlPress) ?? false) ||
                     (candidate.systemControl == nil && CommandMatcher.matches(
                        candidate.command, buffer: buffer, facing: body.facing))) &&
                    body.gameplayEnergy.current >= featurePolicy.scaledCost(
                        candidate.effectiveResourceRules.startCost)
            }
            if let next = candidates.max(by: {
                commandSpecificity($0.command) < commandSpecificity($1.command)
            }) {
                _ = startMove(next, body: &body, events: &events)
                events.append(CombatEvent(
                    frame: frame, kind: .moveCancelled,
                    actorID: body.actorID, targetID: nil,
                    moveID: "\(current.id)->\(next.id)"))
                return
            }
        }
        guard body.canAcceptAction, body.actionTimeline == nil else { return }

        let matchingMoves = profile.moves.enumerated().filter {
            featurePolicy.permits($0.element) &&
                $0.element.effectiveUseState.permits(body.locomotion) &&
                (($0.element.systemControl.map(buffer.isSystemControlPress) ?? false) ||
                ($0.element.systemControl == nil && CommandMatcher.matches(
                    $0.element.command, buffer: buffer, facing: body.facing))) &&
                body.gameplayEnergy.current >= featurePolicy.scaledCost(
                    $0.element.effectiveResourceRules.startCost)
        }
        if let move = matchingMoves.max(by: { lhs, rhs in
            let left = commandSpecificity(lhs.element.command)
            let right = commandSpecificity(rhs.element.command)
            return left == right ? lhs.offset > rhs.offset : left < right
        })?.element {
            _ = startMove(move, body: &body, events: &events)
            return
        }

        let horizontalIntent: Double = input.right == input.left
            ? 0 : (input.right ? 1 : -1)
        let inputFrames = buffer.framesNewestFirst
        let upPressed = input.up &&
            inputFrames.dropFirst().first?.up != true
        if body.locomotion == .grounded, input.up, input.down,
           let surface = environment.surface(id: body.currentSurfaceID),
           surface.kind != .floor {
            body.currentSurfaceID = nil
            body.surfaceFraction = nil
            body.locomotion = .airborne
            body.position.y += 2
            body.velocity.x = horizontalIntent * profile.walkSpeed
            body.velocity.y = BodyWorld.gravityPerFrame
            return
        } else if body.locomotion == .grounded && input.up {
            body.currentSurfaceID = nil
            body.surfaceFraction = nil
            body.locomotion = .airborne
            body.airJumpsUsed = 1
            let chaseJump = body.authority == .autonomous &&
                input.forward(facing: body.facing) &&
                (nearestOpponentHorizontalDistance(from: body) ?? 0) >= 260
            let horizontalSpeed = profile.walkSpeed *
                (chaseJump ? profile.effectiveRunSpeedMultiplier * 0.9 : 1.15)
            body.velocity.x = horizontalIntent * horizontalSpeed
            body.velocity.y = profile.jumpVelocity
            return
        }

        if body.locomotion == .airborne {
            if upPressed,
               body.stunFrames == 0,
               body.actionTimeline == nil,
               body.airJumpsUsed < profile.effectiveMaxJumpCount {
                body.airJumpsUsed += 1
                body.velocity.y = profile.jumpVelocity
                if horizontalIntent != 0 {
                    let desired = horizontalIntent * profile.walkSpeed *
                        profile.effectiveRunSpeedMultiplier * 0.9
                    body.velocity.x += (desired - body.velocity.x) * 0.55
                }
                return
            }
            // Limited air steering keeps planned platform jumps viable without
            // turning the fighter into free-flight movement.
            if horizontalIntent != 0,
               body.stunFrames == 0,
               body.actionTimeline == nil {
                let desired = horizontalIntent * profile.walkSpeed * 0.65
                body.velocity.x += (desired - body.velocity.x) * 0.35
            }
            return
        }

        guard body.locomotion == .grounded else { return }
        if input.left != input.right {
            let direction = input.right ? 1.0 : -1.0
            let distantChase = body.authority == .autonomous &&
                input.forward(facing: body.facing) &&
                (nearestOpponentHorizontalDistance(from: body) ?? 0) >= 320
            let speed = profile.walkSpeed *
                (distantChase ? profile.effectiveRunSpeedMultiplier : 1)
            body.velocity.x = direction * speed
            body.facing = direction > 0 ? .right : .left
        } else {
            body.velocity.x = 0
        }
    }

    private func nearestOpponentHorizontalDistance(
        from body: CombatBodyState
    ) -> Double? {
        snapshot().bodies.filter {
            $0.actorID != body.actorID &&
                $0.healthState == .active &&
                $0.rosterRole != .bench &&
                permitsContact(body.actorID, $0.actorID)
        }.map {
            abs($0.position.x - body.position.x)
        }.min()
    }

    @discardableResult
    private func startMove(
        _ move: CombatMoveDefinition,
        body: inout CombatBodyState,
        events: inout [CombatEvent]
    ) -> Bool {
        let resource = move.effectiveResourceRules
        guard featurePolicy.permits(move),
              move.effectiveUseState.permits(body.locomotion) else { return false }
        let cost = featurePolicy.scaledCost(resource.startCost)
        var energy = body.gameplayEnergy
        guard energy.spend(cost, frame: frame) else { return false }
        body.gameplayEnergy = energy
        if body.locomotion == .grounded &&
           move.actionDefinition.locomotionPolicy == .stationary {
            // A combat move owns locomotion from this frame onward. Do not
            // inherit the previous chase velocity; authored root motion below
            // is the only movement while startup/active/recovery is running.
            body.velocity.x = 0
        }
        let instanceID = body.rules.actionSequence ?? 0
        body.rules.actionSequence = instanceID + 1
        body.actionTimeline = ActionTimeline(
            instanceID: instanceID, definition: move.actionDefinition)
        body.hitTargets.removeAll()
        body.hitLedger.removeAll()
        body.phase = .startup
        events.append(CombatEvent(
            frame: frame, kind: .moveStarted,
            actorID: body.actorID, moveID: move.id))
        RuntimeLogger.shared.debug(
            "combat.move",
            "frame=\(frame) kind=start actor=\(body.actorID.raw) move=\(move.id) x=\(String(format: "%.1f", body.position.x)) y=\(String(format: "%.1f", body.position.y)) nearestDX=\(nearestOpponentHorizontalDistance(from: body).map { String(format: "%.1f", $0) } ?? "-") startup=\(move.startupFrames) active=\(move.activeFrames) recovery=\(move.recoveryFrames) rootX=\(String(format: "%.1f", moveRootMotionXBeforeActive(move)))")
        if cost > 0 {
            events.append(CombatEvent(
                frame: frame, kind: .energySpent, actorID: body.actorID,
                moveID: move.id, amount: cost))
        }
        if resource.family == .powerUp {
            body.powerUpFrames = 480
            events.append(CombatEvent(
                frame: frame, kind: .powerUpStarted,
                actorID: body.actorID, moveID: move.id, amount: 480))
        }
        return true
    }

    private func moveRootMotionXBeforeActive(_ move: CombatMoveDefinition) -> Double {
        guard move.startupFrames > 0 else { return 0 }
        return (move.rootMotion ?? []).reduce(0) { total, motion in
            let start = max(0, motion.active.start)
            let end = min(move.startupFrames - 1, motion.active.end)
            guard end >= start else { return total }
            return total + Double(end - start + 1) * motion.deltaPerFrame.x
        }
    }

    private func commandSpecificity(_ command: CombatCommand) -> Int {
        command.steps.reduce(command.steps.count * 1_000) { score, step in
            score + (step.direction == nil ? 0 : 100) +
                step.requiredButtons.count * 10 + step.minimumHoldFrames
        }
    }

    private func advanceMove(_ body: inout CombatBodyState, profile: CombatProfile,
                             events: inout [CombatEvent]) {
        guard var timeline = body.actionTimeline else {
            if body.stunFrames == 0 { body.phase = .neutral }
            return
        }
        guard timeline.definition.domain == .combat else { return }
        guard let move = profile.move(id: timeline.definition.actionID) else {
            body.actionTimeline = nil
            if body.stunFrames == 0 { body.phase = .neutral }
            return
        }
        switch timeline.phase {
        case .startup: body.phase = .startup
        case .active: body.phase = .active
        case .recovery: body.phase = .recovery
        case .finished, .cancelled:
            if timeline.phase == .finished,
               body.hitTargets.isEmpty,
               !move.hit.attackBoxes.isEmpty,
               move.authoredProjectiles.isEmpty {
                RuntimeLogger.shared.debug(
                    "combat.move",
                    "frame=\(frame) kind=whiff actor=\(body.actorID.raw) move=\(move.id) x=\(String(format: "%.1f", body.position.x)) nearestDX=\(nearestOpponentHorizontalDistance(from: body).map { String(format: "%.1f", $0) } ?? "-")")
            }
            body.actionTimeline = nil
            body.hitTargets.removeAll()
            body.hitLedger.removeAll()
            body.phase = .neutral
            return
        }

        let rootMotion = timeline.rootMotionDelta
        if rootMotion.x != 0 {
            body.position.x += rootMotion.x * body.visualScale * body.facing.sign
        }
        if rootMotion.y != 0, body.locomotion != .grounded {
            body.position.y += rootMotion.y * body.visualScale
        }

        for definition in move.authoredProjectiles where timeline.frame == definition.spawnFrame {
            spawnProjectile(
                definition, move: move, timeline: timeline,
                owner: body, events: &events)
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
                               input: FighterInputFrame,
                               previousInput: FighterInputFrame,
                               events: inout [CombatEvent]) {
        switch body.healthState {
        case .active:
            if body.locomotion == .airborne,
               (1...12).contains(body.stunFrames),
               body.combo.juggleRemaining > 0,
               body.lastRecoveryChoice != .air,
               !input.buttons.subtracting(previousInput.buttons).isEmpty {
                body.stunFrames = 0
                body.phase = .neutral
                body.lastRecoveryChoice = .air
                body.invulnerabilityFrames = max(body.invulnerabilityFrames, 10)
                body.velocity.x = input.forward(facing: body.facing) ? 3.5 * body.facing.sign :
                    (input.back(facing: body.facing) ? -3.5 * body.facing.sign : 0)
                body.velocity.y = min(body.velocity.y, -2.5)
                events.append(CombatEvent(
                    frame: frame, kind: .airTech,
                    actorID: body.actorID, moveID: RecoveryChoice.air.rawValue))
            }
        case .knockedOut:
            break
        case .downed:
            if body.locomotion == .grounded {
                body.velocity.x = 0
                body.velocity.y = 0
                if body.recoveryFramesRemaining > 0 { body.recoveryFramesRemaining -= 1 }
                if body.recoveryFramesRemaining == 0 {
                    let choice: RecoveryChoice
                    if input.down, body.lastRecoveryChoice != .delayed {
                        body.lastRecoveryChoice = .delayed
                        body.recoveryFramesRemaining = 30
                        events.append(CombatEvent(
                            frame: frame, kind: .recoverySelected,
                            actorID: body.actorID, moveID: RecoveryChoice.delayed.rawValue))
                        return
                    } else if input.forward(facing: body.facing) {
                        choice = .forward
                        body.position.x += 28 * body.facing.sign
                    } else if input.back(facing: body.facing) {
                        choice = .backward
                        body.position.x -= 28 * body.facing.sign
                    } else {
                        choice = .neutral
                    }
                    body.lastRecoveryChoice = choice
                    body.healthState = .gettingUp
                    body.recoveryFramesRemaining = profile.getUpFrames
                    var combo = body.combo
                    combo.end(reason: .recovered)
                    body.combo = combo
                    events.append(CombatEvent(
                        frame: frame, kind: .recoverySelected,
                        actorID: body.actorID, moveID: choice.rawValue))
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
                body.lastRecoveryChoice = nil
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
            .filter({
                $0.actorID != body.actorID && $0.healthState == .active &&
                    $0.rosterRole != .bench && permitsContact(body.actorID, $0.actorID)
            })
            .min(by: {
                abs($0.position.x - body.position.x) <
                abs($1.position.x - body.position.x)
            }) else { return }
        let horizontalDistance = abs(target.position.x - body.position.x)
        guard horizontalDistance > 0.001 else { return }

        // At body contact, the push solver may move either fighter by a
        // fraction of a pixel while preserving the same side. Re-facing from
        // that noisy snapshot makes two neutral fighters turn every frame.
        // Explicit player/CPU input still owns facing; this guard only adds
        // hysteresis to the automatic neutral-orientation fallback.
        let contactBand = (profiles[body.actorID.raw]?.pushRadius ?? 24) +
            (profiles[target.actorID.raw]?.pushRadius ?? 24) + 4
        guard horizontalDistance > contactBand else { return }
        body.facing = target.position.x >= body.position.x ? .right : .left
    }

    private func save(_ body: CombatBodyState) {
        rules[body.actorID.raw] = body.rules
        bodyWorld.update(body.actorID) { $0 = body.body }
    }

    private func spawnProjectile(
        _ definition: ProjectileDefinition,
        move: CombatMoveDefinition,
        timeline: ActionTimeline,
        owner: CombatBodyState,
        events: inout [CombatEvent]
    ) {
        guard featurePolicy.projectilesEnabled else { return }
        let entityID = EntityID(
            "projectile:\(owner.actorID.raw):\(timeline.instanceID):\(definition.id)")
        guard projectiles[entityID.raw] == nil else { return }
        let facing = owner.facing
        let position = Vec2(
            x: owner.position.x + definition.spawnOffset.x * facing.sign,
            y: owner.position.y + definition.spawnOffset.y)
        let velocity = Vec2(
            x: definition.velocity.x * facing.sign,
            y: definition.velocity.y)
        bodyWorld.register(
            BodyDefinition(
                entityID: entityID,
                pushRadius: 1,
                visualScale: owner.visualScale,
                pushEnabled: false,
                collisionMask: definition.collisionMask,
                gravityScale: 0),
            state: BodyState(
                entityID: entityID,
                position: position,
                velocity: velocity,
                facing: facing,
                locomotion: .airborne))
        projectiles[entityID.raw] = CombatProjectileState(
            entityID: entityID,
            ownerID: owner.actorID,
            moveID: move.id,
            moveInstanceID: timeline.instanceID,
            definition: definition,
            spawnedAtFrame: frame,
            previousPosition: position)
        events.append(CombatEvent(
            frame: frame, kind: .projectileSpawned,
            actorID: owner.actorID, targetID: entityID, moveID: move.id))
    }

    private func resolveHits(
        environment: BodyEnvironment,
        events: inout [CombatEvent]
    ) {
        // Detect against one immutable frame snapshot first. Resolution happens only
        // after every legal contact is known, so A<->B trades are independent of
        // actor iteration order.
        let snapshot = Dictionary(uniqueKeysWithValues: self.snapshot().bodies.map {
            ($0.actorID.raw, $0)
        })
        resolveProjectileClashes(events: &events)
        let ids = snapshot.keys.sorted()
        var pending: [PendingHit] = []
        var attacks: [String: ActiveAttack] = [:]

        for attackerID in ids {
            guard let attacker = snapshot[attackerID],
                  attacker.rosterRole != .bench,
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
                guard permitsContact(first.actor.actorID, EntityID(secondID)),
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
                guard permitsContact(attack.actor.actorID, EntityID(defenderID)),
                      !clashedDirections.contains("\(attackerID)>\(defenderID)"),
                      canRehit,
                      let defender = snapshot[defenderID],
                      defender.rosterRole != .bench,
                      defender.invulnerabilityFrames == 0,
                      defender.healthState == .active,
                      defender.locomotion != .dragged,
                      let defenderProfile = profiles[defenderID] else { continue }
                if defender.locomotion == .airborne,
                   attack.move.effectiveResourceRules.juggleCost >
                    defender.combo.juggleRemaining { continue }
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
                    moveID: attack.move.id,
                    definition: attack.definition,
                    ledgerKey: ledgerKey,
                    guarding: guarding,
                    projectileID: nil))
            }
        }

        for projectileID in projectiles.keys.sorted() {
            guard let projectile = projectiles[projectileID],
                  projectile.definition.collisionMask.contains(.hurt),
                  let projectileBody = bodyWorld.state(for: projectile.entityID),
                  let owner = snapshot[projectile.ownerID.raw] else { continue }
            let scale = bodyWorld.definition(for: projectile.entityID)?.visualScale ?? 1
            let startRects = projectile.definition.hit.attackBoxes.map {
                $0.placed(
                    at: projectile.previousPosition,
                    facing: projectileBody.facing,
                    scale: scale)
            }
            let displacement = Vec2(
                x: projectileBody.position.x - projectile.previousPosition.x,
                y: projectileBody.position.y - projectile.previousPosition.y)
            var projectileHits: [(time: Double, hit: PendingHit)] = []
            for defenderID in ids where defenderID != projectile.ownerID.raw {
                let ledgerKey = "\(projectile.moveInstanceID)|\(projectile.definition.hit.hitGroup)|\(defenderID)"
                let lastHitFrame = projectile.hitLedger[ledgerKey]
                let canRehit = lastHitFrame == nil || projectile.definition.hit.rehitFrames.map {
                    frame - (lastHitFrame ?? frame) >= Int64($0)
                } == true
                guard permitsContact(projectile.ownerID, EntityID(defenderID)),
                      canRehit,
                      let defender = snapshot[defenderID],
                      defender.rosterRole != .bench,
                      defender.invulnerabilityFrames == 0,
                      defender.healthState == .active,
                      defender.locomotion != .dragged,
                      let defenderProfile = profiles[defenderID] else { continue }
                let projectileMove = profiles[projectile.ownerID.raw]?
                    .move(id: projectile.moveID)
                if defender.locomotion == .airborne,
                   (projectileMove?.effectiveResourceRules.juggleCost ?? 0) >
                    defender.combo.juggleRemaining { continue }
                let hurtRects = defenderProfile.hurtBoxes.map {
                    $0.placed(at: defender.position, facing: defender.facing, scale: defender.visualScale)
                }
                let contactTimes = startRects.flatMap { attackRect in
                    hurtRects.compactMap { hurtRect -> Double? in
                        if attackRect.overlaps(hurtRect) { return 0 }
                        return attackRect.sweep(
                            displacement: displacement,
                            against: hurtRect)?.time
                    }
                }
                guard let contactTime = contactTimes.min() else { continue }
                let input = inputs[defenderID] ?? .neutral
                let attackerIsRight = owner.position.x > defender.position.x
                let guarding = guardMatches(
                    projectile.definition.hit.attackHeight,
                    input: input,
                    holdingBack: attackerIsRight ? input.left : input.right,
                    defender: defender)
                projectileHits.append((contactTime, PendingHit(
                    attackerID: projectile.ownerID.raw,
                    defenderID: defenderID,
                    moveID: projectile.moveID,
                    definition: projectile.definition.hit,
                    ledgerKey: ledgerKey,
                    guarding: guarding,
                    projectileID: projectileID)))
            }
            projectileHits.sort {
                $0.time == $1.time
                    ? $0.hit.defenderID < $1.hit.defenderID
                    : $0.time < $1.time
            }
            if projectile.definition.destroyOnHit {
                pending.append(contentsOf: projectileHits.prefix(1).map(\.hit))
            } else {
                pending.append(contentsOf: projectileHits.map(\.hit))
            }
        }

        // Mark every attacker's contact before mutating defenders. This preserves
        // per-move hit de-duplication even when multiple actors trade on one frame.
        for hit in pending {
            if let projectileID = hit.projectileID,
               var projectile = projectiles[projectileID] {
                projectile.hitLedger[hit.ledgerKey] = frame
                projectiles[projectileID] = projectile
            }
            guard var attacker = body(for: EntityID(hit.attackerID)) else { continue }
            attacker.hitTargets.insert(hit.defenderID)
            attacker.hitLedger[hit.ledgerKey] = frame
            attacker.hitStopFrames = max(attacker.hitStopFrames, hit.definition.hitStopFrames)
            save(attacker)
        }

        for hit in pending.sorted(by: {
            $0.defenderID == $1.defenderID
                ? ($0.attackerID == $1.attackerID
                    ? ($0.projectileID ?? "") < ($1.projectileID ?? "")
                    : $0.attackerID < $1.attackerID)
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
                    moveID: hit.moveID, amount: definition.chipDamage))
            } else {
                let moveRules = profiles[hit.attackerID]?.move(id: hit.moveID)?
                    .effectiveResourceRules ?? MoveResourceRules()
                var combo = defender.combo
                let poweredDamage = attackerAtDetection.powerUpFrames > 0
                    ? Int((Double(definition.damage) * 1.10).rounded(.down))
                    : definition.damage
                let scaled = combo.recordHit(
                    attackerID: attackerAtDetection.actorID,
                    defenderID: defender.actorID,
                    moveID: hit.moveID,
                    baseDamage: poweredDamage,
                    baseHitStun: definition.hitStunFrames,
                    juggleCost: moveRules.juggleCost,
                    frame: frame)
                defender.combo = combo
                defender.lastRecoveryChoice = nil
                defender.hp = max(0, defender.hp - scaled.damage)
                defender.actionTimeline = nil
                defender.hitTargets.removeAll()
                defender.phase = .hitStun
                defender.stunFrames = max(defender.stunFrames, scaled.hitStunFrames)
                defender.hitStopFrames = max(defender.hitStopFrames, definition.hitStopFrames)
                defender.velocity.x = definition.knockbackX * attackerAtDetection.facing.sign
                defender.velocity.y = definition.knockbackY
                if definition.knockbackY < 0 {
                    defender.currentSurfaceID = nil
                    defender.surfaceFraction = nil
                    defender.locomotion = .airborne
                }
                let reachesWall = defender.position.x + defender.velocity.x <= environment.bounds.minX ||
                    defender.position.x + defender.velocity.x >= environment.bounds.maxX
                if definition.wallBounce, reachesWall, combo.consumeWallBounce() {
                    defender.velocity.x *= -0.72
                    defender.combo = combo
                    events.append(CombatEvent(
                        frame: frame, kind: .wallBounce,
                        actorID: defender.actorID,
                        targetID: attackerAtDetection.actorID,
                        moveID: hit.moveID))
                }
                if definition.groundBounce,
                   defender.locomotion == .grounded,
                   combo.consumeGroundBounce() {
                    defender.velocity.y = -max(2.5, abs(definition.knockbackY))
                    defender.currentSurfaceID = nil
                    defender.surfaceFraction = nil
                    defender.locomotion = .airborne
                    defender.combo = combo
                    events.append(CombatEvent(
                        frame: frame, kind: .groundBounce,
                        actorID: defender.actorID,
                        targetID: attackerAtDetection.actorID,
                        moveID: hit.moveID))
                }
                events.append(CombatEvent(
                    frame: frame, kind: .hit,
                    actorID: attackerAtDetection.actorID, targetID: defender.actorID,
                    moveID: hit.moveID, amount: scaled.damage))
                events.append(CombatEvent(
                    frame: frame, kind: .comboAdvanced,
                    actorID: attackerAtDetection.actorID, targetID: defender.actorID,
                    moveID: hit.moveID, amount: combo.hitCount))
            }

            let resource = profiles[hit.attackerID]?.move(id: hit.moveID)?
                .effectiveResourceRules ?? MoveResourceRules()
            if var attacker = body(for: attackerAtDetection.actorID) {
                var energy = attacker.gameplayEnergy
                let gain = featurePolicy.scaledGain(
                    hit.guarding ? resource.onGuardGain : resource.onHitGain)
                energy.gain(gain)
                attacker.gameplayEnergy = energy
                save(attacker)
                events.append(CombatEvent(
                    frame: frame, kind: .energyGained,
                    actorID: attacker.actorID, moveID: hit.moveID,
                    amount: gain))
            }
            var defenderEnergy = defender.gameplayEnergy
            defenderEnergy.gain(featurePolicy.scaledGain(resource.defenderGain))
            defender.gameplayEnergy = defenderEnergy

            if defenderWasAlive && defender.hp == 0 {
                defender.healthState = .knockedOut
                defender.phase = .hitStun
                // A zero-vertical-knockback finishing blow used to transition
                // grounded -> downed in the same frame, so the fighter never
                // visibly fell. Force a short knockdown arc; landing owns the
                // transition to the persistent downed pose.
                if defender.locomotion == .grounded {
                    defender.currentSurfaceID = nil
                    defender.surfaceFraction = nil
                    defender.locomotion = .airborne
                    if defender.velocity.y >= 0 {
                        defender.velocity.y = -3.2
                    }
                } else if definition.knockbackY < 0 {
                    defender.currentSurfaceID = nil
                    defender.surfaceFraction = nil
                }
                events.append(CombatEvent(
                    frame: frame, kind: .knockedOut,
                    actorID: defender.actorID,
                    targetID: attackerAtDetection.actorID,
                    moveID: hit.moveID))
            }
            if !hit.guarding,
               defender.participation == .uninvolved || {
                   if case .alerted = defender.participation { return true }
                   return false
               }() {
                let parentDepth = escalation.cascadeDepth(
                    for: attackerAtDetection.actorID)
                escalation.recordCollateralHit(
                    victimID: defender.actorID,
                    offenderID: attackerAtDetection.actorID,
                    offenderTeamID: teamID(for: attackerAtDetection.actorID),
                    damage: events.last(where: {
                        $0.kind == .hit && $0.actorID == attackerAtDetection.actorID &&
                            $0.targetID == defender.actorID
                    })?.amount ?? definition.damage,
                    frame: frame, cascadeDepth: max(0, parentDepth + 1))
                defender.participation = .alerted(offenderID: attackerAtDetection.actorID)
                events.append(CombatEvent(
                    frame: frame, kind: .neutralAlerted,
                    actorID: defender.actorID, targetID: attackerAtDetection.actorID))
            }
            save(defender)
        }

        for projectileID in Set(pending.compactMap(\.projectileID)).sorted() {
            guard projectiles[projectileID]?.definition.destroyOnHit == true else { continue }
            removeProjectile(projectileID, events: &events)
        }
    }

    private func resolveProjectileClashes(events: inout [CombatEvent]) {
        let ids = projectiles.keys.sorted()
        var destroyed: Set<String> = []
        for (offset, leftID) in ids.enumerated() {
            guard !destroyed.contains(leftID),
                  let left = projectiles[leftID],
                  left.definition.hit.clashLevel > 0,
                  let leftBody = bodyWorld.state(for: left.entityID)
            else { continue }
            for rightID in ids.dropFirst(offset + 1) {
                guard !destroyed.contains(rightID),
                      let right = projectiles[rightID],
                      right.ownerID != left.ownerID,
                      right.definition.hit.clashLevel == left.definition.hit.clashLevel,
                      permitsContact(left.ownerID, right.ownerID),
                      let rightBody = bodyWorld.state(for: right.entityID)
                else { continue }
                let leftRects = left.definition.hit.attackBoxes.map {
                    $0.placed(at: left.previousPosition, facing: leftBody.facing)
                }
                let rightRects = right.definition.hit.attackBoxes.map {
                    $0.placed(at: right.previousPosition, facing: rightBody.facing)
                }
                let relativeDisplacement = Vec2(
                    x: (leftBody.position.x - left.previousPosition.x) -
                        (rightBody.position.x - right.previousPosition.x),
                    y: (leftBody.position.y - left.previousPosition.y) -
                        (rightBody.position.y - right.previousPosition.y))
                let collided = leftRects.contains { leftRect in
                    rightRects.contains { rightRect in
                        leftRect.overlaps(rightRect) ||
                            leftRect.sweep(
                                displacement: relativeDisplacement,
                                against: rightRect) != nil
                    }
                }
                guard collided else { continue }
                destroyed.insert(leftID)
                destroyed.insert(rightID)
                events.append(CombatEvent(
                    frame: frame, kind: .clash,
                    actorID: left.ownerID, targetID: right.ownerID,
                    moveID: left.moveID))
                break
            }
        }
        for id in destroyed.sorted() {
            removeProjectile(id, events: &events)
        }
    }

    private func expireProjectiles(environment: BodyEnvironment, events: inout [CombatEvent]) {
        for id in projectiles.keys.sorted() {
            guard var projectile = projectiles[id],
                  let body = bodyWorld.state(for: projectile.entityID) else {
                projectiles[id] = nil
                continue
            }
            let age = frame - projectile.spawnedAtFrame + 1
            let outside = (body.position.x <= environment.bounds.minX && body.velocity.x < 0) ||
                (body.position.x >= environment.bounds.maxX && body.velocity.x > 0) ||
                (body.position.y <= environment.bounds.minY && body.velocity.y < 0) ||
                (body.position.y >= environment.bounds.maxY && body.velocity.y > 0)
            let exhaustedRange = projectile.definition.maxTravelDistance.map {
                projectile.travelledDistance >= $0
            } ?? false
            if age >= Int64(projectile.definition.lifetimeFrames) || outside || exhaustedRange {
                removeProjectile(id, events: &events)
            } else {
                projectile.previousPosition = body.position
                projectiles[id] = projectile
            }
        }
    }

    private func clampProjectilesToAuthoredRange() {
        for id in projectiles.keys.sorted() {
            guard var projectile = projectiles[id],
                  var body = bodyWorld.state(for: projectile.entityID) else { continue }
            let dx = body.position.x - projectile.previousPosition.x
            let dy = body.position.y - projectile.previousPosition.y
            let stepDistance = hypot(dx, dy)
            if let limit = projectile.definition.maxTravelDistance,
               projectile.travelledDistance >= limit {
                body.position = projectile.previousPosition
                body.velocity = Vec2()
                bodyWorld.update(projectile.entityID) { $0 = body }
                projectiles[id] = projectile
                continue
            }
            guard stepDistance > 0 else { continue }
            if let limit = projectile.definition.maxTravelDistance {
                let remaining = max(0, limit - projectile.travelledDistance)
                if stepDistance > remaining {
                    let fraction = remaining / stepDistance
                    body.position = Vec2(
                        x: projectile.previousPosition.x + dx * fraction,
                        y: projectile.previousPosition.y + dy * fraction)
                    body.velocity = Vec2()
                    bodyWorld.update(projectile.entityID) { $0 = body }
                    projectile.travelledDistance = limit
                } else {
                    projectile.travelledDistance += stepDistance
                }
            } else {
                projectile.travelledDistance += stepDistance
            }
            projectiles[id] = projectile
        }
    }

    private func removeProjectile(_ id: String, events: inout [CombatEvent]) {
        guard let projectile = projectiles.removeValue(forKey: id) else { return }
        bodyWorld.unregister(projectile.entityID)
        events.append(CombatEvent(
            frame: frame, kind: .projectileExpired,
            actorID: projectile.ownerID,
            targetID: projectile.entityID,
            moveID: projectile.moveID))
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

    private func permitsContact(_ attackerID: EntityID, _ defenderID: EntityID) -> Bool {
        if let attackerTeam = teamID(for: attackerID),
           attackerTeam == teamID(for: defenderID) { return false }
        if let attacker = rules[attackerID.raw] {
            switch attacker.participation ?? .uninvolved {
            case .incidentalCombatant(let offenderID):
                return offenderID == defenderID || escalation.isHostile(
                    actorID: attackerID, toward: defenderID,
                    candidateTeamID: teamID(for: defenderID))
            case .alerted(let offenderID):
                return offenderID == defenderID
            case .uninvolved, .withdrawing: break
            case .rosterParticipant: break
            }
        }
        if session?.permits(attackerID, defenderID) == true { return true }
        guard escalation.policy.enabled,
              session?.state == .active,
              session?.participantIDs.contains(attackerID) == true,
              let defender = rules[defenderID.raw],
              defender.rosterRole != .bench else { return false }
        switch defender.participation ?? .uninvolved {
        case .uninvolved, .alerted, .incidentalCombatant: return true
        case .withdrawing, .rosterParticipant: return false
        }
    }

    private func teamID(for actorID: EntityID) -> String? {
        teams.values.first {
            $0.activeID == actorID || $0.benchID == actorID
        }?.teamID
    }

    public func expandedParticipants(for controlledIDs: [EntityID]) -> [EntityID] {
        var result = Set(controlledIDs)
        for team in teams.values
        where result.contains(team.activeID) || result.contains(team.benchID) {
            result.insert(team.activeID)
            result.insert(team.benchID)
        }
        return result.sorted { $0.raw < $1.raw }
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
