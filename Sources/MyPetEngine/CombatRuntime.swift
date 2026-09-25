import Foundation
import MyPet2D
import MyPetCombat
import MyPetCombatCPU
import MyPetCore

public enum CombatEngagementPhase: String, Codable, Equatable, Sendable {
    case seeking
    case engaged
}

public struct CombatEngagementStatus: Codable, Equatable, Sendable {
    public var phase: CombatEngagementPhase
    public var targetID: EntityID?

    public init(phase: CombatEngagementPhase, targetID: EntityID? = nil) {
        self.phase = phase
        self.targetID = targetID
    }
}

/// Serializable state for the complete 60 Hz combat path. Input arbitration
/// is checkpointed together with the rules/body world so replay cannot resume
/// with a different authority than the recorded run.
public struct CombatRuntimeCheckpoint: Codable, Equatable, Sendable {
    public var world: CombatWorldCheckpoint
    public var controls: ControlRouter
    public var combatCPUs: [String: ClassicCombatCPUCheckpoint]?
    public var gameplayCPUs: [String: ClassicGameplayCPUCheckpoint]?
    public var platformIntents: [String: GameplayPlatformIntent]?
    public var platformAuthorizations: [String: WindowAuthorization]?
    public var windowInteractionPolicy: WindowInteractionPolicy?
    public var cpuSeed: UInt64?
    public var gameplayStyles: [String: CharacterGameplayStyle]?
    public var requestedCombatActors: Set<String>?
    public var engagementTargets: [String: EntityID]?
    public var committedEngagements: Set<String>?
    public var combatPacingRate: Double?
    public var lastReceivedHitFrames: [String: Int64]?

    public init(
        world: CombatWorldCheckpoint,
        controls: ControlRouter,
        combatCPUs: [String: ClassicCombatCPUCheckpoint]? = nil,
        gameplayCPUs: [String: ClassicGameplayCPUCheckpoint]? = nil,
        platformIntents: [String: GameplayPlatformIntent]? = nil,
        platformAuthorizations: [String: WindowAuthorization]? = nil,
        windowInteractionPolicy: WindowInteractionPolicy? = nil,
        cpuSeed: UInt64? = nil,
        gameplayStyles: [String: CharacterGameplayStyle]? = nil,
        requestedCombatActors: Set<String>? = nil,
        engagementTargets: [String: EntityID]? = nil,
        committedEngagements: Set<String>? = nil,
        combatPacingRate: Double? = nil,
        lastReceivedHitFrames: [String: Int64]? = nil
    ) {
        self.world = world
        self.controls = controls
        self.combatCPUs = combatCPUs
        self.gameplayCPUs = gameplayCPUs
        self.platformIntents = platformIntents
        self.platformAuthorizations = platformAuthorizations
        self.windowInteractionPolicy = windowInteractionPolicy
        self.cpuSeed = cpuSeed
        self.gameplayStyles = gameplayStyles
        self.requestedCombatActors = requestedCombatActors
        self.engagementTargets = engagementTargets
        self.committedEngagements = committedEngagements
        self.combatPacingRate = combatPacingRate
        self.lastReceivedHitFrames = lastReceivedHitFrames
    }
}

/// A stable value used by adapters and replay tests. It deliberately contains
/// no renderer or platform objects.
public struct CombatRuntimeDigest: Codable, Equatable, Sendable {
    public var world: CombatWorldCheckpoint
    public var controls: ControlRouter
    public var combatCPUs: [String: ClassicCombatCPUCheckpoint]?
    public var gameplayCPUs: [String: ClassicGameplayCPUCheckpoint]?
    public var platformIntents: [String: GameplayPlatformIntent]?
    public var platformAuthorizations: [String: WindowAuthorization]?
    public var windowInteractionPolicy: WindowInteractionPolicy?
    public var cpuSeed: UInt64?
    public var gameplayStyles: [String: CharacterGameplayStyle]?
    public var requestedCombatActors: Set<String>?
    public var engagementTargets: [String: EntityID]?
    public var committedEngagements: Set<String>?
    public var combatPacingRate: Double?
    public var lastReceivedHitFrames: [String: Int64]?

    public init(
        world: CombatWorldCheckpoint,
        controls: ControlRouter,
        combatCPUs: [String: ClassicCombatCPUCheckpoint]? = nil,
        gameplayCPUs: [String: ClassicGameplayCPUCheckpoint]? = nil,
        platformIntents: [String: GameplayPlatformIntent]? = nil,
        platformAuthorizations: [String: WindowAuthorization]? = nil,
        windowInteractionPolicy: WindowInteractionPolicy? = nil,
        cpuSeed: UInt64? = nil,
        gameplayStyles: [String: CharacterGameplayStyle]? = nil,
        requestedCombatActors: Set<String>? = nil,
        engagementTargets: [String: EntityID]? = nil,
        committedEngagements: Set<String>? = nil,
        combatPacingRate: Double? = nil,
        lastReceivedHitFrames: [String: Int64]? = nil
    ) {
        self.world = world
        self.controls = controls
        self.combatCPUs = combatCPUs
        self.gameplayCPUs = gameplayCPUs
        self.platformIntents = platformIntents
        self.platformAuthorizations = platformAuthorizations
        self.windowInteractionPolicy = windowInteractionPolicy
        self.cpuSeed = cpuSeed
        self.gameplayStyles = gameplayStyles
        self.requestedCombatActors = requestedCombatActors
        self.engagementTargets = engagementTargets
        self.committedEngagements = committedEngagements
        self.combatPacingRate = combatPacingRate
        self.lastReceivedHitFrames = lastReceivedHitFrames
    }
}

