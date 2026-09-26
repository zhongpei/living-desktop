import Foundation
import MyPet2D
import MyPetCombat
import MyPetCore

private struct ScoredMove {
    var move: CombatMoveDefinition
    var score: Double
}

/// Stateful classic game CPU. It observes delayed snapshots, performs reflexes,
/// plans terrain at a slower cadence, ranks legal moves, optionally runs bounded
/// deterministic look-ahead, then emits only FighterInput frames.
public struct ClassicCombatCPU: Sendable {
    private var state: ClassicCombatCPUCheckpoint

    public init(
        actorID: EntityID,
        difficulty: CombatCPUDifficulty = .normal,
        seed: UInt64
    ) {
        state = ClassicCombatCPUCheckpoint(
            actorID: actorID,
            configuration: difficulty.configuration,
            rng: DeterministicCPURNG(seed: seed),
            history: [], pendingInputs: [], targetID: nil, slot: nil,
            lastDecisionFrame: .min,
            lastOutput: CombatCPUOutputCheckpoint(), recentMoves: [],
            lastIssuedInput: .neutral, surfaceGraph: nil, actionHistory: ActionHistory(),
            moveUseCounts: [:], nextAttackFrame: nil,
            lastCounteredHitFrame: nil)
    }

    public init(checkpoint: ClassicCombatCPUCheckpoint) {
        state = checkpoint
    }

    public func checkpoint() -> ClassicCombatCPUCheckpoint { state }
    public var reservedSlot: EngagementSlot? {
        guard let slot = state.slot, slot.targetID == state.targetID else { return nil }
        return slot
    }

