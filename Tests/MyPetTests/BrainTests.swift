import XCTest
import MyPetCore
@testable import MyPetEngine
import MyPetSimulation

@testable import MyPetApp
import MyPetPlatform

/// 大脑层纯函数测试：BrainContextSnapshot 装配、BrainState 动力学、GoalDecision 解析校验、
/// GoalBrain 传输链路（URLProtocol mock，离线）。
final class BrainTests: XCTestCase {

    private var testLogURL: URL!

    override func setUp() {
        super.setUp()
        testLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-brain-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("brain_trace.jsonl")
        BrainTraceLog.setLogURLOverrideForTesting(testLogURL)
    }

    override func tearDown() {
        BrainTraceLog.setLogURLOverrideForTesting(nil)
        if let testLogURL {
            try? FileManager.default.removeItem(at: testLogURL.deletingLastPathComponent())
        }
        super.tearDown()
    }

    private func window(_ id: UInt32, owner: String = "Chrome", x: CGFloat = 100,
                        activity: AppActivity = .unknown) -> WindowEntity {
        var w = WindowEntity(id: id, pid: 100, owner: owner, bounds: CGRect(x: x, y: 0, width: 800, height: 600))
        w.activity = activity.rawValue
        return w
    }

    private func senses() -> SensorObservation {
        var o = SensorObservation(requestID: 1, timestamp: 10, app: "Chrome", pid: 1,
                                  windowTitle: "ChatGPT", focused: nil, selectedText: "")
        o.focused = AXElementDTO(id: "ax:1:f", role: "textarea", value: "用户在写方案", focused: true)
        o.siblings = [AXElementDTO(id: "ax:1:s0", role: "statictext", value: "这是聊天记录")]
        o.salient = [AXElementDTO(id: "ax:1:w0", role: "button", title: "Send"),
                     AXElementDTO(id: "ax:1:w1", role: "link", title: "Docs")]
        return o
    }

    // MARK: BrainContextSnapshot

    func testWorldStateBuildTrimsAndDerivesActivity() {
        let ws = BrainContextSnapshotBuilder.build(
            clock: 100, foreground: window(7), idleSeconds: 5,
            windows: (0..<9).map { window(UInt32(10 + $0), x: CGFloat($0) * 100) },
            senses: senses(),
            recentEvents: ["0s ago user switched to Chrome"])
        XCTAssertEqual(ws.activeApp, "Chrome")
        XCTAssertEqual(ws.windowTitle, "ChatGPT")
        XCTAssertEqual(ws.userActivity, "editing_text")  // 聚焦 textarea
        XCTAssertEqual(ws.nearbyWindows.count, 5)        // 9 个窗口截到 5
        XCTAssertTrue(ws.visibleContext.contains("用户在写方案"))
        XCTAssertEqual(ws.salientUI.first, "button:Send")
        XCTAssertEqual(ws.recentEvents.count, 1)
    }

    func testAppActivitySemanticAndNearbyLabels() {
        // app 级语义（零权限归类）与 nearby 标签里的 activity。
        let ws = BrainContextSnapshotBuilder.build(
            clock: 0, foreground: window(7, owner: "Code", activity: .coding), idleSeconds: 3,
            windows: [window(7, owner: "Code", activity: .coding),
                      window(8, owner: "微信", activity: .chatting)],
            senses: nil, recentEvents: [])
        XCTAssertEqual(ws.appActivity, "coding")
        XCTAssertEqual(ws.userActivity, "unknown")  // 无感知、焦点级仍是 unknown
        XCTAssertTrue(ws.nearbyWindows[0].contains("Code, coding"))
        XCTAssertTrue(ws.nearbyWindows[1].contains("微信, chatting"))
    }

