import Foundation
import MLX
import MLXNN
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers // #huggingFaceTokenizerLoader() 展开体引用 Tokenizers.AutoTokenizer

/// perform 闭包的 MLX 值逃生舱：MLX 的数组/cache 类型不声明 Sendable，
/// 但 LocalBrain actor 保证所有使用都串行。
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

// BrainCacheManager —— 静态前缀缓存（brain-local.md §5.3）。
//
// Qwen3.5 是 hybrid 架构：cache 里同时有注意力 KV（KVCacheSimple）与
// 线性注意力的 recurrent 状态（GatedDelta → MambaCache）。MambaCache 继承
// ArraysCache，没有 trim 实现（isTrimmable == false）——recurrent 状态是固定
// 尺寸聚合量，数学上无法回退，**「决策完 trim 回前缀边界」对 Qwen3.5 不成立**。
// 因此本实现的运行形态是：
//
//   master PromptState（每角色一份，只被 prefill，永不被动态 token 污染）
//     └── 每次决策 copy() 一份独立缓存 → 只 prefill 动态段后缀 → 生成 → 丢弃
//
// 拷贝语义已核实：KVCacheSimple.copy() / MambaCache.copy() 各建独立缓冲，
// 后续 update 只写自己的缓冲，master 恒为纯前缀状态 —— 每次决策的前缀状态
// 位级等于全量 prefill（G1 验收「缓存命中路径决策与全量 prefill 一致」由此构造保证）。
// 全量 KV 约 30MB/份（6 层全注意力 × 2 kv-heads × 256 head_dim × 前缀 token 数），
// 拷贝在首次前向时惰性求值，毫秒级。
//
// 持久化走钉死版本的 savePromptCache/loadPromptCache（.safetensors），元数据里
// 存 cache key 与前缀 token 数，加载时校验，key 不符即重建。

enum BrainCacheManager {

    // MARK: Cache Key（§5.3 八项 + §7.4 第 9 项档案 hash）

    struct Key: Equatable {
        var model: String
        var tokenizer: String
        var chatTemplate: String
        var brainPrompt: Int
        var actionSchema: Int
        var fewshot: Int
        var personality: String
        var adapter: String
        var profileHash: String
        var promptKind: String

        var composite: String {
            [model, tokenizer, chatTemplate, "brain-v\(brainPrompt)",
             "actions-v\(actionSchema)", "fewshot-v\(fewshot)",
             personality, "lora-\(adapter)", "profile-\(profileHash)",
             "prompt-\(promptKind)"].joined(separator: "/")
        }

        var hash8: String { BrainProfile.sha8(composite) }
    }

