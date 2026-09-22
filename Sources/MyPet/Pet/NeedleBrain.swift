import CoreGraphics
import Foundation
import MyPetAI
import MyPetCore
import MyPetEngine

/// Needle 3 行动脑：Goal + 世界快照 → 一次 tool call。
///
/// game-v2 定位（game.md 第三节）：决策脑决定「我想做什么」，行动脑决定
/// 「我现在下一步做什么」。两种决策模式：
/// - `.ambient`（行动边界）：拿到当前 Goal，从 choose_scene / move_to /
///   spawn_prop / pick_up / put_down / perform / say / sleep / wait 里挑一个；
/// - `.inScene`（场景决策点）：continue(wait) / leave_scene / say / perform。
///
/// 设计要点（spike 实测结论，2026-09-20，沿用）：
/// - **把当前世界的合法取值编译进 tool schema 的 enum**（解码语法约束），
///   参数合法性由构造保证；每次决策前按 WorldFacts 动态生成 schema。
/// - C API 进程级单模型且非线程安全：所有调用串行在专用队列上。
/// - 模型缺失 / 初始化失败：`isAvailable == false`，控制器自动降级
///   内置 Autopilot（场景兜底）/ RandomBrain。
final class NeedleBrain {

    // MARK: 语义动作（世界无关，Core ActionRuntime 授权后交给身体 driver）

    typealias SemanticAction = SimulationNeedleAction

    /// 决策输入的世界事实（由控制器从真实世界提炼）。
    struct WorldFacts {
        enum Mode: Equatable { case ambient, inScene }

        let actor: String
        let userIdleSeconds: Int
        /// 目标层生成的关联 id；不影响模型输入，只用于把脑路串起来。
        var traceID: String? = nil
        /// 当前场景配方；不影响模型输入，只用于关联执行结果。
        var sceneID: String? = nil
        /// 当前目标（决策脑/内置策略下达）。inScene 模式也带（语境）。
        var goal: (kind: String, activity: String?, style: String?)? = nil
        /// 锚点实体："window_<id>.<slot>"，距离 pt、归属应用、活动、affordance。
        var anchors: [(id: String, distance: Int, owner: String, activity: String, affordances: [String])] = []
        /// 可生成的道具（PropCatalog）。
        var props: [String] = []
        /// 正持有的道具 id（有 → put_down 合法）。
        var heldProp: String? = nil
        /// 附近可拿的 placed 道具（有 → pick_up 合法）。
        var propNearby: String? = nil
        /// 当前目标适配的场景配方 id。
        var scenes: [String] = []
        /// 可表演的 actions/ 名单（不含 sleep*，睡眠走 sleep verb）。
        var performances: [String] = []
        /// 可用的说话意图。
        var speechIntents: [String] = []
        /// 最近动作：动作名 → 多少秒前。
        var recent: [String: Int] = [:]
        /// 决策模式。
        var mode: Mode = .ambient
        /// 需求环概览（0~100 整数，进快照给行动脑语境）。
        var needs: (energy: Int, boredom: Int, social: Int, stress: Int) = (70, 30, 40, 0)
        /// 人格速览（game.md §6：人格同时进决策脑与行动脑——行动脑用它决定
        /// 「同一个目标，用什么风格演」）。
        var personality: (style: String, social: Int, playfulness: Int, diligence: Int, teasing: Int) =
            ("easygoing", 50, 50, 50, 50)
        /// Preferred executable actions compiled from the human semantic character card.
        var signatureActions: [String] = []
        /// 感知层注入的 senses 段（JSON 文本，有界）。
        /// 进入模型输入和 brain_trace.jsonl，保证日志窗口能够还原完整决策上下文。
        var sensesJSON: String? = nil
    }

    // MARK: 纯函数（离线可测）

