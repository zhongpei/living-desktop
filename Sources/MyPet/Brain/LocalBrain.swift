import Foundation
import MyPetAI
import MyPetCore
import MyPetEngine

// LocalBrain —— 本地决策脑：端侧 MLX Qwen3.5-0.8B（brain-local.md §5.2/§5.3）。
//
// actor 隔离：MLX ModelContainer 非线程安全、决策串行；调度门闩（pending /
// nextPlanAt）放在锁守卫的 DispatchGate（actor 可变属性不能 nonisolated），
// 协议入口保持同步语义 —— 与 TeacherBrain 的 DispatchQueue 模式逐位对齐
//（不到点/在飞 → 返回 false → 策略兜底）。
//
// 决策管线（G1）：
//   前缀（每角色/任务一份 PromptState，prefill/磁盘加载一次）
//     → 动态消息（BrainPrefixBuilder.dynamicMessage）
//     → tokenize 成前缀 token 的严格后缀 → master.copy() 只 prefill 后缀
//     → 生成（档案 decision 采样：temp=0 确定性）→ JSON 三关校验
//   失败：原样重试 1 次（附格式提示）→ 仍失败本轮弃权（§2），Needle 沿用旧 goal。
//
// tokenizer 说明：MLXLMCommon 的 Tokenizer 协议不暴露 addGenerationPrompt，
// 前缀拼接必须精确控制生成提示 → 用 swift-transformers AutoTokenizer 直载
// 同一模型目录做 tokenize；生成侧的 detokenize 仍走 container 自带 tokenizer。
//
// 模型加载铁律（G0 实测，勿改）：必须走 VLMModelFactory 的 qwen3_5；mtp 边车
// 绝不能在模型目录；processor shim 由 LocalBrainModel.writeProcessorShim 幂等生成。

