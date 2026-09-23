import Foundation

public enum LocalSpeechSceneID: String, Codable, CaseIterable, Sendable {
    case greet
    case commentActivity = "comment_activity"
    case tease
    case complain
    case chatter
}

public struct LocalSpeechPrompt: Codable, Equatable, Sendable {
    public var role: String
    public var responsibility: String
    public var factRule: String
    public var outputRule: String

    private enum CodingKeys: String, CodingKey {
        case role, responsibility, factRule = "fact_rule", outputRule = "output_rule"
    }
}

public struct LocalSpeechScene: Codable, Equatable, Sendable {
    public var id: LocalSpeechSceneID
    public var direction: String
    public var temperatureOffset: Double

    private enum CodingKeys: String, CodingKey {
        case id, direction, temperatureOffset = "temperature_offset"
    }
}

public struct LocalSpeechPolicy: Codable, Equatable, Sendable {
    public var schema: String
    public var maxCharacters: Int
    public var retryCount: Int
    public var blockedPhrases: [String]
    public var leakMarkers: [String]
    public var prompt: LocalSpeechPrompt
    public var scenes: [LocalSpeechScene]

    private enum CodingKeys: String, CodingKey {
        case schema, maxCharacters = "max_characters", retryCount = "retry_count"
        case blockedPhrases = "blocked_phrases", leakMarkers = "leak_markers", prompt, scenes
    }

    public func scene(_ id: LocalSpeechSceneID) -> LocalSpeechScene? {
        scenes.first { $0.id == id }
    }

    public var configurationErrors: [String] {
        var errors: [String] = []
        if schema != "mypet.local-speech.v1" { errors.append("schema") }
        if !(1...80).contains(maxCharacters) { errors.append("max_characters") }
        if !(0...1).contains(retryCount) { errors.append("retry_count") }
        if prompt.role.isEmpty || prompt.responsibility.isEmpty || prompt.factRule.isEmpty ||
            prompt.outputRule.isEmpty { errors.append("prompt") }
        if Set(scenes.map(\.id)) != Set(LocalSpeechSceneID.allCases) ||
            Set(scenes.map(\.id)).count != scenes.count { errors.append("scene_coverage") }
        if scenes.contains(where: { $0.direction.isEmpty || !$0.temperatureOffset.isFinite ||
            !(-1...1).contains($0.temperatureOffset) }) { errors.append("scene_values") }
        return errors.sorted()
    }

    public func accepts(_ raw: String) -> Bool {
        rejectionReasons(raw).isEmpty
    }

    public func rejectionReasons(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var reasons: [String] = []
        if text.isEmpty { reasons.append("empty") }
        if text.contains("\n") { reasons.append("multiple_lines") }
        if text.count > maxCharacters { reasons.append("too_long:\(text.count)>\(maxCharacters)") }
        reasons += blockedPhrases.filter(text.contains).map { "blocked:\($0)" }
        reasons += leakMarkers.filter(text.contains).map { "leaked:\($0)" }
        return reasons
    }

    public static let fallback = LocalSpeechPolicy(
        schema: "mypet.local-speech.v1", maxCharacters: 40, retryCount: 1,
        blockedPhrases: ["杀了你", "杀死你", "弄死你", "去死", "滚开", "废物",
                         "删掉", "删除", "删干净", "关进电脑", "已故", "废人", "收拾你",
                         "我刚才在代码", "我刚才在编辑代码", "我这边正在处理代码",
                         "触发了你的操作"],
        leakMarkers: ["KNOWN_FACTS", "SPEECH_ACT", "CONSTRAINT", "系统示例", "Prompt"],
        prompt: LocalSpeechPrompt(
            role: "你为生活在用户屏幕上的桌面宠物写一句简短台词。",
            responsibility: "动作大脑已经决定这次说话的场景；你不选择动作、目标、坐标或移动。",
            factRule: "只根据已经发生的事自然回应。分清用户和宠物，不复述事件，不虚构原因和结果，不声称替用户操作代码、文件、键盘或电脑，不威胁用户。",
            outputRule: "只输出台词本身，不加解释、标签、JSON、Markdown 或引号。"),
        scenes: [
            LocalSpeechScene(id: .greet, direction: "用户刚刚召唤宠物来到身边。以宠物身份自然回应用户，不要说成宠物召唤用户。", temperatureOffset: 0.05),
            LocalSpeechScene(id: .commentActivity, direction: "用户正在专心工作。作为一旁陪伴的宠物简短评论，不要自称正在写、改或完成代码。", temperatureOffset: -0.1),
            LocalSpeechScene(id: .tease, direction: "用户刚刚逗了宠物一下。以宠物身份开个有角色味的玩笑，不要说成宠物先逗用户。", temperatureOffset: 0.1),
            LocalSpeechScene(id: .complain, direction: "用户刚刚连续触碰或打扰了宠物。以宠物身份直接表达一点不满，不要说开心，也不要安慰或指挥用户。", temperatureOffset: 0),
            LocalSpeechScene(id: .chatter, direction: "现在没有紧急事件。以陪伴用户的宠物身份随口说一句角色短话，不要假装正在编程或操作文件。", temperatureOffset: 0.05),
        ])
}

/// User-owned differences from the checked-in speech policy. Empty values inherit
/// the shipped prompt, so future default fixes continue to reach customized setups.
public struct LocalSpeechPromptOverrides: Codable, Equatable, Sendable {
    public var role: String?
    public var responsibility: String?
    public var factRule: String?
    public var outputRule: String?
    public var sceneDirections: [String: String]

    public init(
        role: String? = nil,
        responsibility: String? = nil,
        factRule: String? = nil,
        outputRule: String? = nil,
        sceneDirections: [String: String] = [:]
    ) {
        self.role = role
        self.responsibility = responsibility
        self.factRule = factRule
        self.outputRule = outputRule
        self.sceneDirections = sceneDirections
    }

    public var isEmpty: Bool {
        [role, responsibility, factRule, outputRule].allSatisfy { Self.cleaned($0) == nil } &&
            sceneDirections.values.allSatisfy { Self.cleaned($0) == nil }
    }

    public func applying(to base: LocalSpeechPolicy) -> LocalSpeechPolicy {
        var result = base
        result.prompt.role = Self.cleaned(role) ?? base.prompt.role
        result.prompt.responsibility = Self.cleaned(responsibility) ?? base.prompt.responsibility
        result.prompt.factRule = Self.cleaned(factRule) ?? base.prompt.factRule
        result.prompt.outputRule = Self.cleaned(outputRule) ?? base.prompt.outputRule
        result.scenes = base.scenes.map { scene in
            var value = scene
            value.direction = Self.cleaned(sceneDirections[scene.id.rawValue]) ?? scene.direction
            return value
        }
        return result
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