public struct GameplayPlatformContext: Codable, Equatable, Sendable {
    public var userActive: Bool
    public var foregroundWindowIDs: Set<String>
    public var windows: [GameplayWindowState]

    public init(
        userActive: Bool = false,
        foregroundWindowIDs: Set<String> = [],
        windows: [GameplayWindowState] = []
    ) {
        self.userActive = userActive
        self.foregroundWindowIDs = foregroundWindowIDs
        self.windows = windows.sorted { $0.id < $1.id }
    }

    public static let idle = GameplayPlatformContext()
}

/// The sole combat-frame owner beneath `GameRuntime`. Production, harness and
/// replay adapters submit logical input here and never step `CombatWorld`
/// directly.
public final class CombatRuntime {
    public private(set) var world: CombatWorld
    public var bodyWorld: BodyWorld { world.authoritativeBodyWorld }
    private var controls: ControlRouter
    private var gameplayCPUs: [String: ClassicGameplayCPU]
    public private(set) var platformIntents: [String: GameplayPlatformIntent]
    public private(set) var platformAuthorizations: [String: WindowAuthorization]
    public private(set) var gameplayDecisions: [String: GameplayDecision]
    private var cpuDifficulties: [String: CombatCPUDifficulty]
    private var windowInteractionPolicy: WindowInteractionPolicy
    private var cpuSeed: UInt64
    private var gameplayStyles: [String: CharacterGameplayStyle]
    private var requestedCombatActors: Set<String>
    private var engagementTargets: [String: EntityID]
    private var committedEngagements: Set<String>
    /// Runtime tuning, deliberately separate from the deterministic 60 Hz world clock.
    private var combatPacingRate: Double = 1
    private var lastReceivedHitFrames: [String: Int64] = [:]

    public init(cpuSeed: UInt64 = 0) {
        self.world = CombatWorld()
        self.controls = ControlRouter()
        self.gameplayCPUs = [:]
        self.platformIntents = [:]
        self.platformAuthorizations = [:]
        self.gameplayDecisions = [:]
        self.cpuDifficulties = [:]
        self.windowInteractionPolicy = WindowInteractionPolicy()
        self.cpuSeed = cpuSeed
        self.gameplayStyles = [:]
        self.requestedCombatActors = []
        self.engagementTargets = [:]
        self.committedEngagements = []
    }

    public init(checkpoint: CombatRuntimeCheckpoint) {
        self.world = CombatWorld(checkpoint: checkpoint.world)
        self.controls = checkpoint.controls
        self.gameplayCPUs = (checkpoint.gameplayCPUs ?? [:]).mapValues {
            ClassicGameplayCPU(checkpoint: $0)
        }
        self.platformIntents = checkpoint.platformIntents ?? [:]
        self.platformAuthorizations = checkpoint.platformAuthorizations ?? [:]
        self.gameplayDecisions = [:]
        self.cpuDifficulties = [:]
        self.windowInteractionPolicy = checkpoint.windowInteractionPolicy ?? WindowInteractionPolicy()
        self.cpuSeed = checkpoint.cpuSeed ?? 0
        self.gameplayStyles = checkpoint.gameplayStyles ?? [:]
        self.requestedCombatActors = checkpoint.requestedCombatActors ?? []
        self.engagementTargets = checkpoint.engagementTargets ?? [:]
        self.committedEngagements = checkpoint.committedEngagements ?? []
        self.combatPacingRate = min(2, max(0.25, checkpoint.combatPacingRate ?? 1))
        self.lastReceivedHitFrames = checkpoint.lastReceivedHitFrames ?? [:]
    }

    public var digest: CombatRuntimeDigest {
        CombatRuntimeDigest(
            world: world.checkpoint(), controls: controls,
            combatCPUs: nil, gameplayCPUs: gameplayCPUCheckpoints(),
            platformIntents: platformIntents,
            platformAuthorizations: platformAuthorizations,
            windowInteractionPolicy: windowInteractionPolicy,
            cpuSeed: cpuSeed,
            gameplayStyles: gameplayStyles,
            requestedCombatActors: requestedCombatActors,
            engagementTargets: engagementTargets,
            committedEngagements: committedEngagements,
            combatPacingRate: combatPacingRate,
            lastReceivedHitFrames: lastReceivedHitFrames)
    }

