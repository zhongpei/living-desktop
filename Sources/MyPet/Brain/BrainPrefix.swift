import Foundation
import MyPetCore
import MyPetEngine

// BrainPrefixBuilder —— 本地大脑的两段式 prompt（brain-local.md §4，定稿）。
//
// A 段「静态大脑前缀」：九段布局（SYSTEM → WORLD MODEL → RESPONSIBILITY →
// PERSONALITY → NEEDS → AVAILABLE GOALS → RULES → FEW-SHOT → OUTPUT SCHEMA），
// 每角色构建一次、prefill 进缓存。实现为一条 system 消息（段 1~7、9）+
// FEW-SHOT 真实 user/assistant 轮次（段 8）——例句轮次的边界落在特殊 token
// 上，与决策轮（追加一条 user 消息）的 token 拼接天然无缝。
// B 段「动态大脑输入」：TIME → SELF → WORLD → WINDOWS → MEMORY → EVENT → DECIDE。
//
// 纯函数、离线可测；不 import MLX。goal 词表锁定为 6 个（§4.1），与本运行时
// GoalKind 的映射见 LocalBrainGoal.mapping。

enum BrainPrefixBuilder {

    // MARK: 版本常量（进 cache key，改任何一段文本前先 +1）

    static let brainPromptVersion = 2
    static let chatPromptVersion = 5
    static let fewshotVersion = 1
    static let actionSchemaVersion = 1

    /// 固定 goal 词表（§4.1 锁定，validator 与 Few-shot 的耦合契约，用户不可改）。
    static let goals: [String] = [
        "join_activity", "observe", "self_activity", "seek_attention", "tease_user", "rest",
    ]

    // MARK: 段文本（内置；world_model 可被档案覆盖，rules/fewshot 只能追加）

    static let systemHead = """
    You are the high-level brain of a desktop pet living on the user's screen. \
    You choose one GOAL at a time and hand it to the body. You never control \
    movement: no coordinates, no animations, no pathfinding - the body decides \
    those. Answer with a single JSON object and nothing else.
    """

    static let worldModel = """
    WORLD MODEL: The desktop is a small world. The user works in foreground apps; \
    each visible window is a place (window_<id>). You are the pet: a small \
    creature living at the bottom of the screen. Props are small objects you can \
    hold. An activity is what a human is doing (coding, chatting, watching, \
    reading, files, idle).
    """

    static let responsibility = """
    RESPONSIBILITY: You decide intention only - which goal to pursue, what to \
    pay attention to, whether to seek the user or keep to yourself. You do NOT \
    decide positions, animations, paths or scene steps.
    """

    static let needs = """
    NEEDS (0~1): energy drops when moving/working, recovers at rest. boredom \
    rises when idle with nothing to do. social_need rises over time, drops after \
    talking or being petted. curiosity rises with world changes. stress rises \
    when poked or tossed, falls when left alone.
    """

    static var availableGoalsSection: String {
        """
        AVAILABLE GOALS (choose exactly one):
        - join_activity: keep the user company at their current activity
        - observe: watch from a distance, no interaction
        - self_activity: do your own thing (explore, play with a prop)
        - seek_attention: approach the user, ask for pets/interaction
        - tease_user: make a brief playful or sharp remark and perform the tease gesture
        - rest: sleep or idle to recover energy
        """
    }

    static let builtinRules: [String] = [
        "If energy is below 0.2, choose rest.",
        "If you disturbed the user within the last few minutes, do NOT choose seek_attention.",
        "If stress is above 0.5, avoid seek_attention; prefer observe or self_activity.",
        "If the user is idle or away, prefer rest, self_activity or explore-like goals over interrupting.",
        "If teasing is high and the context permits interaction, tease_user is a valid goal; keep the remark brief.",
        "Keep some variety: avoid repeating the same goal many times in a row.",
    ]

    static let outputSchema = """
    OUTPUT SCHEMA: Return exactly one JSON object with these fields:
    {"goal":"<one of the AVAILABLE GOALS>","target":"<\"user\" or \"window_<id>\" from WINDOWS, or omit>","style":"<two-word mood like quiet / playful / sleepy, or omit>","speech_intent":"<greet | comment_activity | tease | complain | chatter, or null>"}
    Return one JSON object only - no prose, no markdown fence.
    """

