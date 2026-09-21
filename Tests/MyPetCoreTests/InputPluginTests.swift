import XCTest
@testable import MyPetCore

final class InputPluginTests: XCTestCase {
    func testDefaultCatalogExposesAllExternalInputPluginsWithSafeDefaults() {
        let catalog = InputPluginCatalog.defaults()
        XCTAssertEqual(Set(catalog.plugins.keys), [
            "window-title", "accessibility", "ocr", "chat-content", "code-content", "browser-content",
        ])
        for config in catalog.plugins.values {
            XCTAssertFalse(config.enabled)
            XCTAssertFalse(config.preemptive)
            XCTAssertGreaterThan(config.ttlTicks, 0)
            XCTAssertGreaterThan(config.maxCharacters, 0)
        }
    }

    func testDisabledPluginAndExpiredObservationNeverEnterKernel() {
        var catalog = InputPluginCatalog.defaults()
        let observation = InputObservation(
            id: "ocr-1", pluginID: "ocr", channel: .ocr,
            appName: "微信", text: "消息", capturedAtTick: 0, expiresAtTick: 1)

        XCTAssertNil(catalog.route(observation, at: 0))
        catalog.setEnabled(true, for: "ocr")
        XCTAssertNotNil(catalog.route(observation, at: 0))
        XCTAssertNil(catalog.route(observation, at: 1))
    }

    func testRouteClipsTextAppliesTTLAndHonorsApplicationAllowlist() {
        var catalog = InputPluginCatalog.defaults()
        var config = try! XCTUnwrap(catalog.plugins["chat-content"])
        config.enabled = true
        config.maxCharacters = 4
        config.ttlTicks = 6
        config.allowedApplications = ["com.tencent.xinwechat"]
        config.preemptive = true
        config.priority = .urgentReactive
        catalog.plugins["chat-content"] = config

        let accepted = InputObservation(
            id: "chat-1", pluginID: "chat-content", channel: .chat,
            appName: "WeChat", bundleID: "com.tencent.xinwechat.mac",
            windowTitle: "Alice", text: "你好，桌宠", capturedAtTick: 2)
        let event = try! XCTUnwrap(catalog.route(accepted, at: 3))
        XCTAssertEqual(event.inputObservation?.text, "你好，桌")
        XCTAssertEqual(event.inputObservation?.expiresAtTick, 9)
        XCTAssertEqual(event.inputPreemptive, true)
        XCTAssertTrue(event.traceDetail.contains("chat-content"))
        XCTAssertTrue(event.traceDetail.contains("window=Alice:text=你好，桌"))

        let rejected = InputObservation(
            id: "chat-2", pluginID: "chat-content", channel: .chat,
            appName: "Other", bundleID: "com.example.other", text: "消息", capturedAtTick: 2)
        XCTAssertNil(catalog.route(rejected, at: 3))
    }

    func testRouteCapsSourceExpiryToConfiguredTTL() {
        var catalog = InputPluginCatalog.defaults()
        var config = try! XCTUnwrap(catalog.plugins["browser-content"])
        config.enabled = true
        config.ttlTicks = 4
        catalog.plugins["browser-content"] = config

        let observation = InputObservation(
            id: "browser-ttl", pluginID: "browser-content", channel: .browser,
            appName: "Safari", text: "page", capturedAtTick: 10, expiresAtTick: 100)
        let event = try! XCTUnwrap(catalog.route(observation, at: 12))

        XCTAssertEqual(event.inputObservation?.expiresAtTick, 16,
                       "插件 TTL 应限制来源声明的过长有效期")
    }

