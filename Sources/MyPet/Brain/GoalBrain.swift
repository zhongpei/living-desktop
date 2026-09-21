import Foundation
import MyPetCore

// GoalBrain —— 高层目标决策的统一接口：
//   TeacherBrain → 本机 llama.cpp + Qwen VLM（高阶教师脑）
//   LocalBrain   → 端侧 MLX 0.8B（本地决策脑）
// GoalBrainCoordinator 可同时调度两个适配器；行动脑和游戏身体不感知模型实现。
struct GoalBrainInput {
    let petID: String
    let world: BrainContextSnapshot
    let brain: BrainState
    let personality: Personality
    let memory: [String]
    let traceID: String
}

protocol GoalBrain: AnyObject {
    var isAvailable: Bool { get }

    /// 世界大变化：把下一次目标规划提前到现在。主线程调用；pending 时无害。
    func expedite()

    /// 当前规划已经失效。昂贵且可取消的实现应停止底层工作；轻量实现可以只丢弃结果。
    /// 主线程调用，不影响独立的聊天请求。
    func cancelPendingPlan()

    /// 发起一次目标规划。调度节奏由 GoalBrainCoordinator 统一管理。
    /// 返回 false = 不可用/已在飞；回调主队列，decision=nil = 失败/被拒/弃权。
    @discardableResult
    func plan(input: GoalBrainInput,
                   completion: @escaping (GoalDecision?) -> Void) -> Bool

    /// 行动脑决定「该说话」，可用的文本生成脑决定「说什么」。返回 false = 本实现
    /// 当前不可用，调用方走内置 Quips。回调主队列，reply=nil = 失败。
    @discardableResult
    func requestSpeech(intent: SpeechIntent, world: BrainContextSnapshot, brain: BrainState,
                       personality: Personality, characterID: String,
                       dialogue: DialogueProfile?, traceID: String?,
                       completion: @escaping (SpeechReply?) -> Void) -> Bool
}

// BrainDecisionLog —— 三档大脑事件，统一写入 brain_trace.jsonl。
// Teacher / Local / Policy 通过 brain_mode 区分；trace_id 与行动脑和场景结局关联。
enum BrainDecisionLog {

    static var logURL: URL {
        BrainTraceLog.logURL
    }

