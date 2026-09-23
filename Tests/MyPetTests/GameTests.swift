import CoreGraphics
import XCTest
import MyPetCore
@testable import MyPetEngine
import MyPetSimulation
import MyPetContent

@testable import MyPetApp
import MyPetPlatform

/// game-v2 纯函数与执行器测试：活动归类、锚点、道具、目标策略、
/// 场景配方执行（假舞台）、记忆、内置台词、设置兼容、OCR profile。
@MainActor
final class GameTests: XCTestCase {
    func testWindowLifecycleProjectionEmitsOnlyMeaningfulChanges() {
        let projection = WindowLifecycleProjection()
        let first = WindowEntity(id: 42, pid: 7, owner: "Code",
                                 bounds: CGRect(x: 10, y: 20, width: 500, height: 400))
        let registered = projection.events(for: [first])
        XCTAssertEqual(registered.map(\.kind), [.registerEntity])
        XCTAssertTrue(projection.events(for: [first]).isEmpty)

        var retitled = first
        retitled.windowTitle = "Changing editor title"
        XCTAssertTrue(projection.events(for: [retitled]).isEmpty)

        var moved = retitled
        moved = WindowEntity(id: 42, pid: 7, owner: "Code",
                             bounds: CGRect(x: 20, y: 20, width: 500, height: 400))
        XCTAssertEqual(projection.events(for: [moved]).map(\.kind), [.windowChanged])
        XCTAssertEqual(projection.events(for: []).map(\.kind), [.destroyEntity])
        XCTAssertEqual(projection.events(for: [first]).map(\.kind), [.windowChanged])

        let handoff = WindowLifecycleProjection(knownEntities: [
            EntityState(id: EntityID("42"), kind: .window, revision: 3),
            EntityState(id: EntityID("43"), kind: .window, revision: 1),
        ])
        XCTAssertEqual(handoff.events(for: [first]).map(\.kind), [.destroyEntity, .windowChanged])

        let reused = WindowLifecycleProjection()
        XCTAssertEqual(reused.events(for: [first]).map(\.kind), [.registerEntity])
        let otherProcess = WindowEntity(id: 42, pid: 99, owner: "Browser",
                                        bounds: first.bounds)
        XCTAssertEqual(reused.events(for: [otherProcess]).map(\.kind),
                       [.destroyEntity, .windowChanged])
    }

    func testSharedForegroundRevisionIsPublishedOnceAcrossOwnerTransfer() {
        let hub = PerceptionHub()
        hub.world.onForegroundChanged?(nil)
        XCTAssertTrue(hub.claimForegroundRevision())
        XCTAssertFalse(hub.claimForegroundRevision())
        hub.resetWindowLifecycle()
        XCTAssertFalse(hub.claimForegroundRevision())
        hub.world.onForegroundChanged?(nil)
        XCTAssertTrue(hub.claimForegroundRevision())
    }

    func testForegroundIdentityChangeWithSameWindowIDStillNotifies() {
        let world = WindowWorld()
        var changes = 0
        world.onForegroundChanged = { _ in changes += 1 }
        let first = WindowEntity(id: 42, pid: 7, owner: "Code",
                                 bounds: CGRect(x: 0, y: 0, width: 500, height: 400))
        let reused = WindowEntity(id: 42, pid: 99, owner: "Browser", bounds: first.bounds)
        world.observeForeground(first)
        world.observeForeground(first)
        world.observeForeground(reused)
        world.observeForeground(nil)
        XCTAssertEqual(changes, 3)
    }