    public mutating func advance(_ observation: CPUCombatObservation) -> CombatCPUOutput {
        record(opponents: observation.opponents, frame: observation.frame)

        guard observation.selfBody.healthState == .active,
              observation.selfBody.locomotion != .dragged,
              observation.selfBody.locomotion != .tossed else {
            state.pendingInputs.removeAll()
            state.targetID = nil
            state.slot = nil
            return issue(.neutral, intent: .wait)
        }

        let counterOpportunity = observation.recentHitFrame.map {
            $0 != state.lastCounteredHitFrame
        } ?? false
        let burstPressure = observation.selfBody.combo.hitCount >= 2 ||
            observation.selfBody.hp * 100 <= observation.selfProfile.maxHP * 30
        if burstPressure,
           (observation.selfBody.phase == .hitStun ||
                observation.selfBody.phase == .blockStun),
           let burst = observation.selfProfile.moves.first(where: {
               $0.systemControl == .defensiveBurst &&
                   observation.selfBody.gameplayEnergy.current >=
                       $0.effectiveResourceRules.startCost
           }) {
            if state.lastOutput.moveID == burst.id {
                return issue(.neutral, intent: .wait, targetID: state.targetID)
            }
            if state.moveUseCounts == nil { state.moveUseCounts = [:] }
            state.moveUseCounts?[burst.id, default: 0] += 1
            var history = state.actionHistory ?? ActionHistory()
            history.record(id: burst.id, family: .burst)
            state.actionHistory = history
            if counterOpportunity {
                state.lastCounteredHitFrame = observation.recentHitFrame
            }
            state.lastOutput = CombatCPUOutputCheckpoint(
                intent: .attack, targetID: state.targetID,
                moveID: burst.id, utilityScore: 1_000, usedSearch: false)
            return issue(
                FighterInputFrame(systemControls: [.defensiveBurst]),
                from: state.lastOutput)
        }

        if !state.pendingInputs.isEmpty {
            return issue(state.pendingInputs.removeFirst(), from: state.lastOutput)
        }

        let perceived = perceivedOpponents()
        let mobility = SurfaceMobility(
            walkSpeed: observation.selfProfile.walkSpeed,
            runSpeedMultiplier: observation.selfProfile.effectiveRunSpeedMultiplier,
            jumpVelocity: observation.selfProfile.jumpVelocity,
            maximumJumpCount: observation.selfProfile.effectiveMaxJumpCount)
        let graphFingerprint = DynamicSurfaceGraph.fingerprint(
            environment: observation.environment, mobility: mobility)
        if state.surfaceGraph?.fingerprint != graphFingerprint {
            state.surfaceGraph = DynamicSurfaceGraph.build(
                environment: observation.environment, mobility: mobility)
        }
        let graph = state.surfaceGraph ?? DynamicSurfaceGraph.build(
            environment: observation.environment, mobility: mobility)
        let target = selectTarget(
            selfBody: observation.selfBody,
            opponents: perceived,
            graph: graph,
            reservations: observation.engagementReservations)
        let previousTargetID = state.targetID
        state.targetID = target?.actorID
        if state.slot?.targetID != state.targetID {
            state.slot = nil
        }
        if previousTargetID != state.targetID {
            state.navigationPlan = nil
        }
        guard let target else {
            state.slot = nil
            return issue(.neutral, intent: .wait)
        }
        let targetProfile = observation.opponentProfiles[target.actorID.raw]

        let distance = abs(target.position.x - observation.selfBody.position.x)
        if target.phase == .active,
           activeAttackThreatens(
                attacker: target,
                attackerProfile: targetProfile,
                defender: observation.selfBody,
                defenderProfile: observation.selfProfile) {
            let back = target.position.x >= observation.selfBody.position.x
                ? FighterInputFrame(left: true)
                : FighterInputFrame(right: true)
            return issue(back, intent: .guard, targetID: target.actorID)
        }

        guard observation.selfBody.canAcceptAction else {
            return issue(.neutral, intent: .wait, targetID: target.actorID)
        }
        let decisionInterval = max(
            1, Int((Double(state.configuration.decisionIntervalFrames) /
                observation.pacingRate).rounded(.up)))
        let decisionDue = state.lastDecisionFrame == .min ||
            observation.frame - state.lastDecisionFrame >= Int64(decisionInterval)
        guard decisionDue else {
            return issue(sustainedInput(state.lastIssuedInput), from: state.lastOutput)
        }
        state.lastDecisionFrame = observation.frame
        let punishWindow = target.phase == .recovery || target.stunFrames > 0
        let attackReady = observation.frame >= (state.nextAttackFrame ?? .min) ||
            punishWindow || counterOpportunity

        if attackReady,
           !counterOpportunity,
           observation.selfBody.powerUpFrames == 0,
           observation.selfBody.gameplayEnergy.current >= 240,
           observation.selfBody.gameplayEnergy.current <
               observation.selfBody.gameplayEnergy.maximum,
           distance >= 260,
           target.phase != .active,
           state.rng.chance(percent: 12),
           let powerUp = observation.selfProfile.moves.first(where: {
               $0.systemControl == .powerUp &&
                   observation.selfBody.gameplayEnergy.current >=
                       $0.effectiveResourceRules.startCost
           }) {
            state.lastOutput = CombatCPUOutputCheckpoint(
                intent: .attack, targetID: target.actorID,
                moveID: powerUp.id, utilityScore: 1_000, usedSearch: false)
            var history = state.actionHistory ?? ActionHistory()
            history.record(id: powerUp.id, family: .powerUp)
            state.actionHistory = history
            state.moveUseCounts?[powerUp.id, default: 0] += 1
            scheduleAttackThrottle(after: powerUp, observation: observation)
            return issue(
                FighterInputFrame(systemControls: [.powerUp]),
                from: state.lastOutput)
        }

        let slot = engagementSlot(
            selfBody: observation.selfBody, target: target,
            profile: observation.selfProfile,
            targetProfile: targetProfile,
            occupied: observation.engagementReservations)
        state.slot = slot
        if let navigation = navigationInput(
            observation: observation,
            target: target,
            slot: slot,
            graph: graph) {
            return issue(
                navigation.input, intent: navigation.intent,
                targetID: target.actorID, slot: slot)
        }

        var candidates = attackReady ? scoreMoves(
            profile: observation.selfProfile,
            selfBody: observation.selfBody,
            target: target,
            targetProfile: targetProfile,
            environment: observation.environment,
            tactics: observation.tactics,
            recentlyHit: counterOpportunity,
            worldCheckpoint: observation.worldCheckpoint) : []
        if candidates.isEmpty {
            return approach(
                selfBody: observation.selfBody, target: target, slot: slot)
        }
        // Variety stays a soft utility prior. Never reorder every unseen move
        // ahead of a tactically better familiar move.
        candidates = Array(candidates.prefix(state.configuration.topK))
        let useSearch = state.configuration.searchIterations > 0 &&
            observation.worldCheckpoint != nil
        if useSearch {
            candidates = ShallowCombatSearch.rank(
                candidates: candidates,
                actorID: observation.selfBody.actorID,
                targetID: target.actorID,
                observation: observation,
                iterations: state.configuration.searchIterations,
                horizon: state.configuration.predictionFrames,
                rng: &state.rng)
        }
        let selected: ScoredMove
        if candidates.count > 1, state.rng.chance(percent: state.configuration.mistakePercent) {
            selected = candidates[min(1, candidates.count - 1)]
        } else {
            selected = candidates[0]
        }
        if let control = selected.move.systemControl {
            state.pendingInputs = [FighterInputFrame(systemControls: [control]), .neutral]
        } else {
            state.pendingInputs = CombatCommandSynthesizer.frames(
                for: selected.move.command, facing: observation.selfBody.facing)
        }
        state.recentMoves.append(selected.move.id)
        if state.moveUseCounts == nil { state.moveUseCounts = [:] }
        state.moveUseCounts?[selected.move.id, default: 0] += 1
        state.recentMoves = Array(state.recentMoves.suffix(
            max(4, observation.selfProfile.moves.count)))
        var history = state.actionHistory ?? ActionHistory()
        history.record(
            id: selected.move.id,
            family: selected.move.effectiveResourceRules.family)
        state.actionHistory = history
        scheduleAttackThrottle(after: selected.move, observation: observation)
        if counterOpportunity {
            state.lastCounteredHitFrame = observation.recentHitFrame
        }
        state.lastOutput = CombatCPUOutputCheckpoint(
            intent: .attack, targetID: target.actorID, slot: slot,
            moveID: selected.move.id, utilityScore: selected.score,
            usedSearch: useSearch)
        return issue(state.pendingInputs.removeFirst(), from: state.lastOutput)
    }

    private mutating func record(opponents: [CombatBodyState], frame: Int64) {
        state.history.append(DelayedOpponent(
            frame: frame,
            bodies: opponents.sorted { $0.actorID.raw < $1.actorID.raw }))
        let limit = state.configuration.perceptionDelayFrames + 2
        if state.history.count > limit {
            state.history.removeFirst(state.history.count - limit)
        }
    }

    private func perceivedOpponents() -> [CombatBodyState] {
        let index = max(0, state.history.count - 1 - state.configuration.perceptionDelayFrames)
        return state.history[index].bodies.filter { $0.healthState == .active }
    }

    private func selectTarget(
        selfBody: CombatBodyState,
        opponents: [CombatBodyState],
        graph: DynamicSurfaceGraph,
        reservations: [EngagementSlot]
    ) -> CombatBodyState? {
        opponents.max { lhs, rhs in
            let l = targetScore(
                lhs, from: selfBody,
                graph: graph, reservations: reservations)
            let r = targetScore(
                rhs, from: selfBody,
                graph: graph, reservations: reservations)
            return l == r ? lhs.actorID.raw > rhs.actorID.raw : l < r
        }
    }

