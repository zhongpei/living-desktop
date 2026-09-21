import Foundation

// BrainState v2 —— 宠物的内部状态（game-v2 扩充）。
//
// WorldState = 外面的世界；BrainState = 我自己现在怎么样。
// v1 只有 energy/curiosity/socialNeed；v2 按 game.md 补齐需求环：
//   boredom   无聊 —— 闲置与重复行为推高，场景/探索后回落（「角色无聊了」的来源）
//   affection 亲密 —— 被摸头/陪伴缓慢上涨，冷落缓慢消退（关系温度）
//   stress    应激 —— 被反复戳/被抛掷推高，安静时消退（高应激 → 躲避/抱怨）
// 变量只通过少数入口变化：tick 自然涨落、MindEvent 决策反馈。

struct BrainState: Codable, Equatable {
    /// 0~1：动多了降，睡/闲升。低到阈值时目标策略应多选 rest。
    var energy = 0.8
    /// 0~1：世界变化与闲置把它推高，探索/表演后回落。
    var curiosity = 0.5
    /// 0~1：随时间上涨，说话/被互动后回落。
    var socialNeed = 0.4
    /// 0~1：闲置上涨、有事做回落。
    var boredom = 0.3
    /// 0~1：被善待上涨，缓慢消退。
    var affection = 0.3
    /// 0~1：被骚扰/抛掷上涨，安静消退。
    var stress = 0.0
    /// 当前注意力（WorldState 里的目标描述，如 "window_123" / "user"）。
    var attentionTarget: String?
    /// 当前自主目标（Goal.kind，如 join_user_activity / rest），供大脑保持连贯。
    var currentGoal: String?
    /// 角色自己最近的活动（场景 id，如 coding_companion）—— game.md §7。
    var lastActivity: String?
    var lastAction: String?
    var lastSpeech: String?
    var lastSpeechAt: Double?

    /// 成员wise init（测试用部分参数构造）。
    init(energy: Double = 0.8, curiosity: Double = 0.5, socialNeed: Double = 0.4,
         boredom: Double = 0.3, affection: Double = 0.3, stress: Double = 0.0) {
        self.energy = energy
        self.curiosity = curiosity
        self.socialNeed = socialNeed
        self.boredom = boredom
        self.affection = affection
        self.stress = stress
    }
}

/// 内部状态的事件入口（决策/交互/场景的反馈全部收窄到这里）。
enum MindEvent: Equatable {
    case spoke(text: String)
    case performed(String)      // 表演名
    case moved(distance: Double)
    case slept
    case woke
    case sceneFinished(scene: String, stayedSeconds: Double)
    case patted                 // 轻点摸头
    case poked                  // 连续被戳
    case startled               // 鼠标突然逼近（惊吓反射）
    case tossed                 // 被抛掷
    case explored
}

extension BrainState {

    /// 自然动力学。dt 秒；worldChanged = 前台/聚焦刚变过（好奇心加速涨、无聊回落）。
    mutating func tick(dt: Double, worldChanged: Bool, isAsleep: Bool, isMoving: Bool,
                       personality: Personality) {
        if isAsleep {
            energy = clamp(energy + dt * 0.020)
            curiosity = clamp(curiosity - dt * 0.004)
            boredom = clamp(boredom - dt * 0.006)
        } else {
            let movingFactor = isMoving ? 2.0 : 1.0
            energy = clamp(energy - dt * personality.energyDecay * movingFactor)
            curiosity = clamp(curiosity + dt * personality.curiosityGain * (worldChanged ? 3.0 : 0.5))
            // 闲置无聊上涨；世界在变 / 正在做事则回落。
            boredom = clamp(boredom + dt * 0.004 * (worldChanged || isMoving ? -2.0 : 1.0))
        }
        socialNeed = clamp(socialNeed + dt * personality.socialGain * (isAsleep ? 0.3 : 1.0))
        // 应激消退慢；亲密度只有陪伴（醒着不累）时极缓慢上涨。
        stress = clamp(stress - dt * 0.003)
        if !isAsleep && !isMoving {
            affection = clamp(affection + dt * 0.0008)
        }
    }

    /// 事件反馈：做了事会累、说了话会被满足、被骚扰会应激 —— 行为闭环。
    mutating func apply(event: MindEvent, now: Double) {
        lastAction = Self.describe(event)
        switch event {
        case .spoke(let text):
            socialNeed = clamp(socialNeed - 0.35)
            energy = clamp(energy - 0.05)
            lastSpeech = text
            lastSpeechAt = now
        case .performed:
            socialNeed = clamp(socialNeed - 0.10)
            boredom = clamp(boredom - 0.15)
            energy = clamp(energy - 0.08)
        case .moved(let distance):
            energy = clamp(energy - min(0.08, distance / 3000))
            curiosity = clamp(curiosity - 0.15)
            boredom = clamp(boredom - 0.10)
        case .slept:
            currentGoal = GoalKind.rest.rawValue
        case .woke:
            break
        case .sceneFinished(let scene, let stayed):
            boredom = clamp(boredom - min(0.5, stayed / 120))
            energy = clamp(energy - min(0.2, stayed / 300))
            lastAction = "scene \(scene) ×\(Int(stayed))s"
        case .patted:
            affection = clamp(affection + 0.05)
            socialNeed = clamp(socialNeed - 0.08)
            stress = clamp(stress - 0.05)
        case .poked:
            stress = clamp(stress + 0.18)
            socialNeed = clamp(socialNeed + 0.05)
        case .startled:
            stress = clamp(stress + 0.06)
        case .tossed:
            stress = clamp(stress + 0.25)
        case .explored:
            curiosity = clamp(curiosity - 0.25)
            boredom = clamp(boredom - 0.2)
            energy = clamp(energy - 0.05)
        }
    }

    /// 目标下达：记录当前目标镜像（进大脑 prompt，保持行为连贯）。
    mutating func adopt(goal: Goal, now: Double) {
        currentGoal = goal.kind.rawValue
        attentionTarget = goal.target ?? attentionTarget
        lastActivity = goal.kind.rawValue
    }

    /// 丢弃当前目标（场景完成/目标过期后的间隙）。
    mutating func clearGoal() {
        currentGoal = nil
    }

    static func describe(_ event: MindEvent) -> String {
        switch event {
        case .spoke: return "spoke"
        case .performed(let n): return "perform \(n)"
        case .moved(let d): return "moved \(Int(d))pt"
        case .slept: return "sleep"
        case .woke: return "wake"
        case .sceneFinished(let s, let t): return "scene \(s) ×\(Int(t))s"
        case .patted: return "patted"
        case .poked: return "poked"
        case .startled: return "startled"
        case .tossed: return "tossed"
        case .explored: return "explore"
        }
    }

    private func clamp(_ v: Double) -> Double {
        min(1.0, max(0.0, v))
    }
}