actor LocalBrain: GoalBrain {

    enum BrainError: LocalizedError {
        case modelMissing
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "本地大脑模型未就位（设置 → 大脑 → 下载）"
            case .loadFailed(let detail):
                return "本地大脑加载失败：\(detail)"
            }
        }
    }

    struct DecisionStats: Sendable, Equatable {
        var decisions = 0
        var cacheHits = 0
        var fullPrefills = 0
        var retries = 0
        var invalid = 0
    }

    /// 设置窗短聊天测试的结果；延时包含模型加载、前缀缓存和生成。
    struct ChatTestResult: Sendable, Equatable {
        var text: String?
        var emotion: String?
        var latency: TimeInterval
        var error: String?
    }

    /// 运行时设置覆盖的采样参数；前缀档案仍由 BrainProfile 决定。
    struct Configuration: Sendable, Equatable {
        /// 目标 JSON：低温结构化输出。
        var goalSampling = BrainProfile.Sampling()
        /// 短聊天单行台词：0.8B 实测使用低温、短输出。
        var chatSampling = BrainProfile.Sampling(
            temperature: 0.3, topP: 1.0, topK: 0, maxTokens: 48, seed: nil)
    }

    // ---- 调度门闩（nonisolated 可达，锁守卫）----
    private nonisolated let gate = DispatchGate()
    private nonisolated let configurationStore = ConfigurationStore()

    // ---- 运行状态（actor 隔离）----
    private let runtime = MLXGenerationRuntime()
    private var stats = DecisionStats()

    init() {}

    nonisolated var isAvailable: Bool { LocalBrainModel.isInstalled }

    /// 调度器统一管理规划节奏；本地脑只维护自己的在飞门闩。
    nonisolated func expedite() {}

    /// 只取消目标规划；聊天使用同一模型门闩，但有独立的用户可见生命周期。
    nonisolated func cancelPendingPlan(traceID: String) {
        gate.cancelPlan(traceID: traceID)
    }

    nonisolated func configure(_ configuration: Configuration) {
        configurationStore.set(configuration)
    }

    // MARK: GoalBrain 协议

    @discardableResult
    nonisolated func plan(input: GoalBrainInput,
                          completion: @escaping (GoalDecision?) -> Void) -> Bool {
        guard LocalBrainModel.isInstalled, gate.claim(traceID: input.traceID) else { return false }
        let configuration = configurationStore.get()
        let task = Task {
            defer { gate.release(traceID: input.traceID) }
            let outcome = await self.plan(input: input, configuration: configuration)
            await MainActor.run {
                completion(outcome.decision)
            }
        }
        gate.trackPlan(task, traceID: input.traceID)
        return true
    }

    /// 本地决策脑生成短聊天单行台词；模型未就绪、生成失败或格式非法时，调用方走 Quips。
    @discardableResult
    nonisolated func requestSpeech(intent: SpeechIntent, world: BrainContextSnapshot, brain: BrainState,
                                   personality: Personality, characterID: String,
                                   dialogue: DialogueProfile?, traceID: String?,
                                   completion: @escaping (SpeechReply?) -> Void) -> Bool {
        requestSpeech(intent: intent, world: world, brain: brain,
                      personality: personality, characterID: characterID,
                      dialogue: dialogue, traceID: traceID, userText: nil,
                      completion: completion)
    }

    /// 带用户原文的短聊天通道。它仍然只生成一条气泡文本，不获得动作、
    /// 目标或坐标权限；用户输入只在本次请求内存在，不写入日志。
    @discardableResult
    nonisolated func requestSpeech(intent: SpeechIntent, world: BrainContextSnapshot, brain: BrainState,
                                   personality: Personality, characterID: String,
                                   dialogue: DialogueProfile?, traceID: String?, userText: String?,
                                   completion: @escaping (SpeechReply?) -> Void) -> Bool {
        guard LocalBrainModel.isInstalled, gate.claim() else { return false }
        let configuration = configurationStore.get()
        let input = SpeechInput(intent: intent, world: world, brain: brain,
                                personality: personality, characterID: characterID,
                                dialogue: dialogue, traceID: traceID,
                                userText: userText.map { String($0.prefix(120)) })
        Task {
            defer { gate.release() }
            let reply = await self.speak(input: input, configuration: configuration)
            await MainActor.run {
                completion(reply)
            }
        }
        return true
    }

    /// 设置窗使用的真实本地聊天测试。它复用生产单行台词管线、独立聊天前缀
    /// 和聊天采样；不伪造网络响应，也不走 Quips。
    func testChat(personality: Personality) async -> ChatTestResult {
        let t0 = Date()
        guard LocalBrainModel.isInstalled else {
            return ChatTestResult(text: nil, emotion: nil,
                                  latency: Date().timeIntervalSince(t0),
                                  error: "本地模型未就位，请先从 URL 下载并校验")
        }
        guard gate.claim() else {
            return ChatTestResult(text: nil, emotion: nil,
                                  latency: Date().timeIntervalSince(t0),
                                  error: "本地决策脑正在处理另一项请求")
        }
        defer { gate.release() }
        let world = BrainContextSnapshot(
            capturedAt: Date().timeIntervalSince1970,
            activeApp: "MyPet",
            windowTitle: "",
            appActivity: "unknown",
            userActivity: "idle",
            focusRole: "",
            visibleContext: [],
            salientUI: [],
            nearbyWindows: [],
            recentEvents: [])
        let input = SpeechInput(intent: .greet, world: world, brain: BrainState(),
                                personality: personality, characterID: "settings-test",
                                dialogue: nil, traceID: nil)
        let reply = await speak(input: input, configuration: configurationStore.get())
        return ChatTestResult(
            text: reply?.text,
            emotion: reply?.emotion,
            latency: Date().timeIntervalSince(t0),
            error: reply == nil ? "本地模型未返回合法单行台词" : nil)
    }

    // MARK: 决策

    private struct PlanOutcome {
        var decision: GoalDecision?
    }

    private struct SpeechInput {
        var intent: SpeechIntent
        var world: BrainContextSnapshot
        var brain: BrainState
        var personality: Personality
        var characterID: String
        var dialogue: DialogueProfile?
        var traceID: String?
        var userText: String? = nil
    }

    private func plan(input: GoalBrainInput, configuration: Configuration) async -> PlanOutcome {
        let t0 = Date()
        let profile = BrainProfile.resolved()
        do {
            try Task.checkCancellation()
            let sampling = configuration.goalSampling
            let memoryLines = input.memory.map { $0.trimmingCharacters(in: .whitespaces) }

            var output: String?
            var decision = BrainPrefixBuilder.Decision(
                goal: "", target: nil, style: nil, speechIntent: nil)
            for attempt in 0...1 {
                let retryHint = attempt == 0 ? nil : BrainPrefixBuilder.retryHint
                let dynamic = BrainPrefixBuilder.dynamicMessage(
                    world: input.world, brain: input.brain, personality: input.personality,
                    memoryLines: memoryLines, retryHint: retryHint)
                let result = try await generateText(
                    petID: input.petID, personality: input.personality, profile: profile,
                    dynamicText: dynamic, sampling: sampling)
                output = result.text
                if result.usedFullPrefill {
                    stats.fullPrefills += 1
                } else {
                    stats.cacheHits += 1
                }
                if attempt > 0 { stats.retries += 1 }
                if let parsed = BrainPrefixBuilder.parseDecision(output ?? "", world: input.world) {
                    decision = parsed
                    break
                }
            }

            let latency = Date().timeIntervalSince(t0)
            stats.decisions += 1
            if let mapped = LocalBrainGoal.mapping(decision.goal) {
                let goalDecision = GoalDecision(
                    goal: mapped, target: decision.target, activity: nil, style: decision.style,
                    speech: nil, speechIntent: decision.speechIntent,
                    memory: nil, why: "local \(decision.goal)")
                BrainDecisionLog.log(world: input.world, brain: input.brain, output: output,
                                 chosen: goalDecision, latency: latency, mode: "local",
                                 traceID: input.traceID,
                                 personality: input.personality, memory: input.memory,
                                 role: "student")
                return PlanOutcome(decision: goalDecision)
            }
            // 两轮都非法：本地决策脑本轮弃权（§2）。这条 trace 同样是素材（G2 回填）。
            stats.invalid += 1
            BrainDecisionLog.log(world: input.world, brain: input.brain, output: output, chosen: nil,
                             latency: latency, mode: "local",
                             decisionValid: false, traceID: input.traceID,
                             personality: input.personality, memory: input.memory,
                             role: "student")
            return PlanOutcome(decision: nil)
        } catch is CancellationError {
            return PlanOutcome(decision: nil)
        } catch {
            NSLog("MyPet LocalBrain: 决策失败 %@", error.localizedDescription)
            stats.invalid += 1
            let latency = Date().timeIntervalSince(t0)
            BrainDecisionLog.log(world: input.world, brain: input.brain,
                             output: "<error: \(error.localizedDescription)>", chosen: nil,
                             latency: latency, mode: "local",
                             decisionValid: false, traceID: input.traceID,
                             fallbackReason: "local_brain_error",
                             personality: input.personality, memory: input.memory,
                             role: "student")
            return PlanOutcome(decision: nil)
        }
    }

    private func speak(input: SpeechInput, configuration: Configuration) async -> SpeechReply? {
        let t0 = Date()
        do {
            let profile = BrainProfile.resolved()
            let promptKind = "chat-\(input.intent.rawValue)"
            var reply: SpeechReply?
            var output = ""
            for attempt in 0...1 {
                let dynamic = BrainPrefixBuilder.chatMessage(
                    intent: input.intent, world: input.world, brain: input.brain,
                    personality: input.personality, userText: input.userText,
                    retryHint: attempt == 0 ? nil : BrainPrefixBuilder.chatRetryHint)
                output = try await generateText(
                    petID: input.characterID, personality: input.personality, profile: profile,
                    promptKind: promptKind, dialogue: input.dialogue, speechIntent: input.intent,
                    dynamicText: dynamic,
                    sampling: SpeechSamplingPolicy.resolve(input.intent, from: configuration.chatSampling)).text
                reply = Self.parseLocalSpeech(output, intent: input.intent)
                if reply != nil { break }
            }
            BrainDecisionLog.logSpeech(intent: input.intent, reply: reply,
                                       latency: Date().timeIntervalSince(t0),
                                       traceID: input.traceID, mode: "local")
            return reply
        } catch {
            NSLog("MyPet LocalBrain: 聊天生成失败 %@", error.localizedDescription)
            BrainDecisionLog.logSpeech(intent: input.intent, reply: nil,
                                       latency: Date().timeIntervalSince(t0),
                                       traceID: input.traceID, mode: "local")
            return nil
        }
    }

    /// Build plain prompt values in the app domain; MyPetAI owns every MLX,
    /// tokenizer and cache object behind this call.
    private func generateText(
        petID: String, personality: Personality, profile: BrainProfile,
        promptKind: String = "goal", dialogue: DialogueProfile? = nil,
        speechIntent: SpeechIntent? = nil, dynamicText: String,
        sampling: BrainProfile.Sampling
    ) async throws -> MLXGenerationResult {
        guard LocalBrainModel.isInstalled else { throw BrainError.modelMissing }
        let modelDir = LocalBrainModel.installDirectory
        let dialogueHash = dialogue.flatMap { value -> String? in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(value)).map { BrainProfile.sha8(String(decoding: $0, as: UTF8.self)) }
        } ?? "-"
        let key = BrainCacheManager.makeKey(petID: petID, personality: personality,
                                            profile: profile, modelDir: modelDir,
                                            promptKind: promptKind,
                                            promptVersion: promptKind.hasPrefix("chat-")
                                                ? BrainPrefixBuilder.chatPromptVersion
                                                : BrainPrefixBuilder.brainPromptVersion,
                                            contentHash: dialogueHash)
        LocalBrainModel.writeProcessorShim(into: modelDir)
        let traitsApplied = profile.applyingTraits(to: personality)
        let messages: [[String: String]]
        if let speechIntent {
            messages = BrainPrefixBuilder.chatPrefixMessages(
                personality: traitsApplied, profile: profile,
                dialogue: dialogue, intent: speechIntent)
        } else {
            messages = BrainPrefixBuilder.prefixMessages(
                personality: traitsApplied, profile: profile)
        }
        return try await runtime.generate(
            modelDirectory: modelDir, petID: petID, cacheKey: key.composite,
            promptVersion: key.brainPrompt, prefixMessages: messages,
            dynamicText: dynamicText,
            sampling: MLXSampling(
                temperature: sampling.temperature, topP: sampling.topP,
                topK: sampling.topK, maxTokens: sampling.maxTokens, seed: sampling.seed),
            memoryEntries: profile.cache.memoryEntries,
            diskEntries: profile.cache.diskEntries)
    }

    private static func validSpeech(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains("\n"), text.count <= 50 else { return false }
        for leaked in ["KNOWN_FACTS", "SPEECH_ACT", "CONSTRAINT", "系统", "示例"]
            where text.contains(leaked) { return false }
        return true
    }

    static func parseLocalSpeech(_ output: String, intent: SpeechIntent) -> SpeechReply? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSpeech(text) else { return nil }
        return SpeechReply(text: text, emotion: emotion(for: intent))
    }

    private static func emotion(for intent: SpeechIntent) -> String {
        switch intent {
        case .greet: "happy"
        case .commentActivity, .chatter: "neutral"
        case .tease: "teasing"
        case .complain: "annoyed"
        }
    }

    // MARK: 诊断

    /// 设置窗「缓存」行与托盘速览的统计快照。
    func snapshotStats() -> DecisionStats { stats }
}