    private func targetScore(
        _ target: CombatBodyState,
        from selfBody: CombatBodyState,
        graph: DynamicSurfaceGraph,
        reservations: [EngagementSlot]
    ) -> Double {
        let distance = abs(target.position.x - selfBody.position.x)
        let threat = target.phase == .active ? 80.0 : 0
        let vulnerability = target.phase == .recovery || target.stunFrames > 0 ? 60.0 : 0
        let lowHP = Double(max(0, 1000 - target.hp)) * 0.03
        let sameSurface = target.currentSurfaceID == selfBody.currentSurfaceID ? 35.0 : 0
        let pathCost: Double
        if let from = selfBody.currentSurfaceID, let to = target.currentSurfaceID {
            pathCost = graph.path(from: from, to: to)?.totalCost ?? 2_000
        } else {
            pathCost = distance / 2
        }
        let crowdPenalty = Double(reservations.filter {
            $0.targetID == target.actorID
        }.count) * 45
        return threat + vulnerability + lowHP + sameSurface - distance * 0.08 -
            pathCost * 0.04 - crowdPenalty
    }

    private func engagementSlot(
        selfBody: CombatBodyState,
        target: CombatBodyState,
        profile: CombatProfile,
        targetProfile: CombatProfile?,
        occupied: [EngagementSlot]
    ) -> EngagementSlot {
        let bodyContact = profile.pushRadius +
            (targetProfile?.pushRadius ?? profile.pushRadius) + 4
        // Movement closes to body-contact spacing. Attack reach may allow an
        // earlier strike, but must never become a "stop walking" distance.
        let near = max(48, bodyContact)
        let nearSides: [EngagementSide]
        let farSides: [EngagementSide]
        if selfBody.position.x < target.position.x {
            nearSides = [.leftNear, .rightNear]
            farSides = [.leftFar, .rightFar]
        } else if selfBody.position.x > target.position.x {
            nearSides = [.rightNear, .leftNear]
            farSides = [.rightFar, .leftFar]
        } else {
            let nearOrder: [EngagementSide] = [.leftNear, .rightNear]
            let farOrder: [EngagementSide] = [.leftFar, .rightFar]
            let offset = stableIndex(selfBody.actorID.raw, count: nearOrder.count)
            nearSides = Array(nearOrder[offset...] + nearOrder[..<offset])
            let farOffset = stableIndex(selfBody.actorID.raw + ":far", count: farOrder.count)
            farSides = Array(farOrder[farOffset...] + farOrder[..<farOffset])
        }
        let used = Set(occupied.filter { $0.targetID == target.actorID }.map(\.side))
        // Traditional brawlers reserve contact slots first. The old random
        // rotation could assign the fighter to the opposite side of the
        // target. It then tried to cross through the target, causing pushbox
        // jitter and alternating left/right inputs.
        let ordered = nearSides + farSides
        let side = ordered.first { !used.contains($0) } ?? ordered[0]
        let multiplier = side == .leftFar || side == .rightFar ? 1.75 : 1.0
        let onLeft = side == .leftNear || side == .leftFar
        return EngagementSlot(
            targetID: target.actorID, side: side,
            anchorX: target.position.x + (onLeft ? -near : near) * multiplier)
    }

    private func stableIndex(_ value: String, count: Int) -> Int {
        let hash = value.utf8.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
        return Int(hash % UInt64(max(1, count)))
    }

    private mutating func navigationInput(
        observation: CPUCombatObservation,
        target: CombatBodyState,
        slot: EngagementSlot,
        graph: DynamicSurfaceGraph
    ) -> (input: FighterInputFrame, intent: CombatCPUIntent)? {
        let selfBody = observation.selfBody
        let frame = observation.frame

        if let continuation = continueNavigationPlan(
            selfBody: selfBody,
            profile: observation.selfProfile,
            graph: graph,
            frame: frame) {
            return continuation
        }

        if frame < (state.tacticalSurfaceHoldUntil ?? .min),
           selfBody.currentSurfaceID != target.currentSurfaceID {
            return (.neutral, .wait)
        }

        guard selfBody.locomotion == .grounded,
              let fromID = selfBody.currentSurfaceID else { return nil }

        // Pursuit across screens/platforms always wins over optional terrain
        // tactics. A* may route through several window tops or monitor floors.
        if let toID = target.currentSurfaceID, fromID != toID,
           let path = graph.path(from: fromID, to: toID),
           let edge = path.edges.first {
            return beginTraversal(
                edge: edge,
                goalSurfaceID: toID,
                reason: .chase,
                selfBody: selfBody,
                profile: observation.selfProfile,
                graph: graph,
                frame: frame)
        }

        // When both fighters share a surface, windows become competitive
        // terrain rather than decoration. Only commit when they solve a real
        // projectile/pressure problem.
        if frame >= (state.tacticalNavigationCooldownUntil ?? .min),
           let tactical = tacticalSurfacePlan(
                observation: observation,
                target: target,
                graph: graph),
           let edge = tactical.path.edges.first {
            return beginTraversal(
                edge: edge,
                goalSurfaceID: tactical.surface.id,
                reason: tactical.reason,
                selfBody: selfBody,
                profile: observation.selfProfile,
                graph: graph,
                frame: frame)
        }

        return nil
    }

