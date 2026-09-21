import XCTest
@testable import MyPetCore

final class GameRuntimeTests: XCTestCase {
    func testFixedStepClockSeparatesFortyHertzFramesFromFiftyMillisecondTicks() {
        var driver = FixedStepClock(stepMilliseconds: 50)
        XCTAssertEqual(driver.advance(elapsedSeconds: 0.025), 0)
        XCTAssertEqual(driver.advance(elapsedSeconds: 0.025), 1)
        XCTAssertEqual(driver.advance(elapsedSeconds: 0.025), 0)
        XCTAssertEqual(driver.advance(elapsedSeconds: 0.025), 1)
        XCTAssertEqual(driver.advance(elapsedSeconds: 0.25), 5)
        XCTAssertEqual(driver.advance(elapsedSeconds: 2), 5)
        XCTAssertEqual(driver.advance(elapsedSeconds: -1), 0)
        XCTAssertEqual(SimClock(stepMilliseconds: 50).seconds(forTicks: 4), 0.2)
    }

    private final class BlockingGoalProvider: SimulationGoalProvider {
        let providerID = "blocking-test"
        let execution: SimulationProviderExecution = .requiresPrefetch
        var callCount = 0

        func decide(
            tick: Int64,
            context: RuntimeContext,
            world: WorldState,
            actorID: EntityID
        ) -> SimulationGoalDecision? {
            callCount += 1
            return SimulationGoalDecision(goal: .wander, issuedAtTick: tick)
        }
    }

    private final class BlockingNeedleProvider: SimulationNeedleProvider {
        let providerID = "blocking-needle-test"
        let execution: SimulationProviderExecution = .requiresPrefetch
        var callCount = 0

        func decide(
            step: SimulationSceneStep,
            tick: Int64,
            context: RuntimeContext,
            world: WorldState,
            actorID: EntityID
        ) -> SimulationNeedleAction? {
            callCount += 1
            return .wait
        }
    }

    private final class DeferredNeedleProvider: SimulationNeedleProvider {
        let providerID = "prefetched-needle-test"
        let missPolicy: SimulationNeedleMissPolicy = .waitForPrefetch
        var prepared = false

        func decide(
            step: SimulationSceneStep,
            tick: Int64,
            context: RuntimeContext,
            world: WorldState,
            actorID: EntityID
        ) -> SimulationNeedleAction? {
            prepared ? .wait : nil
        }
    }

    private final class DeferredGoalProvider: SimulationGoalProvider {
        let providerID = "prefetched-goal-test"
        let missPolicy: SimulationNeedleMissPolicy = .waitForPrefetch
        var prepared = false
        var calledActors: [EntityID] = []

        func decide(
            tick: Int64,
            context: RuntimeContext,
            world: WorldState,
            actorID: EntityID
        ) -> SimulationGoalDecision? {
            calledActors.append(actorID)
            return prepared ? SimulationGoalDecision(goal: .wander, issuedAtTick: tick) : nil
        }
    }

    private final class StoryScopeGoalProvider: SimulationGoalProvider {
        let providerID = "scoped-goal-test"
        var scope: String?
        var scopes: [String?] = []
        var decisions: [(actorID: EntityID, scope: String?)] = []

        func setStoryScope(_ scope: String?) {
            self.scope = scope
            scopes.append(scope)
        }

        func decide(
            tick: Int64,
            context: RuntimeContext,
            world: WorldState,
            actorID: EntityID
        ) -> SimulationGoalDecision? {
            decisions.append((actorID, scope))
            return SimulationGoalDecision(goal: .wander, issuedAtTick: tick)
        }
    }

    func testRuntimeDetachesFromInjectedKernelOwner() {
        let externalKernel = GameKernel()
        let runtime = GameRuntime(kernel: externalKernel)
        let actor = EntityState(id: EntityID("outside"), kind: .actor)

        externalKernel.enqueue(GameEvent(kind: .registerEntity, entity: actor))
        _ = externalKernel.tick()

        XCTAssertEqual(externalKernel.clock.tick, 1)
        XCTAssertEqual(runtime.clock.tick, 0)
        XCTAssertFalse(runtime.world.isAlive(actor.id))
    }

