import CoreGraphics
import Foundation

// Scene / Action Recipe —— 复杂行为的「内容化」表达（game.md 第十一节）。
//
// `coding_companion` 不是一段动画，而是一段小型游戏脚本：
//   找窗口锚点 → 走过去 → 跳上窗台 → 拿出笔记本 → 敲一会 → 决策点（继续/插播/离开）
// 新玩法 = 新配方（数据），不改 Qwen/Needle/World/ActionDirector 任何代码。
//
// 素材降级：perform 步骤给候选 clip 列表，运行时取包里存在的第一个；
// 全都没有就跳过该步（不同角色素材不同，同一个配方人人能演）。
// 目标降级：moveTo 的锚点解析失败（窗口没了）= 场景中断，回目标规划，绝不追空窗口。

/// 场景里的一步。
enum SceneOp: Equatable {
    /// 走到锚点（@activity.* = 活动窗口锚点；floor_near = 用户附近地面）。
    /// top 槽位 = 跳上窗台栖息；bottom 槽位/地面 = 走位。
    case moveTo(anchor: String)
    /// 拿出道具（场景结束自动回收）。
    case spawnProp(String)
    case clearProps
    /// 表演：候选 clip 依次降级。
    case perform([String])
    /// 原地停留。
    case wait(Double)
    /// 说一句话（意图 → 可用决策脑生成 / 内置台词）。
    case say(SpeechIntent)
    case sleep
    /// 放下持有的道具（道具精灵滑到地面 + 宠物点头节拍）→ placed 原地滞留后淡出。
    case putDown
    /// 拿起附近自己放下的道具（滑进手部）。附近没有 = 跳过。
    case pickUp
}

struct SceneStep: Equatable {
    var op: SceneOp
    /// 该步完成后是否挂决策点（行动脑决定继续/离开/插播）。
    var decisionPoint = false

    init(_ op: SceneOp, decisionPoint: Bool = false) {
        self.op = op
        self.decisionPoint = decisionPoint
    }
}

struct SceneRecipe: Equatable {
    var id: String
    /// 菜单/日志可读名。
    var label: String
    /// 适配的目标（choose_scene 的合法集按 goal 过滤）。
    var goals: Set<GoalKind>
    /// 限定的活动语义（nil = 不限；goal.activity 有值时优先进限定集）。
    var activities: Set<AppActivity>?
    /// 是否打扰型（用户忙 + 高共情时被回避）。
    var needsUser: Bool
    var steps: [SceneStep]
    /// 循环段起点（步骤下标）：主干演完回到这里循环，循环每圈都过决策点。
    var loopFrom: Int?
}

enum SceneCatalog {

