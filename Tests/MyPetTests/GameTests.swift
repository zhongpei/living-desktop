import CoreGraphics
import XCTest
import MyPetCore
import MyPetContent

@testable import MyPet
import MyPetPlatform

/// game-v2 纯函数与执行器测试：活动归类、锚点、道具、目标策略、
/// 场景配方执行（假舞台）、记忆、内置台词、设置兼容、OCR profile。
@MainActor
final class GameTests: XCTestCase {

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

    // MARK: SceneCatalog / SceneBodyDriver

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

    func testSceneRunnerExecutesStepsWithDegrade() {
        let recipe = SceneCatalog.recipe(id: "tea_break")!
        let stage = FakeStage()
        let runner = SceneBodyDriver(recipe: recipe)
        runner.start(stage: stage, activityWindow: nil, now: 0)

        // 推进直到结束：spawnProp → perform(全缺失降级) → wait → clearProps。
        var guardCounter = 0
        while runner.isActive, guardCounter < 200 {
            runner.tick(now: runner.currentClock + 1)
            stage.elapse(seconds: 1)
            guardCounter += 1
        }
        XCTAssertTrue(runner.completed)
        XCTAssertTrue(stage.finishedProps, "自然结束只收束手持道具，保留已放下的道具")
        XCTAssertFalse(stage.propsCleared)
    }

    func testSceneRunnerAbortsWhenAnchorVanishes() {
        let recipe = SceneCatalog.recipe(id: "window_sleep")!  // moveTo @activity → 失败
        let stage = FakeStage(resolveAnchor: false)
        let semanticRunner = MyPetCore.SceneRunner(recipes: [recipe])
        let runner = SceneBodyDriver(recipe: recipe, semanticRunner: semanticRunner)
        runner.start(stage: stage, activityWindow: WindowEntity(id: 1, pid: 1, owner: "A",
                                                                bounds: CGRect(x: 0, y: 0, width: 400, height: 300)),
                     now: 0)
        runner.tick(now: 1)
        stage.elapse(seconds: 1)
        runner.tick(now: 2)
        XCTAssertFalse(runner.isActive, "锚点窗口没了 = 场景中断，不追空窗口")
        XCTAssertEqual(semanticRunner.status, .cancelled)
        XCTAssertTrue(stage.propsCleared)
    }

    func testSceneDecisionActionMustPassCoreAuthorizationBeforeBodyExecution() {
        let recipe = SimulationSceneRecipe(
            id: "decision-action", goals: [.wander],
            steps: [SimulationSceneStep(.wait(0), decisionPoint: true)])
        let stage = FakeStage()
        stage.hasClips = true
        stage.nextDecision = .perform(["think"])
        var actions: [SimulationNeedleAction] = []
        var completions: [(Bool) -> Void] = []
        let runner = SceneBodyDriver(recipe: recipe) { action, completion in
            actions.append(action)
            completions.append(completion)
        }

        runner.start(stage: stage, activityWindow: nil, now: 0)
        runner.tick(now: 0)
        completions.removeFirst()(true)
        runner.tick(now: 0)

        XCTAssertEqual(actions, [.wait, .performCandidates(["think"])])
        XCTAssertTrue(stage.performedClips.isEmpty)

        completions.removeFirst()(true)
        XCTAssertEqual(stage.performedClips, ["think"])
    }

    func testProductionSceneBodyWaitsForCoreAuthorizationBeforeEachStep() {
        let recipe = SceneCatalog.recipe(id: "tea_break")!
        let stage = FakeStage()
        var actions: [SimulationNeedleAction] = []
        var completions: [(Bool) -> Void] = []
        let runner = SceneBodyDriver(recipe: recipe) { action, completion in
            actions.append(action)
            completions.append(completion)
        }

        runner.start(stage: stage, activityWindow: nil, now: 0)
        runner.tick(now: 0)

        XCTAssertEqual(actions, [.moveTo("floor_near")])

        completions.removeFirst()(true)
        XCTAssertEqual(actions, [.moveTo("floor_near"), .spawnProp("tea")])

        completions.removeFirst()(true)
        XCTAssertEqual(actions.count, 3, "第二步授权后才请求下一步")
    }

    func testSceneReportsBodyCompletionOnlyAfterPhysicalStepFinishes() {
        let recipe = SimulationSceneRecipe(
            id: "body-result", goals: [.wander],
            steps: [SimulationSceneStep(.wait(2))])
        let stage = FakeStage()
        var authorization: ((Bool, SceneBodyDriver.BodyResultReporter?) -> Void)?
        var results: [Bool] = []
        let runner = SceneBodyDriver(
            recipe: recipe,
            authorize: { _, completion in authorization = completion })

        runner.start(stage: stage, activityWindow: nil, now: 0)
        runner.tick(now: 0)
        authorization?(true, { results.append($0) })
        XCTAssertTrue(results.isEmpty)

        runner.tick(now: 0.05)
        XCTAssertTrue(results.isEmpty)
        runner.tick(now: 0.1)

        XCTAssertEqual(results, [true])
        XCTAssertTrue(runner.completed)
    }