    func testRestorePreservesRuntimeStoryInterruptionPolicy() {
        let policy = StoryInterruptionPolicy(foreground: false, content: true)
        let runtime = GameRuntime(kernel: GameKernel(storyInterruptionPolicy: policy))

        runtime.restore(runtime.snapshot())

        XCTAssertEqual(runtime.kernel.storyInterruptionPolicy, policy)
    }

    func testCheckpointPreservesExternalBodyAndPendingIngress() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let policy = StoryInterruptionPolicy(foreground: false, content: true)
        let runtime = GameRuntime(
            kernel: GameKernel(storyInterruptionPolicy: policy),
            bodyExecutionMode: .external)
        let request = BehaviorRequest(
            id: "external-body", actorID: actor.id, intent: "perform:wave",
            priority: .brainReactive, completionMode: .body,
            durationTicks: 1, timeoutTicks: 10)
        _ = runtime.stepReplayOrFault(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .behaviorRequest, request: request),
        ])
        runtime.updateBodyPose(BodyPose(
            actorID: actor.id, x: 12, yFeet: 34,
            facingRight: false, motion: "grounded", action: "wave"))
        runtime.submitPlatform(PlatformEvent(GameEvent(
            kind: .permissionChanged,
            permissionDomain: "screen-recording",
            permissionAvailable: true)))

        let restored = GameRuntime(checkpoint: runtime.checkpoint())

        XCTAssertEqual(restored.kernel.storyInterruptionPolicy, policy)
        XCTAssertEqual(restored.drainBodyCommands(for: actor.id).map(\.behaviorID), [request.id])
        XCTAssertEqual(
            restored.presentationSnapshot().entities.first { $0.id == actor.id }?.pose?.action,
            "wave")
        XCTAssertEqual(restored.pendingEventCount, 1)
        XCTAssertEqual(restored.step()?.appliedEvents, 1)
    }

    func testPreviewWorldMatchesSemanticAfterEventsBoundary() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "preview-boundary", entities: [actor])))
        let preview = runtime.previewWorld(events: [GameEvent(
            kind: .userInteraction, actorID: actor.id, userAction: "tap")])
        var observed: WorldState?

        _ = runtime.step(events: [GameEvent(
            kind: .userInteraction, actorID: actor.id, userAction: "tap")]) { state in
            observed = state.world
        }

        XCTAssertEqual(preview, observed)
    }

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
            runtime.submitReplayOrFault(GameEvent(kind: .behaviorRequest, request: request))
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
        runtime.submitReplayOrFault(GameEvent(kind: .behaviorRequest, request: request))
        _ = runtime.step()

        XCTAssertEqual(runtime.world.planEpochs[actor.id.raw], request.planEpoch + 1)
        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .rejected)
        XCTAssertTrue(runtime.trace.contains {
            $0.kind == "reject" && $0.detail.contains("stale_plan")
        })
    }

    func testNormalIngressRejectsRawBehaviorButAcceptsActionExecution() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .external)
        _ = runtime.step(events: [GameEvent(kind: .registerEntity, entity: actor)])
        let execution = ActionRuntime(assetCatalog: AssetCatalog(exactActions: ["wave"]))
            .execute(
                .perform("wave"), tick: runtime.clock.tick, actorID: actor.id,
                world: runtime.world, context: RuntimeContext())
        let request = try! XCTUnwrap(execution.request)

        XCTAssertFalse(runtime.submit(GameEvent(kind: .behaviorRequest, request: request)))
        XCTAssertEqual(runtime.submitAction(execution), request.id)
        _ = runtime.step()

        XCTAssertEqual(runtime.drainBodyCommands(for: actor.id).map(\.behaviorID), [request.id])
    }

    func testNormalStepAndPlatformIngressRejectRawBehavior() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let request = BehaviorRequest(
            id: "forged", actorID: actor.id, intent: "perform:wave",
            priority: .brainReactive, durationTicks: 1)
        let runtime = GameRuntime()

        _ = runtime.step(events: [
            GameEvent(kind: .registerEntity, entity: actor),
            GameEvent(kind: .behaviorRequest, request: request),
        ])
        XCTAssertFalse(runtime.submitPlatform(PlatformEvent(
            GameEvent(kind: .behaviorRequest, request: request))))
        _ = runtime.step()

        XCTAssertNil(runtime.world.behaviors[request.id])
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
            _ = runtime.step(pipeline: pipeline, context: context)
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

    func testRuntimeNeverCallsProviderThatRequiresPrefetchWhileLocked() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = BlockingGoalProvider()
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(actorID: actor.id),
            goalProvider: provider)
        let runtime = GameRuntime(kernel: GameKernel(
            scenario: HarnessScenario(id: "blocking-provider", entities: [actor])))

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())

        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(pipeline.logicFailures, ["blocking_goal_provider_requires_prefetch"])
    }

    func testStoryRefusesBlockingGoalProviderUntilPrefetched() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = BlockingGoalProvider()
        let director = StoryDirector(
            episodes: [StoryEpisode(
                id: "blocked", title: "Blocked", participants: [actor.id.raw],
                beats: [StoryBeat(
                    id: "wave", actorIDs: [actor.id.raw], intent: "wave")])],
            executionProvider: SemanticStoryExecutionProvider(goalProvider: provider))
        let runtime = GameRuntime(kernel: GameKernel(
            scenario: HarnessScenario(id: "blocked-story", entities: [actor])))

        XCTAssertNil(runtime.startStory(director))
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertNil(director.currentEpisodeID)
    }

    func testRuntimeNeverCallsNeedleProviderThatRequiresPrefetchWhileLocked() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = BlockingNeedleProvider()
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(actorID: actor.id),
            needleProvider: provider)
        let runtime = GameRuntime(kernel: GameKernel(
            scenario: HarnessScenario(id: "blocking-needle", entities: [actor])))

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())

        XCTAssertEqual(provider.callCount, 0)
        XCTAssertEqual(pipeline.logicFailures, ["blocking_needle_provider_requires_prefetch"])
    }

    func testStoryRefusesBlockingNeedleProviderUntilPrefetched() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = BlockingNeedleProvider()
        let director = StoryDirector(
            episodes: [StoryEpisode(
                id: "blocked", title: "Blocked", participants: [actor.id.raw],
                beats: [StoryBeat(
                    id: "wave", actorIDs: [actor.id.raw], intent: "wave")])],
            executionProvider: SemanticStoryExecutionProvider(needleProvider: provider))
        let runtime = GameRuntime(kernel: GameKernel(
            scenario: HarnessScenario(id: "blocked-story-needle", entities: [actor])))

        XCTAssertNil(runtime.startStory(director))
        XCTAssertEqual(provider.callCount, 0)
        XCTAssertNil(director.currentEpisodeID)
    }

    func testPrefetchedNeedleMissWaitsWithoutCancellingPipeline() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = DeferredNeedleProvider()
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(actorID: actor.id),
            needleProvider: provider)
        let runtime = GameRuntime(kernel: GameKernel(
            scenario: HarnessScenario(id: "deferred-needle", entities: [actor])))

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.status, .running)
        XCTAssertNil(pipeline.pendingActionID)
        XCTAssertTrue(pipeline.logicFailures.isEmpty)

        provider.prepared = true
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertTrue(pipeline.trace.contains {
            $0.stage == "needle" && $0.detail.hasPrefix("prefetched-needle-test:")
        })
        XCTAssertTrue(pipeline.logicFailures.isEmpty)
    }

    func testStoryRetriesDeferredNeedleWithoutAbortingEpisode() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = DeferredNeedleProvider()
        let director = StoryDirector(
            episodes: [StoryEpisode(
                id: "deferred", title: "Deferred", participants: [actor.id.raw],
                beats: [StoryBeat(
                    id: "wave", actorIDs: [actor.id.raw], intent: "wave")])],
            executionProvider: SemanticStoryExecutionProvider(needleProvider: provider))
        let runtime = GameRuntime(kernel: GameKernel(
            scenario: HarnessScenario(id: "deferred-story", entities: [actor])))

        XCTAssertEqual(runtime.startStory(director), "deferred")
        XCTAssertEqual(director.currentEpisodeID, "deferred")
        XCTAssertTrue(director.snapshot().requestIDs.isEmpty)

        provider.prepared = true
        _ = runtime.step(storyDirector: director)
        XCTAssertEqual(director.currentEpisodeID, "deferred")
        XCTAssertEqual(director.snapshot().requestIDs.count, 1)
        XCTAssertNil(director.interruptedEpisodeID)
    }

    func testStoryRetriesDeferredGoalAndEvaluatesEachActor() {
        let first = EntityState(id: EntityID("a"), kind: .actor)
        let second = EntityState(id: EntityID("b"), kind: .actor)
        let provider = DeferredGoalProvider()
        let director = StoryDirector(
            episodes: [StoryEpisode(
                id: "deferred-goal", title: "Deferred Goal",
                participants: [first.id.raw, second.id.raw],
                beats: [StoryBeat(
                    id: "wave", actorIDs: [first.id.raw, second.id.raw], intent: "wave")])],
            executionProvider: SemanticStoryExecutionProvider(goalProvider: provider))
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "deferred-goal-story", entities: [first, second])))

        XCTAssertEqual(runtime.startStory(director), "deferred-goal")
        XCTAssertEqual(director.currentEpisodeID, "deferred-goal")
        XCTAssertTrue(director.snapshot().requestIDs.isEmpty)

        provider.prepared = true
        _ = runtime.step(storyDirector: director)
        XCTAssertEqual(director.snapshot().requestIDs.count, 2)
        XCTAssertTrue(provider.calledActors.contains(first.id))
        XCTAssertTrue(provider.calledActors.contains(second.id))
        XCTAssertNil(director.interruptedEpisodeID)
    }

    func testConsecutiveIdenticalStoryBeatsChangeScopeBeforeDecisions() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = StoryScopeGoalProvider()
        let director = StoryDirector(
            episodes: [StoryEpisode(
                id: "same-intent", title: "Same Intent", participants: [actor.id.raw],
                beats: [
                    StoryBeat(id: "first", actorIDs: [actor.id.raw], intent: "wave", durationTicks: 1),
                    StoryBeat(id: "second", actorIDs: [actor.id.raw], intent: "wave", durationTicks: 1),
                ])],
            executionProvider: SemanticStoryExecutionProvider(goalProvider: provider))
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "story-scope-beats", entities: [actor])))

        XCTAssertEqual(runtime.startStory(director), "same-intent")
        _ = runtime.step(storyDirector: director)
        _ = runtime.step(storyDirector: director)

        XCTAssertEqual(provider.decisions.count, 2)
        if provider.decisions.count == 2 {
            XCTAssertNotNil(provider.decisions[0].scope)
            XCTAssertNotEqual(provider.decisions[0].scope, provider.decisions[1].scope)
            XCTAssertEqual(provider.decisions[1].scope, provider.scope)
        }
    }

    func testStoryAbortInvalidatesScopeBeforeRestart() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = StoryScopeGoalProvider()
        let director = StoryDirector(
            episodes: [StoryEpisode(
                id: "restart", title: "Restart", participants: [actor.id.raw],
                beats: [StoryBeat(
                    id: "wave", actorIDs: [actor.id.raw], intent: "wave", durationTicks: 10)])],
            configuration: StoryDirectorConfiguration(intervalTicks: 0),
            executionProvider: SemanticStoryExecutionProvider(goalProvider: provider))
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "story-scope-restart", entities: [actor])))

        XCTAssertEqual(runtime.startStory(director), "restart")
        _ = runtime.step(storyDirector: director)
        let oldScope = provider.scope
        runtime.abortStory(director)
        XCTAssertNil(provider.scope)
        var restarted: String?
        for _ in 0..<3 {
            _ = runtime.step()
            restarted = runtime.startStory(director)
            if restarted != nil { break }
        }
        XCTAssertEqual(restarted, "restart")
        XCTAssertNotEqual(provider.scope, oldScope)
        XCTAssertEqual(provider.decisions.last?.scope, provider.scope)
    }

    func testStoryAbortCancelsRequestStillWaitingInInbox() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let director = StoryDirector(episodes: [StoryEpisode(
            id: "queued", title: "Queued", participants: [actor.id.raw],
            beats: [StoryBeat(
                id: "wave", actorIDs: [actor.id.raw], intent: "wave", durationTicks: 10)])])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "queued-story", entities: [actor])))

        XCTAssertEqual(runtime.startStory(director), "queued")
        runtime.abortStory(director)
        _ = runtime.step()

        let requestID = "story/queued/run-1/beat-wave/pet"
        XCTAssertEqual(runtime.world.behaviors[requestID]?.status, .cancelled)
        XCTAssertNil(director.currentEpisodeID)
    }
}
