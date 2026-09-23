import Foundation
import MyPetCombat
import MyPetCore

/// Shared combat authority for every visible actor in one desktop session.
/// Solo play owns one coordinator; CastSession injects one shared instance so
/// hitboxes, HP and recovery are resolved on a single deterministic timeline.
@MainActor
final class DesktopCombatCoordinator {
    let world = CombatWorld()
    private var frameClock = CombatFrameClock()
    private let policy = UtilityCombatPolicy()
    private var manualInputs: [String: FighterInputFrame] = [:]
    private var autonomousActors = Set<String>()
    private var pointerActors = Set<String>()
    private var pointerResumeAuthority: [String: CombatControlAuthority] = [:]
    private var registeredActors = Set<String>()

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

    func beginPointerDrag(actorID: EntityID, x: Double, y: Double) {
        let previous = world.body(for: actorID)?.authority ?? .scripted
        pointerResumeAuthority[actorID.raw] = previous
        pointerActors.insert(actorID.raw)
        world.setInput(.neutral, for: actorID, authority: .pointer)
        world.beginDrag(actorID: actorID, x: x, y: y)
    }

    func updatePointerDrag(actorID: EntityID, x: Double, y: Double, elapsedSeconds: Double) {
        guard pointerActors.contains(actorID.raw) else { return }
        world.drag(actorID: actorID, x: x, y: y, elapsedSeconds: elapsedSeconds)
    }

    func endPointerDrag(actorID: EntityID, wasClick: Bool) {
        guard pointerActors.contains(actorID.raw) else { return }
        world.endDrag(actorID: actorID, wasClick: wasClick)
    }

    func synchronize(
        actorID: EntityID,
        x: CGFloat,
        yFeet: CGFloat,
        facingRight: Bool,
        state: PetModel.State,
        displayHeight: CGFloat
    ) {
        let locomotion: BodyLocomotionState
        switch state {
        case .grounded, .perched: locomotion = .grounded
        case .airborne: locomotion = .airborne
        case .dragged: locomotion = .dragged
        case .tossed: locomotion = .tossed
        case .asleep: locomotion = .sleeping
        }
        world.synchronizePose(
            actorID: actorID,
            x: Double(x),
            yFeet: Double(yFeet),
            facing: facingRight ? .right : .left,
            locomotion: locomotion,
            visualScale: max(0.05, Double(displayHeight) / 110.0))
    }

    func advance(elapsedSeconds: Double, desktopWorld: WindowWorld) -> [CombatEvent] {
        let frames = frameClock.advance(elapsedSeconds: elapsedSeconds)
        guard frames > 0 else { return [] }
        var all: [CombatEvent] = []
        for _ in 0..<frames {
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
            all.append(contentsOf: world.step(environment: Self.environment(from: desktopWorld)))
            restorePointerAuthorityAfterLanding()
        }
        return all
    }

    func body(actorID: EntityID) -> CombatBodyState? { world.body(for: actorID) }

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

    private static func environment(from desktopWorld: WindowWorld) -> CombatEnvironment {
        let virtual = Screens.virtualBox()
        var surfaces: [CombatSurface] = Screens.mergedFloorSegments().enumerated().map { index, floor in
            CombatSurface(
                id: "floor:\(index):\(Int(floor.y.rounded()))",
                kind: .floor,
                left: Double(floor.left),
                right: Double(floor.right),
                y: Double(floor.y))
        }
        for window in desktopWorld.windows {
            let host = EntityID("window:\(window.id)")
            surfaces.append(CombatSurface(
                id: "window:\(window.id):top", kind: .windowTop,
                left: Double(window.bounds.minX), right: Double(window.bounds.maxX),
                y: Double(window.topY), hostID: host))
            surfaces.append(CombatSurface(
                id: "window:\(window.id):bottom", kind: .windowBottom,
                left: Double(window.bounds.minX), right: Double(window.bounds.maxX),
                y: Double(window.bottomY), hostID: host))
        }
        return CombatEnvironment(
            bounds: CombatRect(
                x: Double(virtual.left), y: Double(virtual.top),
                width: Double(virtual.width), height: Double(virtual.height)),
            surfaces: surfaces)
    }
}
