import Foundation
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import MyPetCore
import Tokenizers // AutoTokenizer：完整的 applyChatTemplate（含 addGenerationPrompt）

struct BrainMemoryLRU<Value> {
    private(set) var values: [String: Value] = [:]
    private(set) var order: [String] = []

    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    mutating func insert(_ value: Value, for key: String, capacity: Int) {
        trim(capacity: capacity)
        guard capacity > 0 else { return }
        values[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    mutating func trim(capacity: Int) {
        while order.count > max(0, capacity) {
            values.removeValue(forKey: order.removeFirst())
        }
    }
}

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
        /// 短聊天 JSON：0.8B 实测使用低温、短输出。
        var chatSampling = BrainProfile.Sampling(
            temperature: 0.3, topP: 0.8, topK: 20, maxTokens: 48, seed: nil)
    }

    // ---- 调度门闩（nonisolated 可达，锁守卫）----
    private nonisolated let gate = DispatchGate()
    private nonisolated let configurationStore = ConfigurationStore()

    // ---- 运行状态（actor 隔离）----
    private var container: ModelContainer?
    /// swift-transformers tokenizer（applyChatTemplate 全量 API，见文件头说明）。
    private var brainTokenizer: (any Tokenizers.Tokenizer)?
    private var promptStates = BrainMemoryLRU<BrainCacheManager.PromptState>()
    private var stats = DecisionStats()

    init() {}

    nonisolated var isAvailable: Bool { LocalBrainModel.isInstalled }

    /// 调度器统一管理规划节奏；本地脑只维护自己的在飞门闩。
    nonisolated func expedite() {}

    /// 只取消目标规划；聊天使用同一模型门闩，但有独立的用户可见生命周期。
    nonisolated func cancelPendingPlan() {
        gate.cancelPlan()
    }

    nonisolated func configure(_ configuration: Configuration) {
        configurationStore.set(configuration)
    }

    // MARK: GoalBrain 协议

    @discardableResult
    nonisolated func plan(input: GoalBrainInput,
                          completion: @escaping (GoalDecision?) -> Void) -> Bool {
        guard LocalBrainModel.isInstalled, gate.claim() else { return false }
        let configuration = configurationStore.get()
        let task = Task {
            let outcome = await self.plan(input: input, configuration: configuration)
            gate.release()
            await MainActor.run {
                completion(outcome.decision)
            }
        }
        gate.trackPlan(task)
        return true
    }

    /// 本地决策脑生成短聊天 JSON；模型未就绪、生成失败或格式非法时，调用方走 Quips。
    @discardableResult
    nonisolated func requestSpeech(intent: SpeechIntent, world: WorldState, brain: BrainState,
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
    nonisolated func requestSpeech(intent: SpeechIntent, world: WorldState, brain: BrainState,
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
            let reply = await self.speak(input: input, configuration: configuration)
            await MainActor.run {
                completion(reply)
            }
        }
        return true
    }

