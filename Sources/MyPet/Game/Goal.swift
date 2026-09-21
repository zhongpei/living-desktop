import Foundation
import MyPetCore

// Goal —— 决策脑（LLM）或内置策略产出的高层意图。
//
// game.md 铁律：**决策脑永不输出微操**。它只回答「我想做什么」：
//   {"goal":"join_user_activity","target":"user","activity":"coding","style":"quiet_companion"}
// 「下一步具体干什么」是行动脑（Needle）+ 场景配方的事。

typealias GoalKind = SimulationGoalKind

extension SimulationGoalKind {
    /// 目标是否需要用户在场作为参照。
    var targetsUser: Bool {
        switch self {
        case .joinUserActivity, .watchWithUser, .seekAttention, .teaseUser, .complainToUser: return true
        case .explore, .rest, .wander: return false
        }
    }
}

/// 一条已下达的目标。
struct Goal: Equatable {
    var kind: GoalKind
    /// "user" / "window_<id>"；explore/rest 可空。
    var target: String?
    /// 关注的活动语义（coding/reading…），场景配方按它取道具与窗口。
    var activity: AppActivity?
    /// 风格词（quiet_companion / playful / sleepy…），只进大脑 prompt 与台词口吻。
    var style: String?
    /// 下达时刻（控制器时钟秒）与来源（local/teacher = 决策脑，policy = 内置）。
    var issuedAt: Double
    var source: String
    /// 把目标层、行动脑和场景结局串成一条可分析的脑路。
    var traceID: String? = nil

    /// 目标的合理寿命（秒）：到期强制重新规划，防止行为僵死。
    var defaultTTL: Double {
        switch kind {
        case .joinUserActivity, .watchWithUser: return 300
        case .seekAttention, .teaseUser, .complainToUser: return 90
        case .explore: return 120
        case .rest: return 600
        case .wander: return 60
        }
    }

    func expired(at now: Double) -> Bool {
        now - issuedAt > defaultTTL
    }

    func semanticDecision(atTick tick: Int64) -> SimulationGoalDecision {
        SimulationGoalDecision(
            goal: kind, target: target, activity: activity?.rawValue, style: style,
            issuedAtTick: tick, source: source)
    }
}

/// 决策脑结果（LLM 返回体）。
struct GoalDecision: Equatable {
    var goal: GoalKind
    var target: String?
    var activity: String?
    var style: String?
    /// 可选：下达目标的同时说一句话（气泡）。
    var speech: String?
    /// 目标 JSON 只出意图枚举；聊天 JSON 由 requestSpeech 单独生成。
    var speechIntent: SpeechIntent?
    /// 可选：让决策脑记一条高层记忆（用户习惯/关系/事件，≤40 字）。
    var memory: String?
    /// 一句话理由（只进日志）。
    var why: String?

    static let goals = Set(GoalKind.allCases.map { $0.rawValue })

    /// 容错解析：截取首尾大括号之间的 JSON。
    static func parse(_ text: String) -> GoalDecision? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let raw = obj["goal"] as? String, GoalKind(rawValue: raw) != nil else { return nil }
        return GoalDecision(
            goal: GoalKind(rawValue: raw)!,
            target: obj["target"] as? String,
            activity: obj["activity"] as? String,
            style: obj["style"] as? String,
            speech: obj["speech"] as? String,
            speechIntent: nil,
            memory: obj["memory"] as? String,
            why: obj["why"] as? String)
    }

    /// 语义校验：目标必须被当前 BrainContextSnapshot 支撑（与 Needle validate 同哲学：
    /// 拒绝即丢弃，本轮保持旧目标/发呆）。
    static func validate(_ d: GoalDecision, world: BrainContextSnapshot) -> Bool {
        if let target = d.target, target != "user" {
            guard world.nearbyWindows.contains(where: { $0.hasPrefix(target + " ") || $0.hasPrefix(target + "(") }) else {
                return false
            }
        }
        if let activity = d.activity, activity != "unknown", AppActivity(rawValue: activity) == nil {
            return false
        }
        if let speech = d.speech?.trimmingCharacters(in: .whitespacesAndNewlines), speech.isEmpty {
            return false
        }
        return true
    }

    /// 气泡文本上限：桌宠说话要短。
    var clippedSpeech: String? {
        guard let speech, !speech.isEmpty else { return nil }
        return String(speech.prefix(60))
    }
}

/// 语音请求的意图词表（行动脑决定「该说话」，可用决策脑决定「说什么」）。
enum SpeechIntent: String, Equatable, CaseIterable {
    case greet             // 打招呼
    case commentActivity = "comment_activity"   // 评论用户正在干的事
    case tease             // 调侃用户
    case complain          // 抗议被骚扰
    case chatter           // 自言自语
}

/// 文本生成脑对语音请求的回复。
struct SpeechReply: Equatable {
    var text: String
    var emotion: String

    static func parse(_ text: String) -> SpeechReply? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        guard let data = String(text[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let said = obj["text"] as? String else { return nil }
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SpeechReply(text: String(trimmed.prefix(60)),
                           emotion: (obj["emotion"] as? String) ?? "neutral")
    }
}