    static func log(world: BrainContextSnapshot, brain: BrainState, output: String?,
                    chosen: GoalDecision?, latency: TimeInterval,
                    mode: String = "teacher", decisionValid: Bool = true,
                    traceID: String? = nil,
                    fallbackReason: String? = nil,
                    personality: Personality? = nil, memory: [String] = [],
                    role: String? = nil) {
        let worldObj: [String: Any] = [
            "active_app": world.activeApp,
            "window": orNull(world.windowTitle),
            "app_activity": world.appActivity,
            "user_activity": world.userActivity,
            "focus_role": world.focusRole,
            "visible_context": world.visibleContext,
            "salient_ui": world.salientUI,
            "nearby_windows": world.nearbyWindows,
            "recent_events": world.recentEvents,
        ]
        let chosenObject: Any = chosen.map {
            ["goal": $0.goal.rawValue, "target": orNull($0.target),
             "activity": orNull($0.activity), "style": orNull($0.style),
             "speech": orNull($0.speech),
             "memory": orNull($0.memory),
             "why": orNull($0.why)]
        } ?? NSNull()
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": "plan",
            "brain_mode": mode,
            "brain_role": role ?? (mode == "teacher" ? "teacher" : mode == "local" ? "student" : mode),
            "teacher_label_status": mode == "teacher"
                ? (decisionValid ? "valid" : "invalid") : NSNull(),
            "trace_id": traceID ?? NSNull(),
            "world": worldObj,
            "brain": [
                "energy": brain.energy, "curiosity": brain.curiosity,
                "social_need": brain.socialNeed, "boredom": brain.boredom,
                "affection": brain.affection, "stress": brain.stress,
                "goal": orNull(brain.currentGoal),
                "last_action": orNull(brain.lastAction),
            ],
            "personality": personality.map(personalityObject) ?? NSNull(),
            "memory": memory,
            "output": orNull(output),
            "chosen": chosenObject,
            "decision_valid": decisionValid,
            "latency_ms": Int(latency * 1000),
            "fallback_reason": fallbackReason ?? NSNull(),
        ]
        append(record, to: logURL)
    }

    /// 没有模型参与时也记一条目标层记录，避免日志只留下“模型成功”的幸存者。
    static func logPolicy(world: BrainContextSnapshot, brain: BrainState, goal: Goal,
                          personality: Personality, memory: [String],
                          traceID: String, reason: String) {
        let decision = GoalDecision(
            goal: goal.kind,
            target: goal.target,
            activity: goal.activity?.rawValue,
            style: goal.style,
            speech: nil,
            speechIntent: nil,
            memory: nil,
            why: nil)
        log(world: world, brain: brain, output: "<built-in policy>", chosen: decision,
             latency: 0, mode: "policy", decisionValid: true,
             traceID: traceID, fallbackReason: reason,
             personality: personality, memory: memory)
    }

    /// 语音请求日志（与规划同文件，kind=speech）。
    static func logSpeech(intent: SpeechIntent, reply: SpeechReply?, latency: TimeInterval,
                          traceID: String? = nil,
                          mode: String = "teacher") {
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": "speech",
            "brain_mode": mode,
            "trace_id": traceID ?? NSNull(),
            "intent": intent.rawValue,
            "reply": reply.map {
                ["text": $0.text, "emotion": $0.emotion]
            } ?? NSNull(),
            "latency_ms": Int(latency * 1000),
        ]
        append(record, to: logURL)
    }

    // MARK: Outcome（game.md §16：训练数据的 label）

    /// 一段目标/场景执行完的结局。BrainContextSnapshot+BrainState+Goal+轨迹+Outcome
    /// 拼起来才是完整的 (输入, 输出, 效果) 训练样本。
    static func outcomeRecord(
        goalKind: String?, goalSource: String?, scene: String?,
        stayedSeconds: Double, completed: Bool, reason: String,
        interruptedByUser: Bool, personalityStyle: String, memoryCount: Int,
        activeApp: String, activity: String?, traceID: String? = nil
    ) -> [String: Any] {
        [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": "outcome",
            "trace_id": traceID ?? NSNull(),
            "goal": ["kind": goalKind ?? NSNull(), "source": goalSource ?? NSNull(),
                     "activity": activity ?? NSNull()] as [String: Any],
            "scene": scene ?? NSNull(),
            "stayed_s": Int(stayedSeconds),
            "completed": completed,
            "ended_because": reason,
            "interrupted_by_user": interruptedByUser,
            "personality_style": personalityStyle,
            "memory_count": memoryCount,
            "active_app": activeApp,
        ]
    }

    /// 结局落盘（与规划同文件）。
    static func logOutcome(_ record: [String: Any]) {
        append(record, to: logURL)
    }

    /// jsonl 追加（内部共享）。
    static func append(_ record: [String: Any], to _: URL) {
        guard JSONSerialization.isValidJSONObject(record) else { return }
        BrainTraceLog.append(record)
    }

    /// Optional 字段进 JSON 必须显式 NSNull，否则 JSONSerialization 抛错。
    private static func orNull(_ s: String?) -> Any { s ?? NSNull() }

    private static func personalityObject(_ personality: Personality) -> [String: Any] {
        [
            "style": personality.styleWord,
            "social": personality.social,
            "curiosity": personality.curiosity,
            "playfulness": personality.playfulness,
            "diligence": personality.diligence,
            "empathy": personality.empathy,
            "independence": personality.independence,
            "teasing": personality.teasing,
            "chattiness": personality.chattiness,
        ]
    }
}

/// TeacherBrain —— 高阶教师脑适配器。
///
/// 与 Brain v1 的本质区别（game.md 定稿）：**LLM 永不输出微操**。
/// 它只回答「我想做什么」（Goal）+ 偶尔说句话 + 沉淀记忆；
/// 「下一步具体干什么」是行动脑（Needle）+ 场景配方的事。
///
/// 传输：OpenAI 兼容 chat completions。配置来源：Settings（设置窗可改）
/// > 环境变量（MYPET_TEACHER_BASE_URL/MODEL/KEY，实验通道保留）> 无（不可用）。
/// 默认端点指向局域网本地 LLM（192.168.2.60:8001）。
///
/// 调度节奏由 GoalBrainCoordinator 统一管理；行动脑仍独立按行动边界运行。
final class TeacherBrain: GoalBrain {

