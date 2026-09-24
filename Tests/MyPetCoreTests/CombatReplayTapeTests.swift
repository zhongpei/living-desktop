import XCTest
import MyPet2D
import MyPetCombat
import MyPetCombatCPU
import MyPetCore
import MyPetEngine

final class CombatReplayTapeTests: XCTestCase {
    func testSerializedTapeReplaysPointerAndManualControlsExactly() throws {
        let runtime = CombatRuntime(cpuSeed: 9)
        runtime.register(actorID: EntityID("a"), profile: CombatProfile(), x: 60, yFeet: 160)
        runtime.register(actorID: EntityID("b"), profile: CombatProfile(), x: 110, yFeet: 160)
        XCTAssertTrue(runtime.beginSession(id: "replay", participants: [EntityID("a"), EntityID("b")]))
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 240, height: 200),
            surfaces: [Surface(id: "floor", kind: .floor, left: 0, right: 240, y: 160)])
        let tape = CombatReplayTape(
            engineVersion: "test", contentFingerprint: "profiles-v2",
            initialCheckpoint: runtime.checkpoint(),
            frames: [
                CombatReplayFrame(environment: environment, controls: [
                    .activate(actorID: EntityID("a"), source: .manual),
                    .input(actorID: EntityID("a"), source: .manual,
                           frame: FighterInputFrame(buttons: [.x])),
                ]),
                CombatReplayFrame(environment: environment, controls: [
                    .releaseManual(actorID: EntityID("a")),
                    .beginDrag(actorID: EntityID("b"), position: Vec2(x: 130, y: 100)),
                ]),
                CombatReplayFrame(environment: environment, controls: [
                    .endDrag(actorID: EntityID("b"), wasClick: false),
                ]),
            ])
        let decoded = try JSONDecoder().decode(
            CombatReplayTape.self, from: JSONEncoder().encode(tape))
        XCTAssertEqual(
            try CombatReplayRunner.replay(
                tape, expectedEngineVersion: "test",
                expectedContentFingerprint: "profiles-v2"),
            try CombatReplayRunner.replay(
                decoded, expectedEngineVersion: "test",
                expectedContentFingerprint: "profiles-v2"))
    }

    func testReplayRejectsForeignMetadata() throws {
        let runtime = CombatRuntime()
        let tape = CombatReplayTape(
            engineVersion: "engine-a", contentFingerprint: "content-a",
            initialCheckpoint: runtime.checkpoint(), frames: [])

        XCTAssertThrowsError(try CombatReplayRunner.replay(
            tape, expectedEngineVersion: "engine-b",
            expectedContentFingerprint: "content-a")) { error in
            XCTAssertEqual(
                error as? CombatReplayRunner.ReplayError,
                .engineVersionMismatch(expected: "engine-b", actual: "engine-a"))
        }
    }

    func testDuplicateWindowIDsAndDecodedAreaAreNormalized() throws {
        let decoded = try JSONDecoder().decode(
            GameplayWindowState.self,
            from: Data(#"{"id":"window:1:top","areaRatio":4}"#.utf8))
        XCTAssertEqual(decoded.areaRatio, 1)

        let runtime = CombatRuntime(cpuSeed: 1)
        let actor = EntityID("cpu")
        runtime.register(actorID: actor, profile: CombatProfile(), x: 60, yFeet: 160)
        runtime.activate(.autonomous, for: actor)
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 240, height: 200),
            surfaces: [Surface(
                id: "window:1:top", kind: .windowTop,
                left: 0, right: 240, y: 160)])
        let duplicate = GameplayWindowState(id: "window:1:top")
        _ = runtime.advance(
            environment: environment,
            platformContext: GameplayPlatformContext(windows: [duplicate, duplicate]))
    }
}