    /// 配方总表。新玩法加这里（+ PropCatalog / petpack 动作），零代码改动。
    static let recipes: [SceneRecipe] = [
        SceneRecipe(
            id: "coding_companion", label: "陪用户编码",
            goals: [.joinUserActivity], activities: [.coding, .writing, .designing],
            needsUser: false,
            steps: [
                SceneStep(.moveTo(anchor: "@activity.topRight")),
                SceneStep(.spawnProp("laptop")),
                SceneStep(.perform(ActionCatalog.candidates(for: .think))),
                SceneStep(.wait(6), decisionPoint: true),
            ],
            loopFrom: 2),

        SceneRecipe(
            id: "quiet_observer", label: "安静旁观",
            goals: [.joinUserActivity, .watchWithUser], activities: nil,
            needsUser: false,
            steps: [
                SceneStep(.moveTo(anchor: "@activity.topLeft")),
                SceneStep(.perform(ActionCatalog.candidates(for: .think))),
                SceneStep(.wait(8), decisionPoint: true),
            ],
            loopFrom: 2),

        SceneRecipe(
            id: "watch_with_user", label: "一起看",
            goals: [.watchWithUser], activities: [.watching, .browsing, .chatting],
            needsUser: false,
            steps: [
                SceneStep(.moveTo(anchor: "@activity.topCenter")),
                SceneStep(.perform(ActionCatalog.candidates(for: .happy))),
                SceneStep(.spawnProp("popcorn")),
                SceneStep(.wait(10), decisionPoint: true),
            ],
            loopFrom: 3),

        SceneRecipe(
            id: "read_near_user", label: "在旁边看书",
            goals: [.joinUserActivity, .wander], activities: nil,
            needsUser: false,
            steps: [
                SceneStep(.moveTo(anchor: "floor_near")),
                SceneStep(.spawnProp("book")),
                SceneStep(.perform(ActionCatalog.candidates(for: .think))),
                SceneStep(.wait(9), decisionPoint: true),
                SceneStep(.putDown),
            ],
            loopFrom: 3),

        SceneRecipe(
            id: "tea_break", label: "喝口茶休息",
            goals: [.rest, .wander], activities: nil,
            needsUser: false,
            steps: [
                SceneStep(.moveTo(anchor: "floor_near")),
                SceneStep(.spawnProp("tea")),
                SceneStep(.perform(ActionCatalog.candidates(for: .rest))),
                SceneStep(.wait(8)),
                SceneStep(.putDown),   // 茶放原地：宠物走开后它自己待一会再淡出
            ],
            loopFrom: nil),

        SceneRecipe(
            id: "window_sleep", label: "趴窗台上睡",
            goals: [.rest], activities: nil,
            needsUser: false,
            steps: [
                SceneStep(.moveTo(anchor: "@activity.topCenter")),
                SceneStep(.sleep),
            ],
            loopFrom: nil),

        SceneRecipe(
            id: "seek_attention", label: "求关注",
            goals: [.seekAttention], activities: nil,
            needsUser: true,
            steps: [
                SceneStep(.moveTo(anchor: "floor_near")),
                SceneStep(.perform(ActionCatalog.candidates(for: .greet))),
                SceneStep(.say(.greet)),
                // 第二轮求关注允许用嘲讽/调侃式的亲昵动作继续拉住用户注意力。
                SceneStep(.perform(ActionCatalog.candidates(for: .tease)), decisionPoint: true),
            ],
            loopFrom: 3),

        SceneRecipe(
            id: "tease_user", label: "毒舌嘲讽",
            goals: [.teaseUser], activities: nil,
            needsUser: true,
            steps: [
                SceneStep(.moveTo(anchor: "floor_near")),
                SceneStep(.perform(ActionCatalog.candidates(for: .tease))),
                SceneStep(.say(.tease)),
                SceneStep(.wait(4), decisionPoint: true),
            ],
            loopFrom: nil),

        SceneRecipe(
            id: "complain", label: "表达不满",
            goals: [.complainToUser], activities: nil,
            needsUser: true,
            steps: [
                SceneStep(.moveTo(anchor: "floor_near")),
                SceneStep(.say(.complain)),
                SceneStep(.perform(ActionCatalog.candidates(for: .complain))),
                SceneStep(.wait(4), decisionPoint: true),
            ],
            loopFrom: nil),

        SceneRecipe(
            id: "wander", label: "到处逛逛",
            goals: [.wander, .explore], activities: nil,
            needsUser: false,
            steps: [
                SceneStep(.moveTo(anchor: "floor_near")),
                SceneStep(.perform(ActionCatalog.candidates(for: .happy))),
                SceneStep(.wait(3), decisionPoint: true),
            ],
            loopFrom: 0),

        SceneRecipe(
            id: "window_climb_and_peek", label: "爬上窗沿探头",
            goals: [.explore, .seekAttention], activities: nil,
            needsUser: true,
            steps: [
                // sceneMove 的 top 锚点负责真实窗台接触；perform 再负责可见的
                // 攀爬过渡，因此窗口几何与动画素材各自保持独立、可降级。
                SceneStep(.moveTo(anchor: "@activity.topCenter")),
                SceneStep(.perform(ActionCatalog.candidates(for: .windowClimb))),
                SceneStep(.perform(ActionCatalog.candidates(for: .windowPeek))),
                SceneStep(.wait(6), decisionPoint: true),
            ],
            loopFrom: 2),

        SceneRecipe(
            id: "peek_at_user", label: "扒着窗沿看你",
            goals: [.explore, .seekAttention], activities: nil,
            needsUser: true,
            steps: [
                SceneStep(.moveTo(anchor: "@activity.topLeft")),
                SceneStep(.perform(ActionCatalog.candidates(for: .windowPeek))),
                SceneStep(.wait(6), decisionPoint: true),
            ],
            loopFrom: 2),
    ]