    func testSceneWaitsForCorePropCommitBeforeNextDependentStep() {
        let recipe = SimulationSceneRecipe(
            id: "prop-commit", goals: [.wander],
            steps: [SimulationSceneStep(.spawnProp("tea")), SimulationSceneStep(.putDown)])
        let stage = FakeStage()
        var actions: [SimulationNeedleAction] = []
        var results: [Bool] = []
        let runner = SceneBodyDriver(recipe: recipe, authorize: { action, completion in
            actions.append(action)
            completion(true, { results.append($0) })
        })

        runner.start(stage: stage, activityWindow: nil, now: 0)
        runner.tick(now: 0)
        XCTAssertEqual(actions, [.spawnProp("tea")])
        XCTAssertEqual(results, [true])
        runner.tick(now: 1)
        XCTAssertEqual(actions, [.spawnProp("tea")], "未见 Core 道具事实不能继续放下")

        stage.sceneBodyCommitState = .completed
        runner.tick(now: 2)
        XCTAssertEqual(actions, [.spawnProp("tea"), .putDown])
    }

    func testRejectedPropCommitAbortsSceneWithoutExecutingNextStep() {
        let recipe = SimulationSceneRecipe(
            id: "prop-reject", goals: [.wander],
            steps: [SimulationSceneStep(.spawnProp("tea")), SimulationSceneStep(.putDown)])
        let stage = FakeStage()
        var actions: [SimulationNeedleAction] = []
        let runner = SceneBodyDriver(recipe: recipe, authorize: { action, completion in
            actions.append(action)
            completion(true, { _ in })
        })
        runner.start(stage: stage, activityWindow: nil, now: 0)
        runner.tick(now: 0)
        stage.sceneBodyCommitState = .failed
        runner.tick(now: 1)

        XCTAssertFalse(runner.isActive)
        XCTAssertEqual(actions, [.spawnProp("tea")])
        XCTAssertTrue(stage.propsCleared)
    }

    func testScenePhysicalTimeoutReportsFailureAndDoesNotAdvance() {
        let recipe = SimulationSceneRecipe(
            id: "body-timeout", goals: [.wander],
            steps: [SimulationSceneStep(.moveTo("floor_near"))])
        let stage = FakeStage()
        stage.completeMovesImmediately = false
        var results: [Bool] = []
        let runner = SceneBodyDriver(
            recipe: recipe,
            authorize: { _, completion in
                completion(true, { results.append($0) })
            })
        runner.stepTimeout = 0.05

        runner.start(stage: stage, activityWindow: nil, now: 0)
        runner.tick(now: 0)
        runner.tick(now: 0.1)

        XCTAssertEqual(results, [false])
        XCTAssertFalse(runner.completed)
        XCTAssertFalse(runner.isActive)
    }

    func testSceneRunnerDecisionPointAsksStage() {
        let recipe = SceneCatalog.recipe(id: "complain")!
        let stage = FakeStage()
        let runner = SceneBodyDriver(recipe: recipe)
        runner.start(stage: stage, activityWindow: nil, now: 0)
        var guardCounter = 0
        while runner.isActive, guardCounter < 200 {
            runner.tick(now: runner.currentClock + 1)
            stage.elapse(seconds: 1)
            guardCounter += 1
        }
        XCTAssertGreaterThan(stage.decisionPoints, 0, "决策点必须咨询舞台")
        XCTAssertTrue(stage.propsCleared || stage.finishedProps)
    }

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
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("teacherEnabled"),
                       "落盘不再写旧键")
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

// MARK: - 假舞台（SceneBodyDriver 离线执行）

private final class FakeStage: SceneStaging {
    var petX: CGFloat = 100
    var petYFeet: CGFloat = 800
    var resolveAnchorSucceeds = true
    var sceneBodyCommitState: SceneBodyCommitState = .pending
    var propsCleared = false
    var finishedProps = false
    var decisionPoints = 0
    var performedClips: [String] = []
    var hasClips = false
    var completeMovesImmediately = true
    var nextDecision: SceneDecision?
    /// 场景等待的绝对时钟（elapse 推进）。
    var fakeClock: Double = 0
    /// 决策点回答策略：第二次离开，其余继续。
    private var decisionCount = 0

    init(resolveAnchor: Bool = true) {
        resolveAnchorSucceeds = resolveAnchor
    }

    func elapse(seconds: Double) { fakeClock += seconds }

    func hasClip(_ name: String) -> Bool { hasClips }

    func resolveAnchor(_ text: String) -> (x: CGFloat, top: Bool, window: WindowEntity?)? {
        resolveAnchorSucceeds ? (350, true, nil) : nil
    }

    func floorNearPoint() -> CGFloat { petX + 60 }

    func sceneMove(toX: CGFloat, top: Bool, window: WindowEntity?, onDone: @escaping () -> Void) {
        if completeMovesImmediately { onDone() }
    }

    func sceneFadeProps() { propsCleared = true }
    func sceneFinishProps() { finishedProps = true }

    var putDowns = 0
    var pickUps = 0

    @discardableResult
    func scenePutDown() -> Bool { putDowns += 1; return true }

    @discardableResult
    func scenePickUp() -> Bool { pickUps += 1; return true }

    func scenePerform(_ candidates: [String], onDone: @escaping () -> Void) {
        performedClips.append(contentsOf: candidates)
        onDone()
    }

    func sceneSay(_ intent: SpeechIntent) {}

    func sceneSleep() {}

    func sceneDecisionPoint(_ scene: SceneRecipe, stepIndex: Int, resume: @escaping (SceneDecision) -> Void) {
        decisionPoints += 1
        if let nextDecision {
            self.nextDecision = nil
            resume(nextDecision)
            return
        }
        decisionCount += 1
        resume(decisionCount >= 3 ? .leaveScene : .continueScene)
    }
}