/// 决策在飞门闩（锁守卫，nonisolated 可达）。调度时间由协调器统一管理。
/// actor 的可变存储属性不允许 nonisolated，故把这份同步语义收进独立小类。
final class DispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var planPending = false
    private var planTask: Task<Void, Never>?
    private var planTraceID: String?
    private var planCancelled = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !planPending else { return false }
        planPending = true
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard planTraceID == nil else { return }
        planPending = false
    }

    func claim(traceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !planPending else { return false }
        planPending = true
        planTraceID = traceID
        planCancelled = false
        return true
    }

    func release(traceID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard planTraceID == traceID else { return }
        planPending = false
        planTask = nil
        planTraceID = nil
        planCancelled = false
    }

    func trackPlan(_ task: Task<Void, Never>, traceID: String) {
        lock.lock()
        let cancelled = planTraceID == traceID && planCancelled
        if planTraceID == traceID { planTask = task }
        lock.unlock()
        if cancelled { task.cancel() }
    }

    func cancelPlan(traceID: String) {
        lock.lock()
        if planTraceID == traceID { planCancelled = true }
        let task = planTraceID == traceID ? planTask : nil
        lock.unlock()
        task?.cancel()
    }
}

/// 设置更新从主线程同步到 LocalBrain actor 入口的轻量存储。
private final class ConfigurationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = LocalBrain.Configuration()

    func set(_ value: LocalBrain.Configuration) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> LocalBrain.Configuration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
