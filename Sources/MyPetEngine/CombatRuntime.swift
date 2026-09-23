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

    public init(
        world: CombatWorldCheckpoint,
        controls: ControlRouter,
        combatCPUs: [String: ClassicCombatCPUCheckpoint]? = nil
    ) {
        self.world = world
        self.controls = controls
        self.combatCPUs = combatCPUs
    }
}

/// A stable value used by adapters and replay tests. It deliberately contains
/// no renderer or platform objects.
public struct CombatRuntimeDigest: Codable, Equatable, Sendable {
    public var world: CombatWorldCheckpoint
    public var controls: ControlRouter
    public var combatCPUs: [String: ClassicCombatCPUCheckpoint]?

    public init(
        world: CombatWorldCheckpoint,
        controls: ControlRouter,
        combatCPUs: [String: ClassicCombatCPUCheckpoint]? = nil
    ) {
        self.world = world
        self.controls = controls
        self.combatCPUs = combatCPUs
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
    private var cpuDifficulties: [String: CombatCPUDifficulty]

    public init() {
        self.world = CombatWorld()
        self.controls = ControlRouter()
        self.combatCPUs = [:]
        self.cpuDifficulties = [:]
    }

    public init(checkpoint: CombatRuntimeCheckpoint) {
        self.world = CombatWorld(checkpoint: checkpoint.world)
        self.controls = checkpoint.controls
        self.combatCPUs = (checkpoint.combatCPUs ?? [:]).mapValues {
            ClassicCombatCPU(checkpoint: $0)
        }
        self.cpuDifficulties = [:]
    }

    public var digest: CombatRuntimeDigest {
        CombatRuntimeDigest(
            world: world.checkpoint(), controls: controls,
            combatCPUs: cpuCheckpoints())
    }

    public func checkpoint() -> CombatRuntimeCheckpoint {
        CombatRuntimeCheckpoint(
            world: world.checkpoint(), controls: controls,
            combatCPUs: cpuCheckpoints())
    }

    public func restore(_ checkpoint: CombatRuntimeCheckpoint) {
        world = CombatWorld(checkpoint: checkpoint.world)
        controls = checkpoint.controls
        combatCPUs = (checkpoint.combatCPUs ?? [:]).mapValues {
            ClassicCombatCPU(checkpoint: $0)
        }
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
    }

    public func unregister(_ actorID: EntityID) {
        controls.removeActor(actorID)
        combatCPUs.removeValue(forKey: actorID.raw)
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

    public func endSession(cancelled: Bool = false) {
        world.endSession(cancelled: cancelled)
    }

    @discardableResult
    public func advance(environment: BodyEnvironment) -> [CombatEvent] {
        let snapshot = world.snapshot()
        let checkpoint = world.checkpoint()
        let profiles = Dictionary(uniqueKeysWithValues: snapshot.bodies.map {
            ($0.actorID.raw, world.profile(for: $0.actorID) ?? CombatProfile())
        })
        for body in snapshot.bodies {
            if controls.resolve(for: body.actorID)?.authority == .autonomous {
                let opponents = snapshot.bodies.filter {
                    $0.actorID != body.actorID && $0.healthState == .active
                }
                var cpu = combatCPUs[body.actorID.raw] ?? ClassicCombatCPU(
                    actorID: body.actorID,
                    difficulty: cpuDifficulties[body.actorID.raw] ?? .normal,
                    seed: stableCPUSeed(body.actorID))
                let output = cpu.advance(CPUCombatObservation(
                    frame: world.frame,
                    selfBody: body,
                    opponents: opponents,
                    selfProfile: profiles[body.actorID.raw] ?? CombatProfile(),
                    opponentProfiles: profiles,
                    environment: environment,
                    worldCheckpoint: checkpoint,
                    engagementReservations: combatCPUs.compactMap { key, value in
                        key == body.actorID.raw ? nil : value.reservedSlot
                    }))
                combatCPUs[body.actorID.raw] = cpu
                controls.setInput(
                    output.input,
                    source: .autonomous,
                    for: body.actorID)
            }
            applyResolvedInput(for: body.actorID)
        }
        let events = world.step(environment: environment)
        restorePointerAuthorityAfterLanding()
        return events
    }

    private func cpuCheckpoints() -> [String: ClassicCombatCPUCheckpoint] {
        combatCPUs.mapValues { $0.checkpoint() }
    }

    private func stableCPUSeed(_ actorID: EntityID) -> UInt64 {
        actorID.raw.utf8.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
    }

    private func refreshSession() {
        let requested = controls.hasAnyActive([.manual, .authored, .autonomous])
        let participants = world.snapshot().bodies.map(\.actorID)
        if requested, participants.count >= 2 {
            _ = world.beginSession(id: "runtime", participants: participants)
        } else if world.session?.state == .active {
            world.endSession(cancelled: false)
        }
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
