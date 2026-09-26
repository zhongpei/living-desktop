import Foundation
import MyPetCombat
import MyPetCore
import MyPet2D
import MyPetEngine
import MyPetCombatCPU

/// Shared combat authority for every visible actor in one desktop session.
/// Solo play owns one coordinator; CastSession injects one shared instance so
/// hitboxes, HP and recovery are resolved on a single deterministic timeline.
@MainActor
final class DesktopCombatCoordinator {
    private let combatRuntime: CombatRuntime
    private let runtime: GameRuntime
    var bodyWorld: BodyWorld { combatRuntime.bodyWorld }
    var world: CombatWorld { combatRuntime.world }
    var hasActiveSession: Bool { world.session?.state == .active }
    var storyUnavailableActorIDs: Set<EntityID> {
        guard hasActiveSession else { return [] }
        return Set(world.snapshot().bodies.compactMap { body in
            switch body.participation {
            case .uninvolved, .withdrawing:
                return body.authority == .scripted ? nil : body.actorID
            case .alerted, .incidentalCombatant, .rosterParticipant:
                return body.actorID
            }
        })
    }
    private var registeredActors = Set<String>()
    private var deliveredPlatformIntents: [String: String] = [:]

    init(
        runtime injectedRuntime: GameRuntime? = nil,
        combatRuntime injectedCombatRuntime: CombatRuntime? = nil
    ) {
        let combatRuntime = injectedCombatRuntime ?? CombatRuntime()
        self.combatRuntime = combatRuntime
        self.runtime = injectedRuntime ?? GameRuntime(
            bodyExecutionMode: .external, combatRuntime: combatRuntime)
        precondition(self.runtime.combatRuntime === combatRuntime)
    }

    func configure(_ settings: GameFeatureSettings) {
        combatRuntime.setFeaturePolicy(settings.combatPolicy)
        combatRuntime.setCombatPacingRate(settings.combatPacingRate)
        combatRuntime.setEscalationPolicy(settings.neutralNPC)
        combatRuntime.setWindowInteractionPolicy(settings.windowInteraction.policy)
        for actor in registeredActors {
            combatRuntime.setAutonomousDifficulty(settings.cpuDifficulty, for: EntityID(actor))
        }
    }

    func register(actorID: EntityID, profile: CombatProfile, x: CGFloat, yFeet: CGFloat,
                  facingRight: Bool, displayHeight: CGFloat,
                  realCombatReady: Bool = true,
                  cpuDifficulty: CombatCPUDifficulty = .normal) {
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
            visualScale: max(0.05, Double(displayHeight) / 110.0),
            realCombatReady: realCombatReady)
        combatRuntime.setAutonomousDifficulty(cpuDifficulty, for: actorID)
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

    @discardableResult
    func beginAutonomousCombat(actorID: EntityID) -> Bool {
        combatRuntime.requestAutonomousCombat(for: actorID)
    }

    @discardableResult
    func beginContactCombat(actorID: EntityID, targetID: EntityID) -> Bool {
        combatRuntime.requestContactEngagement(for: actorID, targetID: targetID)
    }

    func endAutonomousCombat(actorID: EntityID) {
        combatRuntime.deactivate(.autonomous, for: actorID)
    }

    func engagementStatus(actorID: EntityID) -> CombatEngagementStatus? {
        combatRuntime.engagementStatus(for: actorID)
    }

    var registeredActorIDs: [EntityID] {
        world.snapshot().bodies.map(\.actorID).sorted { $0.raw < $1.raw }
    }

    var sessionParticipantIDs: [EntityID] {
        world.session?.participantIDs ?? []
    }

    func beginPointerDrag(actorID: EntityID) {
        combatRuntime.activate(.pointer, for: actorID)
    }

    func endPointerDrag(actorID: EntityID) {
        guard combatRuntime.isActive(.pointer, for: actorID) else { return }
        _ = combatRuntime.endPointerDrag(actorID: actorID)
    }

    func advance(
        elapsedSeconds: Double,
        environment: BodyEnvironment,
        platformContext: GameplayPlatformContext = .idle,
        beforeFrame: (() -> Void)? = nil
    ) -> [CombatEvent] {
        runtime.advance(
            elapsedSeconds: elapsedSeconds,
            combatEnvironment: environment,
            combatPlatformContext: platformContext,
            bodyStep: { _ in beforeFrame?() }).combatEvents
    }

    func body(actorID: EntityID) -> CombatBodyState? { world.body(for: actorID) }

    func ownsCombatActivity(actorID: EntityID) -> Bool {
        combatRuntime.ownsCombatActivity(for: actorID)
    }

    func combatHUDBody(actorID: EntityID) -> CombatBodyState? {
        guard let body = world.body(for: actorID) else { return nil }
        // Show the initiator's HP/energy while it is seeking a target as well
        // as after the shared session is committed.  Without this, a valid
        // request is visually indistinguishable from a dropped menu event.
        guard world.session?.state == .active ||
                combatRuntime.engagementStatus(for: actorID) != nil else { return nil }
        switch body.participation {
        case .uninvolved, .withdrawing:
            return combatRuntime.engagementStatus(for: actorID) != nil ? body : nil
        case .alerted, .incidentalCombatant, .rosterParticipant: return body
        }
    }

    func platformIntent(actorID: EntityID) -> GameplayPlatformIntent? {
        guard let intent = combatRuntime.platformIntents[actorID.raw] else { return nil }
        let token = "\(world.frame):\(String(describing: intent))"
        guard deliveredPlatformIntents[actorID.raw] != token else { return nil }
        deliveredPlatformIntents[actorID.raw] = token
        return intent
    }

    func checkpoint() -> GameRuntimeCheckpoint { runtime.checkpoint() }

}