    /// 动态 tool schema：enum 只放当前世界的合法取值。
    static func toolSchema(facts: WorldFacts) -> String {
        let anchorIDs = facts.anchors.map { $0.id }.sorted()

        func fn(_ name: String, _ desc: String, _ props: [String: Any], _ req: [String]) -> [String: Any] {
            ["type": "function", "function": [
                "name": name, "description": desc,
                "parameters": ["type": "object", "properties": props, "required": req] as [String: Any],
            ]]
        }

        var tools: [[String: Any]] = []
        switch facts.mode {
        case .ambient:
            if !facts.scenes.isEmpty {
                tools.append(fn("choose_scene", "Pick a scene that fulfills the current goal.", [
                    "scene": ["type": "string", "enum": facts.scenes.sorted()],
                ], ["scene"]))
            }
            if !anchorIDs.isEmpty {
                tools.append(fn("move_to", "Walk the pet to one nearby anchor (window top = perch).", [
                    "target": ["type": "string", "enum": anchorIDs],
                ], ["target"]))
            }
            if facts.heldProp != nil {
                tools.append(fn("put_down", "Put the held prop down here; it stays there for a while.", [:], []))
            } else {
                if !facts.props.isEmpty {
                    tools.append(fn("spawn_prop", "Have the pet hold one prop.", [
                        "prop": ["type": "string", "enum": facts.props.sorted()],
                    ], ["prop"]))
                }
                if facts.propNearby != nil {
                    tools.append(fn("pick_up", "Pick up the prop the pet left nearby.", [:], []))
                }
            }
            if !facts.performances.isEmpty {
                tools.append(fn("perform", "Perform one available gesture in place.", [
                    "action": ["type": "string", "enum": facts.performances.sorted()],
                ], ["action"]))
            }
            if !facts.speechIntents.isEmpty {
                tools.append(fn("say", "Say something: request speech with an intent (text comes from the teacher brain or built-in quips).", [
                    "intent": ["type": "string", "enum": facts.speechIntents.sorted()],
                ], ["intent"]))
            }
            tools.append(fn("sleep", "Curl up and sleep until something happens.", [:], []))
            tools.append(fn("wait", "Do nothing for a while, staying alert.", [:], []))

        case .inScene:
            tools.append(fn("wait", "continue_scene: keep doing the current scene.", [:], []))
            tools.append(fn("leave_scene", "Leave the scene; a new plan will be made.", [:], []))
            if !facts.performances.isEmpty {
                tools.append(fn("perform", "Interject one available gesture, then continue the scene.", [
                    "action": ["type": "string", "enum": facts.performances.sorted()],
                ], ["action"]))
            }
            if !facts.speechIntents.isEmpty {
                tools.append(fn("say", "Interject one spoken line (by intent), then continue the scene.", [
                    "intent": ["type": "string", "enum": facts.speechIntents.sorted()],
                ], ["intent"]))
            }
        }

        let data = try? JSONSerialization.data(withJSONObject: tools)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// 世界快照文本（基础世界事实；senses 在 modelInput 中追加）。
    static func snapshot(facts: WorldFacts) -> String {
        let nearby: [[String: Any]] = facts.anchors.map {
            ["id": $0.id, "app": $0.owner, "activity": $0.activity,
             "distance_pt": $0.distance, "affordances": $0.affordances]
        }
        var object: [String: Any] = [
            "actor": facts.actor,
            "mode": facts.mode == .ambient ? "choose_next" : "scene_decision_point",
            "state": [
                "user_idle_s": facts.userIdleSeconds,
                "energy": facts.needs.energy,
                "boredom": facts.needs.boredom,
                "social_need": facts.needs.social,
                "stress": facts.needs.stress,
            ],
            "recent": Dictionary(uniqueKeysWithValues: facts.recent.map { ("\($0.key)", "\($0.value)s_ago") }),
        ]
        if let goal = facts.goal {
            object["goal"] = ["kind": goal.kind, "activity": goal.activity ?? NSNull(),
                              "style": goal.style ?? NSNull()] as [String: Any]
        }
        object["personality"] = ["style": facts.personality.style,
                                 "social": facts.personality.social,
                                 "playfulness": facts.personality.playfulness,
                                 "diligence": facts.personality.diligence,
                                 "teasing": facts.personality.teasing] as [String: Any]
        if !facts.signatureActions.isEmpty {
            object["signature_actions"] = facts.signatureActions.sorted()
        }
        if !nearby.isEmpty { object["nearby"] = nearby }
        if let held = facts.heldProp { object["held_prop"] = held }
        if let near = facts.propNearby { object["prop_nearby"] = near }
        if !facts.scenes.isEmpty { object["scenes"] = facts.scenes.sorted() }
        if !facts.props.isEmpty { object["props"] = facts.props.sorted() }
        if !facts.performances.isEmpty { object["performances"] = facts.performances.sorted() }
        if !facts.speechIntents.isEmpty { object["speech_intents"] = facts.speechIntents.sorted() }

        let data = try? JSONSerialization.data(withJSONObject: object)
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return text + "\nquestion: choose one appropriate next action"
    }

    /// 模型输入 = 快照 + senses 段；同一份输入会写入统一脑路日志。
    static func modelInput(facts: WorldFacts) -> String {
        guard let senses = facts.sensesJSON else { return snapshot(facts: facts) }
        return snapshot(facts: facts).replacingOccurrences(
            of: "\nquestion: choose one appropriate next action",
            with: "\nsenses: \(senses)\nquestion: choose one appropriate next action")
    }

    /// 解析模型输出：取第一个 function call（后备依次尝试）。
    static func parseCalls(_ output: String) -> [SemanticAction] {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let calls = object["function_calls"] as? [[String: Any]] else { return [] }
        return calls.compactMap { call in
            guard let name = call["name"] as? String else { return nil }
            let args = call["arguments"] as? [String: String] ?? [:]
            switch name {
            case "choose_scene": return args["scene"].map { .chooseScene($0) }
            case "move_to": return args["target"].map { .moveTo($0) }
            case "spawn_prop": return args["prop"].map { .spawnProp($0) }
            case "pick_up": return .pickUp
            case "put_down": return .putDown
            case "perform": return args["action"].map { .perform($0) }
            case "say":
                return args["intent"].flatMap(SpeechIntent.init(rawValue:)).map { .say($0.rawValue) }
            case "leave_scene": return .leaveScene
            case "sleep": return .sleep
            case "wait": return .wait(1)
            default: return nil
            }
        }
    }

    /// 语义校验：参数必须被快照完全支撑（enum 约束之外的第二道门）。
    static func validate(_ action: SemanticAction, facts: WorldFacts) -> Bool {
        switch action {
        case .chooseScene(let scene):
            return facts.scenes.contains(scene)
        case .moveTo(let id):
            return facts.anchors.contains { $0.id == id }
        case .spawnProp(let prop):
            return facts.heldProp == nil && facts.props.contains(prop)
        case .putDown:
            return facts.heldProp != nil
        case .pickUp:
            return facts.heldProp == nil && facts.propNearby != nil
        case .perform(let name):
            return facts.performances.contains(name)
        case .say(let intent):
            return facts.speechIntents.contains(intent)
        case .performCandidates(let candidates):
            return !candidates.isEmpty && candidates.allSatisfy(facts.performances.contains)
        case .clearProps:
            return true
        case .leaveScene:
            return facts.mode == .inScene
        case .sleep, .wait:
            return true
        case .body:
            return false
        }
    }

    static func describe(_ action: SemanticAction) -> String {
        switch action {
        case .chooseScene(let s): return "choose_scene(\(s))"
        case .moveTo(let id): return "move_to(\(id))"
        case .spawnProp(let p): return "spawn_prop(\(p))"
        case .putDown: return "put_down()"
        case .pickUp: return "pick_up()"
        case .perform(let name): return "perform(\(name))"
        case .say(let i): return "say(\(i))"
        case .performCandidates(let values): return "perform_candidates(\(values.joined(separator: ",")))"
        case .clearProps: return "clear_props()"
        case .leaveScene: return "leave_scene()"
        case .sleep: return "sleep()"
        case .wait(let ticks): return "wait(\(ticks))"
        case .body(let value): return "body(\(String(describing: value)))"
        }
    }

    // MARK: 运行时

    static let defaultInterval: ClosedRange<Double> = 4...10

    private let runtime = CNeedleRuntime.shared
    private var pending = false
    private var activeRequest: CNeedleRequestToken?
    var activeActor: String?
    private static let requestTimeout: TimeInterval = 15
    private var nextDecisionAtByActor: [String: Double] = [:]
    private(set) var requestGeneration: Int64 = 0

    func isCurrentGeneration(_ generation: Int64) -> Bool {
        requestGeneration == generation
    }

    /// Queued CNeedle calls are skipped; one already inside the C function
    /// finishes naturally and its old answer is not adopted. The shared model
    /// session is never interrupted here.
    func invalidatePendingDecision(for actor: String) {
        guard activeActor == actor else { return }
        requestGeneration &+= 1
        activeRequest?.cancel()
        activeRequest = nil
        activeActor = nil
        pending = false
    }

    /// 决策间隔（秒）。模型有思考成本，节奏比 RandomBrain 略缓。
    var interval: ClosedRange<Double> = NeedleBrain.defaultInterval
    /// C API 当前唯一可调的生成参数；设置窗不虚构 temperature/top-p 等参数。
    var maxNewTokens: Int = 128

    static func modelURL() -> URL? {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["MYPET_NEEDLE_MODEL"] {
            return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let resource = Bundle.main.resourceURL,
           fm.fileExists(atPath: resource.appendingPathComponent("needle3.cact").path) {
            return resource.appendingPathComponent("needle3.cact")
        }
        // swift run：从可执行文件向上找仓库 Resources/
        if let exe = CommandLine.arguments.first.flatMap({ fm.fileExists(atPath: $0) ? $0 : nil }) {
            var dir = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("Resources/needle3.cact")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                dir = dir.deletingLastPathComponent()
            }
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet/needle3.cact")
        return fm.fileExists(atPath: support.path) ? support : nil
    }

    /// 模型在位才可用；关闭大脑或缺模型时控制器走 Autopilot/RandomBrain。
    var isAvailable: Bool { Self.modelURL() != nil }

    /// 世界大变化 / 有趣事件（game.md §4 行动边界触发器）：
    /// 把下一次决策提前到现在，下一个 tick 的边界询问立即发出。
    func expedite(for actor: String) {
        invalidatePendingDecision(for: actor)
        nextDecisionAtByActor[actor] = 0
    }

    /// 到点且闲着才发起决策。回调在主队列，返回 nil = 决策失败（调用方自行兜底）。
    func maybeDecide(
        now: Double,
        facts: WorldFacts,
        completion: @escaping (SemanticAction?, [String]) -> Void
    ) {
        guard !pending, now >= (nextDecisionAtByActor[facts.actor] ?? 0) else { return }
        dispatchDecision(facts: facts, completion: completion)
        nextDecisionAtByActor[facts.actor] = now + Double.random(in: interval)
    }

    /// 立即决策（场景决策点专用，不吃冷却）。返回 false = 繁忙/不可用，
    /// 调用方应立即用内置策略回答，场景不能等。
    func decideNow(
        facts: WorldFacts,
        completion: @escaping (SemanticAction?, [String]) -> Void
    ) -> Bool {
        guard !pending, Self.modelURL() != nil else { return false }
        dispatchDecision(facts: facts, completion: completion)
        return true
    }

    private func dispatchDecision(
        facts: WorldFacts,
        completion: @escaping (SemanticAction?, [String]) -> Void
    ) {
        guard let modelURL = Self.modelURL() else { return }
        pending = true
        activeActor = facts.actor
        let generation = requestGeneration
        let token = CNeedleRequestToken()
        activeRequest = token

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard let self, self.activeRequest === token,
                  self.isCurrentGeneration(generation) else { return }
            self.invalidatePendingDecision(for: facts.actor)
            completion(nil, [])
        }

        let schema = Self.toolSchema(facts: facts)
        let snapshotForLog = Self.snapshot(facts: facts)
        let modelInput = Self.modelInput(facts: facts)
        let modelPath = modelURL.path
        let t0 = Date()
        runtime.complete(
            modelPath: modelPath,
            systemPrompt: systemPrompt,
            schema: schema,
            snapshot: modelInput,
            maxNewTokens: maxNewTokens,
            requestToken: token
        ) { [weak self] output in
            let latency = Date().timeIntervalSince(t0)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let calls = output.flatMap { Self.parseCalls($0) } ?? []
                let valid = calls.first { Self.validate($0, facts: facts) }
                if output != nil || !token.isCancelled {
                    self.log(facts: facts, schema: schema, snapshot: snapshotForLog,
                              modelInput: modelInput, output: output, chosen: valid,
                              calls: calls, latency: latency)
                }
                guard self.activeRequest === token,
                      self.isCurrentGeneration(generation) else { return }
                self.activeRequest = nil
                self.activeActor = nil
                self.pending = false
                completion(valid, calls.map(Self.describe))
            }
        }
    }