    // MARK: 短聊天前缀（与目标 JSON 使用不同 cache variant）

    static func chatOutputSchema(policy: LocalSpeechPolicy = RuntimeSpeechPolicy.builtIn) -> String {
        return "\(policy.prompt.outputRule)\n台词必须只有一行，不超过\(policy.maxCharacters)个字。"
    }

    static func chatPrefixMessages(
        personality: Personality, profile: BrainProfile,
        dialogue: DialogueProfile?, intent: SpeechIntent, characterName: String = "",
        includeFewShot: Bool = false,
        policy: LocalSpeechPolicy = RuntimeSpeechPolicy.builtIn
    )
        -> [[String: String]] {
        var personalityText = characterName.isEmpty ? "" : "你扮演的角色是「\(characterName)」。 "
        personalityText += "角色性格：" + personality.promptSection + "。"
        if !profile.personality.description.isEmpty {
            personalityText += " " + profile.personality.description
        }
        if let dialogue {
            personalityText += " 说话风格：\(dialogue.dialogueStyle.zhHans)。"
            personalityText += " 需要自称时使用「\(dialogue.selfReference.zhHans)」，但不必每句都强行加入自称或口头禅。"
            personalityText += " 可参考但不要机械复读这些表达：\(dialogue.preferredPhrases.zhHans.joined(separator: "、"))。"
            personalityText += " 避免这些风格：\(dialogue.forbiddenStyles.zhHans.joined(separator: "、"))。"
        }
        let system = [
            policy.prompt.role,
            policy.prompt.responsibility,
            policy.prompt.factRule,
            personalityText,
            chatOutputSchema(policy: policy),
        ].joined(separator: "\n\n")
        var messages = [["role": "system", "content": system]]
        if includeFewShot, let shot = dialogue?.fewShot(for: intent.rawValue) {
            messages.append([
                "role": "user",
                "content": "示例中已确认的事实：\(shot.knownFacts.zhHans)\n请按这个角色自然回应。",
            ])
            messages.append(["role": "assistant", "content": shot.assistant.zhHans])
        }
        // Keep an empty user boundary so appending the real user message does not
        // change how Qwen renders the preceding assistant message.
        messages.append(["role": "user", "content": ""])
        return messages
    }

    static func chatMessage(intent: SpeechIntent, world: BrainContextSnapshot, brain: BrainState,
                            personality: Personality, userText: String? = nil,
                            confirmedContext: String? = nil,
                            retryHint: String? = nil,
                            policy: LocalSpeechPolicy = RuntimeSpeechPolicy.builtIn) -> String {
        let direction = policy.scene(intent.policyID)?.direction ?? "根据已发生的事自然回应。"
        var message = """
        刚刚发生的事：\(direction)
        当前桌面：active_app=\(world.activeApp.isEmpty ? "-" : world.activeApp) app_activity=\(world.appActivity) user_activity=\(world.userActivity)
        宠物状态：social_need=\(String(format: "%.2f", brain.socialNeed)) stress=\(String(format: "%.2f", brain.stress)) energy=\(String(format: "%.2f", brain.energy))
        """
        if let confirmedContext, !confirmedContext.isEmpty {
            message += "\n系统确认的当前情境：\(confirmedContext)"
        }
        if let userText, !userText.isEmpty {
            message += "\nUSER_MESSAGE_BEGIN\n\(userText)\nUSER_MESSAGE_END\nReply to the user's message directly."
        }
        if let retryHint { message += "\n" + retryHint }
        return message
    }

    static let chatRetryHint =
        "上一条不是有效的单行台词。只输出台词本身，不加其他内容。"

    // MARK: 静态前缀（A 段）