    func testPreemptiveInputInvalidatesPlansCancelsAmbientBehaviorAndExpires() {
        let actor = EntityState(id: EntityID("actor"), kind: .actor)
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: actor), atTick: 0)
        _ = kernel.tick()

        let ambient = BehaviorRequest(
            id: "ambient", actorID: actor.id, intent: "idle", priority: .ambient, durationTicks: 20)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: ambient), atTick: 1)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.behaviors[ambient.id]?.status, .running)

        let observation = InputObservation(
            id: "code-1", pluginID: "code-content", channel: .code,
            appName: "Xcode", text: "let answer = 42", capturedAtTick: 2, expiresAtTick: 4)
        kernel.enqueue(GameEvent(
            kind: .contentObservation,
            inputObservation: observation,
            inputPreemptive: true,
            inputPriority: .urgentReactive), atTick: 2)
        _ = kernel.tick()

        XCTAssertEqual(kernel.world.behaviors[ambient.id]?.status, .cancelled)
        XCTAssertEqual(kernel.world.planEpochs[actor.id.raw], 1)
        XCTAssertNotNil(kernel.world.inputObservations[observation.id])
        XCTAssertTrue(kernel.trace.contains { $0.detail.contains("text=let answer = 42") })
        _ = kernel.run(ticks: 2)
        XCTAssertNil(kernel.world.inputObservations[observation.id])
        XCTAssertTrue(kernel.manualViolations.isEmpty)
    }

    func testForegroundAndContentChangesAdvanceEpochTwiceAndRejectOldPlan() {
        let actor = EntityState(id: EntityID("actor"), kind: .actor)
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: actor), atTick: 0)
        _ = kernel.tick()

        let old = BehaviorRequest(
            id: "old", actorID: actor.id, intent: "ambient", priority: .ambient,
            planEpoch: 0, durationTicks: 20)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: old), atTick: 1)
        _ = kernel.tick()

        let observation = InputObservation(
            id: "browser-1", pluginID: "browser-content", channel: .browser,
            appName: "Safari", windowTitle: "Docs", text: "new page",
            capturedAtTick: 2, expiresAtTick: 8)
        kernel.enqueue(GameEvent(kind: .foregroundChanged), atTick: 2)
        kernel.enqueue(GameEvent(
            kind: .contentObservation,
            inputObservation: observation,
            inputPreemptive: true,
            inputPriority: .urgentReactive), atTick: 2)
        _ = kernel.tick()

        XCTAssertEqual(kernel.world.planEpochs[actor.id.raw], 2)
        XCTAssertEqual(kernel.world.behaviors[old.id]?.status, .cancelled)
        XCTAssertNotNil(kernel.world.inputObservations[observation.id])

        let stale = BehaviorRequest(
            id: "old-after", actorID: actor.id, intent: "ambient", priority: .ambient,
            planEpoch: 0, durationTicks: 1)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: stale), atTick: 3)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.behaviors[stale.id]?.status, .rejected)
        XCTAssertTrue(kernel.trace.contains { $0.kind == "reject" && $0.detail.contains("stale_plan") })

        _ = kernel.run(ticks: 5)
        XCTAssertNil(kernel.world.inputObservations[observation.id])
        XCTAssertTrue(kernel.manualViolations.isEmpty)
    }

    func testBuiltInInputMatrixRoutesEveryChannelAndReplaysWithRawText() {
        let scenario = ScenarioLoader.builtInInputMatrix()
        let result = ScenarioRunner.run(scenario)
        XCTAssertTrue(result.0.passed)
        XCTAssertTrue(result.1.manualViolations.isEmpty)
        for pluginID in ["window-title", "accessibility", "ocr", "chat-content", "code-content", "browser-content"] {
            XCTAssertTrue(result.1.trace.contains {
                $0.kind == "event" && $0.detail.contains("\(pluginID):")
            }, "missing routed event for \(pluginID)")
        }
        let traceText = result.1.trace.map(\.detail).joined(separator: "\n")
        XCTAssertTrue(traceText.contains("text=let answer = 42"))
        XCTAssertTrue(traceText.contains("text=private browser content"))
        XCTAssertEqual(ScenarioRunner.replay(scenario).matched, true)
    }
}