    static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet", isDirectory: true)
            .appendingPathComponent("BrainCaches", isDirectory: true)
    }

    /// <pet>_v<task-prompt-version>_<hash8>.safetensors（§5.3 目录布局）。
    static func fileURL(petID: String, key: Key) -> URL {
        cacheDirectory
            .appendingPathComponent("\(petID)_v\(key.brainPrompt)_\(key.hash8).safetensors")
    }

    /// 组装 cache key。tokenizer hash 取 chat_template.jinja 字节摘要；
    /// modelDir 缺该文件时用目录名（半装状态本就不会被 prefill）。
    static func makeKey(petID: String, personality: Personality,
                        profile: BrainProfile, modelDir: URL,
                        promptKind: String = "goal", promptVersion: Int? = nil,
                        contentHash: String = "-") -> Key {
        let templateURL = modelDir.appendingPathComponent("chat_template.jinja")
        let templateHash: String
        if let data = try? Data(contentsOf: templateURL) {
            templateHash = BrainProfile.sha8(
                String(data: data.prefix(64 * 1024), encoding: .utf8) ?? "-")
        } else {
            templateHash = "none"
        }
        // 人格值进 key：同一 pet 改了人格（或档案覆盖维度）→ 前缀内容变 → 重建。
        let personalityHash = BrainProfile.sha8(personality.promptSection)
        return Key(
            model: modelDir.lastPathComponent,
            tokenizer: templateHash,
            chatTemplate: "jinja",
            brainPrompt: promptVersion ?? BrainPrefixBuilder.brainPromptVersion,
            actionSchema: BrainPrefixBuilder.actionSchemaVersion,
            fewshot: BrainPrefixBuilder.fewshotVersion,
            personality: "\(petID)-\(personalityHash)",
            adapter: "none",
            profileHash: BrainProfile.sha8(profile.prefixHash + "/" + contentHash),
            promptKind: promptKind)
    }

    // MARK: PromptState 生命周期

    struct PromptState {
        let petID: String
        let key: Key
        let messages: [[String: String]]
        /// 前缀 token（决策时作为后缀拼接的前缀边界校验基准）。
        let prefixTokens: [Int]
        /// 已 prefill 的主缓存（只读共享；决策方 copy 后使用）。
        let cache: [any KVCache]
    }

    static let metadataKey = "mypet_cache_key"
    static let metadataTokens = "mypet_prefix_tokens"

    /// 构建并 prefill 静态前缀（G1 验收：≤10s）。冷缓存优先从磁盘加载。
    /// tokenizer 为 swift-transformers 版（applyChatTemplate 全量 API，
    /// 含 addGenerationPrompt——前缀拼接的前提，见 LocalBrain.swift 文件头）。
    static func makePromptCache(
        container: ModelContainer, tokenizer: any Tokenizers.Tokenizer,
        petID: String, key: Key, messages: [[String: String]], diskEntries: Int
    ) async throws -> PromptState {
        let prefixTokens = try tokenizer.applyChatTemplate(
            messages: sendableMessages(messages), chatTemplate: nil,
            addGenerationPrompt: false, truncation: false, maxLength: nil, tools: nil)
        guard !prefixTokens.isEmpty else {
            throw BrainCacheError.emptyPrefix
        }

        let fileURL = Self.fileURL(petID: petID, key: key)
        if diskEntries > 0,
           let (cache, tokens) = try? loadPromptCache(from: fileURL, key: key) {
            // 磁盘缓存只有状态没有 token id：前缀文本重新 tokenize（确定性），
            // 数量与落盘时对不上 = key 碰撞 / 版本异常 → 走 prefill 重建。
            let prefixTokens = try tokenizer.applyChatTemplate(
                messages: sendableMessages(messages), chatTemplate: nil,
                addGenerationPrompt: false, truncation: false, maxLength: nil, tools: nil)
            if prefixTokens.count == tokens {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: fileURL.path)
                NSLog("MyPet BrainCache: %@ 加载磁盘前缀缓存（%d tok）", petID, tokens)
                return PromptState(petID: petID, key: key, messages: messages,
                                   prefixTokens: prefixTokens, cache: cache)
            }
            NSLog("MyPet BrainCache: %@ 磁盘缓存 token 数不符（%d vs %d），重建",
                  petID, tokens, prefixTokens.count)
        }

        let cache = try await prefill(container: container, tokens: prefixTokens)
        NSLog("MyPet BrainCache: %@ 前缀 prefill %d tok", petID, prefixTokens.count)
        if diskEntries > 0 {
            savePromptCache(cache, to: fileURL, key: key, tokenCount: prefixTokens.count)
        }
        pruneDiskCache(maxEntries: diskEntries)
        return PromptState(petID: petID, key: key, messages: messages,
                           prefixTokens: prefixTokens, cache: cache)
    }

    /// [[String: String]] → swift-transformers 的 Message（[String: any Sendable]）。
    static func sendableMessages(_ messages: [[String: String]]) -> [[String: any Sendable]] {
        messages.map { $0.mapValues { $0 as any Sendable } }
    }

    /// 把前缀 token 跑进一份新缓存（等价于 generate 前的完整 prefill，但不产 token）。
    static func prefill(container: ModelContainer, tokens: [Int]) async throws -> [any KVCache] {
        let input = LMInput(text: .init(tokens: MLXArray(tokens)))
        let inputBox = UncheckedBox(value: input)
        let box = try await container.perform { ctx -> UncheckedBox<[any KVCache]> in
            // 与 MLXLMCommon.TokenIterator 的默认生成路径一致：长前缀按
            // prefillStepSize 分块，避免 hybrid scan 的分块边界造成微小漂移。
            let parameters = GenerateParameters(prefillStepSize: 512)
            let cache = try ctx.model.newCache(parameters: parameters)
            let result = try ctx.model.prepare(
                inputBox.value, cache: cache, state: nil,
                prefill: .init(stepSize: parameters.prefillStepSize))
            // MLXArray 不可跨 Sendable 边界：出闭包前必须求值（含缓存本体）。
            switch result {
            case .tokens(let text): MLX.eval(text.tokens)
            case .logits(let output): MLX.eval(output.logits)
            }
            for entry in cache {
                MLX.eval(entry.state)
            }
            return UncheckedBox(value: cache)
        }
        return box.value
    }

    // MARK: 持久化

    static func savePromptCache(_ cache: [any KVCache], to url: URL,
                                key: Key, tokenCount: Int) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try MLXLMCommon.savePromptCache(url: url, cache: cache, metadata: [
                metadataKey: key.composite,
                metadataTokens: "\(tokenCount)",
            ])
        } catch {
            NSLog("MyPet BrainCache: 缓存保存失败 %@（下次启动重新 prefill）", String(describing: error))
        }
    }

    /// 加载磁盘缓存并校验 key；不符 / 损坏返回 nil（调用方重建）。
    static func loadPromptCache(from url: URL, key: Key) throws -> ([any KVCache], Int)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (cache, metadata) = try MLXLMCommon.loadPromptCache(url: url)
        guard metadata[metadataKey] == key.composite,
              let tokens = Int(metadata[metadataTokens] ?? ""), tokens > 0 else { return nil }
        return (cache, tokens)
    }

    static func pruneDiskCache(maxEntries: Int, directory: URL = cacheDirectory) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        let caches = files.filter { $0.pathExtension == "safetensors" }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        for url in caches.dropFirst(max(0, maxEntries)) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: 决策路径

    /// 决策输入：master 拷贝 + 动态段后缀 token。前缀拼接校验失败（理论上面）
    /// 返回 nil cache + fullPrefill=true，调用方让 MLX 创建全新 cache——只损失
    /// 速度，不损正确性。显式传空数组不是全量 prefill：MLX 会把它当成一个
    /// 已存在但没有层的 cache，因此这里必须用 Optional 表示“无 cache”。
    static func decisionInput(state: PromptState, tokenizer: any Tokenizers.Tokenizer,
                              dynamicText: String) throws -> (cache: [any KVCache]?,
                                                              input: LMInput, fullPrefill: Bool) {
        let dynamicTokens = try tokenizer.applyChatTemplate(
            messages: sendableMessages(state.messages) + [["role": "user", "content": dynamicText]],
            chatTemplate: nil,
            addGenerationPrompt: true, truncation: false, maxLength: nil, tools: nil)
        let n = state.prefixTokens.count
        if dynamicTokens.count > n, Array(dynamicTokens[..<n]) == state.prefixTokens {
            let suffix = Array(dynamicTokens[n...])
            return (state.cache.map { $0.copy() },
                    LMInput(text: .init(tokens: MLXArray(suffix))), false)
        }
        return (nil, LMInput(text: .init(tokens: MLXArray(dynamicTokens))), true)
    }

    /// 一轮生成（档案采样：decision 默认 temp=0 确定性，maxTokens 封顶）。
    static func generateText(container: ModelContainer, cache: [any KVCache]?,
                             input: LMInput, sampling: BrainProfile.Sampling) async throws -> String {
        let parameters = GenerateParameters(
            maxTokens: sampling.maxTokens,
            temperature: Float(sampling.temperature),
            topP: Float(sampling.topP),
            topK: sampling.topK,
            seed: sampling.seed.map { UInt64($0) })
        let inputBox = UncheckedBox(value: input)
        let cacheBox = UncheckedBox(value: cache)
        return try await container.perform { ctx -> String in
            // MLXLMCommon.TokenIterator has no hook for the model state produced
            // by a detached prefill. Qwen3.5's VLM model consequently recomputes
            // the first continuation position from zero when it receives a
            // non-empty cache. This small adapter supplies the model's neutral
            // rope delta, so the model takes its cache offset branch. The
            // iterator, cache copy, and sampling path remain the normal MLX path.
            let model = CacheAwareLanguageModel(base: ctx.model)
            let iterator = try TokenIterator(
                input: inputBox.value, model: model, cache: cacheBox.value,
                parameters: parameters)
            let (stream, generationTask) = MLXLMCommon.generateTask(
                promptTokenCount: inputBox.value.text.tokens.size,
                modelConfiguration: ctx.configuration,
                tokenizer: ctx.tokenizer,
                iterator: iterator)
            return try await withTaskCancellationHandler(operation: {
                var text = ""
                for await item in stream {
                    if let chunk = item.chunk { text += chunk }
                }
                await generationTask.value
                try Task.checkCancellation()
                return text
            }, onCancel: {
                generationTask.cancel()
            })
        }
    }
}

