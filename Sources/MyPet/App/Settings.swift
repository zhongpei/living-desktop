import Foundation
import ServiceManagement
import MyPetCore

struct StorySettings: Codable, Equatable {
    var enabled = true
    var repeatEpisodes = true
    var intervalTicks: Int64 = 0
    var maxDurationTicks: Int64 = 1_200
    var interruptOnForeground = true
    var interruptOnContent = true
    var relationshipEffectsEnabled = true

    init(
        enabled: Bool = true,
        repeatEpisodes: Bool = true,
        intervalTicks: Int64 = 0,
        maxDurationTicks: Int64 = 1_200,
        interruptOnForeground: Bool = true,
        interruptOnContent: Bool = true,
        relationshipEffectsEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.repeatEpisodes = repeatEpisodes
        self.intervalTicks = max(0, intervalTicks)
        self.maxDurationTicks = max(1, maxDurationTicks)
        self.interruptOnForeground = interruptOnForeground
        self.interruptOnContent = interruptOnContent
        self.relationshipEffectsEnabled = relationshipEffectsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, repeatEpisodes, intervalTicks, maxDurationTicks
        case interruptOnForeground, interruptOnContent, relationshipEffectsEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            repeatEpisodes: try values.decodeIfPresent(Bool.self, forKey: .repeatEpisodes) ?? true,
            intervalTicks: try values.decodeIfPresent(Int64.self, forKey: .intervalTicks) ?? 0,
            maxDurationTicks: try values.decodeIfPresent(Int64.self, forKey: .maxDurationTicks) ?? 1_200,
            interruptOnForeground: try values.decodeIfPresent(Bool.self, forKey: .interruptOnForeground) ?? true,
            interruptOnContent: try values.decodeIfPresent(Bool.self, forKey: .interruptOnContent) ?? true,
            relationshipEffectsEnabled: try values.decodeIfPresent(
                Bool.self, forKey: .relationshipEffectsEnabled) ?? true)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(repeatEpisodes, forKey: .repeatEpisodes)
        try values.encode(intervalTicks, forKey: .intervalTicks)
        try values.encode(maxDurationTicks, forKey: .maxDurationTicks)
        try values.encode(interruptOnForeground, forKey: .interruptOnForeground)
        try values.encode(interruptOnContent, forKey: .interruptOnContent)
        try values.encode(relationshipEffectsEnabled, forKey: .relationshipEffectsEnabled)
    }

    var coreConfiguration: StoryDirectorConfiguration {
        StoryDirectorConfiguration(
            enabled: enabled,
            repeatEpisodes: repeatEpisodes,
            intervalTicks: intervalTicks,
            maxDurationTicks: maxDurationTicks,
            interruptOnForeground: interruptOnForeground,
            interruptOnContent: interruptOnContent,
            relationshipEffectsEnabled: relationshipEffectsEnabled)
    }
}

/// 用户设置，JSON 存 `~/Library/Application Support/MyPet/settings.json`。
///
/// game-v2：三档大脑配置——行动脑、本地决策脑、高阶教师脑——以及
/// 语音、道具/场景玩法和 OCR 感知开关。
/// 解码向后兼容：历史版本的设置键只读迁移，重新编码时只写当前命名。
struct Settings: Codable {

    /// 当前宠物（petpack 目录名）。空 = 用库里的第一只。
    var currentPet = ""
    /// 宠物显示高度（pt）。素材 cell 192×208 等比缩放。
    var displayHeight: CGFloat = 110
    /// 道具大小倍率（乘在每道具 scale 上；1.0 = 标准基准，Q 版默认已放大）。
    var propScale: Double = 1.0
    /// 允许跳上窗口栖息。
    var perchingEnabled = true
    /// 前台应用切换时飞过去看看。
    var foregroundFollow = true
    /// 拉扯窗口（需要辅助功能授权 —— 两级权限的第二级）。
    var windowPullEnabled = false
    /// 登录时启动。
    var launchAtLogin = false

