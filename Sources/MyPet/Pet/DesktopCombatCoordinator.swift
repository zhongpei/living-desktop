import Foundation
import MyPetCombat
import MyPetCore
import MyPet2D

/// Shared combat authority for every visible actor in one desktop session.
/// Solo play owns one coordinator; CastSession injects one shared instance so
/// hitboxes, HP and recovery are resolved on a single deterministic timeline.
@MainActor
final class DesktopCombatCoordinator {
    let bodyWorld: BodyWorld
    let world: CombatWorld
    private var frameClock = CombatFrameClock()
    private let policy = UtilityCombatPolicy()
    private var manualInputs: [String: FighterInputFrame] = [:]
    private var autonomousActors = Set<String>()
    private var pointerActors = Set<String>()
    private var pointerResumeAuthority: [String: CombatControlAuthority] = [:]
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
    }

    func unregister(actorID: EntityID) {
        registeredActors.remove(actorID.raw)
        autonomousActors.remove(actorID.raw)
        pointerActors.remove(actorID.raw)
        pointerResumeAuthority[actorID.raw] = nil
        manualInputs[actorID.raw] = nil
        world.unregister(actorID: actorID)
    }

    func setManualInput(_ input: FighterInputFrame, actorID: EntityID) {
        manualInputs[actorID.raw] = input
        world.setAuthority(.manual, for: actorID)
    }

    func beginManual(actorID: EntityID) {
        autonomousActors.remove(actorID.raw)
        manualInputs[actorID.raw] = .neutral
        world.setAuthority(.manual, for: actorID)
    }

    func endManual(actorID: EntityID) {
        manualInputs[actorID.raw] = nil
        if pointerActors.contains(actorID.raw) {
            pointerResumeAuthority[actorID.raw] = .scripted
        } else {
            world.setInput(.neutral, for: actorID, authority: .scripted)
        }
    }

    func beginAutonomousCombat(actorID: EntityID) {
        autonomousActors.insert(actorID.raw)
        world.setAuthority(.autonomous, for: actorID)
    }

    func endAutonomousCombat(actorID: EntityID) {
        autonomousActors.remove(actorID.raw)
        if pointerActors.contains(actorID.raw) {
            pointerResumeAuthority[actorID.raw] = .scripted
        } else {
            world.setInput(.neutral, for: actorID, authority: .scripted)
        }
    }

    func beginPointerDrag(actorID: EntityID) {
        let previous = world.body(for: actorID)?.authority ?? .scripted
        pointerResumeAuthority[actorID.raw] = previous
        pointerActors.insert(actorID.raw)
        world.setInput(.neutral, for: actorID, authority: .pointer)
    }

    func endPointerDrag(actorID: EntityID) {
        guard pointerActors.contains(actorID.raw) else { return }
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
                if pointerActors.contains(body.actorID.raw) {
                    world.setInput(.neutral, for: body.actorID, authority: .pointer)
                } else if let input = manualInputs[body.actorID.raw] {
                    world.setInput(input, for: body.actorID, authority: .manual)
                } else if autonomousActors.contains(body.actorID.raw) {
                    let opponents = snapshot.bodies.filter {
                        $0.actorID != body.actorID && $0.healthState == .active
                    }
                    world.setInput(
                        policy.decide(CombatObservation(selfBody: body, opponents: opponents)),
                        for: body.actorID,
                        authority: .autonomous)
                } else {
                    world.setInput(.neutral, for: body.actorID, authority: .scripted)
                }
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
        for event in events where event.kind == .knockedOut {
            let involved = [event.actorID, event.targetID].compactMap { $0 }
            for actorID in involved where autonomousActors.remove(actorID.raw) != nil {
                if !pointerActors.contains(actorID.raw),
                   manualInputs[actorID.raw] == nil {
                    world.setInput(.neutral, for: actorID, authority: .scripted)
                }
            }
        }
    }

    private func restorePointerAuthorityAfterLanding() {
        for id in pointerActors.sorted() {
            let actorID = EntityID(id)
            guard let body = world.body(for: actorID),
                  body.locomotion == .grounded else { continue }
            pointerActors.remove(id)
            let authority = pointerResumeAuthority.removeValue(forKey: id) ?? .scripted
            world.setInput(.neutral, for: actorID, authority: authority)
        }
    }

}