    private mutating func continueNavigationPlan(
        selfBody: CombatBodyState,
        profile: CombatProfile,
        graph: DynamicSurfaceGraph,
        frame: Int64
    ) -> (input: FighterInputFrame, intent: CombatCPUIntent)? {
        guard var plan = state.navigationPlan else { return nil }
        guard graph.surface(id: plan.goalSurfaceID) != nil,
              let liveTargetSurface = graph.surface(id: plan.targetSurfaceID),
              frame <= plan.commitUntilFrame + 120 else {
            state.navigationPlan = nil
            return nil
        }
        // Window surfaces are dynamic. Follow the current authoritative bounds,
        // not the rectangle captured when the jump started.
        plan.landingLeft = liveTargetSurface.left
        plan.landingRight = liveTargetSurface.right
        state.navigationPlan = plan

        if selfBody.locomotion == .airborne {
            var input = directionalInput(
                fromX: selfBody.position.x,
                landingLeft: plan.landingLeft,
                landingRight: plan.landingRight)
            // Spend the next jump near the apex. Because sustainedInput strips
            // Up, every extra jump is an actual press rather than a held key.
            if plan.jumpsRemaining > 0, selfBody.velocity.y >= -0.25 {
                input.up = true
                plan.jumpsRemaining -= 1
                state.navigationPlan = plan
                return (input, .jump)
            }
            return (input, .navigate)
        }

        guard selfBody.locomotion == .grounded,
              let currentID = selfBody.currentSurfaceID else { return nil }

        if currentID == plan.targetSurfaceID {
            if currentID == plan.goalSurfaceID {
                if plan.reason != .chase {
                    state.tacticalNavigationCooldownUntil = frame + 180
                    state.tacticalSurfaceHoldUntil = frame + 54
                }
                state.navigationPlan = nil
                return nil
            }
            guard let path = graph.path(from: currentID, to: plan.goalSurfaceID),
                  let edge = path.edges.first else {
                state.navigationPlan = nil
                return nil
            }
            return beginTraversal(
                edge: edge,
                goalSurfaceID: plan.goalSurfaceID,
                reason: plan.reason,
                selfBody: selfBody,
                profile: profile,
                graph: graph,
                frame: frame)
        }

        // We landed on an intermediate/unplanned surface. Re-route from the
        // actual authoritative support rather than forcing stale geometry.
        guard let path = graph.path(from: currentID, to: plan.goalSurfaceID),
              let edge = path.edges.first else {
            state.navigationPlan = nil
            return nil
        }
        return beginTraversal(
            edge: edge,
            goalSurfaceID: plan.goalSurfaceID,
            reason: plan.reason,
            selfBody: selfBody,
            profile: profile,
            graph: graph,
            frame: frame)
    }

    private mutating func beginTraversal(
        edge: SurfaceNavigationEdge,
        goalSurfaceID: String,
        reason: CombatNavigationReason,
        selfBody: CombatBodyState,
        profile: CombatProfile,
        graph: DynamicSurfaceGraph,
        frame: Int64
    ) -> (input: FighterInputFrame, intent: CombatCPUIntent) {
        state.navigationPlan = CombatNavigationPlan(
            targetSurfaceID: edge.toSurfaceID,
            goalSurfaceID: goalSurfaceID,
            landingLeft: edge.landingLeft,
            landingRight: edge.landingRight,
            jumpsRemaining: max(0, edge.effectiveRequiredJumpCount - 1),
            reason: reason,
            commitUntilFrame: frame + Int64(max(45, edge.expectedFrames + 45)))

        let safeLaunchX = effectiveLaunchX(
            edge: edge, selfBody: selfBody, profile: profile, graph: graph)
        let dx = safeLaunchX - selfBody.position.x
        if abs(dx) > 8 {
            return (
                dx > 0 ? FighterInputFrame(right: true) : FighterInputFrame(left: true),
                .navigate)
        }

        let towardLanding = directionalInput(
            fromX: selfBody.position.x,
            landingLeft: edge.landingLeft,
            landingRight: edge.landingRight)
        switch edge.action {
        case .jump:
            var input = towardLanding
            input.up = true
            return (input, .jump)
        case .drop:
            var input = towardLanding
            input.up = true
            input.down = true
            return (input, .navigate)
        case .walk:
            return (towardLanding, .navigate)
        }
    }

    private func effectiveLaunchX(
        edge: SurfaceNavigationEdge,
        selfBody: CombatBodyState,
        profile: CombatProfile,
        graph: DynamicSurfaceGraph
    ) -> Double {
        guard let from = graph.surface(id: edge.fromSurfaceID) else {
            return edge.launchX
        }
        let margin = profile.pushRadius * selfBody.visualScale + 3
        if edge.launchX >= from.right - 1 {
            return max(from.left + margin, from.right - margin)
        }
        if edge.launchX <= from.left + 1 {
            return min(from.right - margin, from.left + margin)
        }
        return min(from.right - margin, max(from.left + margin, edge.launchX))
    }

    private func directionalInput(
        fromX: Double,
        landingLeft: Double,
        landingRight: Double
    ) -> FighterInputFrame {
        if landingRight < fromX { return FighterInputFrame(left: true) }
        if landingLeft > fromX { return FighterInputFrame(right: true) }
        return .neutral
    }

