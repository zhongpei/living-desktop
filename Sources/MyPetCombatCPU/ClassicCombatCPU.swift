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
            moveUseCounts: [:])
    }

    public init(checkpoint: ClassicCombatCPUCheckpoint) {
        state = checkpoint
    }

    public func checkpoint() -> ClassicCombatCPUCheckpoint { state }
    public var reservedSlot: EngagementSlot? { state.slot }

    public mutating func advance(_ observation: CPUCombatObservation) -> CombatCPUOutput {
        record(opponents: observation.opponents, frame: observation.frame)

        guard observation.selfBody.healthState == .active,
              observation.selfBody.locomotion != .dragged,
              observation.selfBody.locomotion != .tossed else {
            state.pendingInputs.removeAll()
            return issue(.neutral, intent: .wait)
        }

        if (observation.selfBody.phase == .hitStun ||
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
            jumpVelocity: observation.selfProfile.jumpVelocity)
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
        state.targetID = target?.actorID
        guard let target else { return issue(.neutral, intent: .wait) }

        let distance = abs(target.position.x - observation.selfBody.position.x)
        if target.phase == .active,
           distance <= 70 + 45 * observation.tactics.defense {
            let back = target.position.x >= observation.selfBody.position.x
                ? FighterInputFrame(left: true)
                : FighterInputFrame(right: true)
            return issue(back, intent: .guard, targetID: target.actorID)
        }

        guard observation.selfBody.canAcceptAction else {
            // A fighting-game CPU should not queue a new move on the first
            // actionable frame after startup/active/recovery. Keep a short,
            // deterministic neutral beat so attacks read as separate actions.
            let minimumPostActionSpacing = 8
            state.lastDecisionFrame = observation.frame + Int64(max(
                0, minimumPostActionSpacing -
                    state.configuration.decisionIntervalFrames))
            return issue(.neutral, intent: .wait, targetID: target.actorID)
        }
        let decisionDue = state.lastDecisionFrame == .min ||
            observation.frame - state.lastDecisionFrame >=
            Int64(state.configuration.decisionIntervalFrames)
        guard decisionDue else {
            return issue(.neutral, from: state.lastOutput)
        }
        state.lastDecisionFrame = observation.frame

        let shouldReserveFirstBurst = shouldReserveFirstDefensiveBurst(
            profile: observation.selfProfile,
            selfBody: observation.selfBody)
        if !shouldReserveFirstBurst,
           let superMove = observation.selfProfile.moves.first(where: {
            $0.effectiveResourceRules.family == .superMove &&
                (state.moveUseCounts?[$0.id, default: 0] ?? 0) == 0 &&
                observation.selfBody.gameplayEnergy.current >=
                    $0.effectiveResourceRules.startCost &&
                distance <= max(55, $0.hit.attackBoxes.map(\.rect.maxX).max() ?? 0) + 18
        }) {
            state.pendingInputs = CombatCommandSynthesizer.frames(
                for: superMove.command, facing: observation.selfBody.facing)
            state.moveUseCounts?[superMove.id, default: 0] += 1
            var history = state.actionHistory ?? ActionHistory()
            history.record(id: superMove.id, family: .superMove)
            state.actionHistory = history
            state.lastOutput = CombatCPUOutputCheckpoint(
                intent: .attack, targetID: target.actorID,
                moveID: superMove.id, utilityScore: 1_000, usedSearch: false)
            return issue(state.pendingInputs.removeFirst(), from: state.lastOutput)
        }

        if observation.selfBody.powerUpFrames == 0,
           observation.selfBody.gameplayEnergy.current >= 240,
           observation.selfBody.gameplayEnergy.current <
               observation.selfBody.gameplayEnergy.maximum,
           !(state.actionHistory ?? ActionHistory()).entries.contains(where: {
               $0.family == .powerUp
           }),
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
            return issue(
                FighterInputFrame(systemControls: [.powerUp]),
                from: state.lastOutput)
        }

        let targetProfile = observation.opponentProfiles[target.actorID.raw]
        let slot = engagementSlot(
            selfBody: observation.selfBody, target: target,
            profile: observation.selfProfile,
            targetProfile: targetProfile,
            occupied: observation.engagementReservations)
        state.slot = slot
        if let navigation = navigationInput(
            selfBody: observation.selfBody, target: target, slot: slot,
            graph: graph, environment: observation.environment) {
            return issue(
                navigation.input, intent: navigation.intent,
                targetID: target.actorID, slot: slot)
        }

        var candidates = scoreMoves(
            profile: observation.selfProfile,
            selfBody: observation.selfBody,
            target: target,
            targetProfile: targetProfile,
            environment: observation.environment,
            tactics: observation.tactics)
        if candidates.isEmpty {
            return approach(
                selfBody: observation.selfBody, target: target, slot: slot)
        }
        let unseenCandidates = candidates.filter {
            (state.moveUseCounts?[$0.move.id, default: 0] ?? 0) == 0
        }
        if !unseenCandidates.isEmpty {
            candidates = observation.tactics.projectile > 1.25
                ? unseenCandidates
                : unseenCandidates.sorted { lhs, rhs in
                let lhsCommitment = lhs.move.startupFrames + lhs.move.activeFrames +
                    lhs.move.recoveryFrames
                let rhsCommitment = rhs.move.startupFrames + rhs.move.activeFrames +
                    rhs.move.recoveryFrames
                return lhsCommitment == rhsCommitment
                    ? lhs.score > rhs.score
                    : lhsCommitment < rhsCommitment
            }
        }
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
        let authoredReach = profile.moves.compactMap { move in
            move.hit.attackBoxes.map(\.rect.maxX).max()
        }.max() ?? 70
        let bodyContact = profile.pushRadius +
            (targetProfile?.pushRadius ?? profile.pushRadius) + 4
        let near = max(bodyContact, authoredReach)
        let nearSides: [EngagementSide] = [.leftNear, .rightNear]
        let farSides: [EngagementSide] = [.leftFar, .rightFar]
        let used = Set(occupied.filter { $0.targetID == target.actorID }.map(\.side))
        let nearOffset = stableIndex(selfBody.actorID.raw, count: nearSides.count)
        let farOffset = stableIndex(selfBody.actorID.raw + ":far", count: farSides.count)
        let orderedNear = Array(nearSides[nearOffset...] + nearSides[..<nearOffset])
        let orderedFar = Array(farSides[farOffset...] + farSides[..<farOffset])
        // Traditional brawlers reserve contact slots first. The old random
        // rotation could assign a lone melee fighter a "far" slot, making it
        // stop outside every HurtBox and swing forever.
        let ordered = orderedNear + orderedFar
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

    private func navigationInput(
        selfBody: CombatBodyState,
        target: CombatBodyState,
        slot: EngagementSlot,
        graph: DynamicSurfaceGraph,
        environment: BodyEnvironment
    ) -> (input: FighterInputFrame, intent: CombatCPUIntent)? {
        guard let fromID = selfBody.currentSurfaceID,
              let toID = target.currentSurfaceID,
              fromID != toID,
              let path = graph.path(from: fromID, to: toID),
              let edge = path.edges.first else { return nil }
        let dx = edge.launchX - selfBody.position.x
        if abs(dx) > 8 {
            return (dx > 0 ? FighterInputFrame(right: true) : FighterInputFrame(left: true), .navigate)
        }
        switch edge.action {
        case .jump:
            return (FighterInputFrame(
                left: edge.landingRight < selfBody.position.x,
                right: edge.landingLeft > selfBody.position.x,
                up: true), .jump)
        case .drop:
            let toward = slot.anchorX >= selfBody.position.x
            return (FighterInputFrame(
                left: !toward, right: toward, up: true, down: true), .navigate)
        case .walk:
            return (slot.anchorX >= selfBody.position.x
                ? FighterInputFrame(right: true)
                : FighterInputFrame(left: true), .navigate)
        }
    }

    private func scoreMoves(
        profile: CombatProfile,
        selfBody: CombatBodyState,
        target: CombatBodyState,
        targetProfile: CombatProfile?,
        environment: BodyEnvironment,
        tactics: CombatTactics
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
        let unseenResourceCost = profile.moves.filter {
            $0.systemControl == nil &&
                (state.moveUseCounts?[$0.id, default: 0] ?? 0) == 0 &&
                $0.effectiveResourceRules.startCost > 0 &&
                $0.effectiveResourceRules.family != .superMove
        }.map { $0.effectiveResourceRules.startCost }.min()
        let reservingForUnseen = unseenResourceCost.map {
            selfBody.gameplayEnergy.current < $0
        } ?? false
        let reservingForBurst = shouldReserveFirstDefensiveBurst(
            profile: profile, selfBody: selfBody)
        let scored: [ScoredMove] = profile.moves.filter {
            $0.systemControl == nil
        }.filter {
            !reservingForSuper || $0.effectiveResourceRules.startCost == 0 ||
                $0.effectiveResourceRules.family == .superMove
        }.filter {
            !reservingForBurst || $0.effectiveResourceRules.startCost == 0
        }.filter {
            !reservingForUnseen || $0.effectiveResourceRules.startCost == 0
        }.map { move in
            let projectileReach = move.authoredProjectiles.map(\.effectiveTravelDistance).max()
            let reach = projectileReach ??
                max(1, move.hit.attackBoxes.map(\.rect.maxX).max() ?? 1)
            let hitChance = max(0, min(1, 1 - abs(distance - reach * 0.75) / max(60, reach)))
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
            let scarcityBonus = lifetimeUses == 0 ? 180.0 : 35.0 / Double(lifetimeUses + 1)
            let resource = move.effectiveResourceRules
            let energy = selfBody.gameplayEnergy
            let reservePressure = energy.current <= 60 ? 2.0 :
                (energy.current < 150 ? 1.0 : 0.2)
            let energyPenalty = Double(resource.startCost) * reservePressure
            let historyPenalty = (state.actionHistory ?? ActionHistory())
                .repetitionPenalty(id: move.id, family: resource.family)
            let score = Double(expectedDamage) * tactics.aggression +
                hitChance * 60 + vulnerabilityBonus + throwBonus + projectileBonus +
                antiAirBonus + diversityBonus + scarcityBonus -
                exposure * max(0.25, 2 - tactics.defense) - terrainRisk -
                Double(repetition * 55) - energyPenalty - historyPenalty
            return ScoredMove(move: move, score: score)
        }
        let reachable: [ScoredMove] = scored.filter { candidate in
            guard selfBody.gameplayEnergy.current >=
                    candidate.move.effectiveResourceRules.startCost else { return false }
            if candidate.move.projectile != nil {
                let repeated = state.recentMoves.suffix(2).allSatisfy {
                    $0 == candidate.move.id
                } && state.recentMoves.count >= 2
                // Balanced fighters close distance after zoning instead of
                // treating the only long-range option as the only legal plan.
                // Dedicated zoners retain sustained projectile pressure.
                let rotating = tactics.projectile <= 1.25 &&
                    (state.actionHistory ?? ActionHistory()).entries.suffix(3)
                        .contains { $0.family == .projectile }
                let authoredReach = candidate.move.authoredProjectiles
                    .map(\.effectiveTravelDistance).max() ?? 0
                return distance <= authoredReach && !repeated && !rotating
            }
            return meleeBoxesOverlap(
                move: candidate.move,
                selfBody: selfBody,
                target: target,
                targetProfile: targetProfile)
        }
        return reachable.sorted {
            $0.score == $1.score ? $0.move.id < $1.move.id : $0.score > $1.score
        }
    }

    private func meleeBoxesOverlap(
        move: CombatMoveDefinition,
        selfBody: CombatBodyState,
        target: CombatBodyState,
        targetProfile: CombatProfile?
    ) -> Bool {
        guard !move.hit.attackBoxes.isEmpty else { return false }
        guard let targetProfile, !targetProfile.hurtBoxes.isEmpty else {
            let distance = abs(target.position.x - selfBody.position.x)
            let reach = move.hit.attackBoxes.map { $0.rect.maxX }.max() ?? 0
            return distance <= Swift.max(55.0, reach + 18.0)
        }
        let attackRects = move.hit.attackBoxes.map {
            $0.placed(
                at: selfBody.position,
                facing: selfBody.facing,
                scale: selfBody.visualScale)
        }
        let hurtRects = targetProfile.hurtBoxes.map {
            $0.placed(
                at: target.position,
                facing: target.facing,
                scale: target.visualScale)
        }
        return attackRects.contains { attack in
            hurtRects.contains(where: attack.overlaps)
        }
    }

    private func shouldReserveFirstDefensiveBurst(
        profile: CombatProfile,
        selfBody: CombatBodyState
    ) -> Bool {
        let healthIsCritical = selfBody.hp * 100 <= profile.maxHP * 45
        let hasDemonstratedSuper = profile.moves.contains {
            $0.effectiveResourceRules.family == .superMove &&
                (state.moveUseCounts?[$0.id, default: 0] ?? 0) > 0
        }
        return (healthIsCritical || hasDemonstratedSuper) &&
            profile.moves.contains {
                $0.systemControl == .defensiveBurst &&
                    (state.moveUseCounts?[$0.id, default: 0] ?? 0) == 0 &&
                    selfBody.gameplayEnergy.current >=
                        $0.effectiveResourceRules.startCost
            }
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
