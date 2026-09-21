import XCTest
@testable import MyPetCore

final class BrainBackendTests: XCTestCase {
    func testStubAndReplayInstallTheSameCassetteIntoTheRealKernel() {
        let actor = EntityState(id: EntityID("actor"), kind: .actor)
        let request = BehaviorRequest(
            id: "stub-action", actorID: actor.id, intent: "wave", priority: .brainReactive)
        let cassette = BrainCassette(mode: .stub, commands: [BrainCommand(atTick: 0, request: request)])

        let first = GameKernel(scenario: HarnessScenario(id: "stub", durationTicks: 1, entities: [actor]))
        let firstStatus = BrainBackend.install(mode: .stub, cassette: cassette, in: first)
        _ = first.tick()
        XCTAssertTrue(firstStatus.available)
        XCTAssertEqual(first.world.behaviors[request.id]?.status, .completed)

        let replay = GameKernel(scenario: HarnessScenario(id: "replay", durationTicks: 1, entities: [actor]))
        let replayStatus = BrainBackend.install(mode: .replay, cassette: cassette, in: replay)
        _ = replay.tick()
        XCTAssertTrue(replayStatus.available)
        XCTAssertEqual(replay.world.stableDigest(), first.world.stableDigest())
    }

    func testLiveModesReportMissingAdapterInsteadOfPretendingToCallAModel() {
        let kernel = GameKernel()
        let local = LiveBrainAdapter(
            mode: .local,
            configuration: LiveBrainConfiguration(baseURL: "", model: ""))
        let teacher = LiveBrainAdapter(
            mode: .teacher,
            configuration: LiveBrainConfiguration(baseURL: "", model: ""))
        XCTAssertEqual(local.status.reason, "live_http_config_missing")
        XCTAssertEqual(teacher.status.reason, "live_http_config_missing")
        XCTAssertFalse(local.maybeEnqueue(in: kernel).requested)
    }

    func testLiveBrainParsesOnlyWorldSupportedBehaviorRequest() {
        let actor = EntityState(id: EntityID("pilot"), kind: .actor)
        let window = EntityState(id: EntityID("window"), kind: .window)
        let slot = InteractionSlot(entityID: window.id, slotID: "top")
        let world = WorldState(
            entities: [actor.id.raw: actor, window.id.raw: window],
            slots: [slot.key: slot],
            planEpochs: [actor.id.raw: 3])
        let request = LiveBrainAdapter.parseBehavior(
            """
            ```json
            {"actor_id":"pilot","intent":"perch","priority":"brainReactive","duration_ticks":2,"slot":"window/top"}
            ```
            """,
            world: world,
            tick: 7)
        XCTAssertEqual(request?.actorID, actor.id)
        XCTAssertEqual(request?.planEpoch, 3)
        XCTAssertEqual(request?.slot, slot.ref)
        XCTAssertEqual(request?.durationTicks, 2)
        XCTAssertNil(LiveBrainAdapter.parseBehavior(
            "{\"actor_id\":\"ghost\",\"intent\":\"perch\"}",
            world: world,
            tick: 7))
    }

    func testLiveBrainFindsFinalObjectAfterReasoningExamples() {
        let actor = EntityState(id: EntityID("pilot"), kind: .actor)
        let world = WorldState(entities: [actor.id.raw: actor], planEpochs: [actor.id.raw: 2])
        let request = LiveBrainAdapter.parseBehavior(
            """
            I will use this schema: {"actor_id":"ghost","intent":"bad"}.
            ```json
            {"actor_id":"pilot","intent":"idle","priority":"ambient","duration_ticks":1}
            ```
            """,
            world: world,
            tick: 3)
        XCTAssertEqual(request?.actorID, actor.id)
        XCTAssertEqual(request?.planEpoch, 2)
        XCTAssertEqual(request?.intent, "idle")
    }
}