    private func tacticalSurfacePlan(
        observation: CPUCombatObservation,
        target: CombatBodyState,
        graph: DynamicSurfaceGraph
    ) -> (surface: Surface, path: SurfacePath, reason: CombatNavigationReason)? {
        guard let fromID = observation.selfBody.currentSurfaceID else { return nil }
        let distance = abs(target.position.x - observation.selfBody.position.x)
        let projectileDanger = incomingProjectileThreat(
            observation: observation, targetID: target.actorID)
        let pressureDanger = distance < 150 &&
            (target.phase == .startup || target.phase == .active ||
             observation.recentlyHit)
        guard projectileDanger || pressureDanger else { return nil }

        var best: (surface: Surface, path: SurfacePath,
                   reason: CombatNavigationReason, score: Double)?
        for surface in graph.tacticalSurfaces
        where surface.id != fromID && surface.id != target.currentSurfaceID {
            guard let path = graph.path(from: fromID, to: surface.id),
                  path.totalCost <= 180 else { continue }
            let center = (surface.left + surface.right) * 0.5
            let heightGain = max(0, observation.selfBody.position.y - surface.y)
            let separation = abs(center - target.position.x)
            let reason: CombatNavigationReason = projectileDanger
                ? .projectileEvade : .pressureEscape
            let score =
                (projectileDanger ? 180.0 : 95.0) +
                min(100, heightGain * 0.45) +
                min(65, separation * 0.08) -
                path.totalCost * 1.1
            if best == nil || score > best!.score {
                best = (surface, path, reason, score)
            }
        }
        guard let best, best.score > 35 else { return nil }
        return (best.surface, best.path, best.reason)
    }

    private func incomingProjectileThreat(
        observation: CPUCombatObservation,
        targetID: EntityID
    ) -> Bool {
        guard let projectiles = observation.worldCheckpoint?.projectiles?.values else {
            return false
        }
        return projectiles.contains { projectile in
            guard projectile.ownerID == targetID else { return false }
            let dx = observation.selfBody.position.x - projectile.previousPosition.x
            let movingToward = projectile.definition.velocity.x * dx > 0
            let verticalBand = abs(
                observation.selfBody.position.y - projectile.previousPosition.y) <= 120
            let timeToCross = abs(dx) /
                max(0.25, abs(projectile.definition.velocity.x))
            return movingToward && verticalBand && timeToCross <= 55
        }
    }

    private func scoreMoves(
        profile: CombatProfile,
        selfBody: CombatBodyState,
        target: CombatBodyState,
        targetProfile: CombatProfile?,
        environment: BodyEnvironment,
        tactics: CombatTactics,
        recentlyHit: Bool,
        worldCheckpoint: CombatWorldCheckpoint?
    ) -> [ScoredMove] {
        let distance = abs(target.position.x - selfBody.position.x)
        let surface = environment.surface(id: selfBody.currentSurfaceID)
        let edgeDistance = surface.map {
            min(selfBody.position.x - $0.left, $0.right - selfBody.position.x)
        } ?? 0
        let reservingForSuper = selfBody.gameplayEnergy.current >= 240 &&
            profile.moves.contains {
                $0.effectiveResourceRules.family == .superMove
            }
        let reservingForBurst = shouldReserveDefensiveBurst(
            profile: profile, selfBody: selfBody)
        let scored: [ScoredMove] = profile.moves.filter {
            $0.systemControl == nil
        }.filter {
            $0.effectiveUseState.permits(selfBody.locomotion)
        }.filter {
            !reservingForSuper || $0.effectiveResourceRules.startCost == 0 ||
                $0.effectiveResourceRules.family == .superMove
        }.filter {
            !reservingForBurst || $0.effectiveResourceRules.startCost == 0
        }.map { move in
            let projectileReach = move.authoredProjectiles.map(\.effectiveTravelDistance).max()
            let reach = projectileReach ??
                max(1, move.hit.attackBoxes.map(\.rect.maxX).max() ?? 1)
            let scoringDistance = move.authoredProjectiles.isEmpty
                ? predictedDistanceAtFirstActive(
                    move: move, selfBody: selfBody, target: target)
                : distance
            let hitChance = max(
                0, min(1, 1 - abs(scoringDistance - reach * 0.75) / max(60, reach)))
            let repetition = state.recentMoves.filter { $0 == move.id }.count
            let repeatHits = move.hit.rehitFrames.map {
                max(1, 1 + max(0, move.activeFrames - 1) / $0)
            } ?? 1
            let expectedDamage = move.projectile?.hit.damage ??
                move.hit.damage * repeatHits
            let exposure = Double(move.startupFrames) * 1.5 + Double(move.recoveryFrames)
            let terrainRisk = edgeDistance < 45 ? (45 - edgeDistance) * 1.8 : 0
            let remainingFrames = target.actionTimeline.flatMap { timeline in
                timeline.definition.durationFrames.map { max(0, $0 - timeline.frame) }
            } ?? 0
            let vulnerabilityBonus = target.phase == .recovery
                ? Double(remainingFrames) * 2 : 0
            let throwBonus = move.hit.attackHeight == .throwAttack && distance <= 70
                ? 55.0 * tactics.throwBias : 0
            // Reliability is already represented by hitChance and long reach;
            // only an explicit zoner bias may add another projectile premium.
            let projectileBonus = move.authoredProjectiles.isEmpty
                ? 0 : 45 * (tactics.projectile - 1)
            let antiAirBonus = target.locomotion == .airborne && move.hit.knockbackY < 0
                ? 55 * tactics.antiAir : 0
            let diversityBonus = state.recentMoves.contains(move.id) ? 0.0 : 55.0
            let lifetimeUses = state.moveUseCounts?[move.id, default: 0] ?? 0
            // Variety is a soft competitive prior, never a legality override.
            let scarcityBonus = lifetimeUses == 0 ? 50.0 : 10.0 / Double(lifetimeUses + 1)
            let resource = move.effectiveResourceRules
            let energy = selfBody.gameplayEnergy
            let reservePressure = energy.current <= 60 ? 2.0 :
                (energy.current < 150 ? 1.0 : 0.2)
            let energyPenalty = Double(resource.startCost) * reservePressure
            let historyPenalty = (state.actionHistory ?? ActionHistory())
                .repetitionPenalty(id: move.id, family: resource.family)
            let counterBonus: Double
            if recentlyHit && target.phase != .active {
                switch resource.family {
                case .fastMelee: counterBonus = 120
                case .throw: counterBonus = 95
                case .special: counterBonus = 55
                default: counterBonus = 0
                }
            } else {
                counterBonus = 0
            }
            let score = Double(expectedDamage) * tactics.aggression +
                hitChance * 60 + vulnerabilityBonus + throwBonus + projectileBonus +
                antiAirBonus + diversityBonus + scarcityBonus + counterBonus -
                exposure * max(0.25, 2 - tactics.defense) - terrainRisk -
                Double(repetition * 55) - energyPenalty - historyPenalty
            return ScoredMove(move: move, score: score)
        }
        let reachable: [ScoredMove] = scored.filter { candidate in
            guard selfBody.gameplayEnergy.current >=
                    candidate.move.effectiveResourceRules.startCost else { return false }
            if !candidate.move.authoredProjectiles.isEmpty {
                let repeated = state.recentMoves.suffix(2).allSatisfy {
                    $0 == candidate.move.id
                } && state.recentMoves.count >= 2
                let recentProjectileCount = (state.actionHistory ?? ActionHistory())
                    .entries.suffix(4).filter { $0.family == .projectile }.count
                let authoredReach = candidate.move.authoredProjectiles
                    .map(\.effectiveTravelDistance).max() ?? 0
                let desktopPracticalReach = min(
                    authoredReach,
                    max(480, min(900, environment.bounds.width * 0.28)))
                let authoredMinimum = candidate.move.authoredProjectiles
                    .compactMap(\.minimumRange).max()
                let minimumRange = authoredMinimum ?? 0
                let verticalReach = candidate.move.authoredProjectiles.map {
                    abs($0.spawnOffset.y) +
                        abs($0.velocity.y) * Double($0.lifetimeFrames) + 100
                }.max() ?? 100
                let verticalDistance = abs(target.position.y - selfBody.position.y)
                let ownedProjectiles = worldCheckpoint?.projectiles?.values
                    .filter { $0.ownerID == selfBody.actorID }.count ?? 0
                let authoredLimit = candidate.move.authoredProjectiles
                    .compactMap(\.maxConcurrentOwned).min()
                let occupancyLimit = authoredLimit ?? (tactics.projectile > 1.25 ? 2 : 1)
                let targetPinned = target.stunFrames >= candidate.move.startupFrames + 2
                return distance <= desktopPracticalReach &&
                    (distance >= minimumRange || targetPinned) &&
                    verticalDistance <= verticalReach &&
                    ownedProjectiles < occupancyLimit &&
                    !repeated &&
                    recentProjectileCount < (tactics.projectile > 1.25 ? 3 : 2)
            }
            return meleeWillOverlapAtFirstActive(
                move: candidate.move,
                selfBody: selfBody,
                target: target,
                targetProfile: targetProfile)
        }
        return reachable.sorted {
            $0.score == $1.score ? $0.move.id < $1.move.id : $0.score > $1.score
        }
    }

