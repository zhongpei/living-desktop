import XCTest
@testable import MyPetCore
import MyPetSimulation

final class PointerResponseTests: XCTestCase {
    private let pet = PointerActor(
        id: EntityID("pet"), x: 500, yFeet: 550, displayHeight: 100,
        availableClips: ["look", "surprised", "recover"])

    func testSlowAttentionDoesNotPreemptOrRepeatAndExitRearms() {
        var reflex = PointerReflex()
        XCTAssertNil(reflex.sample(x: 800, y: 500, time: 0, actors: [pet]))
        let entered = reflex.sample(x: 640, y: 500, time: 1, actors: [pet])
        XCTAssertEqual(entered?.kind, .cursorAttention)
        XCTAssertEqual(entered?.clips, ["look"])
        XCTAssertNil(reflex.sample(x: 610, y: 500, time: 2, actors: [pet]))
        XCTAssertNil(reflex.sample(x: 681, y: 500, time: 3, actors: [pet]))
        XCTAssertEqual(reflex.sample(x: 639, y: 500, time: 4, actors: [pet])?.kind, .cursorAttention)
    }

    func testFastApproachUsesSafeClipsAndMovesAwayFromCursor() {
        var reflex = PointerReflex()
        _ = reflex.sample(x: 750, y: 500, time: 0, actors: [pet])
        let right = reflex.sample(x: 550, y: 500, time: 0.1, actors: [pet])
        XCTAssertEqual(right?.kind, .fastApproach)
        XCTAssertEqual(right?.clips, ["surprised", "recover"])
        XCTAssertLessThan(right?.retreatX ?? .infinity, pet.x)
        XCTAssertNil(reflex.sample(x: 549, y: 500, time: 0.2, actors: [pet]))

        var other = PointerReflex()
        _ = other.sample(x: 250, y: 500, time: 0, actors: [pet])
        XCTAssertGreaterThan(other.sample(x: 450, y: 500, time: 0.1, actors: [pet])?.retreatX ?? 0, pet.x)

        var missing = PointerReflex()
        let bare = PointerActor(id: pet.id, x: pet.x, yFeet: pet.yFeet,
                                displayHeight: 100, availableClips: ["happy", "wave", "walk"])
        _ = missing.sample(x: 750, y: 500, time: 0, actors: [bare])
        XCTAssertEqual(missing.sample(x: 550, y: 500, time: 0.1, actors: [bare])?.clips, [])
    }

    func testVirtualCursorMovementDoesNotEmitUserInteraction() {
        let actor = EntityState(id: pet.id, kind: .actor)
        let scenario = HarnessScenario(id: "pointer", entities: [actor], desktop: VirtualDesktop(
            events: [VirtualDesktopEvent(atTick: 0, action: .user(VirtualUserAction(
                kind: .moveCursor, position: LayoutPoint(x: 40, y: 50))))]))
        let simulation = DataSimulation(scenario: scenario)
        _ = simulation.step()
        XCTAssertEqual(simulation.kernel.world.planEpochs[pet.id.raw], 0)
        XCTAssertEqual(simulation.desktop.cursor.position, LayoutPoint(x: 40, y: 50))
    }

    func testSimulationReplayAndMultipleActors() throws {
        let second = PointerActor(id: EntityID("second"), x: 900, yFeet: 550,
                                  displayHeight: 100, availableClips: ["observe"])
        let samples = [
            PointerSample(time: 0, position: LayoutPoint(x: 1100, y: 500), actors: [pet, second]),
            PointerSample(time: 1, position: LayoutPoint(x: 950, y: 500), actors: [pet, second]),
            PointerSample(time: 2, position: LayoutPoint(x: 530, y: 500), actors: [pet, second]),
            PointerSample(time: 3, position: LayoutPoint(x: 530, y: 500), buttonDown: true,
                          actors: [pet, second]),
        ]
        var simulation = PointerSimulation()
        for sample in samples { simulation.step(sample) }
        XCTAssertEqual(simulation.trace.map(\.plan?.actorID.raw), [nil, "second", "pet", nil])
        XCTAssertEqual(simulation.trace[1].plan?.clips, ["observe"])
        XCTAssertEqual(simulation.trace[3].targetID, nil)
        let replayed = try JSONDecoder().decode(PointerSimulation.self,
                                                 from: JSONEncoder().encode(simulation))
        XCTAssertEqual(replayed, simulation)
    }

    func testSamplingRatesAndContextGate() {
        for hz in [20.0, 40.0, 60.0] {
            var simulation = PointerSimulation()
            let far = PointerSample(time: 0, position: LayoutPoint(x: 750, y: 500), actors: [pet])
            let near = PointerSample(time: 1 / hz, position: LayoutPoint(x: 550, y: 500), actors: [pet])
            simulation.step(far)
            XCTAssertEqual(simulation.step(near)?.kind, .fastApproach)
        }
        var gated = PointerSimulation()
        var busy = pet
        busy.ambient = false
        busy.allowsStartle = false
        gated.step(PointerSample(time: 0, position: LayoutPoint(x: 750, y: 500), actors: [busy]))
        XCTAssertNil(gated.step(PointerSample(time: 0.05, position: LayoutPoint(x: 550, y: 500),
                                              actors: [busy])))
    }

    func testLongSampleGapAndCooldownDoNotInventFastApproach() {
        var reflex = PointerReflex()
        _ = reflex.sample(x: 750, y: 500, time: 0, actors: [pet])
        XCTAssertEqual(reflex.sample(x: 550, y: 500, time: 0.3, actors: [pet])?.kind,
                       .cursorAttention)
        _ = reflex.sample(x: 750, y: 500, time: 1, actors: [pet])
        XCTAssertEqual(reflex.sample(x: 550, y: 500, time: 1.1, actors: [pet])?.kind,
                       .fastApproach)
        XCTAssertGreaterThan(reflex.cooldownRemaining(at: 1.1), 5)
        _ = reflex.sample(x: 750, y: 500, time: 2, actors: [pet])
        XCTAssertNotEqual(reflex.sample(x: 550, y: 500, time: 2.1, actors: [pet])?.kind,
                          .fastApproach)
    }

    func testOverlappingActorsLockUntilExitThenReArbitrate() {
        let other = PointerActor(id: EntityID("other"), x: 560, yFeet: 550,
                                 displayHeight: 100, availableClips: ["observe"])
        var reflex = PointerReflex()
        XCTAssertEqual(reflex.sample(x: 510, y: 500, time: 0,
                                     actors: [pet, other])?.actorID, pet.id)
        XCTAssertNil(reflex.sample(x: 555, y: 500, time: 1, actors: [pet, other]))
        XCTAssertEqual(reflex.targetID, pet.id)
        XCTAssertEqual(reflex.sample(x: 560, y: 500, time: 2,
                                     actors: [other])?.actorID, other.id)
    }
}