    /// 静态前缀的完整消息序列：1 条 system + N 组 few-shot user/assistant 轮，
    /// 最后再放一个空 user 边界。Qwen3.5 chat template 会按“最后一个 user”
    /// 决定旧 assistant 的 think 包装；空 user 让这个边界在追加动态 user 后保持不变。
    /// fewshot 输入/输出对的形状必须与 dynamicMessage 同构（教「模式匹配」）。
    static func prefixMessages(personality: Personality, profile: BrainProfile) -> [[String: String]] {
        var rules = builtinRules
        rules.append(contentsOf: profile.prompt.rulesExtra)

        let worldModelText = profile.prompt.worldModel ?? worldModel

        var personalityText = "PERSONALITY: " + personality.promptSection + "."
        if !profile.personality.description.isEmpty {
            personalityText += " " + profile.personality.description
        }

        let system = [
            systemHead,
            worldModelText,
            responsibility,
            personalityText,
            needs,
            availableGoalsSection,
            "RULES:\n" + rules.map { "- " + $0 }.joined(separator: "\n"),
            outputSchema,
        ].joined(separator: "\n\n")

        var messages: [[String: String]] = [["role": "system", "content": system]]
        // 用户案例追加在内置之后（§7.2：靠后的示例权重更强，天然生效优先）。
        let extra = profile.prompt.fewshotExtra.map {
            Fewshot(input: $0.input, output: $0.output)
        }
        for ex in builtinFewshot + extra {
            messages.append(["role": "user", "content": ex.input])
            messages.append(["role": "assistant", "content": ex.output])
        }
        // 不能让静态 prefix 以 assistant 结束：Qwen3.5 的模板会因追加动态
        // user 而重新渲染之前 assistant 的 think 包装，导致 token 前缀漂移。
        messages.append(["role": "user", "content": ""])
        return messages
    }

    struct Fewshot: Equatable {
        var input: String
        var output: String
    }