    struct PlanSampling: Equatable, Sendable {
        var temperature: Double = 0.8
        var topP: Double = 1.0
        var topK: Int = 0
        var maxTokens: Int = 220
        var seed: Int?
        /// 空 = 不发送；非空按 llama.cpp/OpenAI 兼容端点透传。
        var reasoningEffort = ""
    }

    struct Config: Equatable {
        var baseURL: String
        var model: String
        var apiKey: String
        var planSampling = PlanSampling()

        var isComplete: Bool {
            !baseURL.isEmpty && !model.isEmpty
        }
    }

    /// PetController 在设置变化时刷新（协议入口不再携带端点参数）。
    var config: Config?
    /// 测试注入通道：URLSession mock 与直接指定配置（绕过 config 解析）。
    var session: URLSession = .shared
    var injectedConfig: Config?

    private let queue = DispatchQueue(label: "mypet.teacher-brain")
    private var planPending = false
    private var speechPending = false
    private var planGeneration: UInt64 = 0
    private var planTask: URLSessionTask?

    var isAvailable: Bool { effectiveConfig != nil }

    private var effectiveConfig: Config? { injectedConfig ?? config }

    /// 调度器会把下一轮教师规划提前；适配器自身只处理 pending。
    func expedite() {}

    func cancelPendingPlan() {
        planGeneration &+= 1
        planTask?.cancel()
        planTask = nil
        planPending = false
    }

    // MARK: 配置

    /// Settings 持久配置 + 环境变量覆盖（实验注入通道）。
    static func config(settingsBaseURL: String?, settingsModel: String?, settingsKey: String?,
                       planSampling: PlanSampling = .init()) -> Config? {
        let env = ProcessInfo.processInfo.environment
        let base = env["MYPET_TEACHER_BASE_URL"] ?? settingsBaseURL ?? ""
        let model = env["MYPET_TEACHER_MODEL"] ?? settingsModel ?? ""
        let key = env["MYPET_TEACHER_KEY"] ?? settingsKey ?? ""
        let config = Config(baseURL: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                            model: model.trimmingCharacters(in: .whitespaces),
                            apiKey: key, planSampling: planSampling)
        return config.isComplete ? config : nil
    }

    // MARK: 目标规划

