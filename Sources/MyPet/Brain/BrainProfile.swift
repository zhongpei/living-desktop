import Foundation
import Crypto

// BrainProfile —— 本地大脑配置档案 v1（brain-local.md §7）。
//
// 两层叠加：代码兜底（本文件 defaults）→ 用户档（~/Library/.../MyPet/BrainProfile/
// brain-profile.local.json，只存差异键）。运行时本地决策采样可由 Settings 显式覆盖；
// 高阶教师脑使用 Settings.teacherBrain* 的 Goal 参数，不读取本地档案的语音采样。
// 合并规则：字典递归合并、数组整体替换；例外：rulesExtra /
// fewshotExtra 语义就是「追加」，内置之后追加（§7.2：用户案例天然生效优先）。
//
// cache key 第 9 项 = resolved 前缀内容 hash（§7.4）：只覆盖影响前缀的
// prompt/personality 段 —— 只改采样不重建缓存。
//
// goal 词表不在档案里（硬边界，§7.2）；本档案不落盘任何用户输入，只读。

struct BrainProfile: Equatable {

    struct Sampling: Equatable, Codable, Sendable {
        var temperature: Double = 0.0
        var topP: Double = 1.0
        var topK: Int = 0
        var maxTokens: Int = 160
        var seed: Int? = 42

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case topK = "top_k"
            case maxTokens = "max_tokens"
            case seed
        }

