import Foundation

// GoalPolicy —— 内置目标策略：没有决策脑时的目标兜底。
//
// 设计目标：零 LLM 也完整可玩（默认状态）。规则是人格 × 需求环的加权掷骰，
// 确定性可测（seed 注入），分布由人格参数塑形：
//   能量低 → rest；应激高 → 躲避/抗议；社交需求高 → 求关注/陪工；
//   无聊高 → 探索；用户在忙 → 依共情/认真度决定陪工还是不打扰。
// 决策脑开启时本策略只做兜底（模型失败/超时的那一轮）。

enum GoalPolicy {

    /// 这些阈值同时约束“低能量必须休息”和“休息何时可以被无聊打断”。
    /// 低能量时无聊不能推翻休息，否则控制器会在两个互相矛盾的目标间重规划。
    static let lowEnergyThreshold = 0.2
    static let highBoredomThreshold = 0.85

    struct Context {
        var brain: BrainState
        var personality: Personality
        /// 用户活动语义（前台窗口归类）。
        var userActivity: AppActivity
        /// 用户空闲秒数。
        var userIdleSeconds: Double
        /// 场上是否有可去窗口。
        var hasWindows: Bool
        /// 距上次交互（被摸/说话）的秒数；nil = 从未。
        var secondsSinceInteraction: Double?
        /// 当前时钟（随机数种子外的排序用）。
        var now: Double
    }

    /// 产出一条目标。rng 可注入（测试确定性）。
    static func decide(_ ctx: Context, rng: inout SeededGenerator) -> Goal {
        let b = ctx.brain
        let p = ctx.personality

        // 硬规则在前：需求环的极限值直接压过随机。
        if b.stress >= 0.65 {
            // 高应激：社交型抗议，内向型躲开休息。
            return p.social >= 0.5
                ? make(.complainToUser, target: "user", ctx: ctx)
                : make(.rest, target: nil, ctx: ctx)
        }
        if b.energy <= lowEnergyThreshold {
            return make(.rest, target: nil, ctx: ctx)
        }

        // 加权掷骰：每类目标的权重由人格与需求环塑形。
        var weights: [(GoalKind, Double)] = []
        let busy = isBusy(ctx)

        // 陪工 / 一起看：用户忙时才有意义；共情高不可以在用户专注聊天时捣乱。
        if busy, ctx.hasWindows {
            switch ctx.userActivity {
            case .watching:
                weights.append((.watchWithUser, 0.9 + p.empathy))
            case .coding, .writing, .designing, .reading:
                // 认真度高/共情高 → 想陪工；玩性高反而更想捣乱（权重降低）。
                weights.append((.joinUserActivity, 0.5 + p.diligence + p.empathy * 0.6 - p.playfulness * 0.4))
            case .chatting:
                weights.append((.watchWithUser, 0.4 + p.empathy * 0.8))
            default:
                break
            }
        }
        // 求关注：社交需求推高；独立性强打折扣；用户在忙时被共情压制（别添乱）。
        let attentionBase = max(0, b.socialNeed * 1.6 + p.social * 0.6 - p.independence * 0.5)
        weights.append((.seekAttention, attentionBase * (busy ? (1.0 - p.empathy * 0.8) : 1.0)))
        // 嘲讽是独立目标：毒舌倾向越高、越无聊/越想互动，越容易主动来一句；
        // 用户忙时由共情压低，场景层还会再过滤需要用户注意的配方。
        let teasingBase = max(0, p.teasing * (0.35 + b.boredom * 0.7 + b.socialNeed * 0.5))
        weights.append((.teaseUser, teasingBase * (busy ? (1.0 - p.empathy) : 1.0)))
        // 探索：好奇心 × 无聊。
        weights.append((.explore, max(0, b.curiosity * 0.8 + b.boredom * 0.8 + p.curiosity * 0.3)))
        // 休息：能量中等偏低、或夜深用户闲置。
        weights.append((.rest, max(0, (1.0 - b.energy) * 1.2 - b.socialNeed * 0.4)))
        // 随便走走：填充项，低权重常量。
        weights.append((.wander, 0.25 + p.playfulness * 0.2))

        let total = weights.reduce(0) { $0 + $1.1 }
        var roll = Double.random(in: 0..<max(total, 0.0001), using: &rng)
        for (kind, w) in weights {
            roll -= w
            if roll <= 0 { return make(kind, target: target(for: kind, ctx: ctx), ctx: ctx) }
        }
        return make(.wander, target: nil, ctx: ctx)
    }

    /// 只有能量已经脱离低能量硬约束时，无聊才可以打断休息。
    static func shouldInterruptRest(energy: Double, boredom: Double) -> Bool {
        energy > lowEnergyThreshold && boredom >= highBoredomThreshold
    }

    /// 用户是否「在做正事」（目标策略语境：有明确活动语义且没在摸鱼空闲）。
    static func isBusy(_ ctx: Context) -> Bool {
        guard ctx.userIdleSeconds < 120 else { return false }
        switch ctx.userActivity {
        case .coding, .writing, .reading, .chatting, .watching, .designing, .browsing, .files, .music:
            return true
        case .unknown:
            return false
        }
    }

    private static func target(for kind: GoalKind, ctx: Context) -> String? {
        kind.targetsUser ? "user" : nil
    }

    private static func make(_ kind: GoalKind, target: String?, ctx: Context) -> Goal {
        let style: String
        switch kind {
        case .joinUserActivity:
            style = ctx.personality.playfulness > 0.6 ? "playful_companion" : "quiet_companion"
        case .watchWithUser:
            style = "cozy"
        case .seekAttention:
            style = ctx.personality.playfulness > 0.7 ? "mischievous" : "needy"
        case .teaseUser:
            style = "teasing"
        case .complainToUser:
            style = ctx.personality.empathy > 0.7 ? "grievance" : "mildly_annoyed"
        case .explore:
            style = "curious"
        case .rest:
            style = "sleepy"
        case .wander:
            style = "easygoing"
        }
        let activity: AppActivity? = (kind == .joinUserActivity || kind == .watchWithUser) ? ctx.userActivity : nil
        return Goal(kind: kind, target: target, activity: activity, style: style,
                    issuedAt: ctx.now, source: "policy")
    }
}

/// 可复现的线性同余随机源（测试确定性；游戏运行时用 SystemRandomNumberGenerator 即可）。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
