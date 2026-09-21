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
    /// 决策点：异步咨询行动脑（或内置策略），回答经 SceneBodyDriver.resume 生效。
    func sceneDecisionPoint(_ scene: SceneRecipe, stepIndex: Int, resume: @escaping (SceneDecision) -> Void)
}

/// AppKit body driver for the Core-owned semantic scene cursor.
final class SceneBodyDriver {

    typealias BodyResultReporter = (Bool) -> Void

    private(set) var recipe: SceneRecipe
    private let semanticRunner: MyPetCore.SceneRunner
    private let goal: SimulationGoalDecision
    private let authorize: (
        SimulationNeedleAction,
        @escaping (Bool, BodyResultReporter?) -> Void
    ) -> Void
    private var activeBodyResultReporter: BodyResultReporter?
    private(set) weak var stage: SceneStaging?
    private(set) var startedAt: Double = 0
    var stepIndex: Int { semanticRunner.stepIndex }
    private(set) var completed = false

    enum Phase: Equatable {
        case ready
        case authorizing
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

    init(
        recipe: SceneRecipe,
        goal: SimulationGoalDecision? = nil,
        semanticRunner: MyPetCore.SceneRunner? = nil,
        authorize: @escaping (
            SimulationNeedleAction,
            @escaping (Bool, BodyResultReporter?) -> Void
        ) -> Void = { _, completion in
            completion(true, nil)
        }
    ) {
        self.recipe = recipe
        self.goal = goal ?? SimulationGoalDecision(goal: recipe.goals.first ?? .wander)
        self.semanticRunner = semanticRunner ?? MyPetCore.SceneRunner(recipes: [recipe])
        self.authorize = authorize
    }

    /// Test/content compatibility seam for callers that only model admission.
    /// Production uses the reporter-bearing initializer above.
    convenience init(
        recipe: SceneRecipe,
        goal: SimulationGoalDecision? = nil,
        semanticRunner: MyPetCore.SceneRunner? = nil,
        authorize: @escaping (SimulationNeedleAction, @escaping (Bool) -> Void) -> Void
    ) {
        self.init(
            recipe: recipe,
            goal: goal,
            semanticRunner: semanticRunner,
            authorize: { action, completion in
                authorize(action) { accepted in completion(accepted, nil) }
            })
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
        guard semanticRunner.start(recipeID: recipe.id, goal: goal) else {
            phase = .finished
            return
        }
        self.phase = .ready
        self.completed = false
        self.stepGeneration = 0
    }
    private var activityWindowID: CGWindowID?

    /// 强制结束（用户抓起 / 目标变更 / 醒来）。回收道具。
    func abort() {
        guard phase != .finished else { return }
        finishBody(success: false)
        phase = .finished
        semanticRunner.cancel()
        stage?.sceneClearProps()
    }

    /// 每帧推进：看表（wait 到期 / 步骤超时自愈）。
    func tick(now: Double) {
        currentClock = now
        guard isActive else { return }
        switch phase {
        case .waiting(let until):
            if now >= until { finishStep() }
        case .authorizing:
            if now - stepStartedAt > stepTimeout {
                finishBody(success: false)
                phase = .finished
                semanticRunner.cancel()
                stage?.sceneClearProps()
            }
        case .moving, .performing:
            if now - stepStartedAt > stepTimeout { failScene() }
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
            authorizeDecision(.leaveScene) { [weak self, weak stage] in
                guard let self else { return }
                self.finishBody(success: true)
                self.phase = .finished
                self.completed = true
                self.semanticRunner.cancel()
                stage?.sceneClearProps()
            }
        case .say(let intent):
            authorizeDecision(.say(intent.rawValue)) { [weak self, weak stage] in
                stage?.sceneSay(intent)
                self?.advanceStep()
            }
        case .perform(let candidates):
            authorizeDecision(.performCandidates(candidates)) { [weak self, weak stage] in
                guard let self, let stage else { return }
                let existing = candidates.filter { stage.hasClip($0) }
                if existing.isEmpty {
                    self.advanceStep()
                } else {
                    self.phase = .performing
                    self.stepStartedAt = self.currentClock
                    let gen = self.stepGeneration
                    stage.scenePerform(existing) { [weak self] in
                        self?.stepDone(gen: gen)
                    }
                }
            }
        }
    }

