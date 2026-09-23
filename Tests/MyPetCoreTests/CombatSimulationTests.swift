import XCTest
import MyPetCombat
import MyPetCore
@testable import MyPetSimulation

final class CombatSimulationTests: XCTestCase {
    func testCombatSnapshotRestoresBitExactWorldState() {
        let desktop = VirtualDesktop(
            screens: [VirtualScreen(id: "main", frame: LayoutRect(x: 0, y: 0, width: 1000, height: 700), main: true)])
        let scenario = VirtualCombatScenario(
            id: "replay",
            desktop: desktop,
            actors: [
                VirtualCombatActor(actorID: EntityID("a"), x: 400, yFeet: 700),
                VirtualCombatActor(actorID: EntityID("b"), x: 455, yFeet: 700, facing: .left),
            ],
            inputs: [
                CombatInputEvent(frame: 0, actorID: EntityID("a"), input: FighterInputFrame(buttons: [.x])),
                CombatInputEvent(frame: 1, actorID: EntityID("a"), input: .neutral),
            ],
            durationFrames: 30)
        let first = CombatDataSimulation(scenario: scenario)
        _ = first.run(frames: 8)
        let restored = CombatDataSimulation(snapshot: first.snapshot())
        _ = first.run(frames: 22)
        _ = restored.run(frames: 22)
        XCTAssertEqual(first.combat.snapshot(), restored.combat.snapshot())
    }

    func testMovingVirtualWindowIsRealCombatSurface() {
        var desktop = VirtualDesktop(
            screens: [VirtualScreen(id: "main", frame: LayoutRect(x: 0, y: 0, width: 1000, height: 800), main: true)],
            windows: [VirtualWindow(
                id: EntityID("w"), app: "Test", title: "Platform",
                frame: LayoutRect(x: 300, y: 400, width: 400, height: 200))])
        desktop.schedule(VirtualDesktopEvent(
            atTick: 2,
            action: .moveWindow(EntityID("w"), LayoutRect(x: 500, y: 500, width: 400, height: 200))))
        let scenario = VirtualCombatScenario(
            id: "moving-window", desktop: desktop,
            actors: [VirtualCombatActor(actorID: EntityID("a"), x: 500, yFeet: 390)],
            durationFrames: 30)
        let sim = CombatDataSimulation(scenario: scenario)
        _ = sim.run(frames: 30)
        XCTAssertNotNil(sim.combat.body(for: EntityID("a")))
    }
}