    // ---- 大脑 ----

    /// 行动脑（Needle 3 本地模型）：行动边界上的具体动作决策。
    /// 关闭或缺模型时走 Autopilot（场景玩法）/ 随机脑。
    var actionBrainEnabled = true
    /// 行动脑自身的决策节奏与输出上限；Needle 3 当前只支持 max_new_tokens。
    var actionBrainMinInterval = 4.0
    var actionBrainMaxInterval = 10.0
    var actionBrainMaxTokens = 128
    /// 高阶教师脑总闸：本机 llama.cpp 的 Qwen VLM；可与本地决策脑并行。
    var teacherBrainEnabled = false
    /// 高阶教师脑端点（OpenAI 兼容，含 /v1）。默认本机/内网 llama.cpp。
    var teacherBrainBaseURL = "http://192.168.2.60:8001/v1"
    /// 高阶教师脑模型名（设置窗「探测模型」自动填充）。
    var teacherBrainModel = ""
    /// 高阶教师脑 API 密钥（本机 llama.cpp 通常留空）。
    var teacherBrainAPIKey = ""
    /// 高阶教师脑 Goal 决策采样；没有独立语音采样档。
    var teacherBrainTemperature = 0.8
    var teacherBrainTopP = 1.0
    var teacherBrainTopK = 0
    var teacherBrainMaxTokens = 220
    var teacherBrainSeed: Int?
    /// 服务端透传的思考等级；空 = server default。
    var teacherBrainReasoningEffort = ""

    /// 本地决策脑（端侧 MLX Qwen3.5 0.8B）总闸；可与高阶教师脑并行。
    var localBrainEnabled = false
    /// 本地决策脑目标 JSON 采样：低温、固定 seed，优先保证可解析和可复现。
    var localBrainGoalTemperature = 0.0
    var localBrainGoalTopP = 1.0
    var localBrainGoalTopK = 0
    var localBrainGoalMaxTokens = 160
    var localBrainGoalSeed: Int? = 42
    /// 本地决策脑聊天采样：与目标 JSON 分开，允许更自然的短句。
    var localBrainChatTemperature = 0.3
    var localBrainChatTopP = 0.8
    var localBrainChatTopK = 20
    var localBrainChatMaxTokens = 48
    var localBrainChatSeed: Int?

    // 历史字段只保留源码级兼容；落盘使用明确的 localBrainGoal* / localBrainChat* 键。
    // 这些 alias 不是新的领域命名。
    var localBrainTemperature: Double {
        get { localBrainGoalTemperature }
        set { localBrainGoalTemperature = newValue }
    }
    var localBrainTopP: Double {
        get { localBrainGoalTopP }
        set { localBrainGoalTopP = newValue }
    }
    var localBrainTopK: Int {
        get { localBrainGoalTopK }
        set { localBrainGoalTopK = newValue }
    }
    var localBrainMaxTokens: Int {
        get { localBrainGoalMaxTokens }
        set { localBrainGoalMaxTokens = newValue }
    }
    var localBrainSeed: Int? {
        get { localBrainGoalSeed }
        set { localBrainGoalSeed = newValue }
    }

    /// 本地/高阶决策共用一次快照和一次规划节奏，保证并行标签可对齐。
    var goalBrainMinInterval = 45.0
    var goalBrainMaxInterval = 90.0

    /// 说话总闸：本地决策脑或高阶教师脑可生成短聊天；失败时回退 Quips。
    var speechEnabled = true
    /// 三档大脑统一脑路日志（brain_trace.jsonl）。只保存在本机。
    var brainTraceEnabled = true

    // ---- 玩法 ----

    /// 场景玩法总闸（Action Recipe 目标-场景执行环）。关闭 = 旧的随机闲逛模式。
    var scenesEnabled = true
    /// 道具系统（场景配方里的拿放道具）。
    var propsEnabled = true

    // ---- 感知 ----

