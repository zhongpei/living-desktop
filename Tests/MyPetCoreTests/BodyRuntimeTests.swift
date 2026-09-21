import XCTest
@testable import MyPetCore

final class BodyRuntimeTests: XCTestCase {
    func testBodyPoseDecodesOldSnapshotWithoutHorizontalSpeed() throws {
        let old = """
        {"actorID":{"raw":"pet"},"x":10,"yFeet":20,"facingRight":true,"motion":"airborne","action":null}
        """
        let pose = try JSONDecoder().decode(BodyPose.self, from: Data(old.utf8))
        XCTAssertEqual(pose.horizontalSpeed, 0)
        XCTAssertEqual(pose.actorID, EntityID("pet"))
    }

    func testExternalBodyBehaviorCompletesOnlyAfterAdapterResult() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .external)
        let request = BehaviorRequest(
            id: "move", actorID: actor.id, intent: "move_to_point:320",
            priority: .brainReactive, completionMode: .body,
            durationTicks: 2, timeoutTicks: 20)

        _ = runtime.stepReplayOrFault(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .behaviorRequest, request: request),
        ])

        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .running)
        let command = try! XCTUnwrap(runtime.drainBodyCommands().first)
        XCTAssertEqual(command.behaviorID, request.id)
        XCTAssertTrue(runtime.drainBodyCommands().isEmpty)

        runtime.submitBodyResult(BodyResult(
            behaviorID: request.id,
            executionToken: command.executionToken,
            outcome: .completed))
        _ = runtime.step()

        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .completed)
    }

    func testHeadlessBodyUsesSameCommandLifecycleAndCompletesDeterministically() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .headless)
        let request = BehaviorRequest(
            id: "perform", actorID: actor.id, intent: "perform:wave",
            priority: .brainReactive, completionMode: .body,
            durationTicks: 2, timeoutTicks: 20)

        _ = runtime.stepReplayOrFault(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .behaviorRequest, request: request),
        ])
        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .running)
        XCTAssertTrue(runtime.drainBodyCommands().isEmpty)

        _ = runtime.step()
        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .completed)
    }

    func testHeadlessBodyExecutesDeterministicPoseProjection() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .headless)
        let request = BehaviorRequest(
            id: "move", actorID: actor.id, intent: "move_to_point:320",
            priority: .brainReactive, completionMode: .body,
            durationTicks: 2, timeoutTicks: 20)

        _ = runtime.stepReplayOrFault(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .behaviorRequest, request: request),
        ])
        XCTAssertEqual(
            runtime.presentationSnapshot().entities.first?.pose?.motion,
            "walking")

        _ = runtime.step()
        let pose = runtime.presentationSnapshot().entities.first?.pose
        XCTAssertEqual(pose?.x, 320)
        XCTAssertEqual(pose?.motion, "grounded")
        XCTAssertTrue(pose?.facingRight == true)
    }

    func testBodyTimeoutCancelsAndReleasesClaim() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let surface = EntityState(id: EntityID("window"), kind: .window)
        let slot = InteractionSlot(entityID: surface.id, slotID: "top")
        let runtime = GameRuntime(bodyExecutionMode: .external)
        let request = BehaviorRequest(
            id: "perch", actorID: actor.id, intent: "perch:window",
            priority: .brainReactive, slot: slot.ref,
            completionMode: .body, durationTicks: 1, timeoutTicks: 2)

        _ = runtime.stepReplayOrFault(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .registerEntity, entity: surface),
            GameEvent(kind: .createSlot, slot: slot),
            GameEvent(kind: .behaviorRequest, request: request),
        ])
        _ = runtime.step()

        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .cancelled)
        XCTAssertEqual(runtime.world.slots[slot.key]?.status, .free)
        XCTAssertTrue(runtime.trace.contains {
            $0.kind == "cancel" && $0.detail == "perch:body_timeout"
        })
    }

    func testPresentationSnapshotProjectsKernelOwnershipAndPoseWithoutOwningIt() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let prop = EntityState(id: EntityID("book"), kind: .prop)
        let runtime = GameRuntime(bodyExecutionMode: .external)
        _ = runtime.stepReplayOrFault(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .registerEntity, entity: prop),
        ])
        runtime.updateBodyPose(BodyPose(
            actorID: actor.id, x: 120, yFeet: 600, facingRight: true,
            motion: "grounded", action: "idle"))

        let snapshot = runtime.presentationSnapshot()

        XCTAssertEqual(snapshot.tick, runtime.clock.tick)
        XCTAssertEqual(snapshot.entities.map(\.id), [prop.id, actor.id])
        XCTAssertEqual(snapshot.entities.first { $0.id == actor.id }?.pose?.x, 120)
        XCTAssertTrue(snapshot.attachments.isEmpty)
    }

    func testPresentationEffectsAreDeliveredExactlyOnce() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .external)
        let request = BehaviorRequest(
            id: "wave", actorID: actor.id, intent: "perform:wave",
            priority: .brainReactive, completionMode: .body,
            durationTicks: 1, timeoutTicks: 10)
        _ = runtime.stepReplayOrFault(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .behaviorRequest, request: request),
        ])
        let command = try! XCTUnwrap(runtime.drainBodyCommands().first)
        runtime.submitBodyResult(BodyResult(
            behaviorID: request.id,
            executionToken: command.executionToken,
            outcome: .completed))
        _ = runtime.step()

        XCTAssertEqual(
            runtime.drainPresentationEffects().map(\.kind),
            [.behaviorStarted, .behaviorCompleted])
        XCTAssertTrue(runtime.drainPresentationEffects().isEmpty)
    }

    func testCancelledResultMayPreemptBeforeAdapterTakesCommand() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .external)
        let request = BehaviorRequest(
            id: "old-plan", actorID: actor.id, intent: "perform:old",
            priority: .brainReactive, completionMode: .body,
            durationTicks: 1, timeoutTicks: 20)
        runtime.submit(GameEvent(kind: .registerEntity, entity: actor))
        runtime.submitReplayOrFault(GameEvent(kind: .behaviorRequest, request: request))
        runtime.cancelBodyBehavior(request.id)

        _ = runtime.step()

        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .cancelled)
        XCTAssertTrue(runtime.drainBodyCommands().isEmpty)
    }

    func testRestoreInvalidatesOldExternalBodyCallbackAndReissuesCommand() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .external)
        let request = BehaviorRequest(
            id: "restore-body", actorID: actor.id, intent: "perform:wave",
            priority: .brainReactive, completionMode: .body,
            durationTicks: 1, timeoutTicks: 20)
        _ = runtime.stepReplayOrFault(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .behaviorRequest, request: request),
        ])
        let oldCommand = try! XCTUnwrap(runtime.drainBodyCommands().first)
        let checkpoint = runtime.checkpoint()

        runtime.restore(checkpoint)
        let resumedCommand = try! XCTUnwrap(runtime.drainBodyCommands().first)

        XCTAssertNotEqual(resumedCommand.executionToken, oldCommand.executionToken)
        XCTAssertFalse(runtime.submitBodyResult(BodyResult(
            behaviorID: request.id,
            executionToken: oldCommand.executionToken,
            outcome: .completed)))
        _ = runtime.step()
        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .running)

        XCTAssertTrue(runtime.submitBodyResult(BodyResult(
            behaviorID: request.id,
            executionToken: resumedCommand.executionToken,
            outcome: .completed)))
        _ = runtime.step()
        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .completed)
    }
}