    /// 给目标挑适配配方（行动脑 choose_scene 的合法集；无行动脑时也是兜底池）。
    /// empathy 高的角色在用户忙时避开打扰型场景（求关注类）——若过滤后为空，
    /// 就返回空集（宠物此时不打扰，等目标过期重规划）。
    static func compatible(goal: Goal, activity: AppActivity, personality: Personality,
                           userBusy: Bool) -> [SceneRecipe] {
        var pool = recipes.filter { $0.goals.contains(goal.kind) }
        if let wanted = goal.activity {
            let specific = pool.filter { $0.activities?.contains(wanted) == true }
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

/// 场景对舞台的接口：每一步怎么落地由控制器（ActionDirector 侧）回答。
/// 所有 onDone 必须最终被调用（含失败路径），否则场景卡死。
protocol SceneStaging: AnyObject {
    /// 宠物脚位（翻转坐标，spawnProp 摆放点用）。
    var petX: CGFloat { get }
    var petYFeet: CGFloat { get }
    /// 表演候选是否存在（素材降级判定）。
    func hasClip(_ name: String) -> Bool
    /// 锚点解析：spec → (落点 x, 是否窗台, 目标窗口)。失败 = nil（窗口没了）。
    func resolveAnchor(_ text: String) -> (x: CGFloat, top: Bool, window: WindowEntity?)?
    /// 宠物当前脚位附近的地面游走点（floor_near 用）。
    func floorNearPoint() -> CGFloat

    func sceneMove(toX: CGFloat, top: Bool, window: WindowEntity?, onDone: @escaping () -> Void)
    func sceneSpawnProp(_ id: String, at x: CGFloat, footY: CGFloat)
    func sceneClearProps()
    /// 放下持有的道具（节拍由舞台配合）；返回 false = 手里没道具。
    @discardableResult
    func scenePutDown() -> Bool
    /// 拿起附近自己放下的道具；返回 false = 附近没有。
    @discardableResult
    func scenePickUp() -> Bool
    func scenePerform(_ candidates: [String], onDone: @escaping () -> Void)
    func sceneSay(_ intent: SpeechIntent)
    func sceneSleep()
    /// 决策点：异步咨询行动脑（或内置策略），回答经 SceneRunner.resume 生效。
    func sceneDecisionPoint(_ scene: SceneRecipe, stepIndex: Int, resume: @escaping (SceneDecision) -> Void)
}

/// 场景执行器：回调驱动 + tick 看表/看超时。
final class SceneRunner {

    private(set) var recipe: SceneRecipe
    private(set) weak var stage: SceneStaging?
    private(set) var startedAt: Double = 0
    private(set) var stepIndex = 0
    private(set) var completed = false

    enum Phase: Equatable {
        case ready
        case moving
        case performing
        case waiting(until: Double)
        case deciding
        case sleeping
        case finished
    }
    private(set) var phase: Phase = .ready
    /// 当前步骤开始时刻（卡死看门狗用）。
    private var stepStartedAt: Double = 0
    /// 单步最长停留（移动被卡/表演被吞时的自愈）。
    var stepTimeout: Double = 20
    /// 步骤代际：每开始新步骤 +1。舞台回调携带代际，过期回调（看门狗先走了、
    /// 移动后来才报完成）直接忽略 —— 幂等护栏。
    private(set) var stepGeneration = 0
    /// tick 喂入的当前时钟（wait 相位与 startStep 管道用）。
    var currentClock: Double = 0

    init(recipe: SceneRecipe) {
        self.recipe = recipe
    }

    var isActive: Bool { phase != .finished }

    /// 场景已持续秒数（按控制器时钟）。
    var stayedSeconds: Double { startedAt > 0 ? max(0, currentClock - startedAt) : 0 }

    /// 场景开始时由控制器绑定 "@activity" 锚点的目标窗口（可 nil）。
    func start(stage: SceneStaging, activityWindow: WindowEntity?, now: Double) {
        self.stage = stage
        self.activityWindowID = activityWindow?.id
        self.startedAt = now
        self.currentClock = now
        self.stepIndex = 0
        self.phase = .ready
        self.completed = false
        self.stepGeneration = 0
    }
    private var activityWindowID: CGWindowID?

    /// 强制结束（用户抓起 / 目标变更 / 醒来）。回收道具。
    func abort() {
        guard phase != .finished else { return }
        phase = .finished
        stage?.sceneClearProps()
    }

    /// 每帧推进：看表（wait 到期 / 步骤超时自愈）。
    func tick(now: Double) {
        currentClock = now
        guard isActive else { return }
        switch phase {
        case .waiting(let until):
            if now >= until { finishStep() }
        case .moving, .performing:
            if now - stepStartedAt > stepTimeout { finishStep() }  // 看门狗
        case .ready:
            startStep(now: now)   // ready 不会跨帧存在，防御性兜底
        case .deciding, .sleeping, .finished:
            break
        }
    }

    /// 决策点回答（控制器从行动脑/内置策略回带进来）。
    func resume(_ decision: SceneDecision) {
        guard phase == .deciding, let stage else { return }
        switch decision {
        case .continueScene:
            advanceStep()
        case .leaveScene:
            phase = .finished
            completed = true
            stage.sceneClearProps()
        case .say(let intent):
            stage.sceneSay(intent)
            advanceStep()
        case .perform(let candidates):
            let existing = candidates.filter { stage.hasClip($0) }
            if existing.isEmpty {
                advanceStep()
            } else {
                phase = .performing
                stepStartedAt = currentClock
                let gen = stepGeneration
                stage.scenePerform(existing) { [weak self] in
                    self?.stepDone(gen: gen)
                }
            }
        }
    }

    // MARK: 步进内部

    private func startStep(now: Double) {
        guard let stage else { phase = .finished; return }
        if stepIndex >= recipe.steps.count {
            if let loop = recipe.loopFrom, loop < recipe.steps.count {
                stepIndex = loop
            } else {
                phase = .finished
                completed = true
                stage.sceneClearProps()
                return
            }
        }
        stepGeneration += 1
        let step = recipe.steps[stepIndex]
        stepStartedAt = now

        switch step.op {
        case .moveTo(let anchorText):
            let resolved: (x: CGFloat, top: Bool, window: WindowEntity?)?
            if anchorText == "floor_near" {
                resolved = (stage.floorNearPoint(), false, nil)
            } else if anchorText.hasPrefix("@activity.") {
                let slot = AnchorSlot(rawValue: String(anchorText.dropFirst("@activity.".count))) ?? .topCenter
                resolved = activityWindowID.flatMap { id in
                    stage.resolveAnchor("window_\(id).\(slot.rawValue)")
                }
            } else {
                resolved = stage.resolveAnchor(anchorText)
            }
            guard let target = resolved else {
                // 锚点目标没了：场景中断（不追空窗口）。
                phase = .finished
                stage.sceneClearProps()
                return
            }
            phase = .moving
            let gen = stepGeneration
            stage.sceneMove(toX: target.x, top: target.top, window: target.window) { [weak self] in
                self?.stepDone(gen: gen)
            }

        case .spawnProp(let id):
            stage.sceneSpawnProp(id, at: stage.petX, footY: stage.petYFeet)
            advanceStep()

        case .clearProps:
            stage.sceneClearProps()
            advanceStep()

        case .putDown:
            if stage.scenePutDown() {
                // 放下是一个可见动作：给一个固定节拍再进下一步。
                phase = .performing
                let gen = stepGeneration
                stage.scenePerform(["nod"]) { [weak self] in self?.stepDone(gen: gen) }
            } else {
                advanceStep()   // 手里没道具：跳过
            }

        case .pickUp:
            if stage.scenePickUp() {
                phase = .performing
                let gen = stepGeneration
                stage.scenePerform(["happy", "nod"]) { [weak self] in self?.stepDone(gen: gen) }
            } else {
                advanceStep()   // 附近没有可拿的：跳过
            }

        case .perform(let candidates):
            let existing = candidates.filter { stage.hasClip($0) }
            if existing.isEmpty {
                advanceStep()   // 素材降级：跳过
                return
            }
            phase = .performing
            let gen = stepGeneration
            stage.scenePerform(existing) { [weak self] in self?.stepDone(gen: gen) }

        case .wait(let seconds):
            phase = .waiting(until: now + seconds)

        case .say(let intent):
            stage.sceneSay(intent)
            advanceStep()

        case .sleep:
            phase = .sleeping
            stage.sceneSleep()
        }
    }

    /// 舞台回调入口（带代际）：只有当前步骤的完成才算数。
    private func stepDone(gen: Int) {
        guard gen == stepGeneration else { return }   // 过期回调（看门狗已先行）
        finishStep()
    }

    /// 完成当前步：有决策点先挂决策，否则进下一步。
    /// 相位护栏：只有可完成相位响应（移动/表演/等待），其余忽略（幂等）。
    private func finishStep() {
        guard isActive else { return }
        switch phase {
        case .moving, .performing, .waiting: break
        default: return
        }
        guard let stage else { return }
        let idx = min(stepIndex, recipe.steps.count - 1)
        if recipe.steps[idx].decisionPoint {
            phase = .deciding
            stage.sceneDecisionPoint(recipe, stepIndex: idx) { [weak self] decision in
                self?.resume(decision)
            }
        } else {
            advanceStep()
        }
    }

    /// 步进：index +1 → 下一步（或循环/收工）。
    private func advanceStep() {
        guard isActive else { return }
        stepIndex += 1
        phase = .ready
        startStep(now: currentClock)
    }
}
