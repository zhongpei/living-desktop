import CoreGraphics
import Foundation
import MyPetCore

// Scene / Action Recipe —— 复杂行为的「内容化」表达（game.md 第十一节）。
//
// `coding_companion` 不是一段动画，而是一段小型游戏脚本：
//   找窗口锚点 → 走过去 → 跳上窗台 → 拿出笔记本 → 敲一会 → 决策点（继续/插播/离开）
// 新玩法 = 新配方（数据），不改 Qwen/Needle/World/ActionDirector 任何代码。
//
// 素材降级：perform 步骤给候选 clip 列表，运行时取包里存在的第一个；
// 全都没有就跳过该步（不同角色素材不同，同一个配方人人能演）。
// 目标降级：moveTo 的锚点解析失败（窗口没了）= 场景中断，回目标规划，绝不追空窗口。

typealias SceneRecipe = SimulationSceneRecipe
typealias SceneStep = SimulationSceneStep
typealias SceneOp = SimulationSceneOperation

enum SceneCatalog {

    /// Production and headless simulation read the same authored recipes.
    static let recipes = MyPetCore.SceneRunner.defaultRecipes

    /// 给目标挑适配配方（行动脑 choose_scene 的合法集；无行动脑时也是兜底池）。
    /// empathy 高的角色在用户忙时避开打扰型场景（求关注类）——若过滤后为空，
    /// 就返回空集（宠物此时不打扰，等目标过期重规划）。
    static func compatible(goal: Goal, activity: AppActivity, personality: Personality,
                           userBusy: Bool) -> [SceneRecipe] {
        var pool = recipes.filter { $0.goals.contains(goal.kind) }
        if let wanted = goal.activity {
            let specific = pool.filter { $0.activities.contains(wanted.rawValue) }
            if !specific.isEmpty { pool = specific }
        }
        if userBusy, personality.empathy >= 0.7, goal.kind != .complainToUser {
            pool = pool.filter { !$0.needsUser }
        }
        return pool
    }

    static func recipe(id: String) -> SceneRecipe? {
        recipes.first { $0.id == id }
    }

    /// Canonical data-only projection consumed by the shared semantic engine.
    /// ponytail: recipes use the runtime's current fixed 50 ms semantic tick;
    /// make the step configurable only when the runtime supports variable steps.
    static var semanticRecipes: [SimulationSceneRecipe] { recipes }
}

/// 行动脑在决策点的回答。
enum SceneDecision: Equatable {
    case continueScene
    case leaveScene
    /// 插播一次说话（然后继续）。
    case say(SpeechIntent)
    /// 插播一次表演（然后继续）。
    case perform([String])
}

/// Physical operations used by the result-only AppKit BodyCommand adapter.
@MainActor
protocol SceneStaging: AnyObject {
    func resolveAnchor(_ text: String) -> (x: CGFloat, top: Bool, window: WindowEntity?)?
    func floorNearPoint() -> CGFloat
    func sceneMove(toX: CGFloat, top: Bool, window: WindowEntity?, onDone: @escaping (Bool) -> Void)
    @discardableResult func scenePutDown() -> Bool
    @discardableResult func scenePickUp() -> Bool
    func scenePerform(_ candidates: [String], onDone: @escaping () -> Void)
    func sceneSay(_ intent: SpeechIntent)
    func sceneSleep()
}