    public func checkpoint() -> CombatRuntimeCheckpoint {
        CombatRuntimeCheckpoint(
            world: world.checkpoint(), controls: controls,
            combatCPUs: nil, gameplayCPUs: gameplayCPUCheckpoints(),
            platformIntents: platformIntents,
            platformAuthorizations: platformAuthorizations,
            windowInteractionPolicy: windowInteractionPolicy,
            cpuSeed: cpuSeed,
            gameplayStyles: gameplayStyles,
            requestedCombatActors: requestedCombatActors,
            engagementTargets: engagementTargets,
            committedEngagements: committedEngagements,
            combatPacingRate: combatPacingRate,
            lastReceivedHitFrames: lastReceivedHitFrames)
    }

    public func restore(_ checkpoint: CombatRuntimeCheckpoint) {
        world = CombatWorld(checkpoint: checkpoint.world)
        controls = checkpoint.controls
        gameplayCPUs = (checkpoint.gameplayCPUs ?? [:]).mapValues {
            ClassicGameplayCPU(checkpoint: $0)
        }
        platformIntents = checkpoint.platformIntents ?? [:]
        platformAuthorizations = checkpoint.platformAuthorizations ?? [:]
        gameplayDecisions = [:]
        cpuDifficulties = [:]
        windowInteractionPolicy = checkpoint.windowInteractionPolicy ?? WindowInteractionPolicy()
        cpuSeed = checkpoint.cpuSeed ?? 0
        gameplayStyles = checkpoint.gameplayStyles ?? [:]
        requestedCombatActors = checkpoint.requestedCombatActors ?? []
        engagementTargets = checkpoint.engagementTargets ?? [:]
        committedEngagements = checkpoint.committedEngagements ?? []
        combatPacingRate = min(2, max(0.25, checkpoint.combatPacingRate ?? 1))
        lastReceivedHitFrames = checkpoint.lastReceivedHitFrames ?? [:]
    }

    public func register(
        actorID: EntityID,
        profile: CombatProfile,
        x: Double,
        yFeet: Double,
        facing: CombatFacing = .right,
        visualScale: Double = 1,
        realCombatReady: Bool = true
    ) {
        if world.body(for: actorID) == nil {
            world.register(actorID: actorID, profile: profile, x: x, yFeet: yFeet,
                           facing: facing, visualScale: visualScale,
                           realCombatReady: realCombatReady)
        } else {
            world.setProfile(profile, for: actorID)
        }
        refreshSession()
    }

    public func setAutonomousDifficulty(
        _ difficulty: CombatCPUDifficulty,
        for actorID: EntityID
    ) {
        cpuDifficulties[actorID.raw] = difficulty
        gameplayCPUs[actorID.raw] = ClassicGameplayCPU(
            actorID: actorID, difficulty: difficulty, seed: stableCPUSeed(actorID))
    }

    public func unregister(_ actorID: EntityID) {
        let interruptedParticipants = world.session?.state == .active &&
            world.session?.participantIDs.contains(actorID) == true
            ? world.session?.participantIDs ?? [] : []
        controls.removeActor(actorID)
        gameplayCPUs.removeValue(forKey: actorID.raw)
        platformIntents.removeValue(forKey: actorID.raw)
        platformAuthorizations.removeValue(forKey: actorID.raw)
        gameplayDecisions.removeValue(forKey: actorID.raw)
        cpuDifficulties.removeValue(forKey: actorID.raw)
        gameplayStyles.removeValue(forKey: actorID.raw)
        requestedCombatActors.remove(actorID.raw)
        engagementTargets.removeValue(forKey: actorID.raw)
        lastReceivedHitFrames.removeValue(forKey: actorID.raw)
        committedEngagements = Set(committedEngagements.filter { key in
            !key.split(separator: "|").contains { String($0) == actorID.raw }
        })
        world.unregister(actorID: actorID)
        if !interruptedParticipants.isEmpty { releaseNonManualCombatControls() }
        refreshSession()
    }

    public func activate(
        _ source: ControlSource,
        for actorID: EntityID,
        input: FighterInputFrame = .neutral
    ) {
        controls.activate(source, for: actorID, input: input)
        refreshSession()
    }

    /// User-facing combat entry. The actor gets an autonomous steering route,
    /// but HP-changing combat is deferred until a target is reached.
    @discardableResult
    public func requestAutonomousCombat(for actorID: EntityID) -> Bool {
        guard eligibleCombatant(actorID) else { return false }
        requestedCombatActors.insert(actorID.raw)
        controls.activate(.autonomous, for: actorID)
        if let target = nearestTarget(for: actorID, requireContact: false) {
            engagementTargets[actorID.raw] = target.actorID
            if isInEngagementDistance(actorID, targetID: target.actorID) {
                _ = commitEngagement(actorID: actorID, targetID: target.actorID)
            }
        }
        refreshSession()
        return true
    }

    @discardableResult
    public func requestDraggedEngagement(for actorID: EntityID) -> Bool {
        guard eligibleCombatant(actorID),
              let target = nearestTarget(for: actorID, requireContact: true) else {
            return false
        }
        return commitEngagement(actorID: actorID, targetID: target.actorID)
    }

