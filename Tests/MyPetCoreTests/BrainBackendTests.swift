import XCTest
@testable import MyPetCore
@testable import MyPetEngine
import MyPetSimulation

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
        XCTAssertEqual(
            BrainBackend.install(mode: .local, cassette: nil, in: GameKernel()).reason,
            "live_adapter_required")
        XCTAssertEqual(
            BrainBackend.install(mode: .teacher, cassette: nil, in: GameKernel()).reason,
            "live_adapter_required")
    }
}
