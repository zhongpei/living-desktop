import XCTest
@testable import MyPetCore

final class GameRuntimeTests: XCTestCase {
    func testPlatformIngressKeepsControlEventsAndCoalescesLatestFacts() {
        let ingress = PlatformEventBuffer(capacity: 2)
        for index in 0..<5 {
            let observation = InputObservation(
                id: "ocr-\(index)", pluginID: "ocr", channel: .ocr,
                appName: "Editor", text: "value-\(index)", capturedAtTick: 0)
            ingress.publish(PlatformEvent(GameEvent(
                kind: .contentObservation, inputObservation: observation)))
        }
        for index in 0..<3 {
            ingress.publish(PlatformEvent(GameEvent(
                kind: .userInteraction, actorID: EntityID("pet"),
                userAction: "tap-\(index)")))
        }

        let events = ingress.drain().map(\.gameEvent)
        XCTAssertEqual(events.filter { $0.kind == .userInteraction }.count, 3)
        XCTAssertEqual(
            events.compactMap(\.inputObservation).map(\.text),
            ["value-4"])
    }

    func testPlatformIngressIsTheRuntimeBoundaryForRealAndVirtualAdapters() {
        let runtime = GameRuntime()
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        runtime.submitPlatform(PlatformEvent(GameEvent(
            kind: .registerEntity, entity: actor)))
        runtime.submitPlatform(PlatformEvent(GameEvent(
            kind: .userInteraction, actorID: actor.id, userAction: "tap")))

        let report = try! XCTUnwrap(runtime.step())

        XCTAssertEqual(report.appliedEvents, 2)
        XCTAssertTrue(runtime.world.isAlive(actor.id))
        XCTAssertEqual(runtime.world.planEpochs[actor.id.raw], 1)
    }

    func testPlatformCallbackNeverBlocksActivePulseAndAppliesNextTick() {
        let runtime = GameRuntime()
        let enteredPulse = DispatchSemaphore(value: 0)
        let releasePulse = DispatchSemaphore(value: 0)
        let pulseFinished = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = runtime.step { _ in
                enteredPulse.signal()
                _ = releasePulse.wait(timeout: .now() + 2)
            }
            pulseFinished.signal()
        }
        XCTAssertEqual(enteredPulse.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            runtime.submitPlatform(PlatformEvent(GameEvent(
                kind: .permissionChanged,
                permissionDomain: "accessibility", permissionAvailable: true)))
            callbackFinished.signal()
        }
        XCTAssertEqual(callbackFinished.wait(timeout: .now() + 0.2), .success)
        releasePulse.signal()
        XCTAssertEqual(pulseFinished.wait(timeout: .now() + 2), .success)