    func testPreparedSoloSceneUsesSameCoreSessionForExternalAndHeadlessBodies() throws {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "prepared-solo", goals: [.wander],
            steps: [SimulationSceneStep(.wait(1))])
        let goal = SimulationGoalDecision(goal: .wander, issuedAtTick: 0)
        let context = RuntimeContext()
        let external = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "external", entities: [actor])), bodyExecutionMode: .external)
        let headless = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "headless", entities: [actor])), bodyExecutionMode: .headless)
        let externalProvider = PreparedSemanticProvider(actorID: actor.id)
        let headlessProvider = PreparedSemanticProvider(actorID: actor.id)
        let externalPipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(actorID: actor.id),
            goalProvider: externalProvider, needleProvider: externalProvider, recipes: [recipe])
        let headlessPipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(actorID: actor.id),
            goalProvider: headlessProvider, needleProvider: headlessProvider, recipes: [recipe])
        externalProvider.prepareGoal(goal, planEpoch: 0, context: context)
        headlessProvider.prepareGoal(goal, planEpoch: 0, context: context)
        _ = external.step(pipeline: externalPipeline, context: context)
        _ = headless.step(pipeline: headlessPipeline, context: context)
        XCTAssertEqual(externalPipeline.snapshot().pendingSceneGoal, goal)
        XCTAssertEqual(headlessPipeline.snapshot().pendingSceneGoal, goal)

        externalProvider.prepareSceneSelection(.selected(recipe.id), goal: goal, planEpoch: 0, context: context)
        headlessProvider.prepareSceneSelection(.selected(recipe.id), goal: goal, planEpoch: 0, context: context)
        _ = external.step(pipeline: externalPipeline, context: context)
        _ = headless.step(pipeline: headlessPipeline, context: context)
        let id = try XCTUnwrap(externalPipeline.pendingActionID)
        XCTAssertEqual(id, headlessPipeline.pendingActionID)
        let stage = FakeStage()
        let adapter = SemanticBodyAdapter(stage: stage) { _ = external.submitBodyResult($0) }
        let command = try XCTUnwrap(external.takeBodyCommand(behaviorID: id))
        let started = try XCTUnwrap(external.world.behaviors[id]?.startedAtTick)
        adapter.consume(command, startedAtTick: started)
        adapter.tick(nowTick: external.clock.tick)
        _ = external.step(pipeline: externalPipeline, context: context)
        _ = headless.step(pipeline: headlessPipeline, context: context)
        XCTAssertEqual(externalPipeline.sceneRunner.snapshot(), headlessPipeline.sceneRunner.snapshot())
        XCTAssertEqual(externalPipeline.trace, headlessPipeline.trace)
        XCTAssertEqual(external.world.behaviors[id]?.status, headless.world.behaviors[id]?.status)
    }

    func testMissingAppKitAnchorFailsCoreSceneWithoutExecutingNextStep() throws {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(id: "missing-anchor", goals: [.wander], steps: [
            SimulationSceneStep(.moveTo("missing")), SimulationSceneStep(.say("greet")),
        ])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "missing-anchor", entities: [actor])), bodyExecutionMode: .external)
        let pipeline = SemanticPipeline(configuration: SemanticPipelineConfiguration(
            actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])
        let stage = FakeStage(resolveAnchor: false)
        let adapter = SemanticBodyAdapter(stage: stage) { _ = runtime.submitBodyResult($0) }

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let id = try XCTUnwrap(pipeline.pendingActionID)
        let command = try XCTUnwrap(runtime.takeBodyCommand(behaviorID: id))
        adapter.consume(command, startedAtTick: runtime.world.behaviors[id]?.startedAtTick ?? 0)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.status, .cancelled)
        XCTAssertFalse(runtime.world.behaviors.values.contains { $0.request.intent == "say:greet" })
    }

    func testFailedPhysicalMoveCancelsCoreScene() throws {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "failed-move", goals: [.wander],
            steps: [SimulationSceneStep(.moveTo("floor_near"))])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "failed-move", entities: [actor])), bodyExecutionMode: .external)
        let pipeline = SemanticPipeline(configuration: SemanticPipelineConfiguration(
            actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])
        let stage = FakeStage()
        stage.failMove = true
        let adapter = SemanticBodyAdapter(stage: stage) { _ = runtime.submitBodyResult($0) }

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let id = try XCTUnwrap(pipeline.pendingActionID)
        let command = try XCTUnwrap(runtime.takeBodyCommand(behaviorID: id))
        adapter.consume(command, startedAtTick: runtime.world.behaviors[id]?.startedAtTick ?? 0)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.status, .cancelled)
        XCTAssertEqual(runtime.world.behaviors[id]?.status, .cancelled)
    }

    func testCorePropFactCommitsBeforeDependentPhysicalStep() throws {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(id: "prop-order", goals: [.wander], steps: [
            SimulationSceneStep(.spawnProp("tea")), SimulationSceneStep(.putDown),
        ])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "prop-order", entities: [actor])), bodyExecutionMode: .external)
        let pipeline = SemanticPipeline(configuration: SemanticPipelineConfiguration(
            actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])
        let stage = FakeStage()
        let adapter = SemanticBodyAdapter(stage: stage) { _ = runtime.submitBodyResult($0) }

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let spawnID = try XCTUnwrap(pipeline.pendingActionID)
        let spawn = try XCTUnwrap(runtime.takeBodyCommand(behaviorID: spawnID))
        adapter.consume(spawn, startedAtTick: runtime.world.behaviors[spawnID]?.startedAtTick ?? 0)
        XCTAssertNil(runtime.world.soloProps[actor.id.raw])
        XCTAssertEqual(pipeline.sceneRunner.stepIndex, 0)

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .held)
        XCTAssertEqual(pipeline.sceneRunner.stepIndex, 1)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let putDownID = try XCTUnwrap(pipeline.pendingActionID)
        let putDown = try XCTUnwrap(runtime.takeBodyCommand(behaviorID: putDownID))
        adapter.consume(putDown, startedAtTick: runtime.world.behaviors[putDownID]?.startedAtTick ?? 0)
        XCTAssertEqual(stage.putDowns, 1)
        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .held)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .placed)
        XCTAssertEqual(pipeline.sceneRunner.status, .completed)
    }

    func testRejectedPhysicalPutDownDoesNotCommitCoreProp() throws {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(id: "put-down-rejected", goals: [.wander], steps: [
            SimulationSceneStep(.spawnProp("tea")), SimulationSceneStep(.putDown),
        ])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "put-down-rejected", entities: [actor])), bodyExecutionMode: .external)
        let pipeline = SemanticPipeline(configuration: SemanticPipelineConfiguration(
            actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])
        let stage = FakeStage()
        let adapter = SemanticBodyAdapter(stage: stage) { _ = runtime.submitBodyResult($0) }

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let spawnID = try XCTUnwrap(pipeline.pendingActionID)
        adapter.consume(try XCTUnwrap(runtime.takeBodyCommand(behaviorID: spawnID)),
                        startedAtTick: runtime.world.behaviors[spawnID]?.startedAtTick ?? 0)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let putDownID = try XCTUnwrap(pipeline.pendingActionID)
        stage.allowPutDown = false
        adapter.consume(try XCTUnwrap(runtime.takeBodyCommand(behaviorID: putDownID)),
                        startedAtTick: runtime.world.behaviors[putDownID]?.startedAtTick ?? 0)
        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())

        XCTAssertEqual(runtime.world.soloProps[actor.id.raw]?.phase, .held)
        XCTAssertEqual(runtime.world.behaviors[putDownID]?.status, .cancelled)
        XCTAssertEqual(pipeline.sceneRunner.status, .cancelled)
    }

    func testSemanticBodyAdapterReportsResultWithoutMovingCoreSceneCursor() throws {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "observable-wait", goals: [.wander],
            steps: [SimulationSceneStep(.wait(1))])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "observable-wait", entities: [actor])), bodyExecutionMode: .external)
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])
        let stage = FakeStage()
        let adapter = SemanticBodyAdapter(stage: stage) { result in
            _ = runtime.submitBodyResult(result)
        }

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let id = try XCTUnwrap(pipeline.pendingActionID)
        let command = try XCTUnwrap(runtime.takeBodyCommand(behaviorID: id))
        let startedAt = try XCTUnwrap(runtime.world.behaviors[id]?.startedAtTick)
        adapter.consume(command, startedAtTick: startedAt)
        adapter.tick(nowTick: runtime.clock.tick)
        XCTAssertEqual(pipeline.sceneRunner.stepIndex, 0)
        XCTAssertEqual(pipeline.sceneRunner.status, .running)

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        XCTAssertEqual(pipeline.sceneRunner.status, .completed)
    }

    func testSemanticBodyAdapterDropsCallbackAfterCancellation() throws {
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let recipe = SimulationSceneRecipe(
            id: "move", goals: [.wander],
            steps: [SimulationSceneStep(.moveTo("floor_near"))])
        let runtime = GameRuntime(kernel: GameKernel(scenario: HarnessScenario(
            id: "cancelled-move", entities: [actor])), bodyExecutionMode: .external)
        let pipeline = SemanticPipeline(
            configuration: SemanticPipelineConfiguration(
                actorID: actor.id, initialGoal: SimulationGoalDecision(goal: .wander)),
            recipes: [recipe])
        let stage = FakeStage()
        stage.completeMovesImmediately = false
        var reported: [BodyResult] = []
        let adapter = SemanticBodyAdapter(stage: stage) { reported.append($0) }

        _ = runtime.step(pipeline: pipeline, context: RuntimeContext())
        let id = try XCTUnwrap(pipeline.pendingActionID)
        let command = try XCTUnwrap(runtime.takeBodyCommand(behaviorID: id))
        let startedAt = try XCTUnwrap(runtime.world.behaviors[id]?.startedAtTick)
        adapter.consume(command, startedAtTick: startedAt)
        adapter.invalidate()
        stage.completeMove()

        XCTAssertTrue(reported.isEmpty)
        XCTAssertEqual(pipeline.sceneRunner.stepIndex, 0)
    }

    func testSharedPerceptionPublishesKernelEventOnlyFromOwner() {
        XCTAssertTrue(PerceptionHub.shouldPublishSharedKernelEvent(
            usesSharedGameplayKernel: false, isOwner: false))
        XCTAssertFalse(PerceptionHub.shouldPublishSharedKernelEvent(
            usesSharedGameplayKernel: true, isOwner: false))
        XCTAssertTrue(PerceptionHub.shouldPublishSharedKernelEvent(
            usesSharedGameplayKernel: true, isOwner: true))
    }

    // MARK: AppActivityCatalog

    func testAppClassificationByBundleAndOwner() {
        XCTAssertEqual(AppActivityCatalog.classify(owner: "?", bundleID: "com.microsoft.vscode"), .coding)
        XCTAssertEqual(AppActivityCatalog.classify(owner: "Code", bundleID: nil), .coding)
        XCTAssertEqual(AppActivityCatalog.classify(owner: "微信", bundleID: nil), .chatting)
        XCTAssertEqual(AppActivityCatalog.classify(owner: "微信", bundleID: "com.tencent.xinweimap"), .chatting,
                       "bundleID 打错时 owner 兜底")
        XCTAssertEqual(AppActivityCatalog.classify(owner: "备忘录", bundleID: nil), .writing)
        XCTAssertEqual(AppActivityCatalog.classify(owner: "Unknown App", bundleID: "com.unknown"), .unknown)
    }

    func testBrowserTitleRefinement() {
        XCTAssertEqual(AppActivityCatalog.classify(owner: "Chrome", bundleID: nil,
                                                   windowTitle: "哔哩哔哩 (173)- YouTube"), .watching)
        XCTAssertEqual(AppActivityCatalog.classify(owner: "Chrome", bundleID: nil,
                                                   windowTitle: "GitHub - mypet"), .reading)
        XCTAssertEqual(AppActivityCatalog.classify(owner: "Chrome", bundleID: nil,
                                                   windowTitle: "新标签页"), .browsing)
        // 非浏览器不做标题细分（避免误判）。
        XCTAssertEqual(AppActivityCatalog.classify(owner: "微信", bundleID: nil,
                                                   windowTitle: "GitHub"), .chatting)
    }

    func testOCRProfilesCoverChatCodeAndBrowserFallbackChannels() {
        XCTAssertNotNil(OCRCatalog.profile(owner: "微信", bundleID: "com.tencent.xinwechat"))
        XCTAssertNotNil(OCRCatalog.profile(owner: "Code", bundleID: "com.microsoft.VSCode"))
        XCTAssertNotNil(OCRCatalog.profile(owner: "Chrome", bundleID: "com.google.Chrome"))
        XCTAssertNotNil(OCRCatalog.profile(owner: "飞书", bundleID: "com.bytedance.feishu"))
    }

    func testAffordancesAndProps() {
        let coding = Affordance.affordances(for: .coding)
        XCTAssertTrue(coding.contains(.perch) && coding.contains(.joinCoding))
        let watching = Affordance.affordances(for: .watching)
        XCTAssertTrue(watching.contains(.joinWatching) && !watching.contains(.joinCoding))
        XCTAssertEqual(AppActivityCatalog.preferredProps(for: .coding), ["laptop"])
        XCTAssertTrue(AppActivityCatalog.preferredProps(for: .files).isEmpty)
    }

    func testExpandedActionFamiliesHaveDeterministicFallbacks() {
        XCTAssertEqual(ActionCatalog.resolve(.windowClimb,
                                             available: ["jump_to_sill", "wave"]), "jump_to_sill")
        XCTAssertEqual(ActionCatalog.resolve(.windowHang,
                                             available: ["think"]), "think")
        XCTAssertEqual(ActionCatalog.resolve(.propTake,
                                             available: ["pick_up"]), "pick_up")
        XCTAssertEqual(ActionCatalog.resolve(.socialHug,
                                             available: ["happy"]), "happy")
        XCTAssertEqual(ActionCatalog.resolve(.mechEnterCockpit,
                                             available: ["think"]), "think")
    }

    // MARK: Anchor

    func testAnchorSpecParseRoundTrip() {
        let spec = AnchorSpec.parse("window_42.topRight")
        XCTAssertEqual(spec?.windowID, 42)
        XCTAssertEqual(spec?.slot, .topRight)
        XCTAssertEqual(spec?.id, "window_42.topRight")
        XCTAssertNil(AnchorSpec.parse("window_42"))          // 缺槽位
        XCTAssertNil(AnchorSpec.parse("window_x.topLeft"))   // 非数字
        XCTAssertEqual(AnchorSpec.parse("floor_near")?.virtual, "floor_near")
    }

    func testAnchorPointMath() {
        let w = WindowEntity(id: 7, pid: 1, owner: "Code",
                             bounds: CGRect(x: 100, y: 200, width: 800, height: 600))
        // 翻转坐标：top = minY，bottom = maxY。
        let topRight = AnchorResolver.point(on: w, slot: .topRight)
        XCTAssertEqual(topRight.x, 100 + 800 * 0.85, accuracy: 0.5)
        XCTAssertEqual(topRight.y, 200)
        let bottomLeft = AnchorResolver.point(on: w, slot: .bottomLeft)
        XCTAssertEqual(bottomLeft.y, 800)
    }

    func testNearbyAnchorsSortedByDistanceAndLimited() {
        let near = WindowEntity(id: 1, pid: 1, owner: "A",
                                bounds: CGRect(x: 200, y: 0, width: 400, height: 300))
        let far = WindowEntity(id: 2, pid: 2, owner: "B",
                               bounds: CGRect(x: 3000, y: 0, width: 400, height: 300))
        var nearVar = near; nearVar.activity = AppActivity.coding.rawValue
        var farVar = far; farVar.activity = AppActivity.chatting.rawValue
        let anchors = AnchorResolver.nearbyAnchors(windows: [farVar, nearVar], petX: 300, limit: 3)
        XCTAssertEqual(anchors.count, 3)
        XCTAssertLessThanOrEqual(anchors[0].distance, anchors[1].distance)
        XCTAssertTrue(anchors.contains { $0.activity == .coding })
        XCTAssertEqual(anchors[0].snapshotID.hasPrefix("window_1."), true, "近窗锚点排前")
    }

    func testAnchorResolveMissingWindowReturnsNil() {
        let spec = AnchorSpec.parse("window_99.topCenter")!
        XCTAssertNil(AnchorResolver.resolve(spec, windows: []))
    }

    // MARK: Prop

    func testPropCatalogKnownIds() {
        XCTAssertNotNil(PropCatalog.def("laptop"))
        XCTAssertEqual(PropCatalog.def("laptop")?.emoji, "💻")
        XCTAssertEqual(PropCatalog.def("laptop")?.displayName.en, "Laptop")
        XCTAssertTrue(PropCatalog.ids.contains("book"))
        XCTAssertNil(PropCatalog.def("tank"))
    }

    // MARK: GoalPolicy

    private func policyCtx(brain: BrainState, personality: Personality = .default,
                           activity: AppActivity = .unknown, idle: Double = 5,
                           hasWindows: Bool = true, now: Double = 100) -> GoalPolicy.Context {
        GoalPolicy.Context(brain: brain, personality: personality, userActivity: activity,
                           userIdleSeconds: idle, hasWindows: hasWindows,
                           secondsSinceInteraction: nil, now: now)
    }

    func testLowEnergyMeansRest() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<20 {
            let goal = GoalPolicy.decide(policyCtx(brain: BrainState(energy: 0.1)), rng: &rng)
            XCTAssertEqual(goal.kind, .rest)
        }
    }

    func testLowEnergyRestCannotBeInterruptedByBoredom() {
        XCTAssertFalse(GoalPolicy.shouldInterruptRest(energy: 0.0, boredom: 1.0))
        XCTAssertTrue(GoalPolicy.shouldInterruptRest(energy: 0.8, boredom: 1.0))

        var brain = BrainState(energy: 0.0)
        brain.boredom = 1.0
        var rng = SeededGenerator(seed: 7)
        XCTAssertEqual(GoalPolicy.decide(policyCtx(brain: brain), rng: &rng).kind, .rest)
    }

    func testHighStressSocialMeansComplain() {
        var rng = SeededGenerator(seed: 7)
        var brain = BrainState(stress: 0.9)
        brain.socialNeed = 0.5
        for _ in 0..<20 {
            let goal = GoalPolicy.decide(policyCtx(brain: brain, personality: .mochiCat), rng: &rng)
            XCTAssertEqual(goal.kind, .complainToUser)
        }
    }

    func testHighStressIntrovertMeansRest() {
        var rng = SeededGenerator(seed: 7)
        var brain = BrainState(stress: 0.9)
        brain.socialNeed = 0.5
        for _ in 0..<20 {
            let goal = GoalPolicy.decide(policyCtx(brain: brain, personality: .linDaiyu), rng: &rng)
            XCTAssertEqual(goal.kind, .rest, "内向角色高应激选择躲开休息而非抗议")
        }
    }

    func testBusyCodingWeightsJoinActivity() {
        var rng = SeededGenerator(seed: 42)
        var hits = 0
        for _ in 0..<200 {
            let goal = GoalPolicy.decide(
                policyCtx(brain: BrainState(energy: 0.8, socialNeed: 0.5, boredom: 0.2),
                          activity: .coding),
                rng: &rng)
            if goal.kind == GoalKind.joinUserActivity {
                hits += 1
                XCTAssertEqual(goal.activity, AppActivity.coding)
                XCTAssertEqual(goal.source, "policy")
            }
        }
        XCTAssertGreaterThan(hits, 40, "用户在编码时陪工目标应占显著权重（P≈1/3）")
    }

    func testIdleUserIsNotBusy() {
        XCTAssertFalse(GoalPolicy.isBusy(policyCtx(brain: BrainState(), idle: 300)))
        XCTAssertTrue(GoalPolicy.isBusy(policyCtx(brain: BrainState(), activity: .coding)))
    }

    // MARK: SceneCatalog / Core semantic session

    func testSceneCompatibilityFiltersByGoalAndActivity() {
        let goal = Goal(kind: .joinUserActivity, target: "user", activity: .coding,
                        style: nil, issuedAt: 0, source: "policy")
        let pool = SceneCatalog.compatible(goal: goal, activity: .coding,
                                           personality: .default, userBusy: true)
        XCTAssertEqual(pool.first?.id, "coding_companion",
                       "goal.activity 命中限定集时优先进对应场景")

        let empathy = SceneCatalog.compatible(
            goal: Goal(kind: .seekAttention, target: "user", activity: nil,
                       style: nil, issuedAt: 0, source: "policy"),
            activity: .coding, personality: .linDaiyu, userBusy: true)
        XCTAssertTrue(empathy.isEmpty, "高共情角色在用户忙时不该有任何打扰型场景可选（空集 = 不打扰）")
        let casual = SceneCatalog.compatible(
            goal: Goal(kind: .seekAttention, target: "user", activity: nil,
                       style: nil, issuedAt: 0, source: "policy"),
            activity: .coding, personality: .default, userBusy: true)
        XCTAssertFalse(casual.isEmpty, "普通共情的角色仍可求关注")
    }

    func testWindowClimbAndPeekRecipeUsesWindowSemantics() {
        let recipe = SceneCatalog.recipe(id: "window_climb_and_peek")
        XCTAssertNotNil(recipe)
        XCTAssertEqual(recipe?.goals, [.explore, .seekAttention])
        XCTAssertEqual(recipe?.steps, [
            SceneStep(.moveTo("@activity.topCenter")),
            SceneStep(.performCandidates(ActionCatalog.candidates(for: .windowClimb))),
            SceneStep(.performCandidates(ActionCatalog.candidates(for: .windowPeek))),
            SceneStep(.wait(120), decisionPoint: true),
        ])
        XCTAssertEqual(recipe?.loopFrom, 2,
                       "爬上窗沿只做一次，之后反复探头并在决策点重新规划")

        let goal = Goal(kind: .explore, target: "window", activity: nil,
                        style: nil, issuedAt: 0, source: "policy")
        XCTAssertTrue(SceneCatalog.compatible(goal: goal, activity: .unknown,
                                              personality: .default, userBusy: false)
            .contains { $0.id == "window_climb_and_peek" })
    }

    func testLegacyPeekRecipeUsesWindowPeekCandidates() {
        let recipe = SceneCatalog.recipe(id: "peek_at_user")
        XCTAssertTrue(recipe?.steps.contains {
            if case .performCandidates(let candidates) = $0.operation {
                return candidates == ActionCatalog.candidates(for: .windowPeek)
            }
            return false
        } == true)
    }

    func testProductionScenesAreTheCoreSemanticRecipes() {
        let projected = Dictionary(uniqueKeysWithValues: SceneCatalog.semanticRecipes.map { ($0.id, $0) })
        XCTAssertEqual(Set(projected.keys), Set(SceneCatalog.recipes.map(\.id)))

        for source in SceneCatalog.recipes {
            let recipe = try! XCTUnwrap(projected[source.id])
            XCTAssertEqual(recipe.label, source.label)
            XCTAssertEqual(Set(recipe.goals.map(\.rawValue)), Set(source.goals.map(\.rawValue)))
            XCTAssertEqual(Set(recipe.activities), Set(source.activities))
            XCTAssertEqual(recipe.needsUser, source.needsUser)
            XCTAssertEqual(recipe.loopFrom, source.loopFrom)
            XCTAssertEqual(recipe.steps.count, source.steps.count)
            XCTAssertEqual(recipe.steps.map(\.decisionPoint), source.steps.map(\.decisionPoint))
            XCTAssertEqual(recipe.steps.map(\.operation), source.steps.map(\.operation))
        }
    }

    // Scene stepping, authorization, timeout and decision-point regressions
    // now live against MyPetCore.SemanticPipeline; AppKit tests above cover
    // the result-only physical adapter.

    // MARK: Memory / Quips

    func testMemoryAddDedupeCapAndPrompt() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MemoryStore(fileURL: url)
        store.capacity = 3
        store.add(kind: "habit", text: "用户常在夜里编码")
        store.add(kind: "habit", text: "用户常在夜里编码")   // 去重
        store.add(kind: "event", text: "昨天给了苹果")
        store.add(kind: "relationship", text: "和猫吵过一架")
        store.add(kind: "event", text: "今天被戳了很多下")
        XCTAssertEqual(store.entries.count, 3, "容量挤出最旧")
        XCTAssertEqual(store.promptLines().count, 3)
        XCTAssertTrue(store.promptLines()[0].hasPrefix("["))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testQuipsNeverEmptyAndStyleShaped() {
        var rng = SeededGenerator(seed: 3)
        for intent in SpeechIntent.allCases {
            let line = Quips.line(for: intent, personality: .mochiCat, rng: &rng)
            XCTAssertFalse(line.isEmpty)
        }
        let reserved = Quips.line(for: .complain, personality: .linDaiyu, rng: &rng)
        XCTAssertFalse(reserved.isEmpty)
    }

    // MARK: Personality

    func testPersonalityPresetsMatchGameDoc() {
        XCTAssertEqual(Personality.linDaiyu.social, 0.35, accuracy: 0.001)
        XCTAssertEqual(Personality.linDaiyu.empathy, 0.90, accuracy: 0.001)
        XCTAssertEqual(Personality.forCharacter("mochi_cat"), .mochiCat)
        XCTAssertEqual(Personality.forCharacter("unknown_pet"), .default)
        XCTAssertFalse(Personality.linDaiyu.promptSection.isEmpty)
        XCTAssertTrue(Personality.linDaiyu.promptSection.contains("teasing=85"))
        XCTAssertEqual(Personality.linDaiyu.teasing, 0.85, accuracy: 0.001)
        XCTAssertEqual(Personality.mochiCat.teasing, 0.72, accuracy: 0.001)
        XCTAssertEqual(Personality.panJinlian.teasing, 0.90, accuracy: 0.001)
        XCTAssertEqual(Personality.reiChibi.teasing, 0.18, accuracy: 0.001)
        XCTAssertEqual(Personality.linDaiyu.styleWord, "reserved")
        XCTAssertEqual(Personality.mochiCat.styleWord, "playful")
    }

    func testTeaseGoalUsesTheDedicatedSceneAndBothOutputs() {
        let goal = Goal(kind: .teaseUser, target: "user", activity: nil,
                        style: "teasing", issuedAt: 0, source: "test")
        let recipes = SceneCatalog.compatible(goal: goal, activity: .unknown,
                                              personality: .panJinlian, userBusy: false)
        XCTAssertEqual(recipes.map(\.id), ["tease_user"])
        guard let recipe = recipes.first else { return }
        XCTAssertTrue(recipe.steps.contains {
            if case .performCandidates(let candidates) = $0.operation {
                return candidates == ActionCatalog.candidates(for: .tease)
            }
            return false
        })
        XCTAssertTrue(recipe.steps.contains {
            if case .say("tease") = $0.operation { return true }
            return false
        })
    }

    func testHighTeasingCanChooseTeaseGoalWhenInteractionIsAllowed() {
        var brain = BrainState(energy: 0.8)
        brain.boredom = 1.0
        brain.socialNeed = 1.0
        let personality = Personality(social: 0, curiosity: 0, playfulness: 0,
                                      empathy: 0, independence: 1, teasing: 1)
        var rng = SeededGenerator(seed: 91)
        var sawTease = false
        for _ in 0..<100 {
            let goal = GoalPolicy.decide(
                policyCtx(brain: brain, personality: personality, idle: 600,
                          hasWindows: false), rng: &rng)
            if goal.kind == .teaseUser {
                sawTease = true
                break
            }
        }
        XCTAssertTrue(sawTease, "高嘲讽倾向且允许互动时应有机会选择 tease_user")
    }

    // MARK: Settings 兼容

    func testSettingsDecodeLegacyTeacherEnabled() throws {
        let legacy = """
        {"currentPet": "lin_daiyu", "brainEnabled": true, "teacherEnabled": true,
         "teacherLogEnabled": true, "perchingEnabled": false}
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertTrue(s.teacherBrainEnabled, "旧 teacherEnabled 迁移为 teacherBrainEnabled")
        XCTAssertTrue(s.brainTraceEnabled)
        XCTAssertEqual(s.currentPet, "lin_daiyu")
        XCTAssertFalse(s.perchingEnabled)
        XCTAssertEqual(s.teacherBrainBaseURL, "http://192.168.2.60:8001/v1", "缺省端点 = 本机 llama.cpp")
    }

    func testSettingsRoundTripKeepsNewKeys() throws {
        var s = Settings()
        s.teacherBrainEnabled = true
        s.teacherBrainModel = "qwen3-32b"
        s.teacherBrainTemperature = 0.2
        s.teacherBrainTopP = 0.9
        s.teacherBrainTopK = 20
        s.teacherBrainMaxTokens = 64
        s.teacherBrainSeed = 42
        s.teacherBrainReasoningEffort = "low"
        s.localBrainEnabled = true
        s.localBrainSpeechEnabled = false
        s.localSpeechPromptUsesCustom = true
        s.localSpeechPromptOverrides = LocalSpeechPromptOverrides(
            factRule: "只使用确认事实",
            sceneDirections: [LocalSpeechSceneID.tease.rawValue: "轻松调侃"])
        s.localBrainGoalTemperature = 0.0
        s.localBrainGoalMaxTokens = 96
        s.localBrainChatTemperature = 0.85
        s.localBrainChatTopP = 0.92
        s.localBrainChatMaxTokens = 72
        s.localBrainChatSeed = 7
        s.actionBrainMaxTokens = 96
        s.ocrEnabled = true
        var chatPlugin = s.inputPlugins.plugins["chat-content"]!
        chatPlugin.enabled = true
        chatPlugin.preemptive = true
        chatPlugin.ttlTicks = 8
        chatPlugin.maxCharacters = 240
        chatPlugin.allowedApplications = ["com.tencent.xinwechat"]
        s.inputPlugins.plugins["chat-content"] = chatPlugin
        s.scenesEnabled = false
        s.propScale = 1.5
        s.castSelection = CastSelection(
            mode: .random,
            allGroupsEnabled: false,
            enabledGroupIDs: ["anime"],
            allMembersEnabled: false,
            enabledMemberIDs: ["rei", "asuka"],
            randomCount: 2,
            maxActiveMembers: 3,
            invitationsEnabled: false,
            automaticArrivalsEnabled: false)
        s.storySettings = StorySettings(
            enabled: false,
            repeatEpisodes: false,
            intervalTicks: 40,
            maxDurationTicks: 600,
            interruptOnForeground: false,
            interruptOnContent: true,
            relationshipEffectsEnabled: false)
        s.characterSpeechSettings["lin_daiyu"] = CharacterSpeechSettings(
            chance: 0.18, minimumInterval: 24,
            ambientEnabled: false, characterEnabled: true,
            windowEnabled: true, environmentEnabled: false, propEnabled: true)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.teacherBrainEnabled)
        XCTAssertEqual(decoded.teacherBrainModel, "qwen3-32b")
        XCTAssertEqual(decoded.teacherBrainTemperature, 0.2, accuracy: 0.001)
        XCTAssertEqual(decoded.teacherBrainTopP, 0.9, accuracy: 0.001)
        XCTAssertEqual(decoded.teacherBrainTopK, 20)
        XCTAssertEqual(decoded.teacherBrainMaxTokens, 64)
        XCTAssertEqual(decoded.teacherBrainSeed, 42)
        XCTAssertEqual(decoded.teacherBrainReasoningEffort, "low")
        XCTAssertTrue(decoded.localBrainEnabled)
        XCTAssertFalse(decoded.localBrainSpeechEnabled)
        XCTAssertTrue(decoded.localSpeechPromptUsesCustom)
        XCTAssertEqual(decoded.localSpeechPromptOverrides.factRule, "只使用确认事实")
        XCTAssertEqual(decoded.localSpeechPromptOverrides.sceneDirections["tease"], "轻松调侃")
        XCTAssertEqual(decoded.localBrainGoalMaxTokens, 96)
        XCTAssertEqual(decoded.localBrainChatTemperature, 0.85, accuracy: 0.001)
        XCTAssertEqual(decoded.localBrainChatTopP, 0.92, accuracy: 0.001)
        XCTAssertEqual(decoded.localBrainChatMaxTokens, 72)
        XCTAssertEqual(decoded.localBrainChatSeed, 7)
        XCTAssertEqual(decoded.actionBrainMaxTokens, 96)
        XCTAssertTrue(decoded.ocrEnabled)
        XCTAssertEqual(decoded.inputPlugins.plugins["chat-content"]?.ttlTicks, 8)
        XCTAssertEqual(decoded.inputPlugins.plugins["chat-content"]?.maxCharacters, 240)
        XCTAssertEqual(decoded.inputPlugins.plugins["chat-content"]?.allowedApplications,
                       ["com.tencent.xinwechat"])
        XCTAssertTrue(decoded.inputPlugins.plugins["chat-content"]?.preemptive == true)
        XCTAssertFalse(decoded.scenesEnabled)
        XCTAssertEqual(decoded.propScale, 1.5, accuracy: 0.001)
        XCTAssertEqual(decoded.castSelection.mode, .random)
        XCTAssertEqual(decoded.castSelection.enabledGroupIDs, ["anime"])
        XCTAssertEqual(decoded.castSelection.enabledMemberIDs, ["asuka", "rei"])
        XCTAssertEqual(decoded.castSelection.randomCount, 2)
        XCTAssertEqual(decoded.castSelection.maxActiveMembers, 3)
        XCTAssertFalse(decoded.castSelection.invitationsEnabled)
        XCTAssertFalse(decoded.castSelection.automaticArrivalsEnabled)
        XCTAssertFalse(decoded.storySettings.enabled)
        XCTAssertFalse(decoded.storySettings.repeatEpisodes)
        XCTAssertEqual(decoded.storySettings.intervalTicks, 40)
        XCTAssertEqual(decoded.storySettings.maxDurationTicks, 600)
        XCTAssertFalse(decoded.storySettings.interruptOnForeground)
        XCTAssertTrue(decoded.storySettings.interruptOnContent)
        XCTAssertFalse(decoded.storySettings.relationshipEffectsEnabled)
        XCTAssertEqual(decoded.characterSpeechSettings["lin_daiyu"]?.chance, 0.18)
        XCTAssertEqual(decoded.characterSpeechSettings["lin_daiyu"]?.minimumInterval, 24)
        XCTAssertFalse(decoded.characterSpeechSettings["lin_daiyu"]?.ambientEnabled ?? true)
        XCTAssertFalse(decoded.characterSpeechSettings["lin_daiyu"]?.environmentEnabled ?? true)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("teacherEnabled"),
                       "落盘不再写旧键")
    }

    func testSettingsEnableLocalPersonaSpeechWithoutEnablingGoalByDefault() throws {
        let fresh = Settings()
        XCTAssertTrue(fresh.localBrainSpeechEnabled)
        XCTAssertFalse(fresh.localBrainEnabled)

        let migrated = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(migrated.localBrainSpeechEnabled)
        XCTAssertFalse(migrated.localBrainEnabled)
        XCTAssertFalse(migrated.localSpeechPromptUsesCustom)
        XCTAssertTrue(migrated.localSpeechPromptOverrides.isEmpty)
    }

    func testSettingsDecodePartialInputCatalogKeepsAllBuiltInPluginEntries() throws {
        let data = """
        {
          "sensesEnabled": true,
          "inputPlugins": {
            "plugins": {
              "chat-content": {
                "displayName": "聊天内容",
                "channel": "chat",
                "enabled": true,
                "ttlTicks": 8,
                "maxCharacters": 240,
                "preemptive": true,
                "priority": 1,
                "allowedApplications": ["WeChat"]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(Set(settings.inputPlugins.plugins.keys), [
            "window-title", "accessibility", "ocr", "chat-content", "code-content", "browser-content",
        ])
        XCTAssertTrue(settings.inputPlugins.isEnabled("chat-content"))
        XCTAssertTrue(settings.inputPlugins.isEnabled("accessibility"),
                      "旧的 sensesEnabled 只应补齐缺失的权限插件")
        XCTAssertFalse(settings.inputPlugins.isEnabled("ocr"))
        XCTAssertEqual(settings.inputPlugins.configuration(for: "browser-content")?.channel, .browser)
    }

    func testSettingsEffectivePluginEnablementHonorsLegacyPermissionKeys() {
        var settings = Settings()
        settings.sensesEnabled = true
        settings.ocrEnabled = true
        settings.inputPlugins.setEnabled(true, for: "chat-content")

        XCTAssertTrue(settings.isInputPluginEnabled("accessibility"))
        XCTAssertTrue(settings.isInputPluginEnabled("ocr"))
        XCTAssertTrue(settings.isInputPluginEnabled("chat-content"))

        settings.inputPlugins.setEnabled(false, for: "chat-content")
        XCTAssertFalse(settings.isInputPluginEnabled("chat-content"))
    }

    // MARK: OCR

    func testOCRCatalogWeChatProfile() {
        let p = OCRCatalog.profile(owner: "微信", bundleID: "com.tencent.xinWeChat")
        XCTAssertEqual(p?.cropRightFraction, 0.44, "微信生产配方：右侧聊天区 44%")
        XCTAssertNotNil(OCRCatalog.profile(owner: "Safari", bundleID: "com.apple.Safari"),
                        "浏览器内容插件开启后应有明确的 OCR profile")
        XCTAssertNil(OCRCatalog.profile(owner: "Unknown App", bundleID: "com.unknown"),
                     "未登记应用仍不得被 OCR 默认覆盖")
    }

    func testOCRCropKeepsRightSide() {
        // 10×10 纯色图裁右侧 40% → 宽 4。
        let width = 10, height = 10
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let profile = OCRProfile(cropRightFraction: 0.4, cropLeftFraction: nil, languages: ["en-US"])
        XCTAssertEqual(OCRSensor.crop(image, profile: profile).width, 4)
        let leftProfile = OCRProfile(cropRightFraction: nil, cropLeftFraction: 0.6, languages: ["en-US"])
        XCTAssertEqual(OCRSensor.crop(image, profile: leftProfile).width, 6)
        let none = OCRProfile.standard()
        XCTAssertEqual(OCRSensor.crop(image, profile: none).width, 10)
    }

    // MARK: Tray / 菜单

    func testTrayStatusItemsDisabled() {
        let items = Tray.makeStatusItems(["角色：lin_daiyu", "目标：rest"])
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertEqual(items[0].title, "角色：lin_daiyu")
    }

    func testTraySummonItemsCarryIdAndPlacement() {
        let props = [(id: "tea", label: "茶"), (id: "laptop", label: "笔记本")]
        let held = Tray.makeSummonItems(props, placed: false, action: nil, target: self)
        let placedItems = Tray.makeSummonItems(props, placed: true, action: nil, target: self)
        XCTAssertEqual(held.map { $0.title }, ["茶", "笔记本"])
        XCTAssertEqual(held.map { $0.representedObject as? String }, ["tea|false", "laptop|false"])
        XCTAssertEqual(placedItems.map { $0.representedObject as? String }, ["tea|true", "laptop|true"])
    }

    func testTraySummonablePropsProjectsGameplayManifest() {
        let plugin = GameplayPlugin(
            id: "props", groupID: "interaction", displayNames: .init("道具"), order: 0,
            implementationID: "props", propIDs: ["tea", "unknown", "tea", "book"])
        let catalog = GameplayCatalog(groups: [], plugins: [plugin])
        XCTAssertEqual(Tray.summonableProps(catalog: catalog).map(\.id), ["book", "tea"])
        XCTAssertEqual(Tray.summonableProps(catalog: nil).map(\.id), PropCatalog.ids)
        XCTAssertTrue(Tray.summonableProps(catalog: GameplayCatalog(groups: [], plugins: [])).isEmpty)
        let settingsOnly = GameplayPlugin(
            id: "props", groupID: "interaction", displayNames: .init("道具"), order: 0,
            implementationID: "props", propIDs: ["tea"], surfaces: ["settings"])
        XCTAssertTrue(Tray.summonableProps(catalog: GameplayCatalog(
            groups: [], plugins: [settingsOnly])).isEmpty)
    }

    func testSettingsStoragePathCanBeIsolatedForDesktopSmoke() {
        let isolated = Settings.storageURL(environment: [
            "MYPET_SETTINGS_PATH": "/tmp/mypet-smoke/settings.json"
        ])
        XCTAssertEqual(isolated.path, "/tmp/mypet-smoke/settings.json")
        XCTAssertNotEqual(isolated.path, Settings.storageURL(environment: [:]).path)
    }

    func testCastSessionStopReleasesRuntimeAndPerceptionOwner() {
        _ = NSApplication.shared
        let pack = CastPack(
            id: "logical", groupID: "test", displayName: "Logical", summary: "",
            members: [CastMember(
                id: "logical-actor", kind: .character, displayName: "Actor",
                visualPackID: "invalid-pack", role: "lead")])
        var settings = Settings()
        settings.castSelection = CastSelection(
            allGroupsEnabled: false, enabledGroupIDs: ["test"],
            allMembersEnabled: true, maxActiveMembers: 1)
        let hub = PerceptionHub()
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        let session = CastSession(
            settingsProvider: { settings }, visualsByActor: ["logical-actor": invalidURL], castPacks: [pack],
            resolvedCastPacks: [], storyPacks: [], layoutCoordinator: SpatialLayoutCoordinator(),
            perceptionHub: hub, sharedNeedle: NeedleBrain(),
            sharedLocalBrain: LocalBrain(), sharedTeacherBrain: TeacherBrain())

        session.start()
        XCTAssertEqual(session.activeMemberIDs, ["logical-actor"])
        XCTAssertNil(session.primaryController)
        XCTAssertNil(hub.ownerID)
        session.retireForPackageChange()
        XCTAssertTrue(session.activeMemberIDs.isEmpty)
        XCTAssertNil(hub.ownerID)
        session.start()
        XCTAssertEqual(session.activeMemberIDs, ["logical-actor"])
        session.stop()
        XCTAssertTrue(session.activeMemberIDs.isEmpty)
    }

    func testContentManagerCanOpenWithEmptyCatalog() {
        _ = NSApplication.shared
        let manager = ContentManagerWindowController()
        manager.records = { [] }
        manager.reload()
        XCTAssertEqual(manager.window?.title, "内容包管理")
        XCTAssertNotNil(manager.window?.contentView)
        manager.close()
    }

    // MARK: GoalDecision 气泡

    func testGoalDecisionClippedSpeech() {
        let d = GoalDecision(goal: .seekAttention, target: "user", activity: nil,
                             style: nil, speech: String(repeating: "哈", count: 100),
                             memory: nil, why: nil)
        XCTAssertEqual(d.clippedSpeech?.count, 60)
    }

    // MARK: game.md 缺口补全（§5/§6/§8/§10/§13/§14/§16）

    func testStartleDetectorFastApproachOnly() {
        var detector = StartleDetector()
        let pet = CGPoint(x: 500, y: 500)
        // 第一帧只建立基线。
        XCTAssertFalse(detector.update(cursor: CGPoint(x: 800, y: 500), pet: pet, now: 0))
        // 高速逼近（300pt/s 不足以触发，先用慢速验证不触发）。
        XCTAssertFalse(detector.update(cursor: CGPoint(x: 750, y: 500), pet: pet, now: 1))
        // 慢速逼近到身边：不触发（那是靠近，不是偷袭）。
        XCTAssertFalse(detector.update(cursor: CGPoint(x: 600, y: 500), pet: pet, now: 2))
        // 高速逼近（450pt → 449.2pt in 1s ≈ 瞬移级）+ 距离近 → 触发。
        var fast = StartleDetector()
        _ = fast.update(cursor: CGPoint(x: 700, y: 500), pet: pet, now: 0)
        XCTAssertTrue(fast.update(cursor: CGPoint(x: 450, y: 500), pet: pet, now: 0.1),
                      "0.1s 内逼近 250pt = 突然靠近")
        // 冷却期内不重复触发。
        _ = fast.update(cursor: CGPoint(x: 700, y: 500), pet: pet, now: 0.2)
        XCTAssertFalse(fast.update(cursor: CGPoint(x: 455, y: 500), pet: pet, now: 0.3))
        // 冷却过后可以再触发。
        fast.reset()
        _ = fast.update(cursor: CGPoint(x: 700, y: 500), pet: pet, now: 100)
        XCTAssertTrue(fast.update(cursor: CGPoint(x: 460, y: 500), pet: pet, now: 100.1))
    }

    func testStartleIgnoresSlowHover() {
        var detector = StartleDetector()
        let pet = CGPoint(x: 0, y: 0)
        _ = detector.update(cursor: CGPoint(x: 90, y: 0), pet: pet, now: 0)
        // 1 秒挪 1pt：就在身边也不是「突然」。
        XCTAssertFalse(detector.update(cursor: CGPoint(x: 89, y: 0), pet: pet, now: 1))
    }

    func testEmotionGestureMappingDegradesGracefully() {
        XCTAssertTrue(EmotionGesture.clips(for: "teasing").contains("flirt"))
        XCTAssertTrue(EmotionGesture.clips(for: "HAPPY").contains("happy"), "情绪词大小写不敏感")
        XCTAssertTrue(EmotionGesture.clips(for: "annoyed").contains("nod"))
        XCTAssertTrue(EmotionGesture.clips(for: "unknown-emotion").isEmpty, "未知情绪 = 光说话不表演")
    }

    func testQuipsSpeakCarriesEmotion() {
        var rng = SeededGenerator(seed: 9)
        let tease = Quips.speak(for: .tease, personality: .default, rng: &rng)
        XCTAssertEqual(tease.emotion, "teasing")
        let complain = Quips.speak(for: .complain, personality: .linDaiyu, rng: &rng)
        XCTAssertEqual(complain.emotion, "grievance", "矜持角色抱怨是幽怨不是恼怒")
        let playfulGreet = Quips.speak(for: .greet, personality: .mochiCat, rng: &rng)
        XCTAssertEqual(playfulGreet.emotion, "happy")
        XCTAssertFalse(playfulGreet.text.isEmpty)
    }

    func testPropCatalogGameDocListComplete() {
        // game.md §10 点名的道具词条。
        for id in ["laptop", "book", "tea", "coffee", "apple", "ball", "pillow", "chair", "umbrella", "phone"] {
            XCTAssertNotNil(PropCatalog.def(id), "缺少 game.md §10 道具 \(id)")
        }
    }

    func testAffordanceHangInBaseList() {
        XCTAssertTrue(Affordance.affordances(for: .files).contains(.hang), "game.md §8 hang 词条")
    }

    func testNeedleSnapshotCarriesPersonality() throws {
        var facts = NeedleBrain.WorldFacts(actor: "lin_daiyu", userIdleSeconds: 5)
        facts.personality = (style: "reserved", social: 35, playfulness: 25, diligence: 65, teasing: 85)
        let text = NeedleBrain.snapshot(facts: facts)
        let body = text.components(separatedBy: "\nquestion:").first ?? text
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        let p = object["personality"] as? [String: Any]
        XCTAssertEqual(p?["style"] as? String, "reserved")
        XCTAssertEqual(p?["social"] as? Int, 35)
        XCTAssertEqual(p?["teasing"] as? Int, 85)
    }

    func testOutcomeRecordShape() throws {
        let record = BrainDecisionLog.outcomeRecord(
            goalKind: "join_user_activity", goalSource: "local", scene: "coding_companion",
            stayedSeconds: 245.7, completed: true, reason: "finished",
            interruptedByUser: false, personalityStyle: "reserved", memoryCount: 6,
            activeApp: "Code", activity: "coding")
        // 序列化成功 + 关键字段齐（game.md §16：轨迹结局是训练 label）。
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: record))
        XCTAssertEqual(record["kind"] as? String, "outcome")
        XCTAssertEqual(record["scene"] as? String, "coding_companion")
        XCTAssertEqual(record["stayed_s"] as? Int, 245)
        XCTAssertEqual(record["completed"] as? Bool, true)
        let goal = record["goal"] as? [String: Any]
        XCTAssertEqual(goal?["kind"] as? String, "join_user_activity")
        XCTAssertNil(record["visible_context"], "结局记录不含任何感知文本")
    }

    func testBrainStateStartledAndLastActivity() {
        var b = BrainState(stress: 0.0)
        b.apply(event: .startled, now: 1)
        XCTAssertGreaterThan(b.stress, 0.0)
        b.adopt(goal: Goal(kind: .explore, target: nil, activity: nil, style: nil,
                           issuedAt: 2, source: "policy"), now: 2)
        XCTAssertEqual(b.lastActivity, "explore")
    }

    // MARK: 道具 v2（独立世界实体：held → placed → despawning）

    private func makePropController() -> PropController {
        let controller = PropController(library: ClipLibrary(characterID: "test", cellSize: CGSize(width: 192, height: 208)))
        controller.panelsEnabled = false
        return controller
    }

    func testPropPresentationFollowsCommittedLifecycleAndCanDiscardFrames() {
        let props = makePropController()
        props.tick(petX: 500, petYFeet: 800, facingRight: true, displayHeight: 110,
                   now: 0, worldProp: SoloProp(propID: "laptop", phase: .held))
        XCTAssertEqual(props.entity?.state, .held)

        let placed = SoloProp(propID: "laptop", phase: .placed, x: 560, y: 800)
        props.tick(petX: 500, petYFeet: 800, facingRight: true, displayHeight: 110,
                   now: 10, worldProp: placed)
        XCTAssertEqual(props.entity?.state, .placed)
        props.tick(petX: 900, petYFeet: 800, facingRight: false, displayHeight: 110,
                   now: 10.5, worldProp: placed)
        XCTAssertNil(props.entity?.tween)
        XCTAssertEqual(props.entity?.x ?? -1, 560, accuracy: 1)
        XCTAssertEqual(props.entity?.footY ?? -1, 800, accuracy: 1)

        props.tick(petX: 900, petYFeet: 800, facingRight: false, displayHeight: 110,
                   now: 40.1,
                   worldProp: SoloProp(propID: "laptop", phase: .despawning, x: 560, y: 800))
        XCTAssertEqual(props.entity?.state, .despawning)
        props.tick(petX: 900, petYFeet: 800, facingRight: false, displayHeight: 110,
                   now: 40.6, worldProp: nil)
        XCTAssertNil(props.entity)
    }

    func testPropNearRuleComesFromCoreState() {
        let placed = SoloProp(propID: "tea", phase: .placed, x: 530, y: 800)
        XCTAssertTrue(placed.isPlacedNear(x: 540, y: 800, within: 90))
        XCTAssertFalse(placed.isPlacedNear(x: 5_000, y: 800, within: 90))
        let held = SoloProp(propID: "tea", phase: .held)
        XCTAssertFalse(held.isPlacedNear(x: 0, y: 0, within: 90))
    }

    func testPropSizeScalesWithDisplayHeight() {
        let props = makePropController()
        props.tick(petX: 500, petYFeet: 800, facingRight: true,
                   displayHeight: 110, now: 0,
                   worldProp: SoloProp(propID: "laptop", phase: .held))
        // 世界尺寸 = displayHeight × scale（Q 版基准已整体放大：laptop 0.46）。
        let normal = props.entity?.size(displayHeight: 110) ?? 0
        let large = props.entity?.size(displayHeight: 180) ?? 0
        XCTAssertEqual(normal, CGFloat(110 * 0.46), accuracy: 0.5)
        XCTAssertEqual(large, CGFloat(180 * 0.46), accuracy: 0.5)
        // 用户倍率再乘一层（设置窗「道具大小」）。
        props.userScale = 1.5
        let boosted = props.entity?.effectiveSize(displayHeight: 110, userScale: props.userScale) ?? 0
        XCTAssertEqual(boosted, CGFloat(110 * 0.46 * 1.5), accuracy: 0.5)
        // 手部锚点在面朝方向半臂处。
        let right = PropEntity.holdPoint(petX: 500, petYFeet: 800, facingRight: true, displayHeight: 100)
        let left = PropEntity.holdPoint(petX: 500, petYFeet: 800, facingRight: false, displayHeight: 100)
        XCTAssertEqual(right.x, 530, accuracy: 0.5)
        XCTAssertEqual(left.x, 470, accuracy: 0.5)
        XCTAssertEqual(right.y, 755, accuracy: 0.5)
    }

    func testPlacedPropProjectionDoesNotFollowActor() {
        let props = makePropController()
        props.tick(petX: 1200, petYFeet: 800, facingRight: true, displayHeight: 110,
                   now: 1, worldProp: SoloProp(propID: "tea", phase: .placed, x: 560, y: 800))
        let x = props.entity?.x ?? -1
        XCTAssertEqual(x, CGFloat(560), accuracy: 1)
        props.tick(petX: 1200, petYFeet: 800, facingRight: true, displayHeight: 110,
                   now: 2, worldProp: SoloProp(propID: "tank", phase: .placed))
        XCTAssertNil(props.entity, "没有素材元数据的 Core 道具不生成假面板")
    }

    func testPropHoldPointMathCoveredAbove() {}

    func testSceneRecipesUsePutDownNotOrphanClear() {
        // tea_break / read_near_user 以 putDown 收尾（道具留在原地淡出，不是瞬间清掉）。
        for id in ["tea_break", "read_near_user"] {
            let recipe = SceneCatalog.recipe(id: id)
            XCTAssertEqual(recipe?.steps.last?.operation, .putDown, "\(id) 应以放下收尾")
        }
    }

    func testNeedlePutDownPickUpToolsAndValidation() throws {
        var facts = NeedleBrain.WorldFacts(actor: "mochi_cat", userIdleSeconds: 5)
        facts.heldProp = "laptop"
        facts.propNearby = "tea"
        let schema = try JSONSerialization.jsonObject(
            with: Data(NeedleBrain.toolSchema(facts: facts).utf8)) as! [[String: Any]]
        let names = Set(schema.map { (($0["function"] as! [String: Any])["name"] as! String) })
        XCTAssertTrue(names.contains("put_down"))
        XCTAssertFalse(names.contains("pick_up"), "持有道具时不能再拾取")

        XCTAssertTrue(NeedleBrain.validate(.putDown, facts: facts))
        XCTAssertFalse(NeedleBrain.validate(.pickUp, facts: facts))
        // 没持有 → put_down 非法；附近没道具 → pick_up 非法。
        facts.heldProp = nil
        XCTAssertFalse(NeedleBrain.validate(.putDown, facts: facts))
        XCTAssertTrue(NeedleBrain.validate(.pickUp, facts: facts))
        facts.propNearby = nil
        XCTAssertFalse(NeedleBrain.validate(.pickUp, facts: facts))
    }
}

// MARK: - Result-only AppKit stage fixture

private final class FakeStage: SceneStaging {
    var petX: CGFloat = 100
    var petYFeet: CGFloat = 800
    var resolveAnchorSucceeds = true
    var performedClips: [String] = []
    var completeMovesImmediately = true
    var failMove = false
    var pendingMove: ((Bool) -> Void)?

    init(resolveAnchor: Bool = true) {
        resolveAnchorSucceeds = resolveAnchor
    }

    func resolveAnchor(_ text: String) -> (x: CGFloat, top: Bool, window: WindowEntity?)? {
        resolveAnchorSucceeds ? (350, true, nil) : nil
    }

    func floorNearPoint() -> CGFloat { petX + 60 }

    func sceneMove(toX: CGFloat, top: Bool, window: WindowEntity?, onDone: @escaping (Bool) -> Void) {
        if completeMovesImmediately { onDone(!failMove) } else { pendingMove = onDone }
    }

    func completeMove() {
        let callback = pendingMove
        pendingMove = nil
        callback?(!failMove)
    }

    var putDowns = 0
    var pickUps = 0
    var allowPutDown = true

    @discardableResult
    func scenePutDown() -> Bool { putDowns += 1; return allowPutDown }

    @discardableResult
    func scenePickUp() -> Bool { pickUps += 1; return true }

    func scenePerform(_ candidates: [String], onDone: @escaping () -> Void) {
        performedClips.append(contentsOf: candidates)
        onDone()
    }

    func sceneSay(_ intent: SpeechIntent) {}

    func sceneSleep() {}

}