    private let systemPrompt = """
        You are the action brain of a desktop pet. The decision brain already chose a goal; \
        choose the single most appropriate next action using exactly one tool call.
        """

    // MARK: 日志（行为数据，将来 fine-tune 训练集）

    /// jsonl 落盘：ts / actor / snapshot / output / chosen / latency_ms。
    static var logURL: URL {
        BrainTraceLog.logURL
    }

    private func log(facts: WorldFacts, schema: String, snapshot: String,
                     modelInput: String, output: String?, chosen: SemanticAction?,
                     calls: [SemanticAction], latency: TimeInterval,
                     brainMode: String = "needle") {
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": "decision",
            "trace_id": facts.traceID ?? NSNull(),
            "actor": facts.actor,
            "brain_mode": brainMode,
            "mode": "needle3",
            "scene": facts.sceneID ?? NSNull(),
            "goal": facts.goal.map { goal -> [String: Any] in
                ["kind": goal.kind, "activity": goal.activity ?? NSNull(),
                 "style": goal.style ?? NSNull()]
            } ?? NSNull(),
            "snapshot": snapshot,
            "model_input": modelInput,
            "schema": schema,
            "senses": facts.sensesJSON ?? NSNull(),
            "output": output ?? NSNull(),
            "chosen": chosen.map(Self.describe) ?? "invalid",
            "calls": calls.map(Self.describe),
            "latency_ms": Int(latency * 1000),
        ]
        Self.append(record)
    }

    /// Needle 不可用/失败时，Autopilot 或内置策略的结果也要进入同一条决策流。
    static func logFallback(facts: WorldFacts, chosen: String?, mode: String, reason: String) {
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": "decision",
            "trace_id": facts.traceID ?? NSNull(),
            "actor": facts.actor,
            "brain_mode": mode,
            "mode": "fallback",
            "scene": facts.sceneID ?? NSNull(),
            "goal": facts.goal.map { goal -> [String: Any] in
                ["kind": goal.kind, "activity": goal.activity ?? NSNull(),
                 "style": goal.style ?? NSNull()]
            } ?? NSNull(),
            "snapshot": snapshot(facts: facts),
            "model_input": NSNull(),
            "schema": NSNull(),
            "senses": facts.sensesJSON ?? NSNull(),
            "output": NSNull(),
            "chosen": chosen ?? "invalid",
            "calls": chosen.map { [$0] } ?? [],
            "fallback_reason": reason,
            "latency_ms": 0,
        ]
        Self.append(record)
    }

    private static func append(_ record: [String: Any]) {
        BrainTraceLog.append(record)
    }
}