    // MARK: 步进内部

    private func startStep(now: Double) {
        guard let stage else { failScene(); return }
        guard let step = semanticRunner.currentStep else {
            phase = .finished
            completed = semanticRunner.status == .completed
            stage.sceneClearProps()
            return
        }
        stepGeneration += 1
        stepStartedAt = now
        phase = .authorizing
        let generation = stepGeneration
        authorize(Self.action(for: step.operation)) { [weak self] accepted, reporter in
            guard let self, generation == self.stepGeneration, self.phase == .authorizing else { return }
            guard accepted else {
                self.failScene()
                return
            }
            self.activeBodyResultReporter = reporter
            self.execute(step: step, now: now, generation: generation)
        }
    }

    private func authorizeDecision(
        _ action: SimulationNeedleAction,
        onAccepted: @escaping () -> Void
    ) {
        stepGeneration += 1
        let generation = stepGeneration
        stepStartedAt = currentClock
        phase = .authorizing
        authorize(action) { [weak self] accepted, reporter in
            guard let self, generation == self.stepGeneration, self.phase == .authorizing else { return }
            guard accepted else {
                self.failScene()
                return
            }
            self.activeBodyResultReporter = reporter
            onAccepted()
        }
    }

    private func failScene() {
        finishBody(success: false)
        phase = .finished
        semanticRunner.cancel()
        stage?.sceneClearProps()
    }

    private static func action(for operation: SimulationSceneOperation) -> SimulationNeedleAction {
        switch operation {
        case .moveTo(let value): return .moveTo(value)
        case .perform(let value): return .perform(value)
        case .performCandidates(let values): return .performCandidates(values)
        case .spawnProp(let value): return .spawnProp(value)
        case .clearProps: return .clearProps
        case .putDown: return .putDown
        case .pickUp: return .pickUp
        case .wait: return .wait
        case .say(let value): return .say(value)
        case .sleep: return .sleep
        }
    }

    private func execute(step: SceneStep, now: Double, generation: Int) {
        guard let stage else { failScene(); return }

        switch step.operation {
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
                failScene()
                return
            }
            phase = .moving
            let gen = generation
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
                let gen = generation
                stage.scenePerform(["nod"]) { [weak self] in self?.stepDone(gen: gen) }
            } else {
                advanceStep()   // 手里没道具：跳过
            }

        case .pickUp:
            if stage.scenePickUp() {
                phase = .performing
                let gen = generation
                stage.scenePerform(["happy", "nod"]) { [weak self] in self?.stepDone(gen: gen) }
            } else {
                advanceStep()   // 附近没有可拿的：跳过
            }

        case .perform(let action):
            let candidates = [action]
            let existing = candidates.filter { stage.hasClip($0) }
            if existing.isEmpty {
                advanceStep()
                return
            }
            phase = .performing
            let gen = generation
            stage.scenePerform(existing) { [weak self] in self?.stepDone(gen: gen) }

        case .performCandidates(let candidates):
            let existing = candidates.filter { stage.hasClip($0) }
            if existing.isEmpty {
                advanceStep()   // 素材降级：跳过
                return
            }
            phase = .performing
            let gen = generation
            stage.scenePerform(existing) { [weak self] in self?.stepDone(gen: gen) }

        case .wait(let ticks):
            phase = .waiting(until: now + Double(ticks) * 0.05)

        case .say(let intent):
            if let intent = SpeechIntent(rawValue: intent) { stage.sceneSay(intent) }
            advanceStep()

        case .sleep:
            phase = .sleeping
            stage.sceneSleep()
            finishBody(success: true)
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
        finishBody(success: true)
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

    /// Advance the shared Core cursor, then stage its next command.
    private func advanceStep() {
        guard isActive else { return }
        finishBody(success: true)
        if semanticRunner.completeStep() {
            phase = .finished
            completed = true
            stage?.sceneClearProps()
            return
        }
        phase = .ready
        startStep(now: currentClock)
    }

    private func finishBody(success: Bool) {
        let reporter = activeBodyResultReporter
        activeBodyResultReporter = nil
        reporter?(success)
    }
}
