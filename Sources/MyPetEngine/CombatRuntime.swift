import Foundation
import MyPet2D
import MyPetCombat
import MyPetCombatCPU
import MyPetCore

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

    public init(
        world: CombatWorldCheckpoint,
        controls: ControlRouter,
        combatCPUs: [String: ClassicCombatCPUCheckpoint]? = nil,
        gameplayCPUs: [String: ClassicGameplayCPUCheckpoint]? = nil,
        platformIntents: [String: GameplayPlatformIntent]? = nil,
        platformAuthorizations: [String: WindowAuthorization]? = nil,
        windowInteractionPolicy: WindowInteractionPolicy? = nil,
        cpuSeed: UInt64? = nil,
        gameplayStyles: [String: CharacterGameplayStyle]? = nil
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

    public init(
        world: CombatWorldCheckpoint,
        controls: ControlRouter,
        combatCPUs: [String: ClassicCombatCPUCheckpoint]? = nil,
        gameplayCPUs: [String: ClassicGameplayCPUCheckpoint]? = nil,
        platformIntents: [String: GameplayPlatformIntent]? = nil,
        platformAuthorizations: [String: WindowAuthorization]? = nil,
        windowInteractionPolicy: WindowInteractionPolicy? = nil,
        cpuSeed: UInt64? = nil,
        gameplayStyles: [String: CharacterGameplayStyle]? = nil
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
    }

    public var digest: CombatRuntimeDigest {
        CombatRuntimeDigest(
            world: world.checkpoint(), controls: controls,
            combatCPUs: nil, gameplayCPUs: gameplayCPUCheckpoints(),
            platformIntents: platformIntents,
            platformAuthorizations: platformAuthorizations,
            windowInteractionPolicy: windowInteractionPolicy,
            cpuSeed: cpuSeed,
            gameplayStyles: gameplayStyles)
    }

    public func checkpoint() -> CombatRuntimeCheckpoint {
        CombatRuntimeCheckpoint(
            world: world.checkpoint(), controls: controls,
            combatCPUs: nil, gameplayCPUs: gameplayCPUCheckpoints(),
            platformIntents: platformIntents,
            platformAuthorizations: platformAuthorizations,
            windowInteractionPolicy: windowInteractionPolicy,
            cpuSeed: cpuSeed,
            gameplayStyles: gameplayStyles)
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
        controls.removeActor(actorID)
        gameplayCPUs.removeValue(forKey: actorID.raw)
        platformIntents.removeValue(forKey: actorID.raw)
        platformAuthorizations.removeValue(forKey: actorID.raw)
        gameplayDecisions.removeValue(forKey: actorID.raw)
        cpuDifficulties.removeValue(forKey: actorID.raw)
        gameplayStyles.removeValue(forKey: actorID.raw)
        world.unregister(actorID: actorID)
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

    public func deactivate(_ source: ControlSource, for actorID: EntityID) {
        controls.deactivate(source, for: actorID)
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

    public func setGameplayEnergy(_ current: Int, for actorID: EntityID) {
        world.setGameplayEnergy(current, for: actorID)
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
    }

    @discardableResult
    public func advance(
        environment: BodyEnvironment,
        platformContext: GameplayPlatformContext = .idle
    ) -> [CombatEvent] {
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
            ($0.actorID.raw, world.profile(for: $0.actorID) ?? CombatProfile())
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
                        gameplayStyles[body.actorID.raw] ?? .balanced))
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
                let output = cpu.advance(GameplayCPUObservation(
                    combat: combatObservation,
                    formalRound: world.session?.state == .active,
                    wasAttacked: body.stunFrames > 0,
                    userActive: platformContext.userActive,
                    windows: windowStates,
                    style: gameplayStyles[body.actorID.raw] ?? .balanced,
                    windowPolicy: windowInteractionPolicy))
                gameplayCPUs[body.actorID.raw] = cpu
                gameplayDecisions[body.actorID.raw] = output.decision
                publishPlatformIntent(
                    output.platformIntent,
                    actorID: body.actorID,
                    context: platformContext)
                controls.setInput(
                    output.fighterInput,
                    source: .autonomous,
                    for: body.actorID)
            }
            applyResolvedInput(for: body.actorID)
        }
        let events = world.step(environment: environment)
        restorePointerAuthorityAfterLanding()
        return events
    }

    private func isOpponent(_ candidate: CombatBodyState, of actor: CombatBodyState) -> Bool {
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
        let controlled = controls.actorIDs(activeIn: [.manual, .authored, .autonomous])
        let participants = runtimeParticipants(for: controlled)
        if requested {
            if participants.count >= 2,
               (world.session?.state != .active ||
                world.session?.participantIDs != participants) {
                _ = world.beginSession(id: "runtime", participants: participants)
            }
        } else if world.session?.state == .active, world.session?.id == "runtime" {
            world.endSession(cancelled: false)
        }
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
