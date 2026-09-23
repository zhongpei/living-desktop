import Foundation
import MyPetCombat
import MyPetCore
import MyPet2D
import MyPetEngine

/// Shared combat authority for every visible actor in one desktop session.
/// Solo play owns one coordinator; CastSession injects one shared instance so
/// hitboxes, HP and recovery are resolved on a single deterministic timeline.
@MainActor
final class DesktopCombatCoordinator {
    private let combatRuntime: CombatRuntime
    private let runtime: GameRuntime
    var bodyWorld: BodyWorld { combatRuntime.bodyWorld }
    var world: CombatWorld { combatRuntime.world }
    private var registeredActors = Set<String>()

    init() {
        let combatRuntime = CombatRuntime()
        self.combatRuntime = combatRuntime
        self.runtime = GameRuntime(bodyExecutionMode: .external, combatRuntime: combatRuntime)
    }

    func register(actorID: EntityID, profile: CombatProfile, x: CGFloat, yFeet: CGFloat,
                  facingRight: Bool, displayHeight: CGFloat) {
        guard !registeredActors.contains(actorID.raw) else {
            world.setProfile(profile, for: actorID)
            return
        }
        registeredActors.insert(actorID.raw)
        combatRuntime.register(
            actorID: actorID,
            profile: profile,
            x: Double(x),
            yFeet: Double(yFeet),
            facing: facingRight ? .right : .left,
            visualScale: max(0.05, Double(displayHeight) / 110.0))
    }

    func unregister(actorID: EntityID) {
        registeredActors.remove(actorID.raw)
        combatRuntime.unregister(actorID)
    }

    func setManualInput(_ input: FighterInputFrame, actorID: EntityID) {
        combatRuntime.setInput(input, source: .manual, for: actorID)
    }

    func beginManual(actorID: EntityID) {
        combatRuntime.deactivate(.autonomous, for: actorID)
        combatRuntime.activate(.manual, for: actorID)
    }

    func endManual(actorID: EntityID) {
        combatRuntime.deactivate(.manual, for: actorID)
    }

    func beginAutonomousCombat(actorID: EntityID) {
        combatRuntime.activate(.autonomous, for: actorID)
    }

    func endAutonomousCombat(actorID: EntityID) {
        combatRuntime.deactivate(.autonomous, for: actorID)
    }

    func beginPointerDrag(actorID: EntityID) {
        combatRuntime.activate(.pointer, for: actorID)
    }

    func endPointerDrag(actorID: EntityID) {
        guard combatRuntime.isActive(.pointer, for: actorID) else { return }
    }

    func advance(
        elapsedSeconds: Double,
        environment: BodyEnvironment,
        beforeFrame: (() -> Void)? = nil
    ) -> [CombatEvent] {
        runtime.advance(
            elapsedSeconds: elapsedSeconds,
            combatEnvironment: environment,
            bodyStep: { _ in beforeFrame?() }).combatEvents
    }

    func body(actorID: EntityID) -> CombatBodyState? { world.body(for: actorID) }

    func combatHUDBody(actorID: EntityID) -> CombatBodyState? {
        guard world.session?.state == .active,
              let body = world.body(for: actorID),
              body.rosterRole != .bench else { return nil }
        switch body.participation {
        case .uninvolved, .withdrawing: return nil
        case .alerted, .incidentalCombatant, .rosterParticipant: return body
        }
    }

    func checkpoint() -> GameRuntimeCheckpoint { runtime.checkpoint() }

}
