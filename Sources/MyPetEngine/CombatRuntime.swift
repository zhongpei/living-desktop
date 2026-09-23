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

    public init(
        world: CombatWorldCheckpoint,
        controls: ControlRouter,
        combatCPUs: [String: ClassicCombatCPUCheckpoint]? = nil,
        gameplayCPUs: [String: ClassicGameplayCPUCheckpoint]? = nil,
        platformIntents: [String: GameplayPlatformIntent]? = nil
    ) {
        self.world = world
        self.controls = controls
        self.combatCPUs = combatCPUs
        self.gameplayCPUs = gameplayCPUs
        self.platformIntents = platformIntents
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

    public init(
        world: CombatWorldCheckpoint,
        controls: ControlRouter,
        combatCPUs: [String: ClassicCombatCPUCheckpoint]? = nil,
        gameplayCPUs: [String: ClassicGameplayCPUCheckpoint]? = nil,
        platformIntents: [String: GameplayPlatformIntent]? = nil
    ) {
        self.world = world
        self.controls = controls
        self.combatCPUs = combatCPUs
        self.gameplayCPUs = gameplayCPUs
        self.platformIntents = platformIntents
    }
}

/// The sole combat-frame owner beneath `GameRuntime`. Production, harness and
/// replay adapters submit logical input here and never step `CombatWorld`
/// directly.
public final class CombatRuntime {
    public private(set) var world: CombatWorld
    public var bodyWorld: BodyWorld { world.authoritativeBodyWorld }
    private var controls: ControlRouter
    private var combatCPUs: [String: ClassicCombatCPU]
    private var gameplayCPUs: [String: ClassicGameplayCPU]
    public private(set) var platformIntents: [String: GameplayPlatformIntent]
    private var cpuDifficulties: [String: CombatCPUDifficulty]

    public init() {
        self.world = CombatWorld()
        self.controls = ControlRouter()
        self.combatCPUs = [:]
        self.gameplayCPUs = [:]
        self.platformIntents = [:]
        self.cpuDifficulties = [:]
    }

    public init(checkpoint: CombatRuntimeCheckpoint) {
        self.world = CombatWorld(checkpoint: checkpoint.world)
        self.controls = checkpoint.controls
        self.combatCPUs = (checkpoint.combatCPUs ?? [:]).mapValues {
            ClassicCombatCPU(checkpoint: $0)
        }
        self.gameplayCPUs = (checkpoint.gameplayCPUs ?? [:]).mapValues {
            ClassicGameplayCPU(checkpoint: $0)
        }
        self.platformIntents = checkpoint.platformIntents ?? [:]
        self.cpuDifficulties = [:]
    }

    public var digest: CombatRuntimeDigest {
        CombatRuntimeDigest(
            world: world.checkpoint(), controls: controls,
            combatCPUs: cpuCheckpoints(), gameplayCPUs: gameplayCPUCheckpoints(),
            platformIntents: platformIntents)
    }

    public func checkpoint() -> CombatRuntimeCheckpoint {
        CombatRuntimeCheckpoint(
            world: world.checkpoint(), controls: controls,
            combatCPUs: cpuCheckpoints(), gameplayCPUs: gameplayCPUCheckpoints(),
            platformIntents: platformIntents)
    }

    public func restore(_ checkpoint: CombatRuntimeCheckpoint) {
        world = CombatWorld(checkpoint: checkpoint.world)
        controls = checkpoint.controls
        combatCPUs = (checkpoint.combatCPUs ?? [:]).mapValues {
            ClassicCombatCPU(checkpoint: $0)
        }
        gameplayCPUs = (checkpoint.gameplayCPUs ?? [:]).mapValues {
            ClassicGameplayCPU(checkpoint: $0)
        }
        platformIntents = checkpoint.platformIntents ?? [:]
        cpuDifficulties = [:]
    }

    public func register(
        actorID: EntityID,
        profile: CombatProfile,
        x: Double,
        yFeet: Double,
        facing: CombatFacing = .right,
        visualScale: Double = 1
    ) {
        if world.body(for: actorID) == nil {
            world.register(actorID: actorID, profile: profile, x: x, yFeet: yFeet,
                           facing: facing, visualScale: visualScale)
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
        combatCPUs[actorID.raw] = ClassicCombatCPU(
            actorID: actorID,
            difficulty: difficulty,
            seed: stableCPUSeed(actorID))
        gameplayCPUs[actorID.raw] = ClassicGameplayCPU(
            actorID: actorID, difficulty: difficulty, seed: stableCPUSeed(actorID))
    }

    public func unregister(_ actorID: EntityID) {
        controls.removeActor(actorID)
        combatCPUs.removeValue(forKey: actorID.raw)
        gameplayCPUs.removeValue(forKey: actorID.raw)
        platformIntents.removeValue(forKey: actorID.raw)
        cpuDifficulties.removeValue(forKey: actorID.raw)
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

    @discardableResult
    public func beginSession(id: String) -> Bool {
        world.beginSession(id: id, participants: world.snapshot().bodies.map(\.actorID))
    }

    @discardableResult
    public func beginSession(id: String, participants: [EntityID]) -> Bool {
        world.beginSession(id: id, participants: participants)
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

    public func endSession(cancelled: Bool = false) {
        world.endSession(cancelled: cancelled)
    }

    @discardableResult
    public func advance(environment: BodyEnvironment) -> [CombatEvent] {
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
                    })
                let output = cpu.advance(GameplayCPUObservation(
                    combat: combatObservation,
                    formalRound: world.session?.state == .active,
                    wasAttacked: body.stunFrames > 0,
                    windowIDs: environment.surfaces.filter {
                        $0.kind == .windowTop
                    }.map(\.id)))
                gameplayCPUs[body.actorID.raw] = cpu
                if let intent = output.platformIntent {
                    platformIntents[body.actorID.raw] = intent
                } else {
                    platformIntents.removeValue(forKey: body.actorID.raw)
                }
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

    private func cpuCheckpoints() -> [String: ClassicCombatCPUCheckpoint] {
        combatCPUs.mapValues { $0.checkpoint() }
    }

    private func gameplayCPUCheckpoints() -> [String: ClassicGameplayCPUCheckpoint] {
        gameplayCPUs.mapValues { $0.checkpoint() }
    }

    private func stableCPUSeed(_ actorID: EntityID) -> UInt64 {
        actorID.raw.utf8.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
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
                candidate.healthState == .active && candidate.rosterRole != .bench
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