    func testActivityCatalogRoutesChatAndRealEdgeBundlesToTheRightContentChannel() {
        XCTAssertEqual(
            AppActivityCatalog.classify(
                owner: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
            .chatting)
        XCTAssertEqual(
            AppActivityCatalog.classify(
                owner: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                windowTitle: "GitHub - pull request"),
            .reading)
        XCTAssertEqual(
            AppActivityCatalog.classify(
                owner: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                windowTitle: "YouTube"),
            .watching)
    }

    func testIdleOveridesAppActivity() {
        let ws = BrainContextSnapshotBuilder.build(
            clock: 0, foreground: window(7, owner: "Code", activity: .coding), idleSeconds: 300,
            windows: [], senses: nil, recentEvents: [])
        XCTAssertEqual(ws.userActivity, "idle")
        XCTAssertEqual(ws.appActivity, "unknown", "用户离开后 app 语义不再可信")
    }

    func testActivityDerivation() {
        XCTAssertEqual(BrainContextSnapshotBuilder.deriveActivity(idleSeconds: 300, focusRole: "textarea"), "idle")
        XCTAssertEqual(BrainContextSnapshotBuilder.deriveActivity(idleSeconds: 3, focusRole: ""), "unknown")
        XCTAssertEqual(BrainContextSnapshotBuilder.deriveActivity(idleSeconds: 3, focusRole: "button"), "browsing")
    }

    func testContextLinesPutSelectedTextFirst() {
        var s = senses()
        s.selectedText = "高亮段落"
        let lines = BrainContextSnapshotBuilder.contextLines(from: s)
        XCTAssertEqual(lines.first, "选中: 高亮段落")
        XCTAssertLessThanOrEqual(lines.count, BrainContextSnapshotBuilder.contextLineLimit)
    }

    func testContextLinesIncludeOCRLinesWithinBudget() {
        var s = senses()
        s.ocrLines = (0..<10).map { "聊天行 \($0)" }
        let lines = BrainContextSnapshotBuilder.contextLines(from: s)
        XCTAssertEqual(lines.count, BrainContextSnapshotBuilder.contextLineLimit)  // AX 值 + OCR 共用 6 行预算
        XCTAssertTrue(lines.contains("用户在写方案"))
        XCTAssertTrue(lines.contains("聊天行 0"))
    }

    func testNoSensesGivesUnknownActivityAndEmptyContext() {
        let ws = BrainContextSnapshotBuilder.build(clock: 0, foreground: window(1), idleSeconds: 0,
                                         windows: [], senses: nil, recentEvents: [])
        XCTAssertEqual(ws.userActivity, "unknown")
        XCTAssertTrue(ws.visibleContext.isEmpty)
        XCTAssertTrue(ws.windowTitle.isEmpty)
    }

    func testKernelContentObservationsReachGoalWorldContext() {
        let observation = InputObservation(
            id: "chat-1", pluginID: "chat-content", channel: .chat,
            appName: "WeChat", windowTitle: "Alice", text: "请过来看看这个窗口",
            capturedAtTick: 4, expiresAtTick: 10)
        let ws = BrainContextSnapshotBuilder.build(
            clock: 4, foreground: window(1, owner: "WeChat", activity: .chatting),
            idleSeconds: 0, windows: [], senses: nil,
            inputObservations: [observation], recentEvents: [])
        XCTAssertTrue(ws.visibleContext.contains("[chat] 请过来看看这个窗口"))
        XCTAssertLessThanOrEqual(ws.visibleContext.count, BrainContextSnapshotBuilder.contextLineLimit)
    }

    func testWindowServerTitleFeedsWorldStateWithoutContentPermission() {
        var foreground = window(2, owner: "Code")
        foreground.windowTitle = "main.swift"
        let ws = BrainContextSnapshotBuilder.build(clock: 0, foreground: foreground, idleSeconds: 0,
                                         windows: [], senses: nil, recentEvents: [])
        XCTAssertEqual(ws.windowTitle, "main.swift")
        XCTAssertTrue(ws.visibleContext.isEmpty)
    }

    func testEmptySensorTitleDoesNotEraseWindowServerTitle() {
        var foreground = window(3, owner: "Safari")
        foreground.windowTitle = "Qwen docs"
        let emptyTitle = SensorObservation(
            requestID: 2, timestamp: 1, app: "Safari", pid: 100,
            windowTitle: "", focused: nil, selectedText: "")
        let ws = BrainContextSnapshotBuilder.build(
            clock: 1, foreground: foreground, idleSeconds: 0,
            windows: [], senses: emptyTitle, recentEvents: [])
        XCTAssertEqual(ws.windowTitle, "Qwen docs")
    }

    // MARK: BrainState

    func testTickDynamicsAndClamp() {
        var b = BrainState(energy: 0.98, curiosity: 0.0, socialNeed: 0.0)
        b.tick(dt: 10, worldChanged: true, isAsleep: false, isMoving: false,
               personality: .default)
        XCTAssertLessThan(b.energy, 0.98)
        XCTAssertGreaterThan(b.curiosity, 0.0)   // 世界变了，好奇上涨
        XCTAssertGreaterThan(b.socialNeed, 0.0)

        // 长时间 tick 不越界。
        for _ in 0..<1000 {
            b.tick(dt: 1, worldChanged: true, isAsleep: false, isMoving: true,
                   personality: .default)
        }
        XCTAssertLessThanOrEqual(b.energy, 1.0)
        XCTAssertGreaterThanOrEqual(b.energy, 0.0)
        XCTAssertLessThanOrEqual(b.curiosity, 1.0)
        XCTAssertLessThanOrEqual(b.stress, 1.0)
    }

    func testSleepRecoversEnergyAndMutedSocial() {
        var awake = BrainState(energy: 0.5, curiosity: 0.5, socialNeed: 0.5)
        var asleep = awake
        awake.tick(dt: 10, worldChanged: false, isAsleep: false, isMoving: false, personality: .default)
        asleep.tick(dt: 10, worldChanged: false, isAsleep: true, isMoving: false, personality: .default)
        XCTAssertGreaterThan(asleep.energy, awake.energy)
        XCTAssertLessThan(asleep.socialNeed - 0.5, awake.socialNeed - 0.5)
    }

    func testPersonalityMakesSameWorldDifferent() {
        var lively = BrainState(energy: 0.5, curiosity: 0.0, socialNeed: 0.0)
        var daiyu = lively
        lively.tick(dt: 30, worldChanged: false, isAsleep: false, isMoving: false, personality: .default)
        daiyu.tick(dt: 30, worldChanged: false, isAsleep: false, isMoving: false, personality: .linDaiyu)
        XCTAssertGreaterThan(lively.curiosity, daiyu.curiosity)      // 活泼角色更好奇
        XCTAssertGreaterThan(lively.socialNeed, daiyu.socialNeed)    // 黛玉更矜持
    }

    func testMindEventFeedback() {
        var b = BrainState(socialNeed: 0.9)
        b.apply(event: .spoke(text: "在忙吗？"), now: 10)
        XCTAssertEqual(b.lastSpeech, "在忙吗？")
        XCTAssertLessThan(b.socialNeed, 0.9)   // 说话被满足

        var c = BrainState(curiosity: 0.8)
        c.apply(event: .moved(distance: 1200), now: 11)
        XCTAssertLessThan(c.curiosity, 0.8)    // 探索满足好奇

        var d = BrainState(stress: 0.1)
        d.apply(event: .poked, now: 12)
        XCTAssertGreaterThan(d.stress, 0.1)    // 连戳应激
        d.apply(event: .patted, now: 13)
        XCTAssertLessThan(d.stress, d.stress + 1)  // 摸头（相对断言防越界）
        let afterPoke = d.stress
        d.apply(event: .patted, now: 14)
        XCTAssertLessThanOrEqual(d.stress, afterPoke)  // 摸头压应激
    }

    func testGoalAdoptionMirrorsIntoBrainState() {
        var b = BrainState()
        b.adopt(goal: Goal(kind: .rest, target: nil, activity: nil, style: "sleepy",
                           issuedAt: 5, source: "policy"), now: 5)
        XCTAssertEqual(b.currentGoal, "rest")
        b.clearGoal()
        XCTAssertNil(b.currentGoal)
    }

    // MARK: GoalDecision

    func testGoalParseTolerant() {
        let d = GoalDecision.parse("前置废话\n{\"goal\":\"seek_attention\",\"target\":\"user\",\"style\":\"needy\"} 尾部")
        XCTAssertEqual(d?.goal, .seekAttention)
        XCTAssertEqual(d?.target, "user")
        XCTAssertNil(GoalDecision.parse("没有 json"))
        XCTAssertNil(GoalDecision.parse("{\"action\":\"speak\"}"))  // 缺 goal
        XCTAssertNil(GoalDecision.parse("{\"goal\":\"fly_to_moon\"}"))  // 未知目标词
    }

    func testGoalValidate() {
        let ws = BrainContextSnapshotBuilder.build(clock: 0, foreground: window(7), idleSeconds: 0,
                                         windows: [window(7)], senses: nil, recentEvents: [])
        XCTAssertTrue(GoalDecision.validate(
            GoalDecision(goal: .joinUserActivity, target: "user", activity: "coding",
                         style: nil, speech: nil, memory: nil, why: nil), world: ws))
        XCTAssertFalse(GoalDecision.validate(  // 目标不在世界快照里
            GoalDecision(goal: .explore, target: "window_99", activity: nil,
                         style: nil, speech: nil, memory: nil, why: nil), world: ws))
        XCTAssertFalse(GoalDecision.validate(  // 未知活动词
            GoalDecision(goal: .joinUserActivity, target: "user", activity: "yodeling",
                         style: nil, speech: nil, memory: nil, why: nil), world: ws))
        XCTAssertFalse(GoalDecision.validate(  // 空白 speech
            GoalDecision(goal: .seekAttention, target: "user", activity: nil,
                         style: nil, speech: "  ", memory: nil, why: nil), world: ws))
    }

    func testGoalTTL() {
        let g = Goal(kind: .seekAttention, target: "user", activity: nil, style: nil,
                     issuedAt: 10, source: "policy")
        XCTAssertFalse(g.expired(at: 50))
        XCTAssertTrue(g.expired(at: 10 + g.defaultTTL + 1))
    }

    // MARK: GoalBrain 传输链路（URLProtocol mock，离线）

    func testTeacherBrainRequestBuildsValidJSON() {
        let ws = BrainContextSnapshotBuilder.build(clock: 0, foreground: window(7), idleSeconds: 0,
                                         windows: [], senses: senses(), recentEvents: [])
        let req = TeacherBrain.buildPlanRequest(
            model: "qwen-test", world: ws, brain: BrainState(),
            personality: .linDaiyu, memory: ["[habit] 用户常在夜里编码"],
            sampling: TeacherBrain.PlanSampling(
                temperature: 0.2, topP: 0.9, topK: 20, maxTokens: 64,
                seed: 42, reasoningEffort: "low"))
        // Optional 字段已 NSNull 化，序列化必须成功。
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: req))
        XCTAssertEqual(req["model"] as? String, "qwen-test")
        let body = req["messages"] as? [[String: Any]]
        XCTAssertEqual(body?.count, 2)
        let system = body?.first?["content"] as? String
        XCTAssertTrue(system?.contains("tease_user") == true)
        let user = body?.last?["content"] as? String
        XCTAssertTrue(user?.contains("teasing=85") == true)
        XCTAssertEqual(req["temperature"] as? Double, 0.2)
        XCTAssertEqual(req["top_p"] as? Double, 0.9)
        XCTAssertEqual(req["top_k"] as? Int, 20)
        XCTAssertEqual(req["max_tokens"] as? Int, 64)
        XCTAssertEqual(req["seed"] as? Int, 42)
        XCTAssertEqual(req["reasoning_effort"] as? String, "low")
        let responseFormat = req["response_format"] as? [String: Any]
        XCTAssertEqual(responseFormat?["type"] as? String, "json_schema")
        let jsonSchema = responseFormat?["json_schema"] as? [String: Any]
        XCTAssertEqual(jsonSchema?["name"] as? String, "goal_decision")
        let schema = jsonSchema?["schema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertEqual(schema?["additionalProperties"] as? Bool, false)
        XCTAssertTrue((schema?["required"] as? [String])?.contains("goal") == true)
        let properties = schema?["properties"] as? [String: Any]
        let goals = (properties?["goal"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(Set(goals ?? []), Set(GoalKind.allCases.map(\.rawValue)))
    }

    func testSpeechRequestBuildsValidJSON() {
        let ws = BrainContextSnapshotBuilder.build(clock: 0, foreground: window(7), idleSeconds: 0,
                                         windows: [], senses: nil, recentEvents: [])
        let req = TeacherBrain.buildSpeechRequest(model: "m", intent: .tease, world: ws,
                                               brain: BrainState(), personality: .default)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: req))
    }