/// Keeps Qwen3.5 continuation positions anchored to the copied prefix cache.
/// The dependency's public TokenIterator deliberately owns its state, so the
/// correction lives at the LanguageModel seam instead of mutating MLX cache
/// internals or trimming a hybrid cache.
private final class CacheAwareLanguageModel: Module, LanguageModel {
    private static let ropeDeltasKey = LMOutput.Key<MLXArray>("qwen35.ropeDeltas")

    private let base: any LanguageModel

    init(base: any LanguageModel) {
        self.base = base
        super.init()
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        base.sanitize(weights: weights)
    }

    func sanitize(weights: [String: MLXArray], metadata: [String: String]) -> [String: MLXArray] {
        base.sanitize(weights: weights, metadata: metadata)
    }

    func prepare(
        _ input: LMInput,
        cache: [KVCache],
        state: LMOutput.State?,
        prefill: PrefillParameters
    ) throws -> PrepareResult {
        let state = if state == nil, Self.hasExistingCache(cache) {
            Self.continuationState()
        } else {
            state
        }
        return try base.prepare(input, cache: cache, state: state, prefill: prefill)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?)
        -> LMOutput
    {
        let state = if state == nil, let cache, Self.hasExistingCache(cache) {
            Self.continuationState()
        } else {
            state
        }
        return base(input, cache: cache, state: state)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        base(inputs, cache: cache)
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        try base.newCache(parameters: parameters)
    }

    private static func hasExistingCache(_ cache: [KVCache]) -> Bool {
        cache.contains { $0.offset > 0 }
    }

    private static func continuationState() -> LMOutput.State {
        var state = LMOutput.State()
        // Qwen3.5 text-only prompts have a zero multimodal rope delta. The
        // non-nil value selects the cache-offset branch in the VLM model.
        state[ropeDeltasKey] = MLXArray(0).asType(.int32)
        return state
    }
}

enum BrainCacheError: LocalizedError {
    case emptyPrefix

    var errorDescription: String? {
        switch self {
        case .emptyPrefix: return "静态前缀 tokenize 结果为空"
        }
    }
}
