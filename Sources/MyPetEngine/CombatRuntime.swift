import Foundation
import MyPet2D
import MyPetCombat
import MyPetCore

/// Serializable state for the complete 60 Hz combat path. Input arbitration
/// is checkpointed together with the rules/body world so replay cannot resume
/// with a different authority than the recorded run.
public struct CombatRuntimeCheckpoint: Codable, Equatable, Sendable {
    public var world: CombatWorldCheckpoint
    public var controls: ControlRouter

    public init(world: CombatWorldCheckpoint, controls: ControlRouter) {
        self.world = world
        self.controls = controls
    }
}

/// A stable value used by adapters and replay tests. It deliberately contains
/// no renderer or platform objects.
public struct CombatRuntimeDigest: Codable, Equatable, Sendable {
    public var world: CombatWorldCheckpoint
    public var controls: ControlRouter

    public init(world: CombatWorldCheckpoint, controls: ControlRouter) {
        self.world = world
        self.controls = controls
    }
}

/// The sole combat-frame owner beneath `GameRuntime`. Production, harness and
/// replay adapters submit logical input here and never step `CombatWorld`
/// directly.
public final class CombatRuntime {
    public private(set) var world: CombatWorld
    public var bodyWorld: BodyWorld { world.authoritativeBodyWorld }
    private var controls: ControlRouter
    private let autonomousPolicy = UtilityCombatPolicy()

    public init() {
        self.world = CombatWorld()
        self.controls = ControlRouter()
    }

    public init(checkpoint: CombatRuntimeCheckpoint) {
        self.world = CombatWorld(checkpoint: checkpoint.world)
        self.controls = checkpoint.controls
    }

    public var digest: CombatRuntimeDigest {
        CombatRuntimeDigest(world: world.checkpoint(), controls: controls)
    }

    public func checkpoint() -> CombatRuntimeCheckpoint {
        CombatRuntimeCheckpoint(world: world.checkpoint(), controls: controls)
    }

    public func restore(_ checkpoint: CombatRuntimeCheckpoint) {
        world = CombatWorld(checkpoint: checkpoint.world)
        controls = checkpoint.controls
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

    public func unregister(_ actorID: EntityID) {
        controls.removeActor(actorID)
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
        for body in snapshot.bodies {
            if controls.isActive(.autonomous, for: body.actorID) {
                let opponents = snapshot.bodies.filter {
                    $0.actorID != body.actorID && $0.healthState == .active
                }
                controls.setInput(
                    autonomousPolicy.decide(CombatObservation(
                        selfBody: body, opponents: opponents)),
                    source: .autonomous,
                    for: body.actorID)
            }
            applyResolvedInput(for: body.actorID)
        }
        let events = world.step(environment: environment)
        endAutonomousControlOnKnockout(events)
        restorePointerAuthorityAfterLanding()
        return events
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

    private func endAutonomousControlOnKnockout(_ events: [CombatEvent]) {
        for event in events where event.kind == .knockedOut {
            for actorID in [event.actorID, event.targetID].compactMap({ $0 })
            where controls.isActive(.autonomous, for: actorID) {
                controls.deactivate(.autonomous, for: actorID)
                applyResolvedInput(for: actorID)
            }
        }
        refreshSession()
    }

    private func restorePointerAuthorityAfterLanding() {
        for body in world.snapshot().bodies
        where controls.isActive(.pointer, for: body.actorID) && body.locomotion == .grounded {
            controls.deactivate(.pointer, for: body.actorID)
            applyResolvedInput(for: body.actorID)
        }
    }
}