    /// 发起一次教师 Goal 规划。返回 false = 不可用/已在飞。
    @discardableResult
    func plan(input: GoalBrainInput,
                   completion: @escaping (GoalDecision?) -> Void) -> Bool {
        guard !planPending, let config = effectiveConfig else { return false }
        planPending = true
        planGeneration &+= 1
        let generation = planGeneration

        let request = Self.buildPlanRequest(model: config.model, world: input.world, brain: input.brain,
                                            personality: input.personality, memory: input.memory,
                                            sampling: config.planSampling)
        let t0 = Date()
        planTask = Self.perform(config: config, request: request, session: session) { [weak self] output in
            let latency = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                guard let self, self.planGeneration == generation else { return }
                self.planTask = nil
                self.planPending = false
                let decision = output.flatMap { GoalDecision.parse($0) }
                let valid = decision.flatMap { GoalDecision.validate($0, world: input.world) ? $0 : nil }
                BrainDecisionLog.log(world: input.world, brain: input.brain, output: output,
                                 chosen: valid, latency: latency,
                                 decisionValid: valid != nil,
                                 traceID: input.traceID, personality: input.personality, memory: input.memory,
                                 role: "teacher")
                completion(valid)
            }
        }
        return true
    }

    // MARK: 语音请求（行动脑决定「该说话」，可用决策脑决定「说什么」）

    @discardableResult
    func requestSpeech(
        intent: SpeechIntent,
        world: BrainContextSnapshot,
        brain: BrainState,
        personality: Personality,
        characterID: String,
        dialogue: DialogueProfile?,
        traceID: String?,
        completion: @escaping (SpeechReply?) -> Void
    ) -> Bool {
        guard !speechPending, let config = effectiveConfig else { return false }
        speechPending = true
        let request = Self.buildSpeechRequest(model: config.model, intent: intent,
                                              world: world, brain: brain, personality: personality)
        let session = self.session
        queue.async { [weak self] in
            let t0 = Date()
            Self.perform(config: config, request: request, session: session) { output in
                DispatchQueue.main.async {
                    self?.speechPending = false
                    let reply = output.flatMap { SpeechReply.parse($0) }
                    BrainDecisionLog.logSpeech(intent: intent, reply: reply,
                                           latency: Date().timeIntervalSince(t0),
                                           traceID: traceID)
                    completion(reply)
                }
            }
        }
        return true
    }

    // MARK: prompt 构造（静态纯函数，离线可测）

    /// llama.cpp 的 schema-constrained JSON。只用于 Goal 请求；语音请求仍走
    /// 固定的短输出参数，且不暴露独立语音 sampler。
    static func goalResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "goal_decision",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "goal": ["type": "string", "enum": GoalKind.allCases.map(\.rawValue)],
                        "target": ["type": "string"],
                        "activity": ["type": "string"],
                        "style": ["type": "string"],
                        "speech": ["type": "string"],
                        "memory": ["type": "string"],
                        "why": ["type": "string"],
                    ],
                    "required": ["goal"],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    static func buildPlanRequest(model: String, world: BrainContextSnapshot, brain: BrainState,
                                 personality: Personality, memory: [String],
                                 sampling: PlanSampling = .init()) -> [String: Any] {
        let system = """
        You are the inner mind of a desktop pet living on the user's screen. \
        You NEVER control the body: you only choose a high-level GOAL, and the \
        action brain + scene system carry it out. Choose one goal: \
        join_user_activity(keep the user company at their current activity), \
        watch_with_user(watch what the user watches), seek_attention(want pets/interaction), \
        tease_user(make a brief playful or sharp remark aimed at the user), \
        complain_to_user(protest being disturbed), explore, rest, wander. \
        Consider the pet's personality, especially its teasing tendency, needs and memory. \
        Respond with ONLY a JSON object: \
        {"goal":"...","target":"user|window_<id>|omit","activity":"<activity word or omit>",\
        "style":"<2-word mood>","speech":"<one short line in the pet's voice, or omit>",\
        "memory":"<one <=40 char fact worth remembering, or omit>","why":"<one short sentence>"}.
        """
        let body: [String: Any] = [
            "world": [
                "active_app": world.activeApp,
                "window": world.windowTitle,
                "app_activity": world.appActivity,
                "user_activity": world.userActivity,
                "focus_role": world.focusRole,
                "visible_context": world.visibleContext,
                "nearby_windows": world.nearbyWindows,
                "recent_events": world.recentEvents,
            ],
            "brain": [
                "energy": round(brain.energy * 100) / 100,
                "curiosity": round(brain.curiosity * 100) / 100,
                "social_need": round(brain.socialNeed * 100) / 100,
                "boredom": round(brain.boredom * 100) / 100,
                "affection": round(brain.affection * 100) / 100,
                "stress": round(brain.stress * 100) / 100,
                "current_goal": orNull(brain.currentGoal),
                "last_activity": orNull(brain.lastActivity),
                "last_action": orNull(brain.lastAction),
                "last_speech": orNull(brain.lastSpeech),
            ],
            "personality": personality.promptSection,
            "style_hint": personality.styleWord,
            "memory": memory,
        ]
        let userData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let messages: [[String: String]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": userData],
        ]
        var request: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": sampling.temperature,
            "top_p": sampling.topP,
            "max_tokens": sampling.maxTokens,
        ]
        if sampling.topK > 0 { request["top_k"] = sampling.topK }
        if let seed = sampling.seed { request["seed"] = seed }
        if !sampling.reasoningEffort.isEmpty {
            request["reasoning_effort"] = sampling.reasoningEffort
        } else if model.localizedCaseInsensitiveContains("qwen") {
            request["chat_template_kwargs"] = ["enable_thinking": false]
        }
        request["response_format"] = goalResponseFormat()
        return request
    }

    static func buildSpeechRequest(model: String, intent: SpeechIntent, world: BrainContextSnapshot,
                                   brain: BrainState, personality: Personality) -> [String: Any] {
        let system = """
        You write one short spoken line for a desktop pet. Intent: \(intent.rawValue). \
        For tease, keep it playful and non-abusive. Speak in the pet's voice, stay under 30 characters, output ONLY JSON: \
        {"text":"...","emotion":"neutral|happy|teasing|annoyed|sleepy"}.
        """
        let body: [String: Any] = [
            "context": [
                "active_app": world.activeApp,
                "app_activity": world.appActivity,
                "social_need": round(brain.socialNeed * 100) / 100,
                "stress": round(brain.stress * 100) / 100,
            ],
            "personality": personality.promptSection,
        ]
        let userData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var request: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userData],
            ],
            "temperature": 0.9,
            "max_tokens": 90,
        ]
        if model.localizedCaseInsensitiveContains("qwen") {
            request["chat_template_kwargs"] = ["enable_thinking": false]
        }
        return request
    }

    // MARK: 传输（OpenAI 兼容）

    static func endpoint(_ config: Config, path: String) -> URL? {
        URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }

    /// Optional 字段进 JSON 必须显式 NSNull，否则 JSONSerialization 抛错。
    private static func orNull(_ s: String?) -> Any { s ?? NSNull() }

    @discardableResult
    static func perform(config: Config, request: [String: Any],
                        session: URLSession = .shared,
                        completion: @escaping (String?) -> Void) -> URLSessionTask? {
        guard let url = endpoint(config, path: "/chat/completions") else {
            completion(nil)
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: request)
        let task = session.dataTask(with: req) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                completion(nil)
                return
            }
            if let content = message["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completion(content)
            } else {
                completion(message["reasoning_content"] as? String)
            }
        }
        task.resume()
        return task
    }

    // MARK: 设置窗探测 / 测试

    /// GET /models —— 探测端点上的可用模型列表。返回 (模型 id, 错误信息)。
    static func probeModels(config: Config, session: URLSession = .shared,
                            completion: @escaping ([String], String?) -> Void) {
        guard let url = endpoint(config, path: "/models") else {
            completion([], "baseURL 无效")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        session.dataTask(with: req) { data, _, error in
            guard error == nil, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion([], error?.localizedDescription ?? "无法连接") }
                return
            }
            let ids: [String]
            if let list = obj["data"] as? [[String: Any]] {
                ids = list.compactMap { $0["id"] as? String }
            } else if let list = obj["models"] as? [[String: Any]] {
                ids = list.compactMap { $0["name"] as? String }  // Ollama 风格
            } else {
                ids = []
            }
            DispatchQueue.main.async {
                completion(ids, ids.isEmpty ? "端点可达但没有返回模型" : nil)
            }
        }.resume()
    }

    /// 一轮最小对话测试。返回 (回复摘要, 错误)。
    static func testChat(config: Config, session: URLSession = .shared,
                         completion: @escaping (String, String?) -> Void) {
        let sampling = config.planSampling
        var request: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": "Reply with exactly: OK"]],
            "temperature": sampling.temperature,
            "top_p": sampling.topP,
            "max_tokens": min(sampling.maxTokens, 32),
        ]
        if sampling.topK > 0 { request["top_k"] = sampling.topK }
        if let seed = sampling.seed { request["seed"] = seed }
        if !sampling.reasoningEffort.isEmpty { request["reasoning_effort"] = sampling.reasoningEffort }
        perform(config: config, request: request, session: session) { output in
            DispatchQueue.main.async {
                if let output {
                    completion(String(output.prefix(80)), nil)
                } else {
                    completion("", "请求失败（检查端点/模型名/密钥）")
                }
            }
        }
    }
}