    private func activeAttackThreatens(
        attacker: CombatBodyState,
        attackerProfile: CombatProfile?,
        defender: CombatBodyState,
        defenderProfile: CombatProfile
    ) -> Bool {
        guard let attackerProfile,
              let move = attackerProfile.move(id: attacker.currentMoveID) else {
            let distance = abs(attacker.position.x - defender.position.x)
            return distance <= 70 + 45 * 0.5
        }
        let attacks = move.hit.attackBoxes.map {
            $0.placed(
                at: attacker.position,
                facing: attacker.facing,
                scale: attacker.visualScale)
        }
        let hurts = defenderProfile.hurtBoxes.map {
            $0.placed(
                at: defender.position,
                facing: defender.facing,
                scale: defender.visualScale)
        }
        return attacks.contains { attack in
            hurts.contains(where: attack.overlaps)
        }
    }

    private func predictedDistanceAtFirstActive(
        move: CombatMoveDefinition,
        selfBody: CombatBodyState,
        target: CombatBodyState
    ) -> Double {
        let prediction = predictedPositionsAtFirstActive(
            move: move, selfBody: selfBody, target: target)
        return hypot(
            prediction.target.x - prediction.selfPosition.x,
            prediction.target.y - prediction.selfPosition.y)
    }

    private func meleeWillOverlapAtFirstActive(
        move: CombatMoveDefinition,
        selfBody: CombatBodyState,
        target: CombatBodyState,
        targetProfile: CombatProfile?
    ) -> Bool {
        guard !move.hit.attackBoxes.isEmpty else { return false }
        let prediction = predictedPositionsAtFirstActive(
            move: move, selfBody: selfBody, target: target)
        guard let targetProfile, !targetProfile.hurtBoxes.isEmpty else {
            let distance = abs(prediction.target.x - prediction.selfPosition.x)
            let reach = move.hit.attackBoxes.map { $0.rect.maxX }.max() ?? 0
            return distance <= Swift.max(
                55.0,
                reach * selfBody.visualScale + 18.0)
        }
        let attackRects = move.hit.attackBoxes.map {
            $0.placed(
                at: prediction.selfPosition,
                facing: selfBody.facing,
                scale: selfBody.visualScale)
        }
        let hurtRects = targetProfile.hurtBoxes.map {
            $0.placed(
                at: prediction.target,
                facing: target.facing,
                scale: target.visualScale)
        }
        return attackRects.contains { attack in
            hurtRects.contains(where: attack.overlaps)
        }
    }

