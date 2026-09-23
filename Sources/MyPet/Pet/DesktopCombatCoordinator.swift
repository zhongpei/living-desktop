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
    let bodyWorld: BodyWorld
    let world: CombatWorld
    private var frameClock = CombatFrameClock()
    private let policy = UtilityCombatPolicy()
    private var controlRouter = ControlRouter()
    private var registeredActors = Set<String>()

    init() {
        let bodyWorld = BodyWorld()
        self.bodyWorld = bodyWorld
        self.world = CombatWorld(bodyWorld: bodyWorld)
    }

    func register(actorID: EntityID, profile: CombatProfile, x: CGFloat, yFeet: CGFloat,
                  facingRight: Bool, displayHeight: CGFloat) {
        guard !registeredActors.contains(actorID.raw) else {
            world.setProfile(profile, for: actorID)
            return
        }
        registeredActors.insert(actorID.raw)
        world.register(
            actorID: actorID,
            profile: profile,
            x: Double(x),
            yFeet: Double(yFeet),
            facing: facingRight ? .right : .left,
            visualScale: max(0.05, Double(displayHeight) / 110.0))
        refreshSession()
    }

    func unregister(actorID: EntityID) {
        registeredActors.remove(actorID.raw)
        controlRouter.removeActor(actorID)
        world.unregister(actorID: actorID)
        refreshSession()
    }

    func setManualInput(_ input: FighterInputFrame, actorID: EntityID) {
        controlRouter.setInput(input, source: .manual, for: actorID)
    }

    func beginManual(actorID: EntityID) {
        controlRouter.deactivate(.autonomous, for: actorID)
        controlRouter.activate(.manual, for: actorID)
        refreshSession()
    }

    func endManual(actorID: EntityID) {
        controlRouter.deactivate(.manual, for: actorID)
        applyResolvedInput(for: actorID)
        refreshSession()
    }

    func beginAutonomousCombat(actorID: EntityID) {
        controlRouter.activate(.autonomous, for: actorID)
        refreshSession()
    }

    func endAutonomousCombat(actorID: EntityID) {
        controlRouter.deactivate(.autonomous, for: actorID)
        applyResolvedInput(for: actorID)
        refreshSession()
    }

    func beginPointerDrag(actorID: EntityID) {
        controlRouter.activate(.pointer, for: actorID)
        applyResolvedInput(for: actorID)
    }

    func endPointerDrag(actorID: EntityID) {
        guard controlRouter.isActive(.pointer, for: actorID) else { return }
    }

    func advance(
        elapsedSeconds: Double,
        environment: BodyEnvironment,
        beforeFrame: (() -> Void)? = nil
    ) -> [CombatEvent] {
        let frames = frameClock.advance(elapsedSeconds: elapsedSeconds)
        guard frames > 0 else { return [] }
        var all: [CombatEvent] = []
        for _ in 0..<frames {
            beforeFrame?()
            let snapshot = world.snapshot()
            for body in snapshot.bodies {
                if controlRouter.isActive(.autonomous, for: body.actorID) {
                    let opponents = snapshot.bodies.filter {
                        $0.actorID != body.actorID && $0.healthState == .active
                    }
                    controlRouter.setInput(
                        policy.decide(CombatObservation(selfBody: body, opponents: opponents)),
                        source: .autonomous,
                        for: body.actorID)
                }
                applyResolvedInput(for: body.actorID)
            }
            let frameEvents = world.step(environment: environment)
            all.append(contentsOf: frameEvents)
            endAutonomousSparringOnKnockout(frameEvents)
            restorePointerAuthorityAfterLanding()
        }
        return all
    }

    func body(actorID: EntityID) -> CombatBodyState? { world.body(for: actorID) }

    private func endAutonomousSparringOnKnockout(_ events: [CombatEvent]) {
        var changed = false
        for event in events where event.kind == .knockedOut {
            let involved = [event.actorID, event.targetID].compactMap { $0 }
            for actorID in involved
            where controlRouter.isActive(.autonomous, for: actorID) {
                changed = true
                controlRouter.deactivate(.autonomous, for: actorID)
                applyResolvedInput(for: actorID)
            }
        }
        if changed { refreshSession() }
    }

    private func restorePointerAuthorityAfterLanding() {
        for id in registeredActors.sorted() {
            let actorID = EntityID(id)
            guard controlRouter.isActive(.pointer, for: actorID),
                  let body = world.body(for: actorID),
                  body.locomotion == .grounded else { continue }
            controlRouter.deactivate(.pointer, for: actorID)
            applyResolvedInput(for: actorID)
        }
    }

    private func refreshSession() {
        let requested = controlRouter.hasAnyActive([.manual, .authored, .autonomous])
        if requested, registeredActors.count >= 2 {
            _ = world.beginSession(
                id: "desktop",
                participants: registeredActors.sorted().map(EntityID.init))
        } else if world.session?.state == .active {
            world.endSession(cancelled: false)
        }
    }

    private func applyResolvedInput(for actorID: EntityID) {
        if let route = controlRouter.resolve(for: actorID) {
            world.setInput(route.input, for: actorID, authority: route.authority)
        } else {
            world.setInput(.neutral, for: actorID, authority: .scripted)
        }
    }

}