    /// AX 屏幕感知（聚焦上下文，决策时写入统一脑路日志）。默认关。
    var sensesEnabled = false
    /// OCR 感知（第二传感器；只对 profile 表里的应用截屏，微信等）。默认关。
    var ocrEnabled = false
    /// 外部输入插件总表；旧的 sensesEnabled/ocrEnabled 仍保留作为迁移兼容键。
    var inputPlugins = InputPluginCatalog()

    /// Effective runtime switch for a plugin. The two legacy permission keys
    /// remain valid for callers that construct Settings directly or still have
    /// an older settings file; the normal settings UI mirrors them into the
    /// new catalog as well.
    func isInputPluginEnabled(_ pluginID: String) -> Bool {
        inputPlugins.isEnabled(pluginID)
            || (pluginID == "accessibility" && sensesEnabled)
            || (pluginID == "ocr" && ocrEnabled)
    }

    var accessibilityInputEnabled: Bool {
        isInputPluginEnabled("accessibility")
    }

    var ocrInputEnabled: Bool {
        isInputPluginEnabled("ocr")
    }

    var anyInputPluginEnabled: Bool {
        sensesEnabled || ocrEnabled || inputPlugins.plugins.values.contains { $0.enabled }
    }

    // ---- 角色组与入退场 ----

    /// 当前桌面允许出现的角色组、角色和随机策略。
    /// 空的 allow-list 表示不额外限制，保证旧设置对新角色资源向后兼容。
    var castSelection = CastSelection()
    /// 剧情与关系独立于角色名单；关闭教师脑不影响这里的规则剧情。
    var storySettings = StorySettings()

    static func storageURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["MYPET_SETTINGS_PATH"] {
            precondition(path.hasPrefix("/"), "MYPET_SETTINGS_PATH must be an absolute path")
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet/settings.json")
    }