/// 独立开关下实际可用的高层决策来源（纯函数，离线可测）。
enum GoalBrainSelection {
    enum Source: String, Equatable {
        case local, teacher
    }

    static func active(localEnabled: Bool, localAvailable: Bool,
                       teacherEnabled: Bool, teacherAvailable: Bool) -> [Source] {
        var result: [Source] = []
        if localEnabled, localAvailable { result.append(.local) }
        if teacherEnabled, teacherAvailable { result.append(.teacher) }
        return result
    }

    /// 同时可用时本地脑驱动游戏，教师脑只做 shadow 标签。
    static func runtime(localEnabled: Bool, localAvailable: Bool,
                        teacherEnabled: Bool, teacherAvailable: Bool) -> Source? {
        active(localEnabled: localEnabled, localAvailable: localAvailable,
               teacherEnabled: teacherEnabled, teacherAvailable: teacherAvailable).first
    }
}

/// GoalBrain 的深接口：统一一次快照、调度节奏和并行结果，调用方只收到一个运行时 Goal。
final class GoalBrainCoordinator {
    typealias Source = GoalBrainSelection.Source

    private let local: any GoalBrain
    private let teacher: any GoalBrain
    private var localEnabled = false
    private var teacherEnabled = false
    private var interval: ClosedRange<Double> = 45...90
    private var nextPlanAt: Double = 0
    private var pending = false
    private var planGeneration: UInt64 = 0