        let report = try! XCTUnwrap(runtime.step())
        XCTAssertEqual(report.appliedEvents, 1)
        XCTAssertTrue(runtime.trace.contains {
            $0.kind == "event" && $0.detail == "permissionChanged:accessibility:granted"
        })
    }

    func testStepAppliesExternalEventsBeforeSemanticWorkAndConsumesLateRequest() {
        let actor = EntityState(id: EntityID("actor"), kind: .actor)
        let runtime = GameRuntime(kernel: GameKernel())
        let request = BehaviorRequest(
            id: "same-tick", actorID: actor.id, intent: "greet",
            priority: .brainReactive, durationTicks: 1)

        let report = try! XCTUnwrap(runtime.step(events: [
            GameEvent(kind: .registerEntity, entity: actor),
        ]) { runtime in
            XCTAssertTrue(runtime.world.isAlive(actor.id))
            runtime.submit(GameEvent(kind: .behaviorRequest, request: request))
        })

        XCTAssertEqual(report.appliedEvents, 2)
        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .completed)
        XCTAssertEqual(runtime.clock.tick, 1)
    }

    func testRuntimeRejectsNestedStepInsteadOfAdvancingClockTwice() {
        let runtime = GameRuntime(kernel: GameKernel())
        var nestedReport: TickReport?

        let report = try! XCTUnwrap(runtime.step { runtime in
            nestedReport = runtime.step()
        })

        XCTAssertEqual(report.tick, 0)
        XCTAssertNil(nestedReport)
        XCTAssertEqual(runtime.clock.tick, 1)
    }

    func testSubmitFromAnotherThreadWaitsUntilCurrentPulseFinishes() {
        let runtime = GameRuntime()
        let enteredSemanticWork = DispatchSemaphore(value: 0)
        let releasePulse = DispatchSemaphore(value: 0)
        let pulseFinished = DispatchSemaphore(value: 0)
        let submitFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = runtime.step { _ in
                enteredSemanticWork.signal()
                _ = releasePulse.wait(timeout: .now() + 2)
            }
            pulseFinished.signal()
        }
        XCTAssertEqual(enteredSemanticWork.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            runtime.submit(GameEvent(kind: .foregroundChanged, entityID: EntityID("window")))
            submitFinished.signal()
        }
        XCTAssertEqual(submitFinished.wait(timeout: .now() + 0.05), .timedOut)

        releasePulse.signal()
        XCTAssertEqual(pulseFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(submitFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(runtime.pendingEventCount, 1)
    }

    func testUserPreemptionInvalidatesLateProductionIntentBeforeBodyCommit() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime()
        _ = runtime.step(events: [GameEvent(kind: .registerEntity, entity: actor)])
        let resolver = ActionRuntime(assetCatalog: AssetCatalog(exactActions: ["wave"]))
        let execution = resolver.execute(
            .perform("wave"),
            tick: runtime.clock.tick,
            actorID: actor.id,
            world: runtime.world,
            context: RuntimeContext())
        let request = try! XCTUnwrap(execution.request)

        runtime.submit(GameEvent(
            kind: .userInteraction, actorID: actor.id, userAction: "grab"))
        runtime.submit(GameEvent(kind: .behaviorRequest, request: request))
        _ = runtime.step()

        XCTAssertEqual(runtime.world.planEpochs[actor.id.raw], request.planEpoch + 1)
        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .rejected)
        XCTAssertTrue(runtime.trace.contains {
            $0.kind == "reject" && $0.detail.contains("stale_plan")
        })
    }

    func testVirtualAndProductionLikeDriversShareRuntimeOrderingAndSemanticPipeline() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let window = VirtualWindow(
            id: EntityID("editor"), app: "editor", title: "Code",
            frame: LayoutRect(x: 0, y: 0, width: 800, height: 600), focused: true,
            content: VirtualWindowContent(activity: "coding"))
        let configuration = SemanticPipelineConfiguration(
            actorID: actor.id,
            assetCatalog: AssetCatalog(exactActions: ["think"]))
        let scenario = HarnessScenario(
            id: "runtime-equivalence", durationTicks: 6,
            entities: [actor],
            slots: [InteractionSlot(entityID: window.id, slotID: "top.right")],
            desktop: VirtualDesktop(windows: [window]),
            pipeline: configuration)

        let virtual = DataSimulation(scenario: scenario)
        _ = virtual.run(ticks: scenario.durationTicks)

        let runtime = GameRuntime(kernel: GameKernel(scenario: scenario))
        let pipeline = SemanticPipeline(configuration: configuration)
        let context = scenario.desktop.runtimeContext
        for _ in 0..<scenario.durationTicks {
            _ = runtime.step { runtime in
                pipeline.beforeTick(kernel: runtime.kernel, context: context)
            }
            pipeline.afterTick(kernel: runtime.kernel)
        }

        XCTAssertEqual(runtime.world.stableDigest(), virtual.runtime.world.stableDigest())
        XCTAssertEqual(pipeline.trace, virtual.pipeline?.trace)
    }

    func testSemanticSceneRunnerLoopsFromDeclaredStepInsteadOfCompleting() {
        let recipe = SimulationSceneRecipe(
            id: "looping", label: "Looping", goals: [.teaseUser], needsUser: true,
            steps: [
                SimulationSceneStep(.performCandidates(["tease", "happy"])),
                SimulationSceneStep(.wait(1), decisionPoint: true),
            ],
            loopFrom: 1)
        let runner = SceneRunner(recipes: [recipe])
        XCTAssertTrue(runner.start(SimulationGoalDecision(goal: .teaseUser)))
        XCTAssertFalse(runner.completeStep())
        XCTAssertEqual(runner.stepIndex, 1)
        XCTAssertFalse(runner.completeStep())
        XCTAssertEqual(runner.status, .running)
        XCTAssertEqual(runner.stepIndex, 1)
    }
}