    func testTeacherBrainPerformExtractsOpenAIContent() {
        let content = "{\"goal\":\"rest\",\"style\":\"sleepy\"}"
        let envelope: [String: Any] = ["choices": [["message": ["content": content]]]]
        let body = try! JSONSerialization.data(withJSONObject: envelope)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200, body)
        }
        let config = TeacherBrain.Config(baseURL: "https://api.test/v1/", model: "m", apiKey: "sk-test")
        let session = Self.mockSession()
        let done = expectation(description: "perform")
        TeacherBrain.perform(config: config, request: ["model": "m"], session: session) { out in
            XCTAssertEqual(out, content)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testTeacherBrainPerformNilOnBadPayloadAndHTTPError() {
        let config = TeacherBrain.Config(baseURL: "https://api.test/v1", model: "m", apiKey: "")
        let session = Self.mockSession()

        MockURLProtocol.handler = { _ in (200, Data("{\"nope\":1}".utf8)) }  // 无 choices
        let bad = expectation(description: "bad payload")
        TeacherBrain.perform(config: config, request: [:], session: session) { out in
            XCTAssertNil(out)
            bad.fulfill()
        }
        wait(for: [bad], timeout: 5)

        MockURLProtocol.handler = { _ in (500, Data("{}".utf8)) }  // HTTP 500
        let err = expectation(description: "http 500")
        TeacherBrain.perform(config: config, request: [:], session: session) { out in
            XCTAssertNil(out)
            err.fulfill()
        }
        wait(for: [err], timeout: 5)
    }

    func testTeacherBrainPlanEndToEndRejectsUnsupportedTarget() {
        let ws = BrainContextSnapshotBuilder.build(clock: 0, foreground: window(7), idleSeconds: 0,
                                         windows: [window(7)], senses: nil, recentEvents: [])
        let config = TeacherBrain.Config(baseURL: "https://api.test/v1", model: "m", apiKey: "")
        let session = Self.mockSession()

        func respond(with json: String, _ line: UInt = #line) {
            MockURLProtocol.handler = { _ in
                (200, Data("{\"choices\":[{\"message\":{\"content\":\(String(jsonPayload: json))}}]}".utf8))
            }
        }

        let input = GoalBrainInput(petID: "lin_daiyu", world: ws, brain: BrainState(),
                                   personality: .linDaiyu, memory: [], traceID: "test-rejected")
        // 世界里只有 window_7；教师脑把探索目标定到 window_99 必须被语义校验拒绝。
        respond(with: "{\"goal\":\"explore\",\"target\":\"window_99\"}")
        var brain = TeacherBrain()
        brain.injectedConfig = config
        brain.session = session
        let rejected = expectation(description: "rejected")
        let dispatched = brain.plan(input: input) { d in
            XCTAssertNil(d)
            rejected.fulfill()
        }
        XCTAssertTrue(dispatched)
        wait(for: [rejected], timeout: 5)

        // 合法决策要原样放行。
        brain = TeacherBrain()  // 新实例，绕过规划间隔
        brain.injectedConfig = config
        brain.session = session
        respond(with: "{\"goal\":\"explore\",\"target\":\"window_7\"}")
        let accepted = expectation(description: "accepted")
        let acceptedInput = GoalBrainInput(petID: "lin_daiyu", world: ws, brain: BrainState(),
                                           personality: .linDaiyu, memory: [], traceID: "test-accepted")
        brain.plan(input: acceptedInput) { d in
            XCTAssertEqual(d?.target, "window_7")
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 5)
    }

    func testTeacherBrainPlanSkipsWhileRequestIsInFlight() {
        let ws = BrainContextSnapshotBuilder.build(clock: 0, foreground: window(7), idleSeconds: 0,
                                         windows: [], senses: nil, recentEvents: [])
        let config = TeacherBrain.Config(baseURL: "https://api.test/v1", model: "m", apiKey: "")
        let brain = TeacherBrain()
        brain.injectedConfig = config
        brain.session = Self.mockSession()
        MockURLProtocol.handler = { _ in (200, Data()) }
        let input = GoalBrainInput(petID: "lin_daiyu", world: ws, brain: BrainState(),
                                   personality: .default, memory: [], traceID: "test-due")
        let completed = expectation(description: "in-flight request completed")
        let first = brain.plan(input: input) { _ in completed.fulfill() }
        XCTAssertTrue(first)
        // 节奏由 GoalBrainCoordinator 管理；适配器只拒绝在飞请求。
        let second = brain.plan(input: input) { _ in }
        XCTAssertFalse(second)
        // 测试必须等待异步回调结束，否则回调可能在 teardown 清除测试日志目标后
        // 才执行，把这条测试 trace 写进正式的 brain_trace.jsonl。
        wait(for: [completed], timeout: 5)
    }

    func testTeacherBrainCancelPendingPlanCancelsTransportAndSuppressesResult() {
        let started = expectation(description: "teacher request started")
        let stopped = expectation(description: "teacher request cancelled")
        let delivered = expectation(description: "cancelled result must stay suppressed")
        delivered.isInverted = true
        CancellationURLProtocol.onStart = { started.fulfill() }
        CancellationURLProtocol.onStop = { stopped.fulfill() }
        defer {
            CancellationURLProtocol.onStart = nil
            CancellationURLProtocol.onStop = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let brain = TeacherBrain()
        brain.injectedConfig = .init(baseURL: "https://api.test/v1", model: "m", apiKey: "")
        brain.session = session
        let input = GoalBrainInput(
            petID: "lin_daiyu",
            world: BrainContextSnapshotBuilder.build(clock: 0, foreground: window(7), idleSeconds: 0,
                                           windows: [], senses: nil, recentEvents: []),
            brain: BrainState(), personality: .default, memory: [], traceID: "cancelled")

        XCTAssertTrue(brain.plan(input: input) { _ in delivered.fulfill() })
        wait(for: [started], timeout: 2)
        brain.cancelPendingPlan(traceID: "another-actor")
        XCTAssertFalse(brain.plan(input: input) { _ in delivered.fulfill() },
                       "another actor cannot clear the active Teacher request")
        brain.cancelPendingPlan(traceID: input.traceID)
        wait(for: [stopped], timeout: 2)

        CancellationURLProtocol.onStart = nil
        CancellationURLProtocol.onStop = nil
        XCTAssertTrue(brain.plan(input: input) { _ in delivered.fulfill() },
                      "取消后应立即允许下一轮规划")
        brain.cancelPendingPlan(traceID: input.traceID)
        wait(for: [delivered], timeout: 0.1)
    }

    func testLocalPlanGateOnlyCancelsOwnedRequest() {
        let gate = DispatchGate()
        XCTAssertTrue(gate.claim(traceID: "actor-b-request"))
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        gate.trackPlan(task, traceID: "actor-b-request")
        XCTAssertFalse(gate.claim(traceID: "actor-a-request"))
        gate.cancelPlan(traceID: "actor-a-request")
        XCTAssertFalse(task.isCancelled)
        gate.release(traceID: "actor-a-request")
        XCTAssertFalse(gate.claim(traceID: "actor-a-request"))
        gate.cancelPlan(traceID: "actor-b-request")
        XCTAssertTrue(task.isCancelled)
        gate.release(traceID: "actor-b-request")
        XCTAssertTrue(gate.claim(traceID: "actor-a-request"))
        gate.release(traceID: "actor-a-request")
    }

    func testLocalPlanGateCancelsRequestBeforeTaskIsTracked() {
        let gate = DispatchGate()
        XCTAssertTrue(gate.claim(traceID: "actor-a-request"))
        gate.cancelPlan(traceID: "actor-a-request")
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        gate.trackPlan(task, traceID: "actor-a-request")
        XCTAssertTrue(task.isCancelled, "取消和任务注册之间的竞态不能让昂贵生成继续运行")
        gate.release(traceID: "actor-a-request")
    }

    func testSpeechReplyParse() {
        let reply = SpeechReply.parse("{\"text\":\"你写这么久，还没写完吗？\",\"emotion\":\"teasing\"}")
        XCTAssertEqual(reply?.text, "你写这么久，还没写完吗？")
        XCTAssertEqual(reply?.emotion, "teasing")
        XCTAssertNil(SpeechReply.parse("{\"text\":\"   \"}"))
        XCTAssertNil(SpeechReply.parse("废话"))
    }

    func testProbeModelsParsesOpenAIAndOllamaShapes() {
        let config = TeacherBrain.Config(baseURL: "https://api.test/v1", model: "", apiKey: "")
        let session = Self.mockSession()

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/models")
            return (200, Data("{\"data\":[{\"id\":\"qwen3-32b\"},{\"id\":\"glm-4\"}]}".utf8))
        }
        let openAI = expectation(description: "openai shape")
        TeacherBrain.probeModels(config: config, session: session) { ids, error in
            XCTAssertEqual(ids, ["qwen3-32b", "glm-4"])
            XCTAssertNil(error)
            openAI.fulfill()
        }
        wait(for: [openAI], timeout: 5)

        MockURLProtocol.handler = { _ in
            (200, Data("{\"models\":[{\"name\":\"llama3\"}]}".utf8))
        }
        let ollama = expectation(description: "ollama shape")
        TeacherBrain.probeModels(config: config, session: session) { ids, _ in
            XCTAssertEqual(ids, ["llama3"])
            ollama.fulfill()
        }
        wait(for: [ollama], timeout: 5)

        MockURLProtocol.handler = { _ in (0, Data()) }  // 连不上
        let fail = expectation(description: "unreachable")
        TeacherBrain.probeModels(config: config, session: session) { ids, error in
            XCTAssertTrue(ids.isEmpty)
            XCTAssertNotNil(error)
            fail.fulfill()
        }
        wait(for: [fail], timeout: 5)
    }

    private static func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

/// 离线 mock：把 URLSession 请求拦在本地，不产生真实网络。
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, data) = Self.handler?(request) ?? (200, Data())
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CancellationURLProtocol: URLProtocol {
    static var onStart: (() -> Void)?
    static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() { Self.onStop?() }
}

private extension String {
    /// 把字符串安全编码进 JSON 字符串字面量（测试里拼信封用）。
    init(jsonPayload: String) {
        let data = try! JSONSerialization.data(withJSONObject: [jsonPayload])
        self = String(data: data, encoding: .utf8)!
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
