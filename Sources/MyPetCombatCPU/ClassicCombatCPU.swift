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
            lastIssuedInput: .neutral, surfaceGraph: nil)
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
        if target.phase == .active, distance <= 115 {
            let back = target.position.x >= observation.selfBody.position.x
                ? FighterInputFrame(left: true)
                : FighterInputFrame(right: true)
            return issue(back, intent: .guard, targetID: target.actorID)
        }

        guard observation.selfBody.canAcceptAction else {
            return issue(.neutral, intent: .wait, targetID: target.actorID)
        }
        let decisionDue = state.lastDecisionFrame == .min ||
            observation.frame - state.lastDecisionFrame >=
            Int64(state.configuration.decisionIntervalFrames)
        guard decisionDue else {
            return issue(.neutral, from: state.lastOutput)
        }
        state.lastDecisionFrame = observation.frame

        let slot = engagementSlot(
            selfBody: observation.selfBody, target: target,
            profile: observation.selfProfile,
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
            environment: observation.environment)
        if candidates.isEmpty {
            return approach(
                selfBody: observation.selfBody, target: target, slot: slot)
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
        state.pendingInputs = CombatCommandSynthesizer.frames(
            for: selected.move.command, facing: observation.selfBody.facing)
        state.recentMoves.append(selected.move.id)
        state.recentMoves = Array(state.recentMoves.suffix(
            max(4, observation.selfProfile.moves.count)))
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
        occupied: [EngagementSlot]
    ) -> EngagementSlot {
        let near = max(48, profile.moves.compactMap { move in
            move.hit.attackBoxes.map(\.rect.maxX).max()
        }.max() ?? 70)
        let sides: [EngagementSide] = [.leftNear, .rightNear, .leftFar, .rightFar]
        let used = Set(occupied.filter { $0.targetID == target.actorID }.map(\.side))
        let offset = stableIndex(selfBody.actorID.raw, count: sides.count)
        let ordered = Array(sides[offset...] + sides[..<offset])
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
        environment: BodyEnvironment
    ) -> [ScoredMove] {
        let distance = abs(target.position.x - selfBody.position.x)
        let surface = environment.surface(id: selfBody.currentSurfaceID)
        let edgeDistance = surface.map {
            min(selfBody.position.x - $0.left, $0.right - selfBody.position.x)
        } ?? 0
        let scored: [ScoredMove] = profile.moves.map { move in
            let reach = move.projectile == nil
                ? max(1, move.hit.attackBoxes.map(\.rect.maxX).max() ?? 1)
                : 320
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
            let throwBonus = move.hit.attackHeight == .throwAttack && distance <= 70 ? 55.0 : 0
            let diversityBonus = state.recentMoves.contains(move.id) ? 0.0 : 55.0
            let score = Double(expectedDamage) + hitChance * 60 + vulnerabilityBonus +
                throwBonus + diversityBonus - exposure - terrainRisk -
                Double(repetition * 55)
            return ScoredMove(move: move, score: score)
        }
        let reachable: [ScoredMove] = scored.filter { candidate in
            if candidate.move.projectile != nil {
                let repeated = state.recentMoves.suffix(2).allSatisfy {
                    $0 == candidate.move.id
                } && state.recentMoves.count >= 2
                return distance <= 360.0 && !repeated
            }
            let reach = candidate.move.hit.attackBoxes.map { $0.rect.maxX }.max() ?? 0
            let threshold = Swift.max(55.0, reach + 28.0)
            return distance <= threshold
        }
        return reachable.sorted {
            $0.score == $1.score ? $0.move.id < $1.move.id : $0.score > $1.score
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