    private func predictedPositionsAtFirstActive(
        move: CombatMoveDefinition,
        selfBody: CombatBodyState,
        target: CombatBodyState
    ) -> (selfPosition: Vec2, target: Vec2) {
        // Command synthesis emits neutral/command frames before CombatWorld can
        // actually start the move. Include that delay plus startup, otherwise a
        // moving opponent is judged against a stale "right now" position.
        let commandLead = max(
            0,
            CombatCommandSynthesizer.frames(
                for: move.command, facing: selfBody.facing).count - 1)
        let impactDelay = commandLead + move.startupFrames
        let targetPosition = Vec2(
            x: target.position.x + target.velocity.x * Double(impactDelay),
            y: target.position.y + target.velocity.y * Double(impactDelay))
        let root = rootMotionBeforeActive(move)
        let selfPosition = Vec2(
            x: selfBody.position.x +
                root.x * selfBody.visualScale * selfBody.facing.sign,
            y: selfBody.position.y +
                (selfBody.locomotion == .grounded ? 0 : root.y * selfBody.visualScale))
        return (selfPosition, targetPosition)
    }

    private func rootMotionBeforeActive(_ move: CombatMoveDefinition) -> Vec2 {
        guard move.startupFrames > 0 else { return Vec2() }
        return (move.rootMotion ?? []).reduce(into: Vec2()) { total, motion in
            let start = max(0, motion.active.start)
            let end = min(move.startupFrames - 1, motion.active.end)
            guard end >= start else { return }
            let frames = Double(end - start + 1)
            total.x += motion.deltaPerFrame.x * frames
            total.y += motion.deltaPerFrame.y * frames
        }
    }

    private func shouldReserveDefensiveBurst(
        profile: CombatProfile,
        selfBody: CombatBodyState
    ) -> Bool {
        let healthIsCritical = selfBody.hp * 100 <= profile.maxHP * 35
        let underComboPressure = selfBody.combo.hitCount >= 2
        return (healthIsCritical || underComboPressure) &&
            profile.moves.contains {
                $0.systemControl == .defensiveBurst &&
                    selfBody.gameplayEnergy.current >=
                        $0.effectiveResourceRules.startCost
            }
    }

    private func sustainedInput(_ input: FighterInputFrame) -> FighterInputFrame {
        FighterInputFrame(
            left: input.left,
            right: input.right,
            down: input.down)
    }

    private mutating func scheduleAttackThrottle(
        after move: CombatMoveDefinition,
        observation: CPUCombatObservation
    ) {
        let range: ClosedRange<Int>
        switch move.effectiveResourceRules.family {
        case .fastMelee: range = 8...14
        case .heavyMelee: range = 12...22
        case .throw: range = 14...24
        case .projectile: range = 24...40
        case .special: range = 20...36
        case .superMove: range = 36...56
        case .powerUp: range = 28...44
        case .guardAction: range = 10...18
        case .burst: range = 24...40
        case .movement, .tag, .assist, .windowInteraction: range = 10...18
        }
        let spread = max(1, range.upperBound - range.lowerBound + 1)
        let sampled = range.lowerBound + state.rng.index(spread)
        let pacedGap = max(
            1, Int((Double(sampled) / observation.pacingRate).rounded(.up)))
        state.nextAttackFrame = observation.frame +
            Int64(move.totalFrames + pacedGap)
    }

    private mutating func approach(
        selfBody: CombatBodyState,
        target: CombatBodyState,
        slot: EngagementSlot
    ) -> CombatCPUOutput {
        let dx = slot.anchorX - selfBody.position.x
        if abs(dx) <= 8 { return issue(.neutral, intent: .wait, targetID: target.actorID, slot: slot) }
        return issue(
            dx > 0 ? FighterInputFrame(right: true) : FighterInputFrame(left: true),
            intent: .approach, targetID: target.actorID, slot: slot)
    }

    private mutating func issue(
        _ input: FighterInputFrame,
        intent: CombatCPUIntent,
        targetID: EntityID? = nil,
        slot: EngagementSlot? = nil
    ) -> CombatCPUOutput {
        state.lastOutput = CombatCPUOutputCheckpoint(
            intent: intent, targetID: targetID, slot: slot,
            moveID: nil, utilityScore: 0, usedSearch: false)
        return issue(input, from: state.lastOutput)
    }

    private mutating func issue(
        _ input: FighterInputFrame,
        from output: CombatCPUOutputCheckpoint
    ) -> CombatCPUOutput {
        state.lastIssuedInput = input
        return CombatCPUOutput(
            input: input, intent: output.intent,
            targetID: output.targetID, slot: output.slot,
            moveID: output.moveID, utilityScore: output.utilityScore,
            usedSearch: output.usedSearch)
    }
}

private enum ShallowCombatSearch {
    private struct SecondArm {
        var move: CombatMoveDefinition
        var visits = 0
        var reward = 0.0
    }

    private struct Arm {
        var candidate: ScoredMove
        var visits = 0
        var reward = 0.0
        var children: [SecondArm]?
    }