    @discardableResult
    public func endPointerDrag(actorID: EntityID) -> Bool {
        controls.deactivate(.pointer, for: actorID)
        applyResolvedInput(for: actorID)
        return requestDraggedEngagement(for: actorID)
    }

    public func engagementStatus(for actorID: EntityID) -> CombatEngagementStatus? {
        guard requestedCombatActors.contains(actorID.raw) else { return nil }
        let target = engagementTargets[actorID.raw]
        return CombatEngagementStatus(
            phase: isCommitted(actorID) ? .engaged : .seeking,
            targetID: target)
    }

    public func deactivate(_ source: ControlSource, for actorID: EntityID) {
        controls.deactivate(source, for: actorID)
        if source == .autonomous {
            if isCommitted(actorID) {
                // A runtime combat session is a shared engagement: the
                // selected target is autonomous too, so stopping one fighter
                // must release the whole non-manual round.
                releaseNonManualCombatControls()
            } else {
                requestedCombatActors.remove(actorID.raw)
                engagementTargets.removeValue(forKey: actorID.raw)
            }
        }
        applyResolvedInput(for: actorID)
        refreshSession()
    }

    public func isActive(_ source: ControlSource, for actorID: EntityID) -> Bool {
        controls.isActive(source, for: actorID)
    }

    public func setInput(
        _ input: FighterInputFrame,
        source: ControlSource,
        for actorID: EntityID
    ) {
        controls.setInput(input, source: source, for: actorID)
    }

    public func releaseAllManualInput(for actorID: EntityID) {
        controls.releaseAllManualInput(for: actorID)
    }

    public func beginDrag(actorID: EntityID, x: Double, y: Double) {
        world.beginDrag(actorID: actorID, x: x, y: y)
    }

    public func drag(
        actorID: EntityID, x: Double, y: Double,
        elapsedSeconds: Double
    ) {
        world.drag(
            actorID: actorID, x: x, y: y,
            elapsedSeconds: elapsedSeconds)
    }

    public func endDrag(actorID: EntityID, wasClick: Bool) {
        world.endDrag(actorID: actorID, wasClick: wasClick)
    }

    @discardableResult
    public func beginSession(id: String) -> Bool {
        world.beginSession(id: id, participants: world.snapshot().bodies.map(\.actorID))
    }

    @discardableResult
    public func beginSession(id: String, participants: [EntityID]) -> Bool {
        world.beginSession(id: id, participants: participants)
    }

    @discardableResult
    public func beginFormalSession(
        id: String, participants: [EntityID],
        rules: CombatRoundRules = .formal
    ) -> Bool {
        world.beginSession(id: id, participants: participants, roundRules: rules)
    }

    public func configureTeam(
        teamID: String, activeID: EntityID, benchID: EntityID,
        rules: TeamCombatRules = .standard
    ) {
        world.configureTeam(
            teamID: teamID, activeID: activeID, benchID: benchID, rules: rules)
    }

    public func setEscalationPolicy(_ policy: NeutralEscalationPolicy) {
        world.setEscalationPolicy(policy)
    }

    public func setCombatPacingRate(_ rate: Double) {
        combatPacingRate = min(2, max(0.25, rate))
    }

    public func setFeaturePolicy(_ policy: CombatFeaturePolicy) {
        world.setFeaturePolicy(policy)
    }

    public func setGameplayEnergy(_ current: Int, for actorID: EntityID) {
        world.setGameplayEnergy(current, for: actorID)
    }

    public func ownsCombatActivity(for actorID: EntityID) -> Bool {
        guard world.session?.state == .active,
              let body = world.body(for: actorID) else { return false }
        switch body.participation {
        case .uninvolved, .withdrawing:
            return body.authority == .manual || body.authority == .autonomous ||
                body.authority == .authored
        case .alerted, .incidentalCombatant, .rosterParticipant:
            return true
        }
    }

    public func setWindowInteractionPolicy(_ policy: WindowInteractionPolicy) {
        windowInteractionPolicy = policy
    }

    public func setGameplayStyle(
        _ style: CharacterGameplayStyle,
        for actorID: EntityID
    ) {
        gameplayStyles[actorID.raw] = style
    }

    public func endSession(cancelled: Bool = false) {
        world.endSession(cancelled: cancelled)
        releaseNonManualCombatControls()
    }