    /// 设置窗使用的真实本地聊天测试。它复用生产聊天 JSON 管线、独立聊天前缀
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
        let world = WorldState(
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
            error: reply == nil ? "本地模型未返回合法聊天 JSON" : nil)
    }

    // MARK: 决策

    private struct PlanOutcome {
        var decision: GoalDecision?
    }

    private struct SpeechInput {
        var intent: SpeechIntent
        var world: WorldState
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
            let state = try await ensureReady(petID: input.petID, personality: input.personality,
                                              profile: profile)
            guard let tokenizer = brainTokenizer else { throw BrainError.modelMissing }
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
                let (cache, dynamicInput, fullPrefill) = try BrainCacheManager.decisionInput(
                    state: state, tokenizer: tokenizer, dynamicText: dynamic)
                output = try await BrainCacheManager.generateText(
                    container: container!, cache: cache, input: dynamicInput, sampling: sampling)
                if fullPrefill {
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
            let state = try await ensureReady(
                petID: input.characterID, personality: input.personality,
                profile: profile, promptKind: promptKind,
                dialogue: input.dialogue, speechIntent: input.intent)
            guard let tokenizer = brainTokenizer else { throw BrainError.modelMissing }
            var reply: SpeechReply?
            var output = ""
            for attempt in 0...1 {
                let dynamic = BrainPrefixBuilder.chatMessage(
                    intent: input.intent, world: input.world, brain: input.brain,
                    personality: input.personality, userText: input.userText,
                    retryHint: attempt == 0 ? nil : BrainPrefixBuilder.chatRetryHint)
                let (cache, dynamicInput, _) = try BrainCacheManager.decisionInput(
                    state: state, tokenizer: tokenizer, dynamicText: dynamic)
                output = try await BrainCacheManager.generateText(
                    container: container!, cache: cache, input: dynamicInput,
                    sampling: configuration.chatSampling)
                reply = SpeechReply.parse(output)
                if let text = reply?.text, !Self.validSpeech(text) {
                    reply = nil
                }
                if reply != nil { break }
            }
            BrainDecisionLog.logSpeech(intent: input.intent, reply: reply,
                                       latency: Date().timeIntervalSince(t0),
                                       traceID: input.traceID, mode: "local")
            gate.release()
            return reply
        } catch {
            NSLog("MyPet LocalBrain: 聊天生成失败 %@", error.localizedDescription)
            BrainDecisionLog.logSpeech(intent: input.intent, reply: nil,
                                       latency: Date().timeIntervalSince(t0),
                                       traceID: input.traceID, mode: "local")
            gate.release()
            return nil
        }
    }

    /// 加载模型 + 构建/加载该角色/任务的前缀缓存。key 变化（人格/档案/模型）→ 重建。
    private func ensureReady(petID: String, personality: Personality,
                             profile: BrainProfile, promptKind: String = "goal",
                             dialogue: DialogueProfile? = nil,
                             speechIntent: SpeechIntent? = nil) async throws
        -> BrainCacheManager.PromptState {
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
        let keyText = key.composite
        promptStates.trim(capacity: profile.cache.memoryEntries)
        BrainCacheManager.pruneDiskCache(maxEntries: profile.cache.diskEntries)
        if let state = promptStates.value(for: keyText) { return state }

        if container == nil {
            NSLog("MyPet LocalBrain: 开始加载模型（首次会编译 Metal shader）…")
            let t0 = Date()
            LocalBrainModel.writeProcessorShim(into: modelDir)
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDir,
                using: #huggingFaceTokenizerLoader())
            brainTokenizer = try await AutoTokenizer.from(modelFolder: modelDir)
            NSLog("MyPet LocalBrain: 模型加载完成 %.1fs", Date().timeIntervalSince(t0))
        }

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
        let t0 = Date()
        let state = try await BrainCacheManager.makePromptCache(
            container: container!, tokenizer: brainTokenizer!, petID: petID,
            key: key, messages: messages, diskEntries: profile.cache.diskEntries)
        NSLog("MyPet LocalBrain: 前缀就绪 %@ · %d tok · %.1fs",
              key.hash8, state.prefixTokens.count, Date().timeIntervalSince(t0))
        promptStates.insert(state, for: keyText, capacity: profile.cache.memoryEntries)
        return state
    }

    private static func validSpeech(_ text: String) -> Bool {
        guard !text.contains("\n"), text.count <= 50 else { return false }
        for leaked in ["KNOWN_FACTS", "SPEECH_ACT", "CONSTRAINT", "系统", "示例"]
            where text.contains(leaked) { return false }
        return true
    }

    // MARK: 诊断

    /// 设置窗「缓存」行与托盘速览的统计快照。
    func snapshotStats() -> DecisionStats { stats }
}

/// 决策在飞门闩（锁守卫，nonisolated 可达）。调度时间由协调器统一管理。
/// actor 的可变存储属性不允许 nonisolated，故把这份同步语义收进独立小类。
private final class DispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var planPending = false
    private var planTask: Task<Void, Never>?

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !planPending else { return false }
        planPending = true
        return true
    }

    func release() {
        lock.lock()
        planPending = false
        planTask = nil
        lock.unlock()
    }

    func trackPlan(_ task: Task<Void, Never>) {
        lock.lock()
        planTask = task
        lock.unlock()
    }

    func cancelPlan() {
        lock.lock()
        let task = planTask
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