    /// Root UCT with bounded combat-world rollouts. This preserves the useful
    /// MctsAi23i shape (legal actions, UCB1, fixed horizon, most-tested result)
    /// without copying its unlicensed Java implementation.
    static func rank(
        candidates: [ScoredMove], actorID: EntityID, targetID: EntityID,
        observation: CPUCombatObservation, iterations: Int, horizon: Int,
        rng: inout DeterministicCPURNG
    ) -> [ScoredMove] {
        guard candidates.count > 1, let checkpoint = observation.worldCheckpoint else {
            return candidates
        }
        var arms = candidates.map { Arm(candidate: $0) }
        for iteration in 0..<max(arms.count, iterations) {
            let total = max(1, arms.reduce(0) { $0 + $1.visits })
            let index: Int
            if iteration < arms.count {
                index = iteration
            } else {
                index = arms.indices.max { lhs, rhs in
                    ucb(arms[lhs], total: total) < ucb(arms[rhs], total: total)
                } ?? 0
            }
            var selectedMoves = [arms[index].candidate.move]
            var selectedChild: Int?
            if arms[index].visits >= MctsAi23iCompatibility.expansionVisitThreshold {
                if arms[index].children == nil {
                    arms[index].children = candidates.map {
                        SecondArm(move: $0.move)
                    }
                }
                if let children = arms[index].children {
                    let childTotal = max(1, children.reduce(0) { $0 + $1.visits })
                    let childIndex = children.indices.max { lhs, rhs in
                        secondUCB(children[lhs], total: childTotal) <
                            secondUCB(children[rhs], total: childTotal)
                    } ?? 0
                    selectedMoves.append(children[childIndex].move)
                    selectedChild = childIndex
                }
            }
            while selectedMoves.count < 5 {
                selectedMoves.append(candidates[rng.index(candidates.count)].move)
            }
            let reward = rollout(
                checkpoint: checkpoint, moves: selectedMoves,
                actorID: actorID, targetID: targetID,
                environment: observation.environment, horizon: horizon,
                rng: &rng)
            if let selectedChild {
                arms[index].children?[selectedChild].visits += 1
                arms[index].children?[selectedChild].reward += reward
            }
            arms[index].visits += 1
            arms[index].reward += reward
        }
        return arms.sorted { lhs, rhs in
            if lhs.visits == rhs.visits {
                let la = lhs.visits == 0 ? -.infinity : lhs.reward / Double(lhs.visits)
                let ra = rhs.visits == 0 ? -.infinity : rhs.reward / Double(rhs.visits)
                return la == ra ? lhs.candidate.move.id < rhs.candidate.move.id : la > ra
            }
            return lhs.visits > rhs.visits
        }.map(\.candidate)
    }

    private static func ucb(_ arm: Arm, total: Int) -> Double {
        guard arm.visits > 0 else { return .infinity }
        return MctsAi23iCompatibility.ucb1(
            meanReward: arm.reward / Double(arm.visits),
            parentVisits: total,
            visits: arm.visits)
    }

    private static func secondUCB(_ arm: SecondArm, total: Int) -> Double {
        MctsAi23iCompatibility.ucb1(
            meanReward: arm.visits == 0 ? 0 : arm.reward / Double(arm.visits),
            parentVisits: total,
            visits: arm.visits)
    }

    private static func rollout(
        checkpoint: CombatWorldCheckpoint,
        moves: [CombatMoveDefinition],
        actorID: EntityID,
        targetID: EntityID,
        environment: BodyEnvironment,
        horizon: Int,
        rng: inout DeterministicCPURNG
    ) -> Double {
        let world = CombatWorld(checkpoint: checkpoint)
        for _ in 0..<MctsAi23iCompatibility.aheadFrames {
            world.setInput(.neutral, for: actorID, authority: .autonomous)
            world.setInput(.neutral, for: targetID, authority: .autonomous)
            _ = world.step(environment: environment)
        }
        guard let beforeSelf = world.body(for: actorID),
              let beforeTarget = world.body(for: targetID) else { return -.infinity }
        let availableOpponentMoves = world.profile(for: targetID)?.moves ?? []
        var opponentMoves: [CombatMoveDefinition] = []
        if !availableOpponentMoves.isEmpty {
            for _ in 0..<5 {
                opponentMoves.append(
                    availableOpponentMoves[rng.index(availableOpponentMoves.count)])
            }
        }
        var myCenter = FightingICECommandCenterCompatibility()
        var opponentCenter = FightingICECommandCenterCompatibility()
        var myMoveIndex = 0
        var opponentMoveIndex = 0
        for _ in 0..<horizon {
            if !myCenter.skillFlag,
               myMoveIndex < moves.count,
               let body = world.body(for: actorID), body.canAcceptAction {
                myCenter.commandCall(moves[myMoveIndex].command, facing: body.facing)
                myMoveIndex += 1
            }
            if !opponentCenter.skillFlag,
               opponentMoveIndex < opponentMoves.count,
               let body = world.body(for: targetID), body.canAcceptAction {
                opponentCenter.commandCall(
                    opponentMoves[opponentMoveIndex].command, facing: body.facing)
                opponentMoveIndex += 1
            }
            world.setInput(
                myCenter.getSkillKey(), for: actorID, authority: .autonomous)
            world.setInput(
                opponentCenter.getSkillKey(), for: targetID, authority: .autonomous)
            _ = world.step(environment: environment)
        }
        guard let afterSelf = world.body(for: actorID),
              let afterTarget = world.body(for: targetID) else { return -.infinity }
        let hpAdvantage = Double(
            (beforeTarget.hp - afterTarget.hp) - (beforeSelf.hp - afterSelf.hp))
        let positional = -abs(afterTarget.position.x - afterSelf.position.x) * 0.05
        let safety = surfaceSafety(afterSelf, environment: environment)
        return hpAdvantage + positional + safety
    }

    private static func surfaceSafety(
        _ body: CombatBodyState,
        environment: BodyEnvironment
    ) -> Double {
        guard let surface = environment.surface(id: body.currentSurfaceID) else { return -150 }
        return min(body.position.x - surface.left, surface.right - body.position.x) * 0.3
    }
}