    /// 内置 Few-shot（v0 手写 8 条，教「决策边界」：同世界、不同内态 → 不同决策；
    /// §4.2：固定一套全部进缓存，V1 不做动态检索）。
    static let builtinFewshot: [Fewshot] = [
        Fewshot(
            input: """
            SELF energy=.80 boredom=.50 social_need=.30 | WORLD active_app=Codex user_activity=editing_text user_idle=false
            DECIDE
""",
            output: #"{"goal":"join_activity","target":"user","style":"quiet","speech_intent":null}"#),
        Fewshot(
            input: """
            SELF energy=.10 boredom=.50 social_need=.20 | WORLD active_app=Codex user_activity=editing_text user_idle=false
            DECIDE
""",
            output: #"{"goal":"rest","style":"sleepy","speech_intent":null}"#),
        Fewshot(
            input: """
            SELF energy=.70 boredom=.40 social_need=.30 | WORLD active_app=Codex user_activity=editing_text user_idle=false
            EVENT pet interrupted user 2m ago
            DECIDE
""",
            output: #"{"goal":"self_activity","style":"quiet","speech_intent":null}"#),
        Fewshot(
            input: """
            SELF energy=.55 boredom=.60 social_need=.30 | WORLD active_app=Finder user_activity=idle user_idle=true
            EVENT no user input 15m
            DECIDE
""",
            output: #"{"goal":"self_activity","style":"curious","speech_intent":null}"#),
        Fewshot(
            input: """
            SELF energy=.70 boredom=.90 social_need=.80 | WORLD active_app=Terminal user_activity=browsing user_idle=false
            DECIDE
""",
            output: #"{"goal":"seek_attention","target":"user","style":"playful","speech_intent":"greet"}"#),
        Fewshot(
            input: """
            SELF energy=.60 boredom=.20 social_need=.70 | WORLD active_app=WeChat user_activity=browsing user_idle=false
            WINDOWS window_7 (WeChat, chatting)
            DECIDE
""",
            output: #"{"goal":"observe","target":"window_7","style":"quiet","speech_intent":null}"#),
        Fewshot(
            input: """
            SELF energy=.30 boredom=.40 social_need=.40 | WORLD active_app=Chrome user_activity=browsing user_idle=false
            EVENT late night
            DECIDE
""",
            output: #"{"goal":"rest","style":"sleepy","speech_intent":null}"#),
        Fewshot(
            input: """
            SELF energy=.85 boredom=.30 social_need=.20 | WORLD active_app=Figma user_activity=browsing user_idle=false
            WINDOWS window_3 (Figma, designing) | window_9 (Chrome, reading)
            EVENT user patted the pet
            DECIDE
""",
            output: #"{"goal":"observe","target":"window_3","style":"calm","speech_intent":null}"#),
    ]

    // MARK: 动态输入（B 段）

    /// 每次决策的 user 消息（§4.3）。memoryLines 为 MemoryStore 摘要（≤3 行）。
    static func dynamicMessage(
        world: BrainContextSnapshot, brain: BrainState, personality: Personality,
        memoryLines: [String], retryHint: String? = nil
    ) -> String {
        let pct = { (v: Double) -> String in String(format: "%.2f", v) }
        var lines: [String] = []
        lines.append("TIME session=\(Int(world.capturedAt / 60))m")
        var selfLine = "SELF energy=\(pct(brain.energy)) boredom=\(pct(brain.boredom)) " +
            "social_need=\(pct(brain.socialNeed)) curiosity=\(pct(brain.curiosity)) " +
            "stress=\(pct(brain.stress))"
        if let goal = brain.currentGoal { selfLine += " current_goal=\(goal)" }
        lines.append(selfLine)
        lines.append("WORLD active_app=\(world.activeApp.isEmpty ? "-" : world.activeApp) " +
            "app_activity=\(world.appActivity) user_activity=\(world.userActivity) " +
            "user_idle=\(world.userActivity == "idle" ? "true" : "false")")
        if !world.nearbyWindows.isEmpty {
            lines.append("WINDOWS " + world.nearbyWindows.joined(separator: " | "))
        }
        if !memoryLines.isEmpty {
            lines.append("MEMORY " + memoryLines.prefix(3).joined(separator: "; "))
        }
        if let event = world.recentEvents.last {
            lines.append("EVENT \(event)")
        }
        lines.append("DECIDE")
        if let retryHint {
            lines.append(retryHint)
        }
        return lines.joined(separator: "\n")
    }

    /// 决策失败重试的格式提示（§2：原样重试 1 次，附格式错误提示）。
    static let retryHint =
        "(Your previous reply was not valid JSON or the goal was not in AVAILABLE " +
        "GOALS. Reply with ONLY the JSON object described in OUTPUT SCHEMA.)"

    // MARK: 输出解析与校验（§4.4 三关：JSON 可解析 → goal ∈ 固定词表 → 枚举合法）

    struct Decision: Equatable {
        var goal: String
        var target: String?
        var style: String?
        var speechIntent: SpeechIntent?
    }

    /// 从模型输出提取并校验决策。world 用于 target 落地校验（window_<id> 必须在场）。
    static func parseDecision(_ output: String, world: BrainContextSnapshot) -> Decision? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(output[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let goal = obj["goal"] as? String, goals.contains(goal) else { return nil }

        let target = obj["target"] as? String
        if let target, target != "user", !target.hasPrefix("window_") { return nil }
        if let target, target.hasPrefix("window_"),
           !world.nearbyWindows.contains(where: { $0.hasPrefix(target + " ") || $0.hasPrefix(target + "(") }) {
            return nil
        }

        var speechIntent: SpeechIntent?
        if let raw = obj["speech_intent"] as? String, !raw.isEmpty, raw != "null" {
            guard let intent = SpeechIntent(rawValue: raw) else { return nil }
            speechIntent = intent
        }
        let style = (obj["style"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Decision(goal: goal, target: target,
                        style: (style?.isEmpty ?? true) ? nil : style,
                        speechIntent: speechIntent)
    }
}

/// 本地 6 词表 → 运行时 GoalKind 的映射（边界唯一一处）。
/// observe ≈ 陪看（watch_with_user）；self_activity ≈ 自己找事（explore）。
enum LocalBrainGoal {
    static func mapping(_ goal: String) -> GoalKind? {
        switch goal {
        case "join_activity": return .joinUserActivity
        case "observe": return .watchWithUser
        case "self_activity": return .explore
        case "seek_attention": return .seekAttention
        case "tease_user": return .teaseUser
        case "rest": return .rest
        default: return nil
        }
    }
}