        /// 档案覆盖：只改用户写出的键（稀疏 overlay，缺键 = 保持现值）。
        mutating func merge(_ overlay: SamplingOverlay) {
            if let v = overlay.temperature { temperature = v }
            if let v = overlay.topP { topP = v }
            if let v = overlay.topK { topK = v }
            if let v = overlay.maxTokens { maxTokens = v }
            if let v = overlay.seed { seed = v }
        }
    }

    struct FewshotExample: Equatable, Codable {
        var input: String
        var output: String
    }

    struct PromptSection: Equatable {
        /// 覆盖内置 WORLD MODEL 段文本；nil = 用内置。
        var worldModel: String?
        /// 追加行为规则（不替换内置）。
        var rulesExtra: [String] = []
        /// 追加 Few-shot 案例（追加在内置之后，只能追加不能删改）。
        var fewshotExtra: [FewshotExample] = []
    }

    struct PersonalitySection: Equatable {
        /// 空 = 用宠物内置人设；非空覆盖。
        var description: String = ""
        /// 只覆盖出现的维度（0~1 夹紧）。
        var traitsOverride: [String: Double] = [:]
    }

    /// 本地决策脑的两类任务采样默认。高阶教师脑的 Goal 采样由 Settings 单独配置。
    struct SamplingSection: Equatable {
        var `default` = Sampling()
        /// 0.8B 实测稳定区间：一句话角色反应使用低温和短输出。
        var chat = Sampling(temperature: 0.3, topP: 0.8, topK: 20, maxTokens: 48, seed: nil)
    }

    struct CacheSection: Equatable {
        var memoryEntries = 6
        var diskEntries = 64
    }

    var prompt = PromptSection()
    var personality = PersonalitySection()
    var sampling = SamplingSection()
    var cache = CacheSection()

    // MARK: 代码兜底

    static let fallback = BrainProfile()

    // MARK: 用户档（只存差异键）

    static var localProfileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet", isDirectory: true)
            .appendingPathComponent("BrainProfile", isDirectory: true)
            .appendingPathComponent("brain-profile.local.json")
    }

    /// 读取用户档并叠加到兜底值上。文件缺席 / 解析失败 / 字段非法 → 静默忽略
    /// （§7.4：非法键忽略 + 提示，不拒载整个档案）。
    static func resolved(localURL: URL? = nil) -> BrainProfile {
        let url = localURL ?? localProfileURL
        guard let data = try? Data(contentsOf: url),
              let overlay = try? JSONDecoder().decode(OverlayFile.self, from: data) else {
            return .fallback
        }
        var profile = BrainProfile.fallback
        overlay.apply(to: &profile)
        return profile
    }

    /// 前缀内容的稳定 hash（cache key 第 9 项）：只含影响前缀的 prompt +
    /// personality 段（§7.4：改采样不动前缀、不重建）。
    var prefixHash: String {
        var traits = personality.traitsOverride.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
            .sorted().joined(separator: ",")
        if traits.isEmpty { traits = "-" }
        let canonical = [
            Self.profileHashVersion,
            prompt.worldModel ?? "-",
            prompt.rulesExtra.joined(separator: "\u{1}"),
            prompt.fewshotExtra.map { "\($0.input)\u{1}\($0.output)" }.joined(separator: "\u{2}"),
            personality.description.isEmpty ? "-" : personality.description,
            traits,
        ].joined(separator: "\u{3}")
        return Self.sha8(canonical)
    }

    private static let profileHashVersion = "bp-hash-v1"

    static func sha8(_ text: String) -> String {
        String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    // MARK: 用户档 JSON schema（稀疏：缺键 = 用下层值）

    struct OverlayFile: Codable {
        var schemaVersion: Int?
        var prompt: PromptOverlay?
        var personality: PersonalityOverlay?
        var sampling: SamplingSectionOverlay?
        var cache: CacheOverlay?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case prompt, personality, sampling, cache
        }

        func apply(to profile: inout BrainProfile) {
            if let prompt {
                if let wm = prompt.worldModel { profile.prompt.worldModel = wm }
                if let rules = prompt.rulesExtra { profile.prompt.rulesExtra = rules }
                if let fewshot = prompt.fewshotExtra { profile.prompt.fewshotExtra = fewshot }
            }
            if let p = personality {
                if let d = p.description { profile.personality.description = d }
                if let traits = p.traitsOverride {
                    for (k, v) in traits where PersonalityTraits.valid.contains(k) {
                        profile.personality.traitsOverride[k] = min(1, max(0, v))
                    }
                }
            }
            if let s = sampling {
                if let d = s.default { profile.sampling.default.merge(d) }
                if let chat = s.chat { profile.sampling.chat.merge(chat) }
            }
            if let cache {
                if let value = cache.memoryEntries { profile.cache.memoryEntries = max(0, value) }
                if let value = cache.diskEntries { profile.cache.diskEntries = max(0, value) }
            }
        }
    }

    struct PromptOverlay: Codable {
        var worldModel: String?
        var rulesExtra: [String]?
        var fewshotExtra: [FewshotExample]?

        enum CodingKeys: String, CodingKey {
            case worldModel = "world_model"
            case rulesExtra = "rules_extra"
            case fewshotExtra = "fewshot_extra"
        }
    }

    struct PersonalityOverlay: Codable {
        var description: String?
        var traitsOverride: [String: Double]?

        enum CodingKeys: String, CodingKey {
            case description
            case traitsOverride = "traits_override"
        }
    }

    struct SamplingSectionOverlay: Codable {
        var `default`: SamplingOverlay?
        var chat: SamplingOverlay?
    }

    struct CacheOverlay: Codable {
        var memoryEntries: Int?
        var diskEntries: Int?

        enum CodingKeys: String, CodingKey {
            case memoryEntries = "memory_entries"
            case diskEntries = "disk_entries"
        }
    }

    struct SamplingOverlay: Codable {
        var temperature: Double?
        var topP: Double?
        var topK: Int?
        var maxTokens: Int?
        var seed: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case topK = "top_k"
            case maxTokens = "max_tokens"
            case seed
        }
    }

    /// 人格维度覆盖应用到运行时 Personality（稳定人格维度，动力学参数不受档案影响）。
    func applyingTraits(to base: Personality) -> Personality {
        var p = base
        for (key, value) in personality.traitsOverride {
            switch key {
            case "social": p.social = value
            case "curiosity": p.curiosity = value
            case "playfulness": p.playfulness = value
            case "diligence": p.diligence = value
            case "empathy": p.empathy = value
            case "independence": p.independence = value
            case "teasing": p.teasing = value
            default: break
            }
        }
        return p
    }

    enum PersonalityTraits {
        static let valid: Set<String> = [
            "social", "curiosity", "playfulness", "diligence", "empathy", "independence", "teasing",
        ]
    }
}