    static var url: URL {
        let result = storageURL()
        try? FileManager.default.createDirectory(
            at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        return result
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }

    mutating func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        // 非 .app 环境下（swift run）SMAppService 不可用，注册会抛错并静默忽略。
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("MyPet: 登录项设置失败 %@", error.localizedDescription)
        }
    }

    // MARK: 向后兼容

    private enum CodingKeys: String, CodingKey {
        case currentPet, displayHeight, propScale, perchingEnabled, foregroundFollow
        case windowPullEnabled, launchAtLogin
        case actionBrainEnabled, brainEnabled
        case actionBrainMinInterval, actionBrainMaxInterval, actionBrainMaxTokens
        case teacherBrainEnabled, slowBrainEnabled, teacherEnabled // legacy wire keys
        case teacherBrainBaseURL, teacherBrainModel, teacherBrainAPIKey
        case slowBrainBaseURL, slowBrainModel, slowBrainAPIKey // legacy wire keys
        case teacherBrainTemperature, teacherBrainTopP, teacherBrainTopK
        case teacherBrainMaxTokens, teacherBrainSeed, teacherBrainReasoningEffort
        case localBrainEnabled
        case localBrainGoalTemperature, localBrainGoalTopP, localBrainGoalTopK
        case localBrainGoalMaxTokens, localBrainGoalSeed
        case localBrainChatTemperature, localBrainChatTopP, localBrainChatTopK
        case localBrainChatMaxTokens, localBrainChatSeed
        case localBrainTemperature, localBrainTopP, localBrainTopK, localBrainMaxTokens, localBrainSeed // legacy wire keys
        case goalBrainMinInterval, goalBrainMaxInterval
        case speechEnabled, brainTraceEnabled
        case slowBrainLogEnabled, teacherLogEnabled // legacy wire keys
        case scenesEnabled, propsEnabled
        case sensesEnabled, ocrEnabled, inputPlugins
        case castSelection, storySettings
    }

    init() {
        // BrainProfile 是本地决策脑的低优先级默认层；设置文件或设置窗中的
        // localBrainGoal* / localBrainChat* 字段一旦存在，就覆盖这一层。教师脑采样始终走独立的
        // teacherBrain* 字段。
        let profile = BrainProfile.resolved()
        let goalSampling = profile.sampling.default
        let chatSampling = profile.sampling.chat
        localBrainGoalTemperature = goalSampling.temperature
        localBrainGoalTopP = goalSampling.topP
        localBrainGoalTopK = goalSampling.topK
        localBrainGoalMaxTokens = goalSampling.maxTokens
        localBrainGoalSeed = goalSampling.seed
        localBrainChatTemperature = chatSampling.temperature
        localBrainChatTopP = chatSampling.topP
        localBrainChatTopK = chatSampling.topK
        localBrainChatMaxTokens = chatSampling.maxTokens
        localBrainChatSeed = chatSampling.seed
    }

    /// 手写编码（合成版要求每个 CodingKey 都有存储属性，旧键 teacher* 不满足）。
    /// 旧键只出现在解码侧，落盘即迁移成新键。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(currentPet, forKey: .currentPet)
        try c.encode(displayHeight, forKey: .displayHeight)
        try c.encode(propScale, forKey: .propScale)
        try c.encode(perchingEnabled, forKey: .perchingEnabled)
        try c.encode(foregroundFollow, forKey: .foregroundFollow)
        try c.encode(windowPullEnabled, forKey: .windowPullEnabled)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(actionBrainEnabled, forKey: .actionBrainEnabled)
        try c.encode(actionBrainMinInterval, forKey: .actionBrainMinInterval)
        try c.encode(actionBrainMaxInterval, forKey: .actionBrainMaxInterval)
        try c.encode(actionBrainMaxTokens, forKey: .actionBrainMaxTokens)
        try c.encode(teacherBrainEnabled, forKey: .teacherBrainEnabled)
        try c.encode(teacherBrainBaseURL, forKey: .teacherBrainBaseURL)
        try c.encode(teacherBrainModel, forKey: .teacherBrainModel)
        try c.encode(teacherBrainAPIKey, forKey: .teacherBrainAPIKey)
        try c.encode(teacherBrainTemperature, forKey: .teacherBrainTemperature)
        try c.encode(teacherBrainTopP, forKey: .teacherBrainTopP)
        try c.encode(teacherBrainTopK, forKey: .teacherBrainTopK)
        try c.encode(teacherBrainMaxTokens, forKey: .teacherBrainMaxTokens)
        try c.encodeIfPresent(teacherBrainSeed, forKey: .teacherBrainSeed)
        try c.encode(teacherBrainReasoningEffort, forKey: .teacherBrainReasoningEffort)
        try c.encode(localBrainEnabled, forKey: .localBrainEnabled)
        try c.encode(localBrainGoalTemperature, forKey: .localBrainGoalTemperature)
        try c.encode(localBrainGoalTopP, forKey: .localBrainGoalTopP)
        try c.encode(localBrainGoalTopK, forKey: .localBrainGoalTopK)
        try c.encode(localBrainGoalMaxTokens, forKey: .localBrainGoalMaxTokens)
        try c.encodeIfPresent(localBrainGoalSeed, forKey: .localBrainGoalSeed)
        try c.encode(localBrainChatTemperature, forKey: .localBrainChatTemperature)
        try c.encode(localBrainChatTopP, forKey: .localBrainChatTopP)
        try c.encode(localBrainChatTopK, forKey: .localBrainChatTopK)
        try c.encode(localBrainChatMaxTokens, forKey: .localBrainChatMaxTokens)
        try c.encodeIfPresent(localBrainChatSeed, forKey: .localBrainChatSeed)
        try c.encode(goalBrainMinInterval, forKey: .goalBrainMinInterval)
        try c.encode(goalBrainMaxInterval, forKey: .goalBrainMaxInterval)
        try c.encode(speechEnabled, forKey: .speechEnabled)
        try c.encode(brainTraceEnabled, forKey: .brainTraceEnabled)
        try c.encode(scenesEnabled, forKey: .scenesEnabled)
        try c.encode(propsEnabled, forKey: .propsEnabled)
        try c.encode(sensesEnabled, forKey: .sensesEnabled)
        try c.encode(ocrEnabled, forKey: .ocrEnabled)
        try c.encode(inputPlugins, forKey: .inputPlugins)
        try c.encode(castSelection, forKey: .castSelection)
        try c.encode(storySettings, forKey: .storySettings)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let profile = BrainProfile.resolved()
        let goalSampling = profile.sampling.default
        let chatSampling = profile.sampling.chat
        currentPet = try c.decodeIfPresent(String.self, forKey: .currentPet) ?? ""
        displayHeight = try c.decodeIfPresent(CGFloat.self, forKey: .displayHeight) ?? 110
        propScale = try c.decodeIfPresent(Double.self, forKey: .propScale) ?? 1.0
        perchingEnabled = try c.decodeIfPresent(Bool.self, forKey: .perchingEnabled) ?? true
        foregroundFollow = try c.decodeIfPresent(Bool.self, forKey: .foregroundFollow) ?? true
        windowPullEnabled = try c.decodeIfPresent(Bool.self, forKey: .windowPullEnabled) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        actionBrainEnabled = try c.decodeIfPresent(Bool.self, forKey: .actionBrainEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .brainEnabled) ?? true
        actionBrainMinInterval = try c.decodeIfPresent(Double.self, forKey: .actionBrainMinInterval) ?? 4.0
        actionBrainMaxInterval = try c.decodeIfPresent(Double.self, forKey: .actionBrainMaxInterval) ?? 10.0
        actionBrainMaxTokens = try c.decodeIfPresent(Int.self, forKey: .actionBrainMaxTokens) ?? 128
        teacherBrainEnabled = try c.decodeIfPresent(Bool.self, forKey: .teacherBrainEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .slowBrainEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .teacherEnabled) ?? false
        teacherBrainBaseURL = try c.decodeIfPresent(String.self, forKey: .teacherBrainBaseURL)
            ?? c.decodeIfPresent(String.self, forKey: .slowBrainBaseURL)
            ?? "http://192.168.2.60:8001/v1"
        teacherBrainModel = try c.decodeIfPresent(String.self, forKey: .teacherBrainModel)
            ?? c.decodeIfPresent(String.self, forKey: .slowBrainModel) ?? ""
        teacherBrainAPIKey = try c.decodeIfPresent(String.self, forKey: .teacherBrainAPIKey)
            ?? c.decodeIfPresent(String.self, forKey: .slowBrainAPIKey) ?? ""
        teacherBrainTemperature = try c.decodeIfPresent(Double.self, forKey: .teacherBrainTemperature) ?? 0.8
        teacherBrainTopP = try c.decodeIfPresent(Double.self, forKey: .teacherBrainTopP) ?? 1.0
        teacherBrainTopK = try c.decodeIfPresent(Int.self, forKey: .teacherBrainTopK) ?? 0
        teacherBrainMaxTokens = try c.decodeIfPresent(Int.self, forKey: .teacherBrainMaxTokens) ?? 220
        teacherBrainSeed = try c.decodeIfPresent(Int.self, forKey: .teacherBrainSeed)
        teacherBrainReasoningEffort = try c.decodeIfPresent(String.self, forKey: .teacherBrainReasoningEffort) ?? ""
        localBrainEnabled = try c.decodeIfPresent(Bool.self, forKey: .localBrainEnabled) ?? false
        localBrainGoalTemperature = try c.decodeIfPresent(Double.self, forKey: .localBrainGoalTemperature)
            ?? c.decodeIfPresent(Double.self, forKey: .localBrainTemperature)
            ?? goalSampling.temperature
        localBrainGoalTopP = try c.decodeIfPresent(Double.self, forKey: .localBrainGoalTopP)
            ?? c.decodeIfPresent(Double.self, forKey: .localBrainTopP)
            ?? goalSampling.topP
        localBrainGoalTopK = try c.decodeIfPresent(Int.self, forKey: .localBrainGoalTopK)
            ?? c.decodeIfPresent(Int.self, forKey: .localBrainTopK)
            ?? goalSampling.topK
        localBrainGoalMaxTokens = try c.decodeIfPresent(Int.self, forKey: .localBrainGoalMaxTokens)
            ?? c.decodeIfPresent(Int.self, forKey: .localBrainMaxTokens)
            ?? goalSampling.maxTokens
        localBrainGoalSeed = try c.decodeIfPresent(Int.self, forKey: .localBrainGoalSeed)
            ?? c.decodeIfPresent(Int.self, forKey: .localBrainSeed)
            ?? goalSampling.seed
        localBrainChatTemperature = try c.decodeIfPresent(Double.self, forKey: .localBrainChatTemperature)
            ?? chatSampling.temperature
        localBrainChatTopP = try c.decodeIfPresent(Double.self, forKey: .localBrainChatTopP)
            ?? chatSampling.topP
        localBrainChatTopK = try c.decodeIfPresent(Int.self, forKey: .localBrainChatTopK)
            ?? chatSampling.topK
        localBrainChatMaxTokens = try c.decodeIfPresent(Int.self, forKey: .localBrainChatMaxTokens)
            ?? chatSampling.maxTokens
        localBrainChatSeed = try c.decodeIfPresent(Int.self, forKey: .localBrainChatSeed)
            ?? chatSampling.seed
        goalBrainMinInterval = try c.decodeIfPresent(Double.self, forKey: .goalBrainMinInterval) ?? 45.0
        goalBrainMaxInterval = try c.decodeIfPresent(Double.self, forKey: .goalBrainMaxInterval) ?? 90.0
        speechEnabled = try c.decodeIfPresent(Bool.self, forKey: .speechEnabled) ?? true
        brainTraceEnabled = try c.decodeIfPresent(Bool.self, forKey: .brainTraceEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .slowBrainLogEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .teacherLogEnabled) ?? true
        scenesEnabled = try c.decodeIfPresent(Bool.self, forKey: .scenesEnabled) ?? true
        propsEnabled = try c.decodeIfPresent(Bool.self, forKey: .propsEnabled) ?? true
        sensesEnabled = try c.decodeIfPresent(Bool.self, forKey: .sensesEnabled) ?? false
        ocrEnabled = try c.decodeIfPresent(Bool.self, forKey: .ocrEnabled) ?? false
        if let configured = try c.decodeIfPresent(InputPluginCatalog.self, forKey: .inputPlugins) {
            // Keep newly added built-in sources visible when an older settings
            // file already contains a partial catalog. Explicit entries win;
            // missing entries inherit the safe built-in defaults. The legacy
            // permission flags only fill a missing entry, so an explicit new
            // value is never silently overwritten.
            var merged = InputPluginCatalog.defaults()
            for (pluginID, config) in configured.plugins {
                merged.plugins[pluginID] = config
            }
            if configured.plugins["accessibility"] == nil {
                merged.setEnabled(sensesEnabled, for: "accessibility")
            }
            if configured.plugins["ocr"] == nil {
                merged.setEnabled(ocrEnabled, for: "ocr")
            }
            inputPlugins = merged
        } else {
            // 历史设置只有两个总开关，迁移到对应插件；其余新插件默认关闭。
            inputPlugins = InputPluginCatalog.defaults()
            inputPlugins.setEnabled(sensesEnabled, for: "accessibility")
            inputPlugins.setEnabled(ocrEnabled, for: "ocr")
        }
        castSelection = try c.decodeIfPresent(CastSelection.self, forKey: .castSelection)
            ?? CastSelection()
        storySettings = try c.decodeIfPresent(StorySettings.self, forKey: .storySettings)
            ?? StorySettings()
    }
}