    private(set) var runtimeSource: Source?

    init(local: any GoalBrain, teacher: any GoalBrain) {
        self.local = local
        self.teacher = teacher
    }

    func configure(localEnabled: Bool, teacherEnabled: Bool,
                   interval: ClosedRange<Double>) {
        self.localEnabled = localEnabled
        self.teacherEnabled = teacherEnabled
        self.interval = interval.lowerBound...max(interval.lowerBound, interval.upperBound)
        runtimeSource = GoalBrainSelection.runtime(
            localEnabled: localEnabled, localAvailable: local.isAvailable,
            teacherEnabled: teacherEnabled, teacherAvailable: teacher.isAvailable)
    }

    var activeSources: [Source] {
        GoalBrainSelection.active(
            localEnabled: localEnabled, localAvailable: local.isAvailable,
            teacherEnabled: teacherEnabled, teacherAvailable: teacher.isAvailable)
    }

    /// true = 本轮已有一个或多个决策请求在飞；控制器应等待回调，不能把它
    /// 当成“未到时间”而提前写入规则目标。
    var isPending: Bool { pending }

    func expedite() {
        nextPlanAt = 0
        cancelPendingPlan()
        local.expedite()
        teacher.expedite()
    }

    func cancelPendingPlan() {
        planGeneration &+= 1
        pending = false
        local.cancelPendingPlan()
        teacher.cancelPendingPlan()
    }

    @discardableResult
    func maybePlan(now: Double, input: GoalBrainInput,
                   completion: @escaping (GoalDecision?, Source?) -> Void) -> Bool {
        guard !pending, now >= nextPlanAt else { return false }
        let sources = activeSources
        guard let runtimeSource = GoalBrainSelection.runtime(
            localEnabled: localEnabled, localAvailable: local.isAvailable,
            teacherEnabled: teacherEnabled, teacherAvailable: teacher.isAvailable),
            !sources.isEmpty else { return false }

        pending = true
        nextPlanAt = now + Double.random(in: interval)
        self.runtimeSource = runtimeSource
        let generation = planGeneration
        let batch = GoalBrainBatch(
            remaining: sources.count, runtimeSource: runtimeSource,
            completion: { [weak self] decision, source in
                guard self?.planGeneration == generation else { return }
                completion(decision, source)
            },
            allDone: { [weak self] in
                guard self?.planGeneration == generation else { return }
                self?.pending = false
            })

        for source in sources {
            let brain: any GoalBrain = source == .local ? local : teacher
            let dispatched = brain.plan(input: input) { decision in
                batch.finish(source: source, decision: decision)
            }
            if !dispatched {
                batch.finish(source: source, decision: nil)
            }
        }
        return true
    }

    @discardableResult
    func requestSpeech(intent: SpeechIntent, world: BrainContextSnapshot, brain: BrainState,
                       personality: Personality, characterID: String,
                       dialogue: DialogueProfile?, traceID: String?,
                       completion: @escaping (SpeechReply?) -> Void) -> Bool {
        guard let source = runtimeSource else { return false }
        let adapter: any GoalBrain = source == .local ? local : teacher
        return adapter.requestSpeech(intent: intent, world: world, brain: brain,
                                     personality: personality, characterID: characterID,
                                     dialogue: dialogue, traceID: traceID,
                                     completion: completion)
    }
}

private final class GoalBrainBatch {
    private var remaining: Int
    private let runtimeSource: GoalBrainSelection.Source
    private let completion: (GoalDecision?, GoalBrainSelection.Source?) -> Void
    private let allDone: () -> Void
    private var runtimeDelivered = false

    init(remaining: Int, runtimeSource: GoalBrainSelection.Source,
         completion: @escaping (GoalDecision?, GoalBrainSelection.Source?) -> Void,
         allDone: @escaping () -> Void) {
        self.remaining = remaining
        self.runtimeSource = runtimeSource
        self.completion = completion
        self.allDone = allDone
    }

    func finish(source: GoalBrainSelection.Source, decision: GoalDecision?) {
        if source == runtimeSource, !runtimeDelivered {
            runtimeDelivered = true
            completion(decision, source)
        }
        remaining -= 1
        if remaining == 0 { allDone() }
    }
}
