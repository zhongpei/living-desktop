import XCTest
@testable import MyPet

final class BrainLogTests: XCTestCase {

    func testDecisionLogAlwaysPersistsExternalTextForLocalTraining() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-brain-log-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            BrainTraceLog.setLogURLOverrideForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }

        let traceURL = root.appendingPathComponent("brain_trace.jsonl")
        BrainTraceLog.setLogURLOverrideForTesting(traceURL)
        let world = WorldState(
            capturedAt: 1, activeApp: "WeChat", windowTitle: "Alice: secret",
            appActivity: "chatting", userActivity: "editing_text", focusRole: "textarea",
            visibleContext: ["聊天原文"], salientUI: ["button:发送"],
            nearbyWindows: ["window_1 (WeChat)"], recentEvents: ["secret event"])
        BrainDecisionLog.log(
            world: world, brain: BrainState(), output: "模型复述聊天原文", chosen: nil,
            latency: 0, mode: "local", memory: ["用户私密习惯"])

        let first = try JSONSerialization.jsonObject(
            with: Data(contentsOf: traceURL)) as! [String: Any]
        let firstWorld = first["world"] as! [String: Any]
        XCTAssertEqual(firstWorld["window"] as? String, "Alice: secret")
        XCTAssertEqual(firstWorld["visible_context"] as? [String], ["聊天原文"])
        XCTAssertEqual(first["output"] as? String, "模型复述聊天原文")
    }

    func testBrainTraceSwitchStopsAllBrainRecordsWithoutChangingRawPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-brain-log-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            BrainTraceLog.setEnabled(true)
            BrainTraceLog.setLogURLOverrideForTesting(nil)
            try? FileManager.default.removeItem(at: root)
        }

        let traceURL = root.appendingPathComponent("brain_trace.jsonl")
        BrainTraceLog.setLogURLOverrideForTesting(traceURL)
        BrainTraceLog.setEnabled(false)
        let world = WorldState(
            capturedAt: 1, activeApp: "Code", windowTitle: "file.swift",
            appActivity: "coding", userActivity: "editing_text", focusRole: "editor",
            visibleContext: [], salientUI: [], nearbyWindows: [], recentEvents: [])
        BrainDecisionLog.log(
            world: world,
            brain: BrainState(), output: "hidden", chosen: nil,
            latency: 0, mode: "local")

        XCTAssertFalse(FileManager.default.fileExists(atPath: traceURL.path))

        BrainTraceLog.setEnabled(true)
        BrainDecisionLog.log(
            world: world,
            brain: BrainState(), output: "visible raw text", chosen: nil,
            latency: 0, mode: "local")
        let contents = try String(contentsOf: traceURL)
        XCTAssertTrue(contents.contains("visible raw text"))
    }

    func testStartupCleanupRemovesOnlyRetiredLogFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-brain-log-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let retired = ["slowbrain.jsonl", "teacher.jsonl", "decisions.jsonl"]
        for name in retired {
            try Data("old\n".utf8).write(to: root.appendingPathComponent(name))
        }
        let current = root.appendingPathComponent("brain_trace.jsonl")
        try Data("current\n".utf8).write(to: current)
        let unrelated = root.appendingPathComponent("memory.json")
        try Data("keep".utf8).write(to: unrelated)

        BrainTraceLog.startFreshSession(in: root)

        XCTAssertTrue(retired.allSatisfy {
            !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testGoalEndingBeforeSceneIsClosedAndExplained() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-brain-log-outcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let traceURL = root.appendingPathComponent("brain_trace.jsonl")
        try writeJSONLines([
            [
                "ts": "2026-09-20T12:00:00Z",
                "kind": "plan",
                "brain_mode": "policy",
                "trace_id": "trace-no-scene",
                "chosen": ["goal": "rest"],
                "decision_valid": true,
            ],
            [
                "ts": "2026-09-20T12:00:01Z",
                "kind": "outcome",
                "trace_id": "trace-no-scene",
                "goal": ["kind": "rest", "source": "policy"],
                "scene": NSNull(),
                "stayed_s": 0,
                "completed": false,
                "ended_because": "goal user grabbed",
                "interrupted_by_user": true,
                "personality_style": "sleepy",
                "memory_count": 0,
                "active_app": "Code",
            ],
        ], to: traceURL)

        let report = BrainLogAnalyzer.load(traceLogURL: traceURL,
                                           memoryURL: root.appendingPathComponent("missing.json"))

        XCTAssertEqual(report.traces.count, 1)
        XCTAssertEqual(report.traces[0].status, "已中断")
        XCTAssertEqual(report.summary.openCount, 0)
        XCTAssertEqual(report.traces[0].items.last?.title, "场景结局：未进入场景")
        XCTAssertTrue(report.traces[0].items.last?.analysis.contains {
            $0.contains("在进入场景前结束")
        } == true)
    }

    func testAnalyzerBuildsOneBusinessTraceFromLinkedBrainRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-brain-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let traceURL = root.appendingPathComponent("brain_trace.jsonl")
        let memoryURL = root.appendingPathComponent("memory.json")
        let trace = "trace-test-1"
        let snapshot = #"{"actor":"rei_chibi","mode":"choose_next","goal":{"kind":"join_user_activity","activity":"coding","style":"quiet_companion"},"scenes":["coding_companion"]}"#

        try writeJSONLines([
            [
                "ts": "2026-09-20T12:00:00Z",
                "kind": "plan",
                "brain_mode": "teacher",
                "trace_id": trace,
                "world": [
                    "active_app": "Code",
                    "app_activity": "coding",
                ],
                "brain": [
                    "energy": 0.8,
                    "boredom": 0.2,
                    "social_need": 0.4,
                    "stress": 0.0,
                ],
                "chosen": [
                    "goal": "join_user_activity",
                    "why": "用户正在编码，我陪在旁边。",
                ],
                "output": "{\"goal\":\"join_user_activity\"}",
                "decision_valid": true,
                "latency_ms": 120,
            ],
            [
                "ts": "2026-09-20T12:00:05Z",
                "kind": "outcome",
                "trace_id": trace,
                "goal": [
                    "kind": "join_user_activity",
                    "source": "teacher",
                ],
                "scene": "coding_companion",
                "stayed_s": 5,
                "completed": true,
                "ended_because": "finished",
                "interrupted_by_user": false,
                "personality_style": "quiet_companion",
                "memory_count": 1,
                "active_app": "Code",
        ],
            [
                "ts": "2026-09-20T12:00:01Z",
                "kind": "decision",
                "trace_id": trace,
                "actor": "rei_chibi",
                "brain_mode": "needle",
                "snapshot": snapshot,
                "model_input": snapshot,
                "output": "{\"function_calls\":[{\"name\":\"choose_scene\",\"arguments\":{\"scene\":\"coding_companion\"}}]}",
                "chosen": "choose_scene(coding_companion)",
                "calls": ["choose_scene(coding_companion)"],
                "latency_ms": 35,
            ],
        ], to: traceURL)

        let memory = [MemoryEntry(
            ts: "2026-09-20T12:00:02Z",
            kind: "event",
            text: "用户常在 Code 编码",
            traceID: trace,
        )]
        try JSONEncoder().encode(memory).write(to: memoryURL)

        let report = BrainLogAnalyzer.load(
            traceLogURL: traceURL,
            memoryURL: memoryURL)

        XCTAssertEqual(report.traces.count, 1)
        XCTAssertEqual(report.traces[0].items.count, 4)
        XCTAssertEqual(report.traces[0].status, "已完成")
        XCTAssertTrue(report.traces[0].actorSummary.contains("高阶教师脑"))
        XCTAssertTrue(report.traces[0].actorSummary.contains("行动脑 Needle"))
        XCTAssertTrue(report.traces[0].analysis.contains("这条脑路已经形成「目标 → 行动脑动作 → 场景结果」闭环。"))
        XCTAssertEqual(report.summary.completedCount, 1)
        XCTAssertEqual(report.summary.fallbackCount, 0)
        XCTAssertTrue(BrainLogFilter.needle.matches(report.traces[0]))
        XCTAssertTrue(BrainLogFilter.memory.matches(report.traces[0]))

        let plan = report.traces[0].items.first { $0.kind == .plan }
        XCTAssertEqual(plan?.latencyMs, 120)
        XCTAssertTrue(plan?.details.contains { $0.label == "耗时" && $0.value == "120 ms" } == true)
        let decision = report.traces[0].items.first { $0.kind == .decision }
        XCTAssertEqual(decision?.latencyMs, 35)
        XCTAssertTrue(decision?.details.contains { $0.label == "耗时" && $0.value == "35 ms" } == true)
    }

    private func writeJSONLines(_ records: [[String: Any]], to url: URL) throws {
        let data = try records.map {
            try JSONSerialization.data(withJSONObject: $0)
        }.map { String(data: $0, encoding: .utf8)! + "\n" }
            .joined()
            .data(using: .utf8)!
        try data.write(to: url)
    }
}
