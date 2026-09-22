import Foundation
import MyPetCore
import MyPetEngine

// Personality v2 —— 稳定人格，两颗脑共用。
//
// 七维（0~1，长期稳定）决定「为什么做 / 怎么做」：
//   social       社交性        —— 高：主动凑人；低：独处
//   curiosity    好奇心        —— 高：探索新窗口/新事件
//   playfulness  玩兴          —— 高：捣乱、恶作剧式互动
//   diligence    认真度        —— 高：陪工时真的「工作」（敲电脑不走神）
//   empathy      共情          —— 高：跟随用户情绪，忙时不打扰
//   independence 独立性        —— 高：自己找乐子；低：黏人
//   teasing      嘲讽倾向      —— 高：更愿意用挖苦/调侃来发起互动
// 动力学四参数（curiosityGain/socialGain/energyDecay/chattiness）沿用 Brain v1：
// 它们决定 BrainState 的涨落速度，与七维正交。
//
// 同一个 Goal，不同人格走出不同路线 —— 由 GoalPolicy（选目标）与
// SceneCatalog 兼容加权（选场景）消费，不给每个角色写代码。

struct Personality: Equatable {
    // 七维
    var social: Double
    var curiosity: Double
    var playfulness: Double
    var diligence: Double
    var empathy: Double
    var independence: Double
    /// 毒舌/嘲讽倾向（0~1）：决定嘲讽目标、台词意图与表演动作的概率。
    var teasing: Double
    /// Human-authored identity survives compilation and is shared with both brains.
    var semanticTypes: [String]
    var signatureBehaviors: [String]
    var signatureActions: [String]

    // 动力学（Brain v1 原有）
    var curiosityGain: Double
    var socialGain: Double
    var energyDecay: Double
    /// 说话冷却系数（>1 = 更矜持）。
    var chattiness: Double

    init(social: Double = 0.6, curiosity: Double = 0.6, playfulness: Double = 0.5,
         diligence: Double = 0.5, empathy: Double = 0.6, independence: Double = 0.5,
         teasing: Double = 0.5,
         semanticTypes: [String] = [], signatureBehaviors: [String] = [],
         signatureActions: [String] = [],
         curiosityGain: Double = 0.020, socialGain: Double = 0.014,
         energyDecay: Double = 0.006, chattiness: Double = 1.0) {
        self.social = social
        self.curiosity = curiosity
        self.playfulness = playfulness
        self.diligence = diligence
        self.empathy = empathy
        self.independence = independence
        self.teasing = teasing
        self.semanticTypes = semanticTypes
        self.signatureBehaviors = signatureBehaviors
        self.signatureActions = signatureActions
        self.curiosityGain = curiosityGain
        self.socialGain = socialGain
        self.energyDecay = energyDecay
        self.chattiness = chattiness
    }

    /// 默认：活泼外向。
    static let `default` = Personality()

    /// 林黛玉（game.md 定稿数值）：好奇收敛、社交矜持、易倦；高共情高独立。
    static let linDaiyu = Personality(
        social: 0.35, curiosity: 0.75, playfulness: 0.25,
        diligence: 0.65, empathy: 0.90, independence: 0.70, teasing: 0.85,
        curiosityGain: 0.012, socialGain: 0.007, energyDecay: 0.009, chattiness: 1.8)

    /// mochi_cat：玩性大发的黏人猫。
    static let mochiCat = Personality(
        social: 0.75, curiosity: 0.80, playfulness: 0.95,
        diligence: 0.15, empathy: 0.45, independence: 0.30, teasing: 0.72,
        curiosityGain: 0.022, socialGain: 0.016, energyDecay: 0.005, chattiness: 0.8)

    /// pan_jinlian：爱凑热闹、爱表现。
    static let panJinlian = Personality(
        social: 0.85, curiosity: 0.65, playfulness: 0.70,
        diligence: 0.35, empathy: 0.55, independence: 0.40, teasing: 0.90,
        curiosityGain: 0.018, socialGain: 0.020, energyDecay: 0.006, chattiness: 0.9)

    /// rei_chibi：元气但不过分黏人。
    static let reiChibi = Personality(
        social: 0.60, curiosity: 0.70, playfulness: 0.65,
        diligence: 0.50, empathy: 0.60, independence: 0.55, teasing: 0.18,
        curiosityGain: 0.019, socialGain: 0.013, energyDecay: 0.006, chattiness: 1.1)

    static func forCharacter(_ id: String) -> Personality {
        switch id {
        case "lin_daiyu": return .linDaiyu
        case "mochi_cat": return .mochiCat
        case "pan_jinlian": return .panJinlian
        case "rei_chibi": return .reiChibi
        default: return .default
        }
    }

    static func forDefinition(_ definition: CharacterDefinition) -> Personality {
        let value = definition.personality
        return Personality(
            social: Double(value.social) / 100,
            curiosity: Double(value.curiosity) / 100,
            playfulness: Double(value.playfulness) / 100,
            diligence: Double(value.diligence) / 100,
            empathy: Double(value.empathy) / 100,
            independence: Double(value.independence) / 100,
            teasing: Double(value.teasing) / 100,
            semanticTypes: definition.semanticProfile?.personalityTypes ?? [],
            signatureBehaviors: definition.semanticProfile?.signatureBehaviors.values
                .map(\.label).sorted() ?? [],
            signatureActions: Array(Set(definition.semanticProfile?.signatureBehaviors.values
                .flatMap(\.actionCandidates) ?? [])).sorted())
    }

    /// 大脑 prompt 里的人格段（两颗脑共用一份描述，保证口吻一致）。
    var promptSection: String {
        let pct = { (v: Double) -> String in String(Int((v * 100).rounded())) }
        var result = "personality(0-100): social=\(pct(social)) curiosity=\(pct(curiosity)) " +
            "playfulness=\(pct(playfulness)) diligence=\(pct(diligence)) " +
            "empathy=\(pct(empathy)) independence=\(pct(independence)) " +
            "teasing=\(pct(teasing))"
        if !semanticTypes.isEmpty { result += " types=\(semanticTypes.joined(separator: ","))" }
        if !signatureBehaviors.isEmpty {
            result += " signature_behaviors=\(signatureBehaviors.joined(separator: ","))"
        }
        return result
    }

    /// 行为风格词（场景选择与台词生成的口吻依据）。
    var styleWord: String {
        if playfulness >= 0.7 { return "playful" }
        if social >= 0.7 { return "sociable" }
        if chattiness > 1.4 { return "reserved" }
        if diligence >= 0.6 { return "diligent" }
        return "easygoing"
    }
}