    @discardableResult
    public func advance(
        environment: BodyEnvironment,
        platformContext: GameplayPlatformContext = .idle
    ) -> [CombatEvent] {
        advancePendingEngagements()
        let snapshot = world.snapshot()
        for body in snapshot.bodies {
            if case .withdrawing = body.participation,
               controls.isActive(.autonomous, for: body.actorID) {
                controls.deactivate(.autonomous, for: body.actorID)
                applyResolvedInput(for: body.actorID)
            }
        }
        for body in snapshot.bodies where body.rosterRole == .incidental {
            guard case .incidentalCombatant = body.participation else { continue }
            if !controls.isActive(.autonomous, for: body.actorID) {
                controls.activate(.autonomous, for: body.actorID)
                setAutonomousDifficulty(
                    cpuDifficulties[body.actorID.raw] ?? .normal,
                    for: body.actorID)
            }
        }
        let checkpoint = world.checkpoint()
        let profiles = Dictionary(uniqueKeysWithValues: snapshot.bodies.map {
            ($0.actorID.raw, policyAdjustedProfile(
                world.profile(for: $0.actorID) ?? CombatProfile()))
        })
        for body in snapshot.bodies {
            if body.rosterRole == .bench { continue }
            if controls.resolve(for: body.actorID)?.authority == .autonomous {
                let opponents = snapshot.bodies.filter {
                    $0.actorID != body.actorID && $0.healthState == .active &&
                    $0.rosterRole != .bench && isOpponent($0, of: body)
                }
                var cpu = gameplayCPUs[body.actorID.raw] ?? ClassicGameplayCPU(
                    actorID: body.actorID,
                    difficulty: cpuDifficulties[body.actorID.raw] ?? .normal,
                    seed: stableCPUSeed(body.actorID))
                let combatObservation = CPUCombatObservation(
                    frame: world.frame,
                    selfBody: body,
                    opponents: opponents,
                    selfProfile: profiles[body.actorID.raw] ?? CombatProfile(),
                    opponentProfiles: profiles,
                    environment: environment,
                    worldCheckpoint: checkpoint,
                    engagementReservations: gameplayCPUs.compactMap { key, value in
                        key == body.actorID.raw ? nil : value.reservedSlot
                    },
                    tactics: combatTactics(
                        gameplayStyles[body.actorID.raw] ?? .balanced),
                    pacingRate: combatPacingRate,
                    recentlyHit: lastReceivedHitFrames[body.actorID.raw].map {
                        world.frame - $0 <= 60
                    } ?? false)
                let suppliedWindows = Dictionary(
                    platformContext.windows.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first })
                let windowStates = environment.surfaces.filter {
                    $0.kind == .windowTop
                }.map {
                    if let supplied = suppliedWindows[$0.id] { return supplied }
                    return GameplayWindowState(
                        id: $0.id,
                        areaRatio: min(1, max(0, ($0.right - $0.left) /
                            max(1, environment.bounds.width))),
                        isForeground: platformContext.foregroundWindowIDs.contains($0.id),
                        isMoving: false,
                        isPullable: true,
                        allowsDamageOverlay: true)
                }
                let team = world.teamState(for: body.actorID)
                let benchReady = team.flatMap { state in
                    world.body(for: state.benchID).map {
                        $0.healthState == .active && $0.rosterRole == .bench
                    }
                } ?? false
                let teamActionReady = team.map {
                    $0.activeID == body.actorID &&
                        $0.benchPhase == .standby && $0.cooldownFrames == 0 && benchReady
                } ?? false
                let output = cpu.advance(GameplayCPUObservation(
                    combat: combatObservation,
                    formalRound: world.session.map {
                        $0.state == .active && $0.roundRules != .desktop
                    } ?? false,
                    wasAttacked: body.stunFrames > 0,
                    userActive: platformContext.userActive,
                    windows: windowStates,
                    style: gameplayStyles[body.actorID.raw] ?? .balanced,
                    windowPolicy: windowInteractionPolicy,
                    assistAvailable: world.currentFeaturePolicy.assistsEnabled && teamActionReady,
                    tagAvailable: world.currentFeaturePolicy.freeTagEnabled && teamActionReady))
                gameplayCPUs[body.actorID.raw] = cpu
                gameplayDecisions[body.actorID.raw] = output.decision
                publishPlatformIntent(
                    output.platformIntent,
                    actorID: body.actorID,
                    context: platformContext)
                controls.setInput(
                    policyAdjustedInput(output.fighterInput),
                    source: .autonomous,
                    for: body.actorID)
            }
            if let seekInput = pendingEngagementInput(for: body.actorID) {
                // The tactical CPU intentionally emits a fresh decision only
                // every few frames. A user-requested seeker needs continuous
                // locomotion until the engagement gate is reached; otherwise
                // it crawls at the CPU decision cadence and can look stuck.
                controls.setInput(seekInput, source: .autonomous, for: body.actorID)
            }
            applyResolvedInput(for: body.actorID)
        }
        let events = world.step(environment: environment)
        for event in events
        where (event.kind == .hit || event.kind == .blocked), let targetID = event.targetID {
            lastReceivedHitFrames[targetID.raw] = event.frame
        }
        lastReceivedHitFrames = lastReceivedHitFrames.filter {
            world.frame - $0.value <= 120
        }
        if events.contains(where: { $0.kind == .roundEnded }) {
            releaseNonManualCombatControls()
        }
        restorePointerAuthorityAfterLanding()
        return events
    }

    private func releaseNonManualCombatControls() {
        let actorIDs = controls.actorIDs(activeIn: [.autonomous, .authored])
        for actorID in actorIDs {
            controls.deactivate(.autonomous, for: actorID)
            controls.deactivate(.authored, for: actorID)
            applyResolvedInput(for: actorID)
        }
        requestedCombatActors.removeAll()
        engagementTargets.removeAll()
        committedEngagements.removeAll()
        lastReceivedHitFrames.removeAll()
    }

    private func policyAdjustedProfile(_ profile: CombatProfile) -> CombatProfile {
        var adjusted = profile
        let policy = world.currentFeaturePolicy
        adjusted.moves = profile.moves.compactMap { move in
            guard policy.permits(move) else { return nil }
            var move = move
            var resources = move.effectiveResourceRules
            resources.startCost = policy.scaledCost(resources.startCost)
            resources.onHitGain = policy.scaledGain(resources.onHitGain)
            resources.onGuardGain = policy.scaledGain(resources.onGuardGain)
            resources.defenderGain = policy.scaledGain(resources.defenderGain)
            move.resourceRules = resources
            return move
        }
        return adjusted
    }

    private func policyAdjustedInput(_ input: FighterInputFrame) -> FighterInputFrame {
        var adjusted = input
        let policy = world.currentFeaturePolicy
        if !policy.teamsEnabled {
            adjusted.systemControls.remove(.tag)
            adjusted.systemControls.remove(.assist)
        } else {
            if !policy.freeTagEnabled { adjusted.systemControls.remove(.tag) }
            if !policy.assistsEnabled { adjusted.systemControls.remove(.assist) }
        }
        if !policy.powerUpEnabled { adjusted.systemControls.remove(.powerUp) }
        if !policy.defensiveBurstEnabled {
            adjusted.systemControls.remove(.defensiveBurst)
        }
        return adjusted
    }

    private func advancePendingEngagements() {
        // Committing a pair adds the target to the requested set, so iterate a
        // stable snapshot instead of mutating the collection being traversed.
        for rawID in requestedCombatActors.sorted() {
            let actorID = EntityID(rawID)
            guard eligibleCombatant(actorID), controls.isActive(.autonomous, for: actorID)
            else {
                requestedCombatActors.remove(rawID)
                engagementTargets.removeValue(forKey: rawID)
                continue
            }
            if let targetID = engagementTargets[rawID],
               !eligibleCombatant(targetID) {
                engagementTargets[rawID] = nil
            }
            guard !isCommitted(actorID) else { continue }
            guard let target = nearestTarget(for: actorID, requireContact: false) else {
                engagementTargets[rawID] = nil
                continue
            }
            engagementTargets[rawID] = target.actorID
            if isInEngagementDistance(actorID, targetID: target.actorID) {
                _ = commitEngagement(actorID: actorID, targetID: target.actorID)
            }
        }
    }

    private func eligibleCombatant(_ actorID: EntityID) -> Bool {
        guard let body = world.body(for: actorID) else { return false }
        return body.healthState == .active && body.rosterRole != .bench &&
            world.isCombatReady(actorID) && body.locomotion != .sleeping
    }

    private func pendingEngagementInput(for actorID: EntityID) -> FighterInputFrame? {
        guard requestedCombatActors.contains(actorID.raw), !isCommitted(actorID),
              let targetID = engagementTargets[actorID.raw],
              let actor = world.body(for: actorID), let target = world.body(for: targetID)
        else { return nil }
        let delta = target.position.x - actor.position.x
        if abs(delta) <= 8 { return .neutral }
        return delta > 0 ? FighterInputFrame(right: true) : FighterInputFrame(left: true)
    }

    private func nearestTarget(
        for actorID: EntityID, requireContact: Bool
    ) -> CombatBodyState? {
        guard let actor = world.body(for: actorID) else { return nil }
        return world.snapshot().bodies
            .filter { candidate in
                candidate.actorID != actorID && eligibleCombatant(candidate.actorID) &&
                    !sameTeam(actor, candidate)
            }
            .filter { !requireContact || isInEngagementDistance(actorID, targetID: $0.actorID) }
            .min { lhs, rhs in
                let leftDistance = hypot(
                    lhs.position.x - actor.position.x,
                    lhs.position.y - actor.position.y)
                let rightDistance = hypot(
                    rhs.position.x - actor.position.x,
                    rhs.position.y - actor.position.y)
                return leftDistance == rightDistance
                    ? lhs.actorID.raw < rhs.actorID.raw
                    : leftDistance < rightDistance
            }
    }

    private func isInEngagementDistance(_ actorID: EntityID, targetID: EntityID) -> Bool {
        guard let actor = world.body(for: actorID), let target = world.body(for: targetID),
              let actorProfile = world.profile(for: actorID),
              let targetProfile = world.profile(for: targetID) else { return false }
        // ClassicGameplayCPU deliberately keeps a short defensive buffer
        // before committing to an exchange. The engagement gate must include
        // that buffer or a seeker can hover forever without starting a round.
        let horizontalLimit = max(
            120, actorProfile.pushRadius + targetProfile.pushRadius + 24)
        let verticalLimit = max(28, min(actorProfile.pushRadius, targetProfile.pushRadius) * 1.5)
        return abs(actor.position.x - target.position.x) <= horizontalLimit &&
            abs(actor.position.y - target.position.y) <= verticalLimit
    }

    private func sameTeam(_ left: CombatBodyState, _ right: CombatBodyState) -> Bool {
        guard case .rosterParticipant(let leftTeam) = left.participation,
              case .rosterParticipant(let rightTeam) = right.participation else { return false }
        return leftTeam == rightTeam
    }

    @discardableResult
    private func commitEngagement(actorID: EntityID, targetID: EntityID) -> Bool {
        guard actorID != targetID, eligibleCombatant(actorID), eligibleCombatant(targetID),
              let actor = world.body(for: actorID),
              let target = world.body(for: targetID),
              !sameTeam(actor, target) else {
            return false
        }
        autoConfigureEngagementTeams(actorID: actorID, targetID: targetID)
        requestedCombatActors.insert(actorID.raw)
        requestedCombatActors.insert(targetID.raw)
        engagementTargets[actorID.raw] = targetID
        engagementTargets[targetID.raw] = actorID
        committedEngagements.insert(engagementKey(actorID, targetID))
        controls.activate(.autonomous, for: actorID)
        controls.activate(.autonomous, for: targetID)
        refreshSession()
        return world.session?.state == .active &&
            world.session?.participantIDs.contains(actorID) == true &&
            world.session?.participantIDs.contains(targetID) == true
    }

    private func autoConfigureEngagementTeams(
        actorID: EntityID,
        targetID: EntityID
    ) {
        guard world.currentFeaturePolicy.teamsEnabled else { return }
        var candidates = world.snapshot().bodies.filter { candidate in
            candidate.actorID != actorID && candidate.actorID != targetID &&
                candidate.healthState == .active &&
                candidate.rosterRole != .bench &&
                world.isCombatReady(candidate.actorID) &&
                world.teamState(for: candidate.actorID) == nil &&
                !requestedCombatActors.contains(candidate.actorID.raw)
        }
        func nearestHelper(to principal: EntityID) -> CombatBodyState? {
            guard let principalBody = world.body(for: principal) else { return nil }
            return candidates.min { lhs, rhs in
                let ld = hypot(
                    lhs.position.x - principalBody.position.x,
                    lhs.position.y - principalBody.position.y)
                let rd = hypot(
                    rhs.position.x - principalBody.position.x,
                    rhs.position.y - principalBody.position.y)
                return ld == rd ? lhs.actorID.raw < rhs.actorID.raw : ld < rd
            }
        }
        if world.teamState(for: actorID) == nil,
           let helper = nearestHelper(to: actorID) {
            world.configureTeam(
                teamID: "runtime-team:\(actorID.raw)",
                activeID: actorID, benchID: helper.actorID)
            candidates.removeAll { $0.actorID == helper.actorID }
        }
        if world.teamState(for: targetID) == nil,
           let helper = nearestHelper(to: targetID) {
            world.configureTeam(
                teamID: "runtime-team:\(targetID.raw)",
                activeID: targetID, benchID: helper.actorID)
        }
    }

    private func isCommitted(_ actorID: EntityID) -> Bool {
        guard let targetID = engagementTargets[actorID.raw] else { return false }
        return committedEngagements.contains(engagementKey(actorID, targetID))
    }

    private func engagementKey(_ left: EntityID, _ right: EntityID) -> String {
        [left.raw, right.raw].sorted().joined(separator: "|")
    }

    private func isOpponent(_ candidate: CombatBodyState, of actor: CombatBodyState) -> Bool {
        if engagementTargets[actor.actorID.raw] == candidate.actorID ||
            engagementTargets[candidate.actorID.raw] == actor.actorID {
            return true
        }
        if case .incidentalCombatant(let offenderID) = actor.participation {
            return candidate.actorID == offenderID
        }
        if case .alerted(let offenderID) = actor.participation {
            return candidate.actorID == offenderID
        }
        switch candidate.participation {
        case .uninvolved, .withdrawing: return false
        case .alerted(let offenderID): return offenderID == actor.actorID
        case .incidentalCombatant(let offenderID): return offenderID == actor.actorID
        case .rosterParticipant(let candidateTeam):
            if case .rosterParticipant(let actorTeam) = actor.participation {
                return candidateTeam != actorTeam
            }
            return true
        }
    }

    private func gameplayCPUCheckpoints() -> [String: ClassicGameplayCPUCheckpoint] {
        gameplayCPUs.mapValues { $0.checkpoint() }
    }

    private func combatTactics(_ style: CharacterGameplayStyle) -> CombatTactics {
        CombatTactics(
            aggression: 0.5 + style.combat + style.risk * 0.4,
            defense: 1.5 - style.risk,
            projectile: 0.7 + style.energyReserve * 0.6,
            throwBias: 0.7 + style.risk * 0.6,
            antiAir: 0.8 + style.combat * 0.4)
    }

    private func stableCPUSeed(_ actorID: EntityID) -> UInt64 {
        actorID.raw.utf8.reduce(UInt64(0xcbf29ce484222325) ^ cpuSeed) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
    }

    private func publishPlatformIntent(
        _ intent: GameplayPlatformIntent?,
        actorID: EntityID,
        context: GameplayPlatformContext
    ) {
        guard let intent else {
            platformIntents.removeValue(forKey: actorID.raw)
            platformAuthorizations.removeValue(forKey: actorID.raw)
            return
        }
        let actionAndWindow: (WindowGameplayAction, String)?
        switch intent {
        case .pullWindow(let id): actionAndWindow = (.pull, id)
        case .damageWindowOverlay(let id): actionAndWindow = (.damageOverlay, id)
        case .inspectWindow, .perchWindow, .rest, .observe, .interactProp, .perform:
            actionAndWindow = nil
        }
        guard let (action, windowID) = actionAndWindow else {
            platformIntents[actorID.raw] = intent
            platformAuthorizations.removeValue(forKey: actorID.raw)
            return
        }
        let authorization = world.authorizeWindowInteraction(
            action, for: actorID, policy: &windowInteractionPolicy,
            userActive: context.userActive,
            targetIsForeground: context.foregroundWindowIDs.contains(windowID))
        platformAuthorizations[actorID.raw] = authorization
        if authorization == .allowed {
            platformIntents[actorID.raw] = intent
        } else {
            platformIntents.removeValue(forKey: actorID.raw)
        }
    }

    private func refreshSession() {
        let requested = controls.hasAnyActive([.manual, .authored, .autonomous])
        guard requested else {
            if world.session?.state == .active, world.session?.id == "runtime" {
                world.endSession(cancelled: false)
            }
            return
        }

        if !committedEngagements.isEmpty {
            let participants = committedParticipantIDs()
            guard participants.count >= 2 else { return }
            if world.session?.state == .active, world.session?.id == "runtime" {
                _ = world.addParticipants(participants)
            } else {
                _ = world.beginSession(id: "runtime", participants: participants)
            }
            return
        }

        // User requests stay in the seek phase until a target is reached.
        guard requestedCombatActors.isEmpty else { return }
        let controlled = controls.actorIDs(activeIn: [.manual, .authored, .autonomous])
        let participants = runtimeParticipants(for: controlled)
        if participants.count >= 2,
           (world.session?.state != .active || world.session?.participantIDs != participants) {
            _ = world.beginSession(id: "runtime", participants: participants)
        }
    }

    private func committedParticipantIDs() -> [EntityID] {
        var ids = Set<EntityID>()
        for actorRaw in requestedCombatActors {
            let actorID = EntityID(actorRaw)
            guard isCommitted(actorID), let targetID = engagementTargets[actorRaw] else { continue }
            ids.insert(actorID)
            ids.insert(targetID)
        }
        return world.expandedParticipants(for: Array(ids))
    }

    /// A desktop control session names its controlled side, not every bystander.
    /// If no team supplies an opponent, select exactly one deterministic nearest
    /// active actor. Remaining registered actors stay neutral until collateral
    /// escalation admits them through the combat rules.
    private func runtimeParticipants(for controlled: [EntityID]) -> [EntityID] {
        var participants = world.expandedParticipants(for: controlled)
        guard let anchorID = controlled.first,
              let anchor = world.body(for: anchorID) else { return participants }
        let participantTeams = Set(participants.compactMap { actorID -> String? in
            guard let body = world.body(for: actorID),
                  case .rosterParticipant(let teamID) = body.participation
            else { return nil }
            return teamID
        })
        if participantTeams.count >= 2 { return participants }
        let participantSet = Set(participants)
        let candidates = world.snapshot().bodies.filter { candidate in
            !participantSet.contains(candidate.actorID) &&
                candidate.healthState == .active && candidate.rosterRole != .bench &&
                world.isCombatReady(candidate.actorID)
        }
        let opposingRoster = candidates.filter { candidate in
            guard case .rosterParticipant(let teamID) = candidate.participation
            else { return false }
            return !participantTeams.contains(teamID)
        }
        guard let opponent = (opposingRoster.isEmpty ? candidates : opposingRoster).min(by: { lhs, rhs in
            let leftDistance = abs(lhs.position.x - anchor.position.x)
            let rightDistance = abs(rhs.position.x - anchor.position.x)
            return leftDistance == rightDistance
                ? lhs.actorID.raw < rhs.actorID.raw
                : leftDistance < rightDistance
        }) else { return participants }
        participants = world.expandedParticipants(for: participants + [opponent.actorID])
        return participants
    }

    private func applyResolvedInput(for actorID: EntityID) {
        if let route = controls.resolve(for: actorID) {
            world.setInput(route.input, for: actorID, authority: route.authority)
        } else {
            world.setInput(.neutral, for: actorID, authority: .scripted)
        }
    }

    private func restorePointerAuthorityAfterLanding() {
        for body in world.snapshot().bodies
        where controls.isActive(.pointer, for: body.actorID) && body.locomotion == .grounded {
            controls.deactivate(.pointer, for: body.actorID)
            applyResolvedInput(for: body.actorID)
        }
    }
}
