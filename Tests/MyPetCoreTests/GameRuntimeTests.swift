import XCTest
@testable import MyPetCore

final class GameRuntimeTests: XCTestCase {
    func testPreparedDecisionsAreOneShotAndRejectOldPlanEpoch() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = PreparedSemanticProvider(actorID: actor.id)
        let goal = SimulationGoalDecision(goal: .wander)
        let context = RuntimeContext()
        let initial = WorldState(entities: [actor.id.raw: actor])
        provider.prepareGoal(goal, planEpoch: 0, context: context)
        provider.prepareSceneSelection(.selected("tea_break"), goal: goal,
                                       planEpoch: 0, context: context)

        XCTAssertEqual(provider.decide(
            tick: 0, context: context, world: initial, actorID: actor.id), goal)
        XCTAssertNil(provider.decide(
            tick: 0, context: context, world: initial, actorID: actor.id))
        XCTAssertEqual(provider.chooseScene(
            goal: goal, tick: 0, context: context,
            world: initial, actorID: actor.id), .selected("tea_break"))
        XCTAssertEqual(provider.chooseScene(
            goal: goal, tick: 0, context: context,
            world: initial, actorID: actor.id), .waitForPrefetch)

        provider.prepareGoal(goal, planEpoch: 0, context: context)
        provider.prepareSceneSelection(.selected("tea_break"), goal: goal,
                                       planEpoch: 0, context: context)
        var newer = initial
        newer.planEpochs[actor.id.raw] = 1
        XCTAssertNil(provider.decide(
            tick: 1, context: context, world: newer, actorID: actor.id))
        XCTAssertEqual(provider.chooseScene(
            goal: goal, tick: 1, context: context,
            world: newer, actorID: actor.id), .waitForPrefetch)
    }

    func testPreparedDecisionPointCannotBeReusedByLaterLoop() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let provider = PreparedSemanticProvider(actorID: actor.id)
        let world = WorldState(entities: [actor.id.raw: actor])
        let goal = SimulationGoalDecision(goal: .wander)
        let step = SimulationSceneStep(.wait(2), decisionPoint: true)
        let context = RuntimeContext()
        provider.prepareDecision(
            .say("greet"), goal: goal, step: step,
            planEpoch: 0, context: context)

        XCTAssertEqual(provider.decideAtPoint(
            step: step, goal: goal, tick: 0, context: context,
            world: world, actorID: actor.id), .say("greet"))
        XCTAssertEqual(provider.decideAtPoint(
            step: step, goal: goal, tick: 1, context: context,
            world: world, actorID: actor.id), .waitForPrefetch)
    }

    func testPipelineCanReuseProductionSemanticEngineWithoutSecondActionSequence() {
        let actor = EntityID("pet")
        let engine = SemanticEngine()
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(actorID: actor),
            engine: engine)
        XCTAssertTrue(pipeline.engine === engine)
        XCTAssertTrue(pipeline.actionRuntime === engine.actionRuntime)
        XCTAssertTrue(pipeline.sceneRunner === engine.sceneRunner)
    }

    private final class DeferredDecisionNeedle: SimulationNeedleProvider {
        let providerID = "deferred-decision"
        var choice: SimulationDecisionPointChoice = .waitForPrefetch
        func decideAtPoint(
            step: SimulationSceneStep, goal: SimulationGoalDecision,
            tick: Int64, context: RuntimeContext, world: WorldState,
            actorID: EntityID
        ) -> SimulationDecisionPointChoice { choice }
        func decide(
            step: SimulationSceneStep, tick: Int64, context: RuntimeContext,
            world: WorldState, actorID: EntityID
        ) -> SimulationNeedleAction? {
            NeedleBrain().decide(
                step: step, tick: tick, context: context,
                world: world, actorID: actorID)
        }
    }

    func testDeferredDecisionPointWaitsThenAuthorizesLeaveThroughBodyResult() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "decision-leave", goals: [.wander],
            steps: [SimulationSceneStep(.wait(1), decisionPoint: true),
                    SimulationSceneStep(.say("should_not_run"))])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "decision-leave", entities: [actor])))
        let provider = DeferredDecisionNeedle()
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            needleProvider: provider, recipes: [recipe])

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let snapshot = pipeline.snapshot()
        XCTAssertNotNil(snapshot.pendingDecisionSinceTick)
        pipeline.restore(snapshot)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.stepIndex, 0)
        XCTAssertNil(pipeline.pendingActionID)
        provider.choice = .leaveScene
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertNotNil(pipeline.pendingActionID)
        XCTAssertEqual(pipeline.sceneRunner.status, .running)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.status, .completed)
        XCTAssertFalse(runtime.world.behaviors.values.contains {
            $0.request.intent == "say:should_not_run"
        })
    }

    func testMissingDecisionAnswerFallsBackAfterTwentySecondsOfRuntimeTicks() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "timeout-decision", goals: [.wander],
            steps: [SimulationSceneStep(.wait(1), decisionPoint: true)])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "timeout-decision", entities: [actor])))
        let provider = DeferredDecisionNeedle()
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            needleProvider: provider, recipes: [recipe])

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        for _ in 0..<400 {
            _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        }

        XCTAssertEqual(pipeline.sceneRunner.status, .completed)
        XCTAssertTrue(pipeline.trace.contains {
            $0.stage == "decision" && $0.detail == "timeout_continue"
        })
    }

    func testDecisionPointHoldsSceneCursorUntilNextDecisionBoundary() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "decision", goals: [.wander],
            steps: [SimulationSceneStep(.wait(1), decisionPoint: true),
                    SimulationSceneStep(.say("greet"))])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "decision-boundary", entities: [actor])))
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())

        XCTAssertEqual(pipeline.sceneRunner.stepIndex, 0)
        XCTAssertEqual(pipeline.sceneRunner.status, .running)
        XCTAssertNil(pipeline.pendingActionID)
    }

    func testFinalDecisionContinuationCompletesWithoutMissingStepFailure() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "final-decision", goals: [.wander],
            steps: [SimulationSceneStep(.wait(1), decisionPoint: true)])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "final-decision", entities: [actor])))
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())

        XCTAssertEqual(pipeline.sceneRunner.status, .completed)
        XCTAssertFalse(pipeline.logicFailures.contains("scene_step_missing"))
    }

    func testSleepKeepsSceneResidentUntilPreempted() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "sleep", goals: [.rest], steps: [SimulationSceneStep(.sleep)])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "resident-sleep", entities: [actor])))
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .rest)),
            recipes: [recipe])

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())

        XCTAssertEqual(pipeline.sceneRunner.status, .running)
        XCTAssertEqual(pipeline.sceneRunner.stepIndex, 0)
        XCTAssertNil(pipeline.pendingActionID)
        _ = runtime.step(
            events: [GameEvent(kind: .userInteraction, actorID: actor.id, userAction: "wake")],
            pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.status, .cancelled)
    }

    func testPreemptionBetweenStepsCancelsOldSceneBeforeNewAction() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "preempt", goals: [.wander],
            steps: [SimulationSceneStep(.wait(1)), SimulationSceneStep(.say("greet"))])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "between-step-preempt", entities: [actor])))
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.stepIndex, 1)
        _ = runtime.step(
            events: [GameEvent(kind: .userInteraction, actorID: actor.id, userAction: "grab")],
            pipeline: pipeline, context: RuntimeContext())

        XCTAssertEqual(pipeline.sceneRunner.status, .cancelled)
        XCTAssertNil(pipeline.pendingActionID)
        XCTAssertFalse(runtime.world.behaviors.values.contains { $0.request.intent == "say:greet" })
    }

    private final class ExplicitSceneNeedle: SimulationNeedleProvider {
        let providerID = "explicit-scene"
        func chooseScene(
            goal: SimulationGoalDecision, tick: Int64, context: RuntimeContext,
            world: WorldState, actorID: EntityID
        ) -> SimulationSceneSelection { .selected("tea_break") }

        func decide(
            step: SimulationSceneStep, tick: Int64, context: RuntimeContext,
            world: WorldState, actorID: EntityID
        ) -> SimulationNeedleAction? {
            NeedleBrain().decide(
                step: step, tick: tick, context: context,
                world: world, actorID: actorID)
        }
    }

    private final class DeferredSceneNeedle: SimulationNeedleProvider {
        let providerID = "deferred-scene"
        var isReady = false
        func chooseScene(
            goal: SimulationGoalDecision, tick: Int64, context: RuntimeContext,
            world: WorldState, actorID: EntityID
        ) -> SimulationSceneSelection {
            isReady ? .selected("tea_break") : .waitForPrefetch
        }
        func decide(
            step: SimulationSceneStep, tick: Int64, context: RuntimeContext,
            world: WorldState, actorID: EntityID
        ) -> SimulationNeedleAction? {
            NeedleBrain().decide(
                step: step, tick: tick, context: context,
                world: world, actorID: actorID)
        }
    }

    func testDeferredSceneSelectionKeepsOneGoalAcrossTicksAndCheckpoint() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "deferred-scene", entities: [actor])))
        let provider = DeferredSceneNeedle()
        let configuration = SemanticPipelineConfiguration(
            actorID: actor.id,
            initialGoal: SimulationGoalDecision(goal: .wander))
        let pipeline = SemanticPipeline(configuration: configuration, needleProvider: provider)

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let snapshot = pipeline.snapshot()
        XCTAssertNotNil(snapshot.pendingSceneGoal)
        XCTAssertNil(pipeline.sceneRunner.recipeID)
        pipeline.restore(snapshot)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.trace.filter { $0.stage == "goal" }.count, 1)
        provider.isReady = true
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.recipeID, "tea_break")
        XCTAssertNil(pipeline.snapshot().pendingSceneGoal)
        XCTAssertEqual(pipeline.trace.filter { $0.stage == "goal" }.count, 1)
    }

    func testExplicitSceneSelectionUsesNeedleChoiceInsteadOfFirstRecipe() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "explicit-scene", entities: [actor])))
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id,
                initialGoal: SimulationGoalDecision(goal: .wander)),
            needleProvider: ExplicitSceneNeedle())

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())

        XCTAssertEqual(pipeline.sceneRunner.recipeID, "tea_break")
    }

    func testAuthoredWaitDurationSurvivesNeedleAndActionRuntime() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let world = WorldState(entities: [actor.id.raw: actor])
        let step = SimulationSceneStep(.wait(3))
        let action = NeedleBrain().decide(
            step: step, tick: 0, context: RuntimeContext(),
            world: world, actorID: actor.id)
        let execution = action.flatMap {
            ActionRuntime().execute(
                $0, tick: 0, actorID: actor.id,
                world: world, context: RuntimeContext())
        }
        XCTAssertEqual(execution?.request?.durationTicks, 3)
    }

    func testLegacyWaitActionWithoutDurationDecodesAsOneTick() throws {
        let legacy = Data(#"{"kind":"wait"}"#.utf8)
        let action = try JSONDecoder().decode(SimulationNeedleAction.self, from: legacy)
        XCTAssertEqual(action, .wait(1))
        let roundTrip = try JSONDecoder().decode(
            SimulationNeedleAction.self,
            from: JSONEncoder().encode(SimulationNeedleAction.wait(3)))
        XCTAssertEqual(roundTrip, .wait(3))
    }

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
            return .wait(1)
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
            guard prepared else { return nil }
            if case .perform(let name) = step.operation { return .perform(name) }
            return .wait(1)
        }
    }

    func testStoryActionRuntimeRejectsNeedleActionThatCannotRepresentAuthoredBeat() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let world = WorldState(entities: [actor.id.raw: actor])
        let runtime = ActionRuntime()

        let mismatch = runtime.executeStory(
            .wait(1), tick: 0, actorID: actor.id, world: world,
            requestID: "story/mismatch", storyIntent: "wave",
            target: nil, slot: nil, claims: ["body"],
            durationTicks: 1, occupySlotOnSuccess: false)
        XCTAssertFalse(mismatch.accepted)
        XCTAssertNil(mismatch.request)

        let match = runtime.executeStory(
            .perform("wave"), tick: 0, actorID: actor.id, world: world,
            requestID: "story/match", storyIntent: "wave",
            target: nil, slot: nil, claims: ["body"],
            durationTicks: 1, occupySlotOnSuccess: false)
        XCTAssertTrue(match.accepted)
        XCTAssertEqual(match.request?.intent, "wave")
    }

    func testStoryMismatchCannotEmitBodyCommandOrSuccessEffects() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let director = StoryDirector(
            episodes: [StoryEpisode(
                id: "mismatch", title: "Mismatch", participants: [actor.id.raw],
                beats: [StoryBeat(id: "wave", actorIDs: [actor.id.raw], intent: "wave")])],
            executionProvider: SemanticStoryExecutionProvider(
                needleProvider: MismatchedNeedleProvider()))
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "story-mismatch", entities: [actor])), bodyExecutionMode: .external)

        _ = runtime.startStory(director)
        _ = runtime.step(storyDirector: director)
        XCTAssertEqual(director.interruptedEpisodeID, "mismatch")
        XCTAssertTrue(runtime.drainBodyCommands().isEmpty)
        XCTAssertNil(runtime.world.facts["episode/mismatch/completed"])
    }

    private final class MismatchedNeedleProvider: SimulationNeedleProvider {
        let providerID = "mismatch-test"
        func decide(
            step: SimulationSceneStep, tick: Int64, context: RuntimeContext,
            world: WorldState, actorID: EntityID
        ) -> SimulationNeedleAction? { .wait(1) }
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

    func testUserDirectActionIsResolvedAfterInterruptionAndPreemptsBrainAction() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .external)
        _ = runtime.step(events: [GameEvent(kind: .registerEntity, entity: actor)])
        let resolver = ActionRuntime(assetCatalog: AssetCatalog(exactActions: ["wave"]))
        let brain = resolver.execute(
            .perform("wave"), tick: runtime.clock.tick, actorID: actor.id,
            world: runtime.world, context: RuntimeContext())
        _ = runtime.submitAction(brain)
        _ = runtime.step()

        runtime.submitPlatform(PlatformEvent(GameEvent(
            kind: .userInteraction, actorID: actor.id, userAction: "menu")))
        _ = runtime.step()
        let direct = resolver.executeUserDirect(
            "wave", tick: runtime.clock.tick, actorID: actor.id, world: runtime.world)
        let request = try! XCTUnwrap(direct.request)
        XCTAssertEqual(request.priority, .userDirect)
        XCTAssertEqual(request.planEpoch, runtime.world.planEpochs[actor.id.raw])
        _ = runtime.submitAction(direct)
        _ = runtime.step()

        XCTAssertEqual(runtime.world.behaviors[request.id]?.status, .running)
        XCTAssertEqual(runtime.drainBodyCommands(for: actor.id).last?.behaviorID, request.id)

        let rest = resolver.executeUserDirect(
            nil, tick: runtime.clock.tick, actorID: actor.id, world: runtime.world)
        XCTAssertEqual(rest.request?.intent, "rest")
        XCTAssertEqual(rest.request?.priority, .userDirect)
    }

    func testSoloPropLifecycleIsInRuntimeCheckpointAndExpiresOnCoreClock() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime()
        _ = runtime.step(events: [GameEvent(kind: .registerEntity, entity: actor)])
        runtime.submit(GameEvent(kind: .propCommand, actorID: actor.id,
                                 propCommand: PropCommand(.spawnHeld, propID: "tea")))
        _ = runtime.step()
        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .held)

        runtime.submit(GameEvent(kind: .propCommand, actorID: actor.id,
                                 propCommand: PropCommand(.putDown, x: 500, y: 800, ttlTicks: 2)))
        _ = runtime.step()
        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .placed)
        let fork = GameRuntime(checkpoint: runtime.checkpoint())
        XCTAssertEqual(fork.world.soloProps, runtime.world.soloProps)

        _ = runtime.step()
        _ = runtime.step()
        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .despawning)
        for _ in 0..<8 { _ = runtime.step() }
        XCTAssertNil(runtime.world.soloProps[actor.id.raw])
    }

    func testSoloPropRejectsFarPickUpAndClearsOnActorDeparture() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime()
        _ = runtime.step(events: [GameEvent(kind: .registerEntity, entity: actor)])
        runtime.submit(GameEvent(kind: .propCommand, actorID: actor.id,
                                 propCommand: PropCommand(.spawnPlaced, propID: "book",
                                                          x: 500, y: 800)))
        _ = runtime.step()
        runtime.submit(GameEvent(kind: .propCommand, actorID: actor.id,
                                 propCommand: PropCommand(.pickUp, x: 100, y: 800, within: 90)))
        _ = runtime.step()
        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .placed)
        runtime.submit(GameEvent(kind: .propCommand, actorID: actor.id,
                                 propCommand: PropCommand(.pickUp, x: 510, y: 800, within: 90)))
        _ = runtime.step()
        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .held)
        _ = runtime.step(events: [GameEvent(kind: .destroyEntity, entityID: actor.id)])
        XCTAssertNil(runtime.world.soloProps[actor.id.raw])
    }

    func testHeadlessAndExternalBodyCompletionApplyTheSamePropFact() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let resolver = ActionRuntime()
        for mode in [BodyExecutionMode.headless, .external] {
            let runtime = GameRuntime(bodyExecutionMode: mode)
            _ = runtime.step(events: [GameEvent(kind: .registerEntity, entity: actor)])
            let execution = resolver.execute(
                .spawnProp("tea"), tick: runtime.clock.tick,
                actorID: actor.id, world: runtime.world, context: RuntimeContext())
            _ = runtime.submitAction(execution)
            _ = runtime.step()
            if mode == .external {
                let command = try! XCTUnwrap(runtime.drainBodyCommands(for: actor.id).first)
                XCTAssertTrue(runtime.submitBodyResult(BodyResult(
                    behaviorID: command.behaviorID,
                    executionToken: command.executionToken,
                    outcome: .completed)))
            }
            _ = runtime.step()
            XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.propID, "tea")
            XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .held)
        }
    }

    func testCancelledPropBodyCannotCreateAnOrphanFact() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let runtime = GameRuntime(bodyExecutionMode: .external)
        _ = runtime.step(events: [GameEvent(kind: .registerEntity, entity: actor)])
        let execution = ActionRuntime().execute(
            .spawnProp("tea"), tick: runtime.clock.tick,
            actorID: actor.id, world: runtime.world, context: RuntimeContext())
        _ = runtime.submitAction(execution)
        _ = runtime.step()
        let command = try! XCTUnwrap(runtime.drainBodyCommands(for: actor.id).first)
        runtime.submit(GameEvent(
            kind: .userInteraction, actorID: actor.id, userAction: "grab"))
        _ = runtime.step()
        XCTAssertFalse(runtime.submitBodyResult(BodyResult(
            behaviorID: command.behaviorID,
            executionToken: command.executionToken,
            outcome: .completed)))
        XCTAssertNil(runtime.world.soloProps[actor.id.raw])
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

    func testHeadlessAndExternalBodiesAdvanceOneSemanticPipelineAtTheSameTickBoundaries() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let configuration = SemanticPipelineConfiguration(
            actorID: actor.id,
            assetCatalog: AssetCatalog(exactActions: ["think", "read", "sit_idle", "nod", "look"]),
            initialGoal: SimulationGoalDecision(goal: .wander))
        let scenario = HarnessScenario(id: "same-semantic-session", entities: [actor])
        let headless = GameRuntime(kernel: GameKernel(scenario: scenario), bodyExecutionMode: .headless)
        let external = GameRuntime(kernel: GameKernel(scenario: scenario), bodyExecutionMode: .external)
        let headlessPipeline = SemanticPipeline(configuration: configuration)
        let externalPipeline = SemanticPipeline(configuration: configuration)
        var commandIDs: [String] = []
        var pendingCommands: [(BodyCommand, Int64)] = []

        for _ in 0..<10 {
            _ = headless.step(pipeline: headlessPipeline, context: RuntimeContext())
            _ = external.step(pipeline: externalPipeline, context: RuntimeContext())
            for command in external.drainBodyCommands() {
                commandIDs.append(command.behaviorID)
                let startedAt = external.clock.tick - 1
                pendingCommands.append((
                    command,
                    startedAt + max(1, command.durationTicks - 1)))
            }
            let due = pendingCommands.filter { $0.1 <= external.clock.tick }
            pendingCommands.removeAll { $0.1 <= external.clock.tick }
            for (command, _) in due {
                XCTAssertTrue(external.submitBodyResult(BodyResult(
                    behaviorID: command.behaviorID,
                    executionToken: command.executionToken,
                    outcome: .completed)))
            }
            XCTAssertEqual(external.world.stableDigest(), headless.world.stableDigest())
            XCTAssertEqual(externalPipeline.trace, headlessPipeline.trace)
            XCTAssertEqual(externalPipeline.sceneRunner.snapshot(), headlessPipeline.sceneRunner.snapshot())
        }
        XCTAssertGreaterThanOrEqual(commandIDs.count, 3)
        XCTAssertEqual(commandIDs.count, Set(commandIDs).count)
    }

    func testHeadlessAndExternalSemanticBodiesRejectTheSamePreemptedCommand() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let configuration = SemanticPipelineConfiguration(
            actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander))
        let scenario = HarnessScenario(id: "preempted-semantic-session", entities: [actor])
        let headless = GameRuntime(kernel: GameKernel(scenario: scenario), bodyExecutionMode: .headless)
        let external = GameRuntime(kernel: GameKernel(scenario: scenario), bodyExecutionMode: .external)
        let headlessPipeline = SemanticPipeline(configuration: configuration)
        let externalPipeline = SemanticPipeline(configuration: configuration)

        _ = headless.step(pipeline: headlessPipeline, context: RuntimeContext())
        _ = external.step(pipeline: externalPipeline, context: RuntimeContext())
        let oldCommand = try! XCTUnwrap(external.drainBodyCommands().first)
        let preempt = GameEvent(kind: .userInteraction, actorID: actor.id, userAction: "grab")
        _ = headless.step(events: [preempt], pipeline: headlessPipeline, context: RuntimeContext())
        _ = external.step(events: [preempt], pipeline: externalPipeline, context: RuntimeContext())

        XCTAssertEqual(headless.world.stableDigest(), external.world.stableDigest())
        XCTAssertEqual(headlessPipeline.trace, externalPipeline.trace)
        XCTAssertEqual(headlessPipeline.sceneRunner.status, .cancelled)
        XCTAssertEqual(externalPipeline.sceneRunner.status, .cancelled)
        XCTAssertFalse(external.submitBodyResult(BodyResult(
            behaviorID: oldCommand.behaviorID,
            executionToken: oldCommand.executionToken,
            outcome: .completed)))
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

    func testDefaultStoryExecutesAuthoredBeatWithoutModelDecisionStages() {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let director = StoryDirector(episodes: [StoryEpisode(
            id: "authored", title: "Authored", participants: [actor.id.raw],
            beats: [StoryBeat(id: "wave", actorIDs: [actor.id.raw], intent: "wave")])])
        let runtime = GameRuntime(kernel: GameKernel(
            scenario: HarnessScenario(id: "authored-story", entities: [actor])))

        XCTAssertEqual(runtime.startStory(director), "authored")
        XCTAssertEqual(director.executionTrace.map(\.stage), ["story.authored"])
        XCTAssertEqual(director.snapshot().requestIDs.count, 1)
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
        XCTAssertEqual(pipeline.logicFailures, ["blocking_scene_provider_requires_prefetch"])
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
