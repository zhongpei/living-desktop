import AppKit
import CoreGraphics
import CoreText
import MyPetCore
import MyPetPlatform

/// WindowWorld + Screens + 系统空闲时间的生产装配，喂给 PetModel。
final class SystemWorld: WorldReading {

    let world: WindowWorld

    init(world: WindowWorld) {
        self.world = world
    }

    func liveBounds(_ id: CGWindowID) -> CGRect? {
        world.liveBounds(id)
    }

    func surfaces(near x: CGFloat, footY: CGFloat) -> [(surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)] {
        world.surfaces(near: x, footY: footY)
    }

    func floorBeyond(edgeX: CGFloat, direction: CGFloat) -> (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)? {
        world.floorBeyond(edgeX: edgeX, direction: direction)
    }

    func workBox(at point: CGPoint) -> Screens.Box {
        Screens.workBox(containing: point)
    }

    func virtualBox() -> Screens.Box {
        Screens.virtualBox()
    }

    /// 用户无输入秒数（CGEventSource 硬件事件空闲计）。
    func idleSeconds() -> Double {
        MacSystemActivity.idleSeconds()
    }
}

/// 总装配：世界 → 决策脑/行动脑 → 身体 → 动画 → 面板，一条 40fps 的主循环串起来。
///
/// game-v2 决策环（game.md 架构）：
/// - **目标层**（45~90s / 到期 / 世界大变化）：决策脑出 Goal；没配 LLM
///   时 GoalPolicy 内置策略兜底 —— 零 LLM 也完整可玩；
/// - **场景层**（行动边界）：行动脑 Needle 在合法场景集里 choose_scene，
///   SceneBodyDriver 按配方步进执行（找锚点→走→跳→道具→表演→决策点）；
///   Needle 缺模型时 Autopilot 按人格加权随机选场景；
/// - **反射层**（<50ms，不进大脑）：摸头开心跳、连戳三下应激躲开；
///   事件进 recentEvents 供决策脑下一轮社会理解。
final class PetController {
    private enum PendingRuntimeAction {
        case semantic(NeedleBrain.SemanticAction)
        case random(PetIntent)
        case scene(
            SimulationNeedleAction,
            (Bool, SceneBodyDriver.BodyResultReporter?) -> Void
        )
    }

    let world: WindowWorld
    let systemWorld: SystemWorld
    let model: PetModel
    /// 运行时实体 ID。单宠物模式等于素材包 ID；角色组可用同一视觉包
    /// 渲染不同角色，因此必须由角色成员 ID 独立标识。
    let runtimeActorID: EntityID
    /// 随机脑：无模型成本，决策即时；场景玩法关闭时的兜底。
    let brain = RandomBrain()
    /// Needle 3 行动脑（模型缺失时 isAvailable == false）。
    let needle: NeedleBrain
    let animator: SpriteAnimator
    let library: ClipLibrary
    /// 动作运行时：verbs 唯一入口（大脑/菜单/前台跟随都走它）。
    let actions: ActionRuntime
    private(set) var settings: Settings

    /// 高层决策脑适配器：本地决策脑与高阶教师脑可独立启用。
    let teacherBrain: TeacherBrain
    let localBrain: LocalBrain
    /// 统一快照/并行调度器；本地脑负责运行时，教师脑负责训练标签。
    private(set) var goalBrainCoordinator: GoalBrainCoordinator!
    /// 内部状态（energy/boredom/stress…），与 BrainContextSnapshot 相对。
    private(set) var brainState = BrainState()
    /// 大脑的唯一世界边界快照来源。
    private(set) var lastWorldState: BrainContextSnapshot?
    /// 当前目标（决策脑/内置策略下达）。
    private(set) var currentGoal: Goal?
    /// 运行中的场景。
    private(set) var sceneRunner: SceneBodyDriver?
    /// 当前场景的空间根和角色根。道具通过它们挂接，不再自建一套坐标树。
    let sceneGraph: SceneGraph
    let actorNode: SceneNode
    /// 道具。
    let props: PropController
    /// 高层记忆。
    let memory = MemoryStore()
    /// 桌面程序与 headless harness 共用的确定性世界写入边界。
    /// AppKit/LLM 只投递事件，状态由 tick 内核消费。
    let gameplayRuntime: GameRuntime
    var gameplayKernel: GameKernel { gameplayRuntime.kernel }
    private let semanticPipeline: SemanticPipeline
    /// 角色组使用 CastRuntime 的共享 kernel，由 CastRuntime 统一推进时钟。
    private let usesSharedGameplayKernel: Bool
    /// 行动脑只提交语义请求。只有 Kernel 接受且计划世代仍有效时，
    /// 下一个 runtime pulse 才会让 AppKit 身体执行。
    private var pendingRuntimeActions: [String: PendingRuntimeAction] = [:]

    private let panel: OverlayPanel
    private let view: PetView
    /// 右键角色时的快速操作环；它只属于当前角色，不进入全局菜单。
    private let actionRing = ActionRingPanel()
    /// 多角色共用的空间登记表；单宠物/测试装配仍可传 nil。
    private let layoutCoordinator: SpatialLayoutCoordinator?
    /// 窗口/AX/OCR 是桌面级感知；多角色只共享采集结果，不共享各自内核。
    private let perception: PerceptionHub
    private var perceptionEventCursor: Int64 = 0
    private var lastWindowTitleFingerprint: String?
    private var handledForegroundRevision = 0
    private let puller = WindowPuller()
    /// 气泡（角色说话）。
    private let bubble = SpeechBubble()
    /// 世界事件环（进 BrainContextSnapshot.recentEvents）。
    private var recentEvents: [(t: Double, text: String)] = []
    private var lastWorldFingerprint = ""

    private var timer: Timer?
    private var lastTick = Date()
    private var pollAccumulator: Double = 0
    private var foregroundCooldown: Double = 0
    private var speechCooldown: Double = 0
    private var sceneCooldown: Double = 0
    /// 目标结束后的稳定窗口：避免清目标与下一次规划在同一批 tick 中来回抖动。
    private var goalCooldown: Double = 0
    /// 当前正在等待决策脑回调的 Trace；应用退出/切换宠物时也要收束它。
    private var pendingGoalTraceID: String?
    private var isStopped = false
    private var isDeparting = false
    /// 操作环打开期间暂停自动决策和移动，避免用户选动作时角色被脑路抢走。
    private var actionRingOpen = false
    /// Cast 生命周期的视觉过渡只改变面板表现，不改变 PetModel 的世界位姿。
    /// 这样 Core 已确认的布局仍是唯一空间真相，过渡结束后不会留下第二套坐标。
    private var castTransition: CastTransitionPlan?
    private var castTransitionStartedAt: TimeInterval?
    /// CastProjection 给出的最终面板框。多角色剧情中的人物—人物/机甲
    /// 附着必须在 AppKit 面板上可见，不能只留在 Core 的报告里。
    private var castPresentationFrame: LayoutRect?
    /// A direct user drag detaches this panel from the automatic cast layout.
    /// Rebuilding the cast restores managed placement.
    private var userDetachedFromCastLayout = false
    private var idleClip = ""
    private var idleSwapAt: Double = 0
    private var clock: Double = 0
    private var pullCursorStart: CGPoint?
    /// 内置决策的随机源（可复现测试）。
    var autopilotRng = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970))
    /// 距上次用户交互（摸头/戳）的秒数基准。
    private var lastInteractionAt: Double?
    /// 连戳检测窗口。
    private var pokeTimes: [Double] = []
    /// 目标下达时的活动语义（前台活动变了 → 重新规划）。
    private var goalActivity: AppActivity?
    private let characterDefinition: CharacterDefinition?
    private let declaredCapabilities: Set<String>?

    /// 窗口实时 bounds 查询要用的栖息窗口信息（拉窗时需要 owner/pid）。
    private var perchOwner: String = ""

    init(library: ClipLibrary, settings: Settings, spawnAt: CGPoint? = nil,
         actorID: EntityID? = nil,
         layoutCoordinator: SpatialLayoutCoordinator? = nil,
         perceptionHub: PerceptionHub? = nil,
         gameplayRuntime injectedRuntime: GameRuntime? = nil,
         sceneGraph injectedSceneGraph: SceneGraph? = nil,
         characterDefinition: CharacterDefinition? = nil,
         capabilities: [String]? = nil,
         needle: NeedleBrain? = nil,
         localBrain: LocalBrain? = nil,
         teacherBrain: TeacherBrain? = nil) {
        self.library = library
        self.settings = settings
        self.runtimeActorID = actorID ?? EntityID(library.characterID)
        self.layoutCoordinator = layoutCoordinator
        self.perception = perceptionHub ?? PerceptionHub(ownerID: actorID ?? EntityID(library.characterID))
        self.perceptionEventCursor = self.perception.latestInputSequence
        let runtime = injectedRuntime ?? GameRuntime(bodyExecutionMode: .external)
        self.gameplayRuntime = runtime
        self.semanticPipeline = SemanticPipeline(configuration: SemanticPipelineConfiguration(
            actorID: actorID ?? EntityID(library.characterID),
            enabled: false,
            assetCatalog: AssetCatalog(exactActions: Set(library.actionNames))))
        self.usesSharedGameplayKernel = injectedRuntime != nil
        self.characterDefinition = characterDefinition
        self.declaredCapabilities = capabilities.map(Set.init)
        self.needle = needle ?? NeedleBrain()
        self.localBrain = localBrain ?? LocalBrain()
        self.teacherBrain = teacherBrain ?? TeacherBrain()
        self.world = perception.world
        self.systemWorld = SystemWorld(world: world)
        self.animator = SpriteAnimator(library: library)
        let graph = injectedSceneGraph ?? SceneGraph(rootID: "scene")
        let actorNode = SceneNode(id: "actor:\(runtimeActorID.raw)")
        let handSocket = try! actorNode.addSocket("hand")
        try! graph.add(actorNode)
        self.sceneGraph = graph
        self.actorNode = actorNode
        if runtime.world.entities[runtimeActorID.raw] == nil {
            runtime.submit(GameEvent(
                kind: .registerEntity,
                entity: EntityState(id: runtimeActorID, kind: .actor)
            ), atTick: runtime.clock.tick)
        }
        self.props = PropController(library: library, sceneGraph: graph,
                                    actorNode: actorNode, handSocket: handSocket)
        props.userScale = settings.propScale

        let displayH = settings.displayHeight
        let displayW = library.cellSize.width / library.cellSize.height * displayH
        let startWork = Screens.workBox(containing: CGPoint(x: 0, y: 0))
        let startX = startWork.left + startWork.width * 0.62
        let startY = startWork.bottom - displayH
        let spawnPoint = spawnAt ?? CGPoint(x: startX, y: startY)

        self.model = PetModel(world: systemWorld, displayHeight: displayH, startAt: spawnPoint)
        model.spawn(onFloorAt: spawnPoint)
        self.actions = ActionRuntime(model: model, library: library)

        self.view = PetView(frame: NSRect(x: 0, y: 0, width: displayW, height: displayH))
        self.panel = OverlayPanel(contentView: view, initialFrame: NSRect(x: startX - displayW / 2, y: 0, width: displayW, height: displayH))

        wireView()
        goalBrainCoordinator = GoalBrainCoordinator(local: self.localBrain, teacher: self.teacherBrain)
        refreshGoalBrains()
        placePanel()
        pushFirstFrame()
        // 非激活面板不会自己上屏：不抢 key 也要 orderFront。
        panel.orderFrontRegardless()
    }

    func start() {
        isStopped = false
        isDeparting = false
        if isPerceptionOwner { perception.world.poll() }
        consumePerceptionEvents()
        // Cast 的 Runtime 与所有角色帧由 AppDelegate 的单一 driver 推进；
        // 角色不再各自创建 Timer。单宠物仍由自己的 panel driver 推进。
        guard !usesSharedGameplayKernel else { return }
        let t = Timer(timeInterval: 1.0 / 40.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 角色组入场后由 AppDelegate 调用；素材包没有专属入场 clip 时静默降级
    /// 到通用动作，生命周期状态仍由 CastRuntime 确认。
    func playArrival(style: CastArrivalStyle?) {
        isDeparting = false
        let plan = CastTransitionPlan.arrival(for: style)
        beginCastTransition(plan)
        let visual = plan.actionCandidates.lazy.compactMap(library.action(named:)).first ?? idlePrimary
        model.wake()
        actions.inject(.perform(visual), userInitiated: true)
    }

    /// 角色组离场先完成一个可见的语义节拍，再由 AppDelegate 收起面板。
    /// Core 已经确认角色死亡；这里仅是渲染过渡，不改变世界状态。
    func playDeparture(style: CastArrivalStyle?) {
        guard !isStopped else { return }
        isDeparting = true
        model.wake()
        cancelGoalAndScene(reason: "cast departure")
        let plan = CastTransitionPlan.departure(for: style)
        beginCastTransition(plan)
        let visual = plan.actionCandidates.lazy.compactMap(library.action(named:)).first ?? idlePrimary
        actions.inject(.perform(visual), userInitiated: true)
    }

    func cancelCastDeparture() {
        isDeparting = false
        castTransition = nil
        castTransitionStartedAt = nil
        panel.alphaValue = 1
        placePanel()
    }

    /// 播放角色组剧情节拍。剧情层只传语义 intent，不能越过身体动作入口
    /// 直接操作动画器；这里负责把跨角色通用词映射到当前 petpack 可用的
    /// 动作，并在需要时触发一条短台词。
    func performStoryIntent(
        _ intent: String,
        targetX: CGFloat? = nil,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard !isStopped else { completion(false); return }
        model.wake()
        model.stopWalk()
        cancelGoalAndScene(reason: "story beat")
        if let targetX {
            model.faceToward(targetX)
        }

        let normalized = intent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let semantic: ActionIntent
        switch normalized {
        case "run":
            semantic = .run
        case "turn":
            semantic = .turn
        case "jump_start":
            semantic = .jumpStart
        case "airborne":
            semantic = .airborne
        case "land":
            semantic = .land
        case "fall":
            semantic = .fall
        case "look":
            semantic = .look
        case "read":
            semantic = .propRead
        case "standby":
            semantic = .mechStandby
        case "think":
            semantic = .think
        case "observe":
            semantic = .windowLookOut
        case "complain":
            semantic = .complain
        case "face_other":
            semantic = .socialFace
        case "play", "practice":
            semantic = .happy
        case "protect", "comfort":
            semantic = .socialComfort
        case "launch":
            semantic = .mechActivate
        case "greet", "invite":
            semantic = .greet
        case "climb", "climb_up":
            semantic = .windowClimb
        case "jump_to_sill":
            semantic = .windowJumpToSill
        case "climb_down":
            semantic = .windowClimbDown
        case "pull_up":
            semantic = .windowPullUp
        case "hang", "hang_edge":
            semantic = .windowHang
        case "peek", "peek_over", "peek_at_user":
            semantic = .windowPeek
        case "sit", "sit_sill", "perch":
            semantic = .windowSit
        case "lean", "lean_sill":
            semantic = .windowLean
        case "look_out":
            semantic = .windowLookOut
        case "drop_from_sill":
            semantic = .windowDropFromSill
        case "reach":
            semantic = .propReach
        case "take", "pick_up":
            semantic = .propTake
        case "hold":
            semantic = .propHold
        case "carry":
            semantic = .propCarry
        case "inspect", "read_prop":
            semantic = .propInspect
        case "type":
            semantic = .propType
        case "drink":
            semantic = .propDrink
        case "eat":
            semantic = .propEat
        case "play_prop":
            semantic = .propPlay
        case "use":
            semantic = .propUse
        case "place", "put_down":
            semantic = .propPlace
        case "push":
            semantic = .propPush
        case "pull":
            semantic = .propPull
        case "throw", "toss":
            semantic = .propThrow
        case "give", "hand_over", "offer":
            semantic = .propGive
        case "receive":
            semantic = .propReceive
        case "look_at":
            semantic = .socialLookAt
        case "approach_other":
            semantic = .socialApproach
        case "talk":
            semantic = .socialTalk
        case "listen":
            semantic = .socialListen
        case "follow":
            semantic = .socialFollow
        case "greet_other":
            semantic = .socialGreet
        case "high_five":
            semantic = .socialHighFive
        case "touch":
            semantic = .socialTouch
        case "tease_other":
            semantic = .socialTease
        case "hug":
            semantic = .socialHug
        case "argue", "challenge":
            semantic = .socialArgue
        case "activate":
            semantic = .mechActivate
        case "deactivate":
            semantic = .mechDeactivate
        case "signal":
            semantic = .mechSignal
        case "move":
            semantic = .mechMove
        case "damage":
            semantic = .mechDamage
        case "guard", "protect_mech":
            semantic = .mechGuard
        case "respond":
            semantic = .mechRespond
        case "enter_cockpit":
            semantic = .mechEnterCockpit
        case "exit_cockpit":
            semantic = .mechExitCockpit
        default:
            // 未知剧情词仍然有一个确定的视觉降级，不让一个新剧本让角色静默。
            semantic = .think
        }
        let key = ActionCatalog.resolve(semantic, available: library.actionNames)
            .flatMap(library.action(named:)) ?? idlePrimary
        if !key.isEmpty {
            scenePerform([key]) { completion(true) }
        } else {
            // Missing presentation content is a content degradation, not a
            // failure of the committed story logic.
            completion(true)
        }

        if let speech = storySpeechIntent(normalized) {
            speak(intent: speech)
        }
    }

    private func storySpeechIntent(_ intent: String) -> SpeechIntent? {
        switch intent {
        case "talk", "greet_other", "greet", "invite": return .greet
        case "argue", "challenge": return .tease
        case "comfort", "protect": return .commentActivity
        case "face_other": return .chatter
        default: return nil
        }
    }

    /// 共享空间登记变化后重新把 AppKit 面板放到安全框。
    func relayout() {
        guard !isStopped else { return }
        placePanel()
    }

    /// Apply the shared CastVisualProjection frame. `nil` returns the controller
    /// to its ordinary PetModel/SpatialLayoutCoordinator placement path.
    func applyCastProjectionFrame(_ frame: LayoutRect?) {
        guard !isStopped else { return }
        guard !userDetachedFromCastLayout, model.state != .dragged else { return }
        castPresentationFrame = frame
        placePanel()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        goalBrainCoordinator.cancelPendingPlan()
        isDeparting = false
        castTransition = nil
        castTransitionStartedAt = nil
        panel.alphaValue = 1
        timer?.invalidate()
        timer = nil
        cancelPendingRuntimeActions()
        layoutCoordinator?.remove(runtimeActorID)
        // A shared Cast graph must not retain a departed actor root. Props are
        // cleared by closePanel, while this removes the actor/socket container
        // itself so a later invitation cannot collide with the old node ID.
        try? actorNode.reparent(to: nil, keepWorldTransform: true)
        // 停止主循环不会自动结束目标/场景；显式写终态，避免退出或切换宠物
        // 留下一条永久“未收束”的脑路。
        if currentGoal != nil {
            clearGoal(reason: "application terminated")
        } else if let pendingTrace = pendingGoalTraceID {
            logGoalOutcome(goal: nil, scene: nil, stayed: 0,
                           completed: false, reason: "application terminated",
                           traceID: pendingTrace)
            pendingGoalTraceID = nil
        } else if sceneRunner != nil {
            abortScene(reason: "application terminated")
        }
        actionRing.dismiss()
        actionRingOpen = false
    }

    /// 切换宠物时收起旧面板（定时器停了不代表窗口会自己消失）。
    func closePanel() {
        actionRing.dismiss()
        actionRingOpen = false
        panel.alphaValue = 1
        panel.orderOut(nil)
        bubble.dismiss()
        props.clear()
    }

    /// 当前宠物脚下位置（切宠物原地换装用）。
    var petPosition: CGPoint {
        CGPoint(x: model.x, y: model.yFeet)
    }

    // ============ 主循环 ============

    @objc func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        clock += dt

        // 感知只提交事件；单宠物的语义工作与 Kernel 推进由同一个
        // GameRuntime pulse 排序。Cast 的 pulse 由 CastRuntime 唯一拥有。
        consumePerceptionEvents()

        pollAccumulator += dt
        if pollAccumulator >= 0.3 {
            pollAccumulator = 0
            let fingerprintBefore = lastWorldFingerprint
            if isPerceptionOwner { perception.world.poll() }
            refreshSenses()
            refreshWorldState()
            let changed = lastWorldFingerprint != fingerprintBefore
            brainState.tick(
                dt: 0.3,  // 轮询周期即步长
                worldChanged: changed,
                isAsleep: model.state == .asleep,
                isMoving: model.walking,
                personality: personality)
            checkNeedThresholds()
        }
        foregroundCooldown = max(0, foregroundCooldown - dt)
        speechCooldown = max(0, speechCooldown - dt)
        sceneCooldown = max(0, sceneCooldown - dt)
        goalCooldown = max(0, goalCooldown - dt)

        // 右键操作环是一个短暂的直接操控态。角色停在当前位姿，自动脑、
        // 场景和移动都暂时让出控制权；关闭环后下一帧自然恢复规划。
        if actionRingOpen {
            if !usesSharedGameplayKernel { _ = gameplayRuntime.step() }
            model.stopWalk()
            placePanel()
            renderFrame(dt: 0)
            return
        }

        updateSleepState()
        if !usesSharedGameplayKernel {
            _ = gameplayRuntime.step { [weak self] _ in
                self?.drainCommittedRuntimeActions()
                self?.driveMind()
            }
        }
        tickStartle()
        tickSceneMove()
        tickScenePerform()
        model.update(dtIn: dt)
        actions.tick(now: clock)
        gameplayRuntime.updateBodyPose(BodyPose(
            actorID: runtimeActorID,
            x: Double(model.x),
            yFeet: Double(model.yFeet),
            facingRight: model.facingRight,
            motion: String(describing: model.state),
            action: actions.performance?.clipKey))
        placePanel()
        renderFrame(dt: dt)
        // 道具在物理/渲染之后推进：held 走合成层（本帧坐标已定），
        // placed/补间/淡出走自己的独立窗口。
        props.tick(petX: model.x, petYFeet: model.yFeet, facingRight: model.facingRight,
                   displayHeight: settings.displayHeight, now: clock)
        if let layout = props.heldLayout(displayHeight: settings.displayHeight) {
            view.displayProp(image: layout.image, rect: layout.rect)
        } else {
            view.displayProp(image: nil, rect: .zero)
        }
    }

    private var displayHeadOffset: CGFloat { settings.displayHeight * 0.15 }

    /// 当前人格（供策略/prompt/测试）。
    var personality: Personality {
        characterDefinition.map(Personality.forDefinition) ?? Personality.forCharacter(library.characterID)
    }

    // ---- 决策脑配置（brain-local.md §2：两个适配器独立、可并行） ----

    /// 刷新本地决策脑与高阶教师脑。两个脑收到同一份 GoalBrainInput；
    /// 本地脑的有效结果驱动游戏，教师脑的有效结果只作为最终训练标签。
    private func refreshGoalBrains() {
        let teacherReady = TeacherBrain.config(
            settingsBaseURL: settings.teacherBrainBaseURL,
            settingsModel: settings.teacherBrainModel,
            settingsKey: settings.teacherBrainAPIKey,
            planSampling: TeacherBrain.PlanSampling(
                temperature: boundedSampling(settings.teacherBrainTemperature, fallback: 0.8,
                                             lower: 0, upper: 2),
                topP: boundedSampling(settings.teacherBrainTopP, fallback: 1.0,
                                      lower: 0, upper: 1),
                topK: max(0, settings.teacherBrainTopK),
                maxTokens: max(1, settings.teacherBrainMaxTokens),
                seed: settings.teacherBrainSeed,
                reasoningEffort: settings.teacherBrainReasoningEffort))
        teacherBrain.config = teacherReady
        BrainTraceLog.setEnabled(settings.brainTraceEnabled)
        localBrain.configure(.init(
            goalSampling: .init(
                temperature: boundedSampling(settings.localBrainGoalTemperature, fallback: 0.0,
                                             lower: 0, upper: 2),
                topP: boundedSampling(settings.localBrainGoalTopP, fallback: 1.0,
                                      lower: 0, upper: 1),
                topK: max(0, settings.localBrainGoalTopK),
                maxTokens: max(1, settings.localBrainGoalMaxTokens),
                seed: settings.localBrainGoalSeed),
            chatSampling: .init(
                temperature: boundedSampling(settings.localBrainChatTemperature, fallback: 0.3,
                                             lower: 0, upper: 2),
                topP: boundedSampling(settings.localBrainChatTopP, fallback: 0.8,
                                      lower: 0, upper: 1),
                topK: max(0, settings.localBrainChatTopK),
                maxTokens: max(1, settings.localBrainChatMaxTokens),
                seed: settings.localBrainChatSeed)))
        needle.interval = validatedInterval(minimum: settings.actionBrainMinInterval,
                                            maximum: settings.actionBrainMaxInterval,
                                            fallback: NeedleBrain.defaultInterval)
        needle.maxNewTokens = max(1, settings.actionBrainMaxTokens)
        goalBrainCoordinator.configure(
            localEnabled: settings.localBrainEnabled,
            teacherEnabled: settings.teacherBrainEnabled,
            interval: validatedInterval(minimum: settings.goalBrainMinInterval,
                                         maximum: settings.goalBrainMaxInterval,
                                         fallback: 45...90))
        NSLog("MyPet: 决策脑 = %@ · 教师标签 = %@ · 行动脑 = %@",
              settings.localBrainEnabled ? (LocalBrainModel.isInstalled ? "本地" : "本地缺模型") : "关闭",
              settings.teacherBrainEnabled ? (teacherReady == nil ? "配置不完整" : "高阶教师脑") : "关闭",
              settings.actionBrainEnabled ? (needle.isAvailable ? "Needle 3" : "缺模型") : "关闭")
    }

    private func validatedInterval(minimum: Double, maximum: Double,
                                   fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        let lower = minimum.isFinite ? Swift.max(0, minimum) : fallback.lowerBound
        let upper = maximum.isFinite ? Swift.max(lower, maximum) : fallback.upperBound
        return lower...upper
    }

    private func boundedSampling(_ value: Double, fallback: Double,
                                 lower: Double, upper: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(upper, max(lower, value))
    }

    // ---- §5.4 需求越阈触发（不做无脑轮询的另一半：阈值突破才提前规划） ----

    private var needFlags = (energyLow: false, boredomHigh: false, stressHigh: false)

    private func checkNeedThresholds() {
        let energyLow = brainState.energy < 0.22
        let boredomHigh = brainState.boredom > 0.85
        let stressHigh = brainState.stress > 0.6
        if energyLow != needFlags.energyLow || boredomHigh != needFlags.boredomHigh
            || stressHigh != needFlags.stressHigh {
            if energyLow && !needFlags.energyLow { pushRecentEvent("need crossed: energy low") }
            if boredomHigh && !needFlags.boredomHigh { pushRecentEvent("need crossed: boredom high") }
            if stressHigh && !needFlags.stressHigh { pushRecentEvent("need crossed: stress high") }
            goalBrainCoordinator.expedite()
        }
        needFlags = (energyLow, boredomHigh, stressHigh)
    }

    // ---- 睡眠 ----

    private func updateSleepState() {
        let idle = systemWorld.idleSeconds()
        if idle > PetModel.napAfterIdle && model.state != .asleep && model.state != .dragged && model.state != .tossed {
            model.sleep()
            brainState.apply(event: .slept, now: clock)
        } else if idle < 1.0 && model.state == .asleep {
            model.wake()
            brainState.apply(event: .woke, now: clock)
        }
    }

    // ============ 决策环（目标层 → 场景层 → 随机兜底） ============

    private func driveMind() {
        guard !isDeparting else { return }
        // 一次语义行动必须先经 Kernel 仲裁并落下终态，避免异步脑
        // 在相邻帧重复提交同一身体动作。
        guard pendingRuntimeActions.isEmpty else { return }
        // 表演收尾：once 型播完（isFinished）由这里清掉。
        if let p = actions.performance, p.endsAt == nil,
           animator.clipName == p.clipKey, animator.isFinished {
            actions.cancelPerformance()
        }

        // 0. 世界大变化（game.md §17）：前台活动类别变了，正在做的事失去语境——
        //    无论是否在场景中都立即停下（清道具、清目标），决策脑/行动脑都提前触发。
        checkWorldChangeInterrupt()
        // 0.5 「角色无聊了」（game.md §5 触发器）：休息中无聊见顶 → 醒着无聊就别躺了。
        if currentGoal?.kind == .rest,
           GoalPolicy.shouldInterruptRest(energy: brainState.energy, boredom: brainState.boredom) {
            clearGoal(reason: "bored of resting")
        }

        // 用户抓起宠物 = 目标作废（反射优先于一切意图）。
        if model.state == .dragged { clearGoal(reason: "user grabbed"); return }

        let busy = model.state == .airborne || model.state == .dragged
            || model.state == .tossed || model.walking
        // 场景运行中：行动权在场景（busy 时只推 tick，让等待相位自然计时）。
        if let runner = sceneRunner {
            runner.tick(now: clock)
            if !runner.isActive { finishScene() }
            return
        }
        guard !busy, actions.performance == nil else { return }

        // 1. 目标层
        if let goal = currentGoal, goal.expired(at: clock) {
            clearGoal(reason: "expired")
        }
        if currentGoal == nil {
            guard goalCooldown <= 0 else { return }
            planGoal()
            return
        }

        // 2. 场景层：行动脑选场景（或 Autopilot 兜底），场景没就绪的冷却期发呆。
        guard sceneCooldown <= 0 else { return }
        if settings.actionBrainEnabled, needle.isAvailable {
            askNeedleForScene()
            return
        }
        if settings.scenesEnabled {
            autopilotPickScene()
            sceneCooldown = 2
            return
        }

        // 3. 随机脑兜底（场景玩法整体关闭时的经典模式）。
        driveRandom()
    }

    /// 经典随机脑路径（v0 兼容；scenesEnabled == false 时使用）。
    private func driveRandom() {
        guard brain.isDue(now: clock) else { return }
        let decision = brain.decide(pet: model, world: world, library: library, now: clock)
        var facts = makeWorldFacts()
        facts.mode = .ambient
        let reason = "scenes_disabled_or_needle_disabled"
        switch decision {
        case .stroll(let target):
            NeedleBrain.logFallback(facts: facts, chosen: "move_to(\(Int(target)))",
                                    mode: "random", reason: reason)
        case .walkAlong:
            NeedleBrain.logFallback(facts: facts, chosen: "walk_along()",
                                    mode: "random", reason: reason)
        case .gesture(let clip):
            NeedleBrain.logFallback(facts: facts, chosen: "perform(\(clip))",
                                    mode: "random", reason: reason)
        case .leap(let w):
            NeedleBrain.logFallback(facts: facts, chosen: "perch(\(w.id))",
                                    mode: "random", reason: reason)
        case .hop:
            NeedleBrain.logFallback(facts: facts, chosen: "hop()",
                                    mode: "random", reason: reason)
        case .dropOff:
            NeedleBrain.logFallback(facts: facts, chosen: "drop_off()",
                                    mode: "random", reason: reason)
        case .nothing:
            NeedleBrain.logFallback(facts: facts, chosen: "wait()",
                                    mode: "random", reason: reason)
        }
        let execution = semanticPipeline.actionRuntime.execute(
            semanticBodyAction(for: decision),
            tick: gameplayRuntime.clock.tick,
            actorID: runtimeActorID,
            world: gameplayRuntime.world,
            context: runtimeContext())
        submitRuntimeAction(.random(decision), execution: execution)
    }

    // ---- 目标层 ----

    /// 目标规划：本地决策脑/高阶教师脑可并行；本地脑优先驱动游戏，
    /// 教师脑独立产出训练标签；没有可用决策脑时走内置策略。
    private func planGoal() {
        guard let ws = lastWorldState else { return }
        let traceID = UUID().uuidString
        let input = GoalBrainInput(
            petID: runtimeActorID.raw,
            world: ws,
            brain: brainState,
            personality: personality,
            memory: memory.promptLines(),
            traceID: traceID)
        pendingGoalTraceID = traceID
        let dispatched = goalBrainCoordinator.maybePlan(now: clock, input: input) { [weak self] decision, source in
            guard let self else { return }
            self.pendingGoalTraceID = nil
            guard !self.isStopped else { return }
            if let decision {
                self.adopt(decision: decision, traceID: traceID,
                           source: source?.rawValue ?? "teacher")
            } else {
                self.adoptPolicyGoal(traceID: traceID,
                                    reason: "goal_brain_failed_or_rejected")
            }
        }
        if !dispatched {
            pendingGoalTraceID = nil
            guard !goalBrainCoordinator.isPending else { return }
            if goalBrainCoordinator.activeSources.isEmpty {
                adoptPolicyGoal(traceID: traceID, reason: "goal_brains_unavailable")
            }
            // 有可用决策脑但尚未到下一次规划时机：保持无目标状态，等待调度器。
        }
    }

    /// 内置目标策略（零 LLM 完整玩法的关键）。
    private func adoptPolicyGoal(traceID: String = UUID().uuidString,
                                reason: String = "goal_brains_unavailable") {
        var rng = autopilotRng
        defer { autopilotRng = rng }
        let ctx = GoalPolicy.Context(
            brain: brainState,
            personality: personality,
            userActivity: world.foreground?.appActivity ?? .unknown,
            userIdleSeconds: systemWorld.idleSeconds(),
            hasWindows: !world.windows.isEmpty,
            secondsSinceInteraction: lastInteractionAt.map { clock - $0 },
            now: clock)
        var goal = GoalPolicy.decide(ctx, rng: &rng)
        goal.traceID = traceID
        if let ws = lastWorldState {
            BrainDecisionLog.logPolicy(world: ws, brain: brainState, goal: goal,
                                   personality: personality, memory: memory.promptLines(),
                                   traceID: traceID, reason: reason)
        }
        adopt(goal: goal)
    }

    /// 决策脑结果落地；source 只记录运行时来源，不改变教师标签的独立记录。
    private func adopt(decision: GoalDecision, traceID: String, source: String) {
        let goal = Goal(
            kind: decision.goal,
            target: decision.target,
            activity: decision.activity.flatMap(AppActivity.init(rawValue:)),
            style: decision.style,
            issuedAt: clock,
            source: source,
            traceID: traceID)
        adopt(goal: goal)
        if let intent = decision.speechIntent {
            // 目标 JSON 只出意图枚举；聊天 JSON 由 requestSpeech 单独生成。
            speakBuiltin(intent)
        } else if let line = decision.clippedSpeech {
            showSpeech(line)
        }
        if let mem = decision.memory {
            memory.add(kind: "event", text: mem, traceID: traceID)
        }
    }

    private func adopt(goal: Goal) {
        currentGoal = goal
        goalActivity = goal.activity
        brainState.adopt(goal: goal, now: clock)
        pushRecentEvent("goal: \(goal.kind.rawValue)\(goal.activity.map { " (\($0.rawValue))" } ?? "")")
    }

    private func clearGoal(reason: String) {
        guard let goal = currentGoal else { return }
        pushRecentEvent("goal cleared: \(reason)")
        // 先结束场景再清目标，确保 outcome 与原目标共享同一个 trace_id。
        let hadScene = sceneRunner != nil
        abortScene(reason: "goal \(reason)")
        // 目标可能尚未进入场景（例如刚规划完就被拖拽/世界切换）。
        // 这类目标也必须有终态，否则查看器只能把它永久显示为“未收束”。
        if !hadScene {
            logGoalOutcome(goal: goal, scene: nil, stayed: 0,
                           completed: false, reason: "goal \(reason)")
        }
        goalCooldown = max(goalCooldown, 1.5)
        currentGoal = nil
        goalActivity = nil
        brainState.clearGoal()
    }

    /// 用户/行动脑主动接管时，同时终止当前场景和它所属的目标。
    /// 没有目标但仍有挂起场景时，保留纯场景中断路径。
    private func cancelGoalAndScene(reason: String) {
        goalBrainCoordinator.cancelPendingPlan()
        cancelPendingRuntimeActions()
        if reason.localizedCaseInsensitiveContains("user") ||
            reason.localizedCaseInsensitiveContains("grab") {
            gameplayRuntime.submitPlatform(PlatformEvent(GameEvent(
                kind: .userInteraction,
                actorID: runtimeActorID,
                userAction: reason)))
        }
        if let pendingTrace = pendingGoalTraceID {
            logGoalOutcome(goal: nil, scene: nil, stayed: 0,
                           completed: false, reason: reason, traceID: pendingTrace)
            pendingGoalTraceID = nil
        }
        if currentGoal != nil {
            clearGoal(reason: reason)
        } else {
            abortScene(reason: reason)
        }
    }

    /// 前台活动类别变化 = 目标语境失效（game.md §5「用户切换主要活动」、§17 示例）。
    /// 场景运行中也生效：正在做的事立即停下，决策脑/行动脑都提前触发。
    private func checkWorldChangeInterrupt() {
        guard let goal = currentGoal, goal.kind.targetsUser else { return }
        guard let wanted = goalActivity, wanted != .unknown else { return }
        guard let fg = world.foreground, fg.appActivity != wanted else { return }
        goalBrainCoordinator.expedite()
        needle.expedite()
        clearGoal(reason: "world changed: \(wanted.rawValue) → \(fg.appActivity.rawValue)")
    }

    // ---- 场景层 ----

    /// 行动脑选场景（冷却由 Needle 自身节奏控制）。
    private func askNeedleForScene() {
        var facts = makeWorldFacts()
        facts.mode = .ambient
        needle.maybeDecide(now: clock, facts: facts) { [weak self] semantic, _ in
            guard let self else { return }
            guard let semantic else {
                // 决策失败：这轮交给 Autopilot，保证玩法不中断。
                if self.settings.scenesEnabled { self.autopilotPickScene() }
                return
            }
            self.apply(semantic)
        }
    }

    /// Autopilot：人格加权的场景兜底（Needle 缺模型/失败时）。
    private func autopilotPickScene() {
        guard let goal = currentGoal else { return }
        let userBusy = GoalPolicy.isBusy(.init(
            brain: brainState, personality: personality,
            userActivity: world.foreground?.appActivity ?? .unknown,
            userIdleSeconds: systemWorld.idleSeconds(),
            hasWindows: !world.windows.isEmpty,
            secondsSinceInteraction: nil, now: clock))
        let pool = SceneCatalog.compatible(goal: goal,
                                           activity: world.foreground?.appActivity ?? .unknown,
                                           personality: personality,
                                           userBusy: userBusy)
        guard !pool.isEmpty else { sceneCooldown = 5; return }
        var rng = autopilotRng
        defer { autopilotRng = rng }
        let recipe = pool[Int.random(in: 0..<pool.count, using: &rng)]
        var facts = makeWorldFacts()
        facts.mode = .ambient
        NeedleBrain.logFallback(
            facts: facts,
            chosen: "choose_scene(\(recipe.id))",
            mode: "autopilot",
            reason: "needle_unavailable_or_failed")
        apply(.chooseScene(recipe.id))
    }

    private func beginScene(_ recipe: SceneRecipe) {
        let runner = SceneBodyDriver(
            recipe: recipe,
            goal: currentGoal?.semanticDecision(atTick: gameplayRuntime.clock.tick),
            semanticRunner: semanticPipeline.sceneRunner,
            authorize: { [weak self] action, completion in
                guard let self else { completion(false, nil); return }
                self.authorizeSceneAction(action, completion: completion)
            })
        // "@activity" 锚点绑定：优先前台窗口，其次最近的活动匹配窗口。
        let activity = currentGoal?.activity ?? world.foreground?.appActivity
        let activityWindow: WindowEntity? = {
            if let fg = world.foreground, activity == nil || fg.appActivity == activity { return fg }
            return world.windows.first { $0.appActivity == activity }
        }()
        runner.start(stage: self, activityWindow: activityWindow, now: clock)
        sceneRunner = runner
        pushRecentEvent("scene: \(recipe.id)")
    }

    private func finishScene() {
        guard let runner = sceneRunner else { return }
        let stayed = stayedSeconds(since: runner.startedAt)
        brainState.apply(event: .sceneFinished(scene: runner.recipe.id, stayedSeconds: stayed), now: clock)
        brainState.lastActivity = runner.recipe.id
        // 结局先记（currentGoal 还在），再清目标。
        logSceneOutcome(runner: runner, stayed: stayed, completed: runner.completed,
                        reason: runner.completed ? "finished" : "aborted")
        // 无论是正常完成还是执行层中断，这个场景对应的目标都已经结束。
        // 保留目标会让下一帧继续拿同一目标启动新场景，形成重复决策和孤立链路。
        currentGoal = nil
        goalActivity = nil
        brainState.clearGoal()
        goalCooldown = max(goalCooldown, 1.5)
        sceneRunner = nil
        sceneCooldown = 2
        sceneMoveDone = nil
        sceneMoveTarget = nil
        scenePerformDone = nil
        // 自然收场：手里还有道具就放在原地（真实感——宠物去别处，东西待在原处，
        // 滞留 placedDefaultTTL 后自己淡出）；placed 的道具不动，继续自己的倒计时。
        if props.isHolding {
            props.putDown(at: model.x, footY: model.yFeet, now: clock)
        }
    }

    private func abortScene(reason: String = "interrupted") {
        guard let runner = sceneRunner else {
            // 没场景也可能有挂起的场景移动（Needle 的 move_to 语义）。
            sceneMoveDone = nil
            sceneMoveTarget = nil
            scenePerformDone = nil
            return
        }
        runner.abort()
        brainState.lastActivity = runner.recipe.id
        logSceneOutcome(runner: runner, stayed: stayedSeconds(since: runner.startedAt),
                        completed: false, reason: reason)
        sceneRunner = nil
        sceneMoveDone = nil
        sceneMoveTarget = nil
        scenePerformDone = nil
        sceneCooldown = 1.5
        // 中断收场：道具淡出（不瞬间消失，视觉不跳变）。
        props.despawn(now: clock)
    }

    /// game.md §16：goal/场景的轨迹 + 结局是训练数据的关键 label，
    /// 与规划决策同文件（brain_trace.jsonl，kind=outcome，完整保留本地业务上下文）。
    private func logSceneOutcome(runner: SceneBodyDriver, stayed: Double, completed: Bool, reason: String) {
        logGoalOutcome(goal: currentGoal, scene: runner.recipe.id, stayed: stayed,
                       completed: completed, reason: reason)
    }

    private func logGoalOutcome(goal: Goal?, scene: String?, stayed: Double,
                                completed: Bool, reason: String, traceID: String? = nil) {
        let record = BrainDecisionLog.outcomeRecord(
            goalKind: goal?.kind.rawValue,
            goalSource: goal?.source,
            scene: scene,
            stayedSeconds: stayed,
            completed: completed,
            reason: reason,
            interruptedByUser: reason.localizedCaseInsensitiveContains("user")
                || reason.localizedCaseInsensitiveContains("grab"),
            personalityStyle: personality.styleWord,
            memoryCount: memory.entries.count,
            activeApp: lastWorldState?.activeApp ?? "",
            activity: goal?.activity?.rawValue,
            traceID: traceID ?? goal?.traceID)
        BrainDecisionLog.logOutcome(record)
    }

    /// 控制器时钟下的时长（runner.startedAt 同源）。
    private func stayedSeconds(since start: Double) -> Double {
        max(0, clock - start)
    }

    // ---- Needle 语义动作 → 身体 ----

    /// 语义动作先进入共享 Kernel；表现层不再直接接受模型结果。
    private func apply(_ semantic: NeedleBrain.SemanticAction) {
        let execution = semanticPipeline.actionRuntime.execute(
            semantic,
            tick: gameplayRuntime.clock.tick,
            actorID: runtimeActorID,
            world: gameplayRuntime.world,
            context: runtimeContext())
        submitRuntimeAction(.semantic(semantic), execution: execution)
    }

    private func runtimeContext() -> RuntimeContext {
        RuntimeContext(focus: world.foreground.map {
            RuntimeContext.Focus(
                id: EntityID(String($0.id)), app: $0.owner,
                title: $0.windowTitle, activity: $0.appActivity.rawValue)
        })
    }

    private func submitRuntimeAction(
        _ action: PendingRuntimeAction,
        execution: ActionExecution
    ) {
        guard execution.accepted, let request = execution.request else { return }
        let id = request.id
        pendingRuntimeActions[id] = action
        gameplayRuntime.submit(GameEvent(kind: .behaviorRequest, request: request))
    }

    private func cancelPendingRuntimeActions() {
        let pending = pendingRuntimeActions
        pendingRuntimeActions.removeAll()
        for (id, action) in pending {
            gameplayRuntime.submitBodyResult(BodyResult(behaviorID: id, outcome: .cancelled))
            if case .scene(_, let completion) = action { completion(false, nil) }
        }
    }

    private func authorizeSceneAction(
        _ action: SimulationNeedleAction,
        completion: @escaping (Bool, SceneBodyDriver.BodyResultReporter?) -> Void
    ) {
        let execution = semanticPipeline.actionRuntime.execute(
            action,
            tick: gameplayRuntime.clock.tick,
            actorID: runtimeActorID,
            world: gameplayRuntime.world,
            context: runtimeContext())
        guard execution.accepted else { completion(false, nil); return }
        guard let request = execution.request else {
            // Missing optional content is a valid degradation, not a logic
            // failure; the body driver will skip the unavailable clip.
            completion(true, nil)
            return
        }
        pendingRuntimeActions[request.id] = .scene(action, completion)
        gameplayRuntime.submit(GameEvent(kind: .behaviorRequest, request: request))
    }

    /// 只消费 Engine 发出的一次性 BodyCommand。命令执行完毕后，生产身体
    /// 必须把结果送回同一事件入口；Kernel 不再用计时器冒充物理完成。
    private func drainCommittedRuntimeActions() {
        for command in gameplayRuntime.drainBodyCommands(for: runtimeActorID) {
            guard let action = pendingRuntimeActions.removeValue(forKey: command.behaviorID) else {
                gameplayRuntime.submitBodyResult(BodyResult(
                    behaviorID: command.behaviorID, outcome: .cancelled))
                continue
            }
            guard gameplayRuntime.world.planEpochs[runtimeActorID.raw, default: 0]
                    == command.planEpoch else {
                gameplayRuntime.submitBodyResult(BodyResult(
                    behaviorID: command.behaviorID, outcome: .cancelled))
                if case .scene(_, let completion) = action { completion(false, nil) }
                continue
            }
            let report: SceneBodyDriver.BodyResultReporter = { [weak self] success in
                self?.gameplayRuntime.submitBodyResult(BodyResult(
                    behaviorID: command.behaviorID,
                    outcome: success ? .completed : .failed))
            }
            executeCommitted(action, report: report)
        }
        let terminal = pendingRuntimeActions.keys.filter { id in
            guard let status = gameplayRuntime.world.behaviors[id]?.status else { return false }
            return status == .cancelled || status == .rejected
        }
        for id in terminal {
            if case .scene(_, let completion) = pendingRuntimeActions.removeValue(forKey: id) {
                completion(false, nil)
            } else {
                pendingRuntimeActions[id] = nil
            }
        }
    }

    private func semanticBodyAction(for intent: PetIntent) -> SimulationNeedleAction {
        switch intent {
        case .stroll(let target): return .body(.moveToPoint(Double(target)))
        case .walkAlong: return .body(.walkAlong)
        case .gesture(let clip): return .perform(clip)
        case .leap(let window): return .body(.perch(String(window.id)))
        case .hop: return .body(.hop)
        case .dropOff: return .body(.dropOff)
        case .nothing: return .wait
        }
    }

    private func executeCommitted(
        _ action: PendingRuntimeAction,
        report: @escaping SceneBodyDriver.BodyResultReporter
    ) {
        switch action {
        case .semantic(let semantic): executeCommitted(semantic, report: report)
        case .random(let intent): executeCommitted(intent, report: report)
        case .scene(_, let completion): completion(true, report)
        }
    }

    private func executeCommitted(
        _ intent: PetIntent,
        report: @escaping SceneBodyDriver.BodyResultReporter
    ) {
        switch intent {
        case .stroll(let target):
            sceneMove(toX: target, top: false, window: nil) { report(true) }
        case .walkAlong:
            model.startWalk(CGFloat.random(in: 0..<1) < 0.5 ? -1 : 1)
            report(true)
        case .gesture(let clip):
            scenePerform([clip]) { report(true) }
        case .leap(let window):
            guard settings.perchingEnabled else { report(false); return }
            sceneMove(toX: window.bounds.midX, top: true, window: window) { report(true) }
        case .hop, .dropOff:
            model.hop()
            report(true)
        case .nothing:
            report(true)
        }
    }

    /// Kernel 承诺后的平台适配：从此开始才允许操作 AppKit/精灵身体。
    private func executeCommitted(
        _ semantic: NeedleBrain.SemanticAction,
        report: @escaping SceneBodyDriver.BodyResultReporter
    ) {
        switch semantic {
        case .chooseScene(let id):
            guard let recipe = SceneCatalog.recipe(id: id) else { report(false); return }
            beginScene(recipe)
            report(true)
        case .moveTo(let text):
            guard let resolved = resolveAnchor(text) else { report(false); return }
            sceneMove(toX: resolved.x, top: resolved.top, window: resolved.window) { report(true) }
        case .spawnProp(let id):
            guard settings.propsEnabled else { report(false); return }
            model.wake()
            props.spawnHeld(id, petX: model.x, petYFeet: model.yFeet,
                            facingRight: model.facingRight, now: clock)
            report(true)
        case .putDown:
            report(semanticPutDown())
        case .pickUp:
            report(semanticPickUp())
        case .perform(let name):
            guard let key = library.action(named: name) else { report(false); return }
            scenePerform([key]) { report(true) }
        case .performCandidates(let names):
            guard let key = names.lazy.compactMap({ self.library.action(named: $0) }).first else {
                report(false)
                return
            }
            scenePerform([key]) { report(true) }
        case .clearProps:
            props.clear()
            report(true)
        case .say(let intent):
            if let intent = SpeechIntent(rawValue: intent) { speak(intent: intent) }
            report(true)
        case .leaveScene:
            cancelGoalAndScene(reason: "action brain left scene")
            report(true)
        case .sleep:
            actions.inject(.sleep)
            report(true)
        case .wait:
            report(true)
        case .body:
            report(false)
        }
    }

    /// 放下（行动脑语义/场景共用）：手部 → 身前地面滑落 + 点头节拍。
    /// 包里有真 pick_up/put_down clip 的角色将来自动换成专用动画。
    @discardableResult
    private func semanticPutDown() -> Bool {
        guard settings.propsEnabled, props.isHolding else { return false }
        model.wake()
        model.stopWalk()
        let front = model.x + (model.facingRight ? 1 : -1) * settings.displayHeight * 0.30
        let placed = props.putDown(at: front, footY: model.yFeet, now: clock)
        if placed, let nod = library.action(named: "put_down") ?? library.action(named: "nod") {
            actions.inject(.perform(nod))
        }
        if placed { pushRecentEvent("put down \(props.heldPropID ?? "prop")") }
        return placed
    }

    /// 拿起（行动脑语义/场景共用）：附近自己的 placed 道具滑进手部 + 高兴节拍。
    @discardableResult
    private func semanticPickUp() -> Bool {
        guard settings.propsEnabled else { return false }
        guard props.placedNear(petX: model.x, petYFeet: model.yFeet, within: 90) != nil else {
            return false
        }
        model.wake()
        model.stopWalk()
        let picked = props.pickUp(petX: model.x, petYFeet: model.yFeet,
                                  facingRight: model.facingRight, now: clock)
        if picked, let beat = library.action(named: "pick_up") ?? library.action(named: "happy") {
            actions.inject(.perform(beat))
        }
        if picked { pushRecentEvent("picked up prop") }
        return picked
    }

    /// Needle 世界快照。实体 v2 = 锚点（带 app/activity/affordance）；
    /// 场景集由当前目标过滤；表演名单来自包的 actions/。
    private func makeWorldFacts() -> NeedleBrain.WorldFacts {
        let anchors = AnchorResolver.nearbyAnchors(windows: world.windows, petX: model.x, limit: 5)
        let performances = library.actionNames.filter { !$0.hasPrefix("sleep") }
        let recent = actions.lastPerformAt.mapValues { at in
            max(0, Int(clock - at))
        }
        var facts = NeedleBrain.WorldFacts(
            actor: runtimeActorID.raw,
            userIdleSeconds: Int(systemWorld.idleSeconds()))
        facts.traceID = currentGoal?.traceID
        facts.sceneID = sceneRunner?.recipe.id
        facts.goal = currentGoal.map {
            (kind: $0.kind.rawValue, activity: $0.activity?.rawValue, style: $0.style)
        }
        facts.anchors = anchors.map {
            (id: $0.snapshotID, distance: $0.distance, owner: $0.owner,
             activity: $0.activity.rawValue, affordances: $0.affordances.map { $0.rawValue })
        }
        facts.props = settings.propsEnabled ? PropCatalog.ids : []
        if settings.propsEnabled {
            facts.heldProp = props.heldPropID
            // 附近可再拿的道具（放下的东西自己还在原地）。
            if let near = props.placedNear(petX: model.x, petYFeet: model.yFeet, within: 120) {
                facts.propNearby = near.def.id
            }
        }
        if let goal = currentGoal, settings.scenesEnabled {
            let userBusy = GoalPolicy.isBusy(.init(
                brain: brainState, personality: personality,
                userActivity: world.foreground?.appActivity ?? .unknown,
                userIdleSeconds: systemWorld.idleSeconds(),
                hasWindows: !world.windows.isEmpty,
                secondsSinceInteraction: nil, now: clock))
            facts.scenes = SceneCatalog.compatible(goal: goal,
                                                   activity: world.foreground?.appActivity ?? .unknown,
                                                   personality: personality,
                                                   userBusy: userBusy).map { $0.id }
        }
        facts.performances = performances
        facts.speechIntents = settings.speechEnabled ? SpeechIntent.allCases.map { $0.rawValue } : []
        facts.recent = recent
        facts.needs = (
            energy: Int((brainState.energy * 100).rounded()),
            boredom: Int((brainState.boredom * 100).rounded()),
            social: Int((brainState.socialNeed * 100).rounded()),
            stress: Int((brainState.stress * 100).rounded()))
        // game.md §6：人格同时进决策脑与行动脑——同一个目标，不同性格演法不同。
        let p = personality
        facts.personality = (style: p.styleWord,
                             social: Int((p.social * 100).rounded()),
                             playfulness: Int((p.playfulness * 100).rounded()),
                             diligence: Int((p.diligence * 100).rounded()),
                             teasing: Int((p.teasing * 100).rounded()))
        facts.signatureActions = p.signatureActions.filter(performances.contains)
        // 感知段同时进入模型输入和统一脑路日志，保证查看器能还原行动脑决策。
        if settings.anyInputPluginEnabled {
            facts.sensesJSON = perception.senses.sensesSection(now: clock)
        }
        return facts
    }

    // ============ SceneStaging（场景对身体的接口） ============

    private var sceneMoveDone: (() -> Void)?
    private var sceneMoveTarget: (x: CGFloat, top: Bool, window: WindowEntity?)?
    private var sceneMoveDeadline: Double = 0
    private var scenePerformDone: (() -> Void)?
    /// 完成令牌：sceneMove/scenePerform 每次调用 +1，过期回调（场景已步进、
    /// 看门狗已先行）自动作废 —— 与 SceneBodyDriver 的 stepGeneration 双向幂等。
    private var sceneMoveToken = 0
    private var scenePerformToken = 0

    /// 走向锚点：地面 = stroll；窗台 = 先走近再起跳（落定为完成）。
    func sceneMove(toX: CGFloat, top: Bool, window: WindowEntity?, onDone: @escaping () -> Void) {
        sceneMoveToken += 1
        let token = sceneMoveToken
        guard model.state == .grounded || model.state == .perched else {
            onDone()
            return
        }
        model.wake()
        sceneMoveDone = { [weak self] in
            guard let self, token == self.sceneMoveToken else { return }
            onDone()
        }
        sceneMoveTarget = (toX, top, window)
        sceneMoveDeadline = clock + 14
        if top, let window, settings.perchingEnabled {
            if abs(model.x - window.bounds.midX) < 80 {
                actions.inject(.interact(window))
            } else {
                actions.inject(.moveTo(window.bounds.midX))
            }
        } else {
            actions.inject(.moveTo(toX))
        }
    }

    /// 每帧检查场景移动的到位/超时（move 的完成由身体状态回答）。
    private func tickSceneMove() {
        guard let target = sceneMoveTarget else { return }
        if clock > sceneMoveDeadline { completeSceneMove(); return }
        if target.top, let window = target.window {
            if model.perch?.id == window.id { completeSceneMove(); return }
            if model.state == .grounded, !model.walking,
               abs(model.x - window.bounds.midX) < 80 {
                actions.inject(.interact(window))
            }
        } else if abs(model.x - target.x) < 28, !model.walking {
            completeSceneMove()
        }
    }

    private func completeSceneMove() {
        sceneMoveTarget = nil
        let done = sceneMoveDone
        sceneMoveDone = nil
        done?()
    }

    func sceneSpawnProp(_ id: String, at x: CGFloat, footY: CGFloat) {
        guard settings.propsEnabled else { return }
        props.spawnHeld(id, petX: x, petYFeet: footY,
                        facingRight: model.facingRight, now: clock)
    }

    func sceneClearProps() {
        props.despawn(now: clock)
    }

    @discardableResult
    func scenePutDown() -> Bool {
        semanticPutDown()
    }

    @discardableResult
    func scenePickUp() -> Bool {
        semanticPickUp()
    }

    func scenePerform(_ candidates: [String], onDone: @escaping () -> Void) {
        model.wake()
        model.stopWalk()
        for name in candidates {
            if let key = library.action(named: name) {
                scenePerformToken += 1
                let token = scenePerformToken
                scenePerformDone = { [weak self] in
                    guard let self, token == self.scenePerformToken else { return }
                    onDone()
                }
                actions.inject(.perform(key))
                return
            }
        }
        onDone()   // 素材全缺失：立即完成（场景继续）
    }

    /// 表演完成轮询：performance 被清（播完/被打断）即算完成。
    private func tickScenePerform() {
        guard let done = scenePerformDone else { return }
        if actions.performance == nil {
            scenePerformDone = nil
            done()
        }
    }

    func sceneSay(_ intent: SpeechIntent) {
        speak(intent: intent)
    }

    func sceneSleep() {
        actions.inject(.sleep)
    }

    /// 决策点：行动脑优先（不吃冷却），不可用/失败 → 内置策略即时回答。
    func sceneDecisionPoint(_ scene: SceneRecipe, stepIndex: Int,
                            resume: @escaping (SceneDecision) -> Void) {
        if settings.actionBrainEnabled, needle.isAvailable {
            var facts = makeWorldFacts()
            facts.mode = .inScene
            let dispatched = needle.decideNow(facts: facts) { [weak self] semantic, _ in
                resume(self?.mapSceneDecision(semantic) ?? .continueScene)
            }
            if dispatched { return }
        }
        resume(policySceneDecision(scene))
    }

    /// 内置决策点策略：人格塑形的继续/插播/离开。
    private func policySceneDecision(_ scene: SceneRecipe) -> SceneDecision {
        var rng = autopilotRng
        defer { autopilotRng = rng }
        let roll = Double.random(in: 0..<1, using: &rng)
        let p = personality
        if brainState.stress >= 0.5 { return .leaveScene }
        if roll < 0.55 { return .continueScene }
        if roll < 0.65, settings.speechEnabled, speechCooldown <= 0 {
            return .say(.chatter)
        }
        if roll < 0.8 {
            let gestures = scene.steps.compactMap { step -> [String]? in
                switch step.operation {
                case .perform(let name): return [name]
                case .performCandidates(let names): return names
                default: return nil
                }
            }.flatMap { $0 }
            if !gestures.isEmpty { return .perform(gestures) }
        }
        // 玩性高爱恋战；独立性强说走就走。
        return Double.random(in: 0..<1, using: &rng) < p.playfulness * 0.7 ? .continueScene : .leaveScene
    }

    private func mapSceneDecision(_ semantic: NeedleBrain.SemanticAction?) -> SceneDecision? {
        switch semantic {
        case .wait: return .continueScene
        case .leaveScene: return .leaveScene
        case .say(let intent):
            return SpeechIntent(rawValue: intent).map(SceneDecision.say) ?? .continueScene
        case .perform(let name): return .perform([name])
        case .performCandidates(let names): return .perform(names)
        default: return .continueScene
        }
    }

    // MARK: 说话（意图 → 本地/高阶决策脑生成 / 内置台词）

    private func speak(intent: SpeechIntent) {
        guard settings.speechEnabled, speechCooldown <= 0 else { return }
        speechCooldown = 8
        // 没有当前目标时也创建独立 Trace，避免手动互动/反射台词成为无主事件。
        let traceID = currentGoal?.traceID ?? UUID().uuidString
        guard let ws = lastWorldState else {
            speakBuiltin(intent, traceID: traceID)
            return
        }
        let dispatched = goalBrainCoordinator.requestSpeech(
            intent: intent,
            world: ws,
            brain: brainState,
            personality: personality,
            characterID: characterDefinition?.id ?? library.characterID,
            dialogue: characterDefinition?.dialogue,
            traceID: traceID
        ) { [weak self] reply in
            guard let self else { return }
            if let reply {
                self.showSpeech(reply.text, emotion: reply.emotion)
            } else {
                self.speakBuiltin(intent, traceID: traceID)
            }
        }
        if !dispatched {
            speakBuiltin(intent, traceID: traceID)
        }
    }

    private func speakBuiltin(_ intent: SpeechIntent, traceID: String? = nil) {
        var rng = autopilotRng
        defer { autopilotRng = rng }
        let said: (text: String, emotion: String)
        if let lines = characterDefinition?.dialogue?.fallbackLines[intent.rawValue]?.zhHans,
           !lines.isEmpty {
            let emotion = intent == .greet ? "happy" : intent == .tease ? "teasing" :
                intent == .complain ? "annoyed" : "neutral"
            said = (lines[Int.random(in: 0..<lines.count, using: &rng)], emotion)
        } else {
            said = Quips.speak(for: intent, personality: personality, rng: &rng)
        }
        BrainDecisionLog.logSpeech(intent: intent,
                               reply: SpeechReply(text: said.text, emotion: said.emotion),
                               latency: 0,
                               traceID: traceID ?? currentGoal?.traceID ?? UUID().uuidString,
                               mode: "builtin")
        showSpeech(said.text, emotion: said.emotion)
    }

    private func showSpeech(_ text: String, emotion: String = "neutral") {
        model.wake()
        bubble.show(text, headX: model.x, headY: model.yFeet)
        brainState.apply(event: .spoke(text: text), now: clock)
        pushRecentEvent("pet spoke")
        // game.md §14：语言和动画结合 —— 情绪驱动一个短表演
        // （候选按包内素材降级；场景运行中不插手，场景有自己的节奏）。
        if sceneRunner == nil {
            for name in EmotionGesture.clips(for: emotion) {
                if let key = library.action(named: name) {
                    actions.inject(.perform(key))
                    break
                }
            }
        }
    }

    /// 菜单/设置窗改设置后热更新。displayHeight 也已支持实时预览：
    /// 物理尺寸（bodyRadius 等）与面板大小下一帧即按新值运转。
    func updateSettings(_ s: Settings) {
        let heightChanged = s.displayHeight != settings.displayHeight
        let brainChanged = s.actionBrainEnabled != settings.actionBrainEnabled
            || s.actionBrainMinInterval != settings.actionBrainMinInterval
            || s.actionBrainMaxInterval != settings.actionBrainMaxInterval
            || s.actionBrainMaxTokens != settings.actionBrainMaxTokens
            || s.localBrainEnabled != settings.localBrainEnabled
            || s.localBrainGoalTemperature != settings.localBrainGoalTemperature
            || s.localBrainGoalTopP != settings.localBrainGoalTopP
            || s.localBrainGoalTopK != settings.localBrainGoalTopK
            || s.localBrainGoalMaxTokens != settings.localBrainGoalMaxTokens
            || s.localBrainGoalSeed != settings.localBrainGoalSeed
            || s.localBrainChatTemperature != settings.localBrainChatTemperature
            || s.localBrainChatTopP != settings.localBrainChatTopP
            || s.localBrainChatTopK != settings.localBrainChatTopK
            || s.localBrainChatMaxTokens != settings.localBrainChatMaxTokens
            || s.localBrainChatSeed != settings.localBrainChatSeed
            || s.teacherBrainEnabled != settings.teacherBrainEnabled
            || s.teacherBrainBaseURL != settings.teacherBrainBaseURL
            || s.teacherBrainModel != settings.teacherBrainModel
            || s.teacherBrainAPIKey != settings.teacherBrainAPIKey
            || s.teacherBrainTemperature != settings.teacherBrainTemperature
            || s.teacherBrainTopP != settings.teacherBrainTopP
            || s.teacherBrainTopK != settings.teacherBrainTopK
            || s.teacherBrainMaxTokens != settings.teacherBrainMaxTokens
            || s.teacherBrainSeed != settings.teacherBrainSeed
            || s.teacherBrainReasoningEffort != settings.teacherBrainReasoningEffort
            || s.goalBrainMinInterval != settings.goalBrainMinInterval
            || s.goalBrainMaxInterval != settings.goalBrainMaxInterval
            || s.brainTraceEnabled != settings.brainTraceEnabled
        let inputChanged = s.inputPlugins != settings.inputPlugins
            || s.sensesEnabled != settings.sensesEnabled
            || s.ocrEnabled != settings.ocrEnabled
        settings = s
        props.userScale = s.propScale
        if heightChanged {
            model.displayHeight = s.displayHeight
        }
        if brainChanged {
            refreshGoalBrains()
        }
        if inputChanged, !s.anyInputPluginEnabled {
            perception.senses.clear()
            perception.ocrLines = []
            perception.ocrLinesAt = nil
        }
        if inputChanged || !s.inputPlugins.isEnabled("window-title") {
            lastWindowTitleFingerprint = nil
        }
    }

    // ---- 屏幕感知 ----

    private var isPerceptionOwner: Bool {
        perception.ownerID == runtimeActorID
    }

    /// 把桌面级感知总线的结果投递到游戏 kernel。单宠物模式使用自己的
    /// kernel；角色组只由 owner 投递到 CastRuntime 的共享 kernel，避免
    /// 多个面板重复消费同一事件或重复推进同一时钟。
    private func consumePerceptionEvents() {
        let input = perception.inputEvents(after: perceptionEventCursor)
        let mayPublishSharedEvent = PerceptionHub.shouldPublishSharedKernelEvent(
            usesSharedGameplayKernel: usesSharedGameplayKernel,
            isOwner: isPerceptionOwner)
        if mayPublishSharedEvent {
            for event in input.events {
                gameplayRuntime.submitPlatform(event)
            }
        }
        if !input.events.isEmpty {
            // 内容只推动快速反应，不直接执行动作；本地脑在下一次 tick
            // 看到更新后的 BrainContextSnapshot 后决定是否升级当前反应。
            goalBrainCoordinator.expedite()
            needle.expedite()
        }
        perceptionEventCursor = input.latestSequence

        guard handledForegroundRevision < perception.foregroundRevision else { return }
        handledForegroundRevision = perception.foregroundRevision
        guard mayPublishSharedEvent else { return }
        handleForegroundChanged(perception.world.foreground)
    }

    /// AX 感知：随 0.3s 世界轮询跑；OCR 感知：profile 命中的前台窗口按 TTL 拉取。
    /// 事件只当「感知失效通知」，重感之后 BrainContextSnapshot 才变化，反应与否由大脑决定。
    private func refreshSenses() {
        guard isPerceptionOwner else { return }
        guard let fg = world.foreground else { return }

        let semanticPlugins = ["chat-content", "code-content", "browser-content"]
            .contains { settings.inputPlugins.isEnabled($0) }
        let needsAX = settings.accessibilityInputEnabled
            || semanticPlugins

        // Window title is the low-latency channel. When the window server
        // exposes a title, it works without waiting for AX and without making
        // the fast path depend on the accessibility permission.
        publishWindowTitlePlugin(foreground: fg)

        if needsAX {
            let now = clock
            let stale = perception.senses.current(now: now) == nil
            if (stale || perception.senses.shouldResense(now: now)), !perception.sensesPending {
                perception.sensesPending = true
                let hub = perception
                perception.sensor.sense(pid: fg.pid, now: now) { [weak self, hub] observation in
                    guard let self else {
                        hub.sensesPending = false
                        return
                    }
                    self.perception.sensesPending = false
                    guard !self.isStopped, self.isPerceptionOwner else { return }
                    if var merged = observation {
                        // OCR 行合并进同一次观察（两个传感器共用 BrainContextSnapshot 预算）。
                        merged.ocrLines = self.perception.ocrLines
                        self.publishInputPlugins(merged, foreground: fg)
                        if self.settings.anyInputPluginEnabled {
                            self.perception.senses.update(merged)
                        }
                    }
                }
            }
        }

        if settings.ocrInputEnabled, !perception.ocrPending,
           let bundleID = fg.bundleID,
           let profile = OCRCatalog.profile(owner: fg.owner, bundleID: bundleID) {
            let due = perception.ocrLinesAt == nil
                || clock - (perception.ocrLinesAt ?? 0) > 8
            if due {
                perception.ocrPending = true
                let hub = perception
                perception.ocrSensor.sense(windowID: fg.id, profile: profile) { [weak self, hub] lines in
                    guard let self else {
                        hub.ocrPending = false
                        return
                    }
                    self.perception.ocrPending = false
                    guard !self.isStopped, self.isPerceptionOwner else { return }
                    self.perception.ocrLinesAt = self.clock
                    self.perception.ocrLines = lines ?? []
                    var o = SensorObservation(requestID: 0, timestamp: self.clock,
                                              app: fg.owner, pid: Int(fg.pid), windowTitle: "")
                    o.ocrLines = self.perception.ocrLines
                    self.publishInputPlugins(o, foreground: fg)
                    if !self.settings.accessibilityInputEnabled {
                        // OCR-only 模式：合成最小观察，让 OCR 行进 BrainContextSnapshot/快照
                        //（不申请辅助功能、不跑 AX）。
                        self.perception.senses.update(o)
                    } else {
                        self.perception.senses.markDirty(now: self.clock)   // 新 OCR 行 → 重组 senses
                    }
                }
            }
        }
    }

    /// 把 AX/OCR 的一次结果拆成可独立开关的输入插件事件。
    /// 插件只进入 GameKernel；它们不直接调用动作，抢占只负责使旧计划失效。
    private func publishInputPlugins(_ observation: SensorObservation, foreground: WindowEntity) {
        var catalog = settings.inputPlugins
        // 旧设置键的迁移兜底：Settings 由测试或旧调用方直接构造时仍有效。
        if settings.sensesEnabled { catalog.setEnabled(true, for: "accessibility") }
        if settings.ocrEnabled { catalog.setEnabled(true, for: "ocr") }
        let tick = gameplayKernel.clock.tick
        let app = observation.app.isEmpty ? foreground.owner : observation.app
        let bundleID = observation.pid == Int(foreground.pid) ? foreground.bundleID : nil
        let stamp = Int(observation.timestamp * 1000)
        let title = observation.windowTitle.isEmpty ? foreground.windowTitle : observation.windowTitle

        func emit(_ pluginID: String, _ channel: InputChannel, _ text: String) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let input = InputObservation(
                id: "\(pluginID):\(observation.requestID):\(stamp)",
                pluginID: pluginID,
                channel: channel,
                appName: app,
                bundleID: bundleID,
                windowTitle: title,
                text: value,
                capturedAtTick: tick)
            if let event = catalog.route(input, at: tick) {
                perception.appendInputEvent(event)
            }
        }

        emit("window-title", .windowTitle, title)
        emit("ocr", .ocr, observation.ocrLines.joined(separator: "\n"))

        var axLines: [String] = []
        if !observation.selectedText.isEmpty { axLines.append(observation.selectedText) }
        if let focused = observation.focused {
            axLines.append(focused.value.isEmpty ? focused.title : focused.value)
        }
        axLines += observation.siblings.map { $0.value.isEmpty ? $0.title : $0.value }
        axLines += observation.salient.map(\.title)
        let axText = axLines.filter { !$0.isEmpty }.joined(separator: "\n")
        emit("accessibility", .accessibility, axText)

        switch foreground.appActivity {
        case .chatting:
            emit("chat-content", .chat, axText.isEmpty ? observation.ocrLines.joined(separator: "\n") : axText)
        case .coding:
            emit("code-content", .code, axText.isEmpty ? observation.ocrLines.joined(separator: "\n") : axText)
        case .browsing, .reading:
            let browserNames = ["chrome", "safari", "firefox", "arc", "edge", "brave", "vivaldi"]
            if browserNames.contains(where: { foreground.owner.lowercased().contains($0) }) {
                emit("browser-content", .browser, axText.isEmpty ? observation.ocrLines.joined(separator: "\n") : axText)
            }
        default:
            break
        }
    }

    /// Fast title-only input path. It intentionally does not synthesize chat /
    /// code / browser content: those channels still require a real AX/OCR
    /// observation and therefore cannot mistake an app switch for page text.
    private func publishWindowTitlePlugin(foreground: WindowEntity) {
        guard settings.inputPlugins.isEnabled("window-title"),
              !foreground.windowTitle.isEmpty else { return }
        var catalog = settings.inputPlugins
        if settings.sensesEnabled { catalog.setEnabled(true, for: "accessibility") }
        let tick = gameplayKernel.clock.tick
        let input = InputObservation(
            id: "window-title:\(foreground.id):\(tick)",
            pluginID: "window-title",
            channel: .windowTitle,
            appName: foreground.owner,
            bundleID: foreground.bundleID,
            windowTitle: foreground.windowTitle,
            text: foreground.windowTitle,
            capturedAtTick: tick)
        guard input.fingerprint != lastWindowTitleFingerprint,
              let event = catalog.route(input, at: tick) else { return }
        lastWindowTitleFingerprint = input.fingerprint
        perception.appendInputEvent(event)
    }

    // ---- BrainContextSnapshot（大脑唯一世界边界） ----

    private func refreshWorldState() {
        let ws = makeWorldState()
        let fingerprint = "\(ws.activeApp)|\(ws.windowTitle)|\(ws.userActivity)|\(ws.appActivity)|\(ws.focusRole)|\(ws.visibleContext.first ?? "")"
        lastWorldFingerprint = fingerprint
        lastWorldState = ws
    }

    private func makeWorldState() -> BrainContextSnapshot {
        let events = recentEvents.map { event -> String in
            let ago = max(0, Int(clock - event.t))
            return "\(ago)s ago \(event.text)"
        }
        let tick = gameplayKernel.clock.tick
        let inputObservations = gameplayKernel.world.inputObservations.values
            .filter { $0.isValid(at: tick) && settings.isInputPluginEnabled($0.pluginID) }
        return BrainContextSnapshotBuilder.build(
            clock: clock,
            foreground: world.foreground,
            idleSeconds: systemWorld.idleSeconds(),
            windows: world.windows,
            senses: settings.anyInputPluginEnabled ? perception.senses.current(now: clock) : nil,
            inputObservations: Array(inputObservations),
            recentEvents: events)
    }

    func pushRecentEvent(_ text: String) {
        recentEvents.append((clock, text))
        if recentEvents.count > 8 { recentEvents.removeFirst(recentEvents.count - 8) }
    }

    // MARK: SceneStaging / AnchorLookup 小件

    func hasClip(_ name: String) -> Bool {
        library.action(named: name) != nil
    }

    /// 锚点文本 → 世界落点（SceneBodyDriver 与 Needle 语义共用）。
    func resolveAnchor(_ text: String) -> (x: CGFloat, top: Bool, window: WindowEntity?)? {
        guard let spec = AnchorSpec.parse(text),
              let resolved = AnchorResolver.resolve(spec, windows: world.windows) else { return nil }
        return (resolved.point.x, spec.slot.isTop, resolved.window)
    }

    func floorNearPoint() -> CGFloat {
        let refX: CGFloat = world.foreground?.bounds.midX ?? model.x
        let span = world.floorSpan(near: refX, footY: model.yFeet)
        let jitter = CGFloat.random(in: -120...120)
        return min(max(refX + jitter, span.left + 40), span.right - 40)
    }

    /// 右键操作环的一级动作：只接受语义动作，具体 clip 仍由当前角色包解析。
    func performMenuAction(_ intent: ActionIntent) {
        guard !isStopped else { return }
        if let declaredCapabilities,
           let required = ActionCatalog.requiredCapability(for: intent),
           !declaredCapabilities.contains(required) {
            return
        }
        if intent == .rest {
            actions.cancelPerformance()
            actions.clearPendingUserActions()
            cancelGoalAndScene(reason: "user action")
            if model.state == .asleep {
                model.wake()
            } else {
                model.sleep()
            }
            return
        }
        model.wake()
        model.stopWalk()
        cancelGoalAndScene(reason: "user action")
        let key = ActionCatalog.resolve(intent, available: library.actionNames)
            .flatMap(library.action(named:)) ?? idlePrimary
        guard !key.isEmpty else { return }
        actions.inject(.perform(key), userInitiated: true)
    }

    private func openActionRing(at cursor: CGPoint) {
        guard !isStopped, !isDeparting else { return }
        model.wake()
        model.stopWalk()
        actions.cancelPerformance()
        actions.clearPendingUserActions()
        cancelGoalAndScene(reason: "user opened action ring")
        actionRingOpen = true
        actionRing.show(
            at: cursor,
            primary: ActionCatalog.rightClickMenuItems(available: Set(library.actionNames))
                .filter(isAuthorizedMenuItem),
            extended: [],
            available: Set(library.actionNames))
    }

    private func isAuthorizedMenuItem(_ item: ActionCatalog.MenuItem) -> Bool {
        guard let declaredCapabilities,
              let required = ActionCatalog.requiredCapability(for: item.intent) else { return true }
        return declaredCapabilities.contains(required)
    }

    /// 操作环中的“聊天”先接入本地文本聊天通道；能识别为短动作指令时，
    /// 直接执行语义动作，避免把简单鼠标可完成的命令再绕一圈送进大脑。
    private func openChatInput() {
        let alert = NSAlert()
        alert.messageText = "和角色聊天"
        alert.informativeText = "可以聊天，也可以直接输入“攀爬”“休息”等指挥。"
        let field = NSTextField(string: "")
        field.placeholderString = "输入聊天内容或动作指令"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = field
        alert.addButton(withTitle: "发送")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let clipped = String(text.prefix(120))
        if let intent = ActionCatalog.menuIntent(for: clipped) {
            performMenuAction(intent)
        } else {
            requestChatReply(to: clipped)
        }
    }

    private func requestChatReply(to text: String) {
        guard !isStopped, settings.speechEnabled else { return }
        model.wake()
        model.stopWalk()
        actions.cancelPerformance()
        cancelGoalAndScene(reason: "user chat")
        // 只记录事件类型，不把用户原文写进持久化/决策日志。
        pushRecentEvent("user sent chat")

        let traceID = currentGoal?.traceID ?? UUID().uuidString
        let worldState = lastWorldState ?? makeWorldState()
        guard settings.localBrainEnabled else {
            speakBuiltin(.chatter, traceID: traceID)
            return
        }
        let dispatched = localBrain.requestSpeech(
            intent: .chatter,
            world: worldState,
            brain: brainState,
            personality: personality,
            characterID: characterDefinition?.id ?? library.characterID,
            dialogue: characterDefinition?.dialogue,
            traceID: traceID,
            userText: text) { [weak self] reply in
                guard let self else { return }
                if let reply {
                    self.showSpeech(reply.text, emotion: reply.emotion)
                } else {
                    self.speakBuiltin(.chatter, traceID: traceID)
                }
            }
        if !dispatched {
            speakBuiltin(.chatter, traceID: traceID)
        }
    }

    // ---- 前台跟随 ----

    private func handleForegroundChanged(_ window: WindowEntity?) {
        guard let window else { return }
        gameplayRuntime.submitPlatform(PlatformEvent(GameEvent(
            kind: .foregroundChanged,
            actorID: usesSharedGameplayKernel ? nil : runtimeActorID,
            entityID: EntityID(String(window.id))
        )))
        // 感知失效通知：前台换了，旧的聚焦上下文不可信。
        perception.senses.markDirty(now: clock)
        perception.ocrLines = []
        pushRecentEvent("user switched to \(window.owner)")
        // 重要窗口出现（game.md §5/§4 触发器）：行动脑下个边界立即反应。
        goalBrainCoordinator.expedite()
        needle.expedite()
        guard settings.foregroundFollow else { return }
        guard foregroundCooldown <= 0 else { return }
        guard model.state != .dragged, model.state != .tossed else { return }
        foregroundCooldown = 6
        // 睡着也被叫醒：有新窗口要看，睡觉不是借口。
        model.wake()
        actions.inject(.interact(window), userInitiated: true)
    }

    // ---- 渲染 ----

    /// 身体线的第一选择（base/idle 保证存在，加载期已校验）。
    private var idlePrimary: String { library.baseOrFallback(.idle) }

    /// 睡眠姿态 clip（actions/sleep*），包里没有就退回 idle。
    private var sleepClip: String? { library.sleepActionKey() }

    private func pushFirstFrame() {
        let idle = idlePrimary
        if let frames = library.frames(for: idle), let img = frames.first {
            animator.play(idle)
            view.display(image: img, mirrored: false)
        }
    }

    private func renderFrame(dt: Double) {
        selectClip()
        let (image, changed) = animator.tick(dt: dt)
        if changed, let image {
            // 素材实况朝向 ⊕ 移动方向 = 是否镜像（rei_chibi 步态实为朝左，靠这个翻正）。
            let authored = library.facing(for: animator.clipName)
            view.display(
                image: image,
                mirrored: ClipLibrary.mirrorNeeded(authored: authored, movingRight: model.facingRight)
            )
        }
    }

    /// 身体状态 + 当前活动 → 该播哪个 clip。
    /// 身体线（走/跑/空中/拖拽/睡）每帧由状态直接推导，无「上一个 clip」记忆；
    /// 表演线（actions/*）作为覆盖层，播完或到 deadline 回身体线。
    private func selectClip() {
        switch model.state {
        case .asleep:
            animator.play(sleepClip ?? idlePrimary)
        case .dragged:
            animator.play(library.baseOrFallback(.drag))
        case .tossed:
            animator.play(library.baseOrFallback(.airborne))
        case .airborne:
            // 水平速度大 → 奔跑姿势飞跃；否则屏息。
            animator.play(abs(model.vx) > 200
                ? library.baseOrFallback(.run)
                : library.baseOrFallback(.airborne))
        case .grounded, .perched:
            // 表演线：actions/ 覆盖层（tick 已保证身体一动就取消）。
            if let p = actions.performance {
                animator.play(p.clipKey)
                return
            }
            if model.walking {
                animator.play(library.baseOrFallback(.walk))
                return
            }
            // 画面还挂在移动/睡眠 clip 上（刚停步/刚醒来）→ 立刻切回 idle。
            if animator.clipName != idleClip {
                let movementKeys: Set<String> = [
                    library.baseOrFallback(.walk),
                    library.baseOrFallback(.run),
                    sleepClip ?? ""
                ]
                if movementKeys.contains(animator.clipName) {
                    idleClip = idlePrimary
                    animator.play(idleClip, restart: true)
                }
            }
            // 偶尔换一种闲姿（idle 变体池轮换）。
            if clock > idleSwapAt {
                idleSwapAt = clock + Double.random(in: 4...9)
                idleClip = library.idlePool.randomElement() ?? idlePrimary
                animator.play(idleClip, restart: true)
            } else {
                if idleClip.isEmpty { idleClip = idlePrimary }
                animator.play(idleClip)
            }
        }
    }

    // ---- 面板摆放 ----

    private func beginCastTransition(_ plan: CastTransitionPlan) {
        castTransition = plan
        castTransitionStartedAt = ProcessInfo.processInfo.systemUptime
        placePanel()
    }

    private func placePanel() {
        let displayH = settings.displayHeight
        let displayW = library.cellSize.width / library.cellSize.height * displayH
        if model.state == .dragged || userDetachedFromCastLayout {
            // Direct manipulation follows the cursor in virtual-desktop space.
            // Do not fit to one screen or run group layout while the mouse owns
            // the character; those policies made vertical and cross-screen drag
            // appear stuck. Release returns to normal toss/bounce physics.
            panel.setFrame(
                Screens.appKitRect(
                    flippedTop: model.yFeet - displayH * ClipLibrary.baselineRatio,
                    x: model.x - displayW / 2,
                    width: displayW,
                    height: displayH),
                display: false)
            return
        }
        // 以当前屏幕的可见工作区为硬边界。窗口顶沿可能在菜单栏后面，
        // 不能把“脚锚点”当成“面板必须原样放置”，否则最大化窗口会吃掉半个角色。
        let work = Screens.workBox(containing: CGPoint(x: model.x, y: model.yFeet))
        let safe = SpatialSafety.placeActor(
            id: runtimeActorID,
            anchorX: Double(model.x),
            feetY: Double(model.yFeet),
            width: Double(displayW),
            height: Double(displayH),
            baselineRatio: Double(ClipLibrary.baselineRatio),
            in: LayoutRect(
                x: Double(work.left),
                y: Double(work.top),
                width: Double(work.width),
                height: Double(work.height))
        )
        let workBounds = LayoutRect(
            x: Double(work.left),
            y: Double(work.top),
            width: Double(work.width),
            height: Double(work.height))
        if castTransition == nil, let castPresentationFrame {
            let presented = SpatialSafety.fit(castPresentationFrame, in: workBounds)
            let rect = Screens.appKitRect(
                flippedTop: CGFloat(presented.y),
                x: CGFloat(presented.x),
                width: CGFloat(presented.width),
                height: CGFloat(presented.height))
            panel.setFrame(rect, display: false)
            return
        }
        // 工作区坐标本身是稳定的屏幕 seam：同一块显示器上的角色需要
        // 分离，不同显示器上的角色不能被后一次更新重新打包到一起。
        let groupID = "screen:\(Int(work.left)):\(Int(work.top)):\(Int(work.width))x\(Int(work.height))"
        let placed = layoutCoordinator?.update(safe, in: workBounds, groupID: groupID) ?? safe
        let transition = castTransition
        let progress: Double
        if let transition, let startedAt = castTransitionStartedAt {
            let duration = max(0.025, Double(transition.durationTicks) * 0.05)
            progress = (ProcessInfo.processInfo.systemUptime - startedAt) / duration
        } else {
            progress = 1
        }
        let presentation = transition?.presentation(
            at: progress,
            leadingEdge: model.x <= (work.left + work.right) / 2)
        var presented = placed.frame
        if let presentation {
            presented = LayoutRect(
                x: presented.x + presented.width * presentation.offsetXRatio,
                y: presented.y + presented.height * presentation.offsetYRatio,
                width: presented.width,
                height: presented.height)
            panel.alphaValue = CGFloat(presentation.opacity)
        } else {
            panel.alphaValue = 1
        }
        let rect = Screens.appKitRect(
            flippedTop: CGFloat(presented.y),
            x: CGFloat(presented.x),
            width: CGFloat(presented.width),
            height: CGFloat(presented.height)
        )
        panel.setFrame(rect, display: false)
        if transition != nil, progress >= 1 {
            castTransition = nil
            castTransitionStartedAt = nil
            panel.alphaValue = 1
            let finalRect = Screens.appKitRect(
                flippedTop: CGFloat(placed.frame.y),
                x: CGFloat(placed.frame.x),
                width: CGFloat(placed.frame.width),
                height: CGFloat(placed.frame.height))
            panel.setFrame(finalRect, display: false)
        }
    }

    // ---- 鼠标（反射层：<50ms，不进大脑） ----

    private func wireView() {
        actionRing.onDismiss = { [weak self] in
            self?.actionRingOpen = false
        }
        actionRing.onAction = { [weak self] intent in
            self?.performMenuAction(intent)
        }
        actionRing.onChat = { [weak self] in
            self?.openChatInput()
        }

        view.onMouseDown = { [weak self] cursor in
            guard let self else { return }
            self.actionRing.dismiss()
            self.actionRingOpen = false
            // Direct user control temporarily owns the panel. The next Cast
            // tick may reapply the confirmed scene frame, but it must not pin
            // a dragged character to yesterday's relationship layout.
            if self.castPresentationFrame != nil {
                self.userDetachedFromCastLayout = true
            }
            self.castPresentationFrame = nil
            self.model.wake()
            self.actions.cancelPerformance() // 用户触摸取消表演
            self.actions.clearPendingUserActions() // 抓起 = 接管，排队的菜单指令作废
            self.cancelGoalAndScene(reason: "user grabbed")   // 用户接管：场景意图作废
            self.pullCursorStart = cursor
            self.model.beginDrag(at: cursor)
            if self.model.isPulling() {
                self.beginPull()
            }
        }
        view.onMouseDragged = { [weak self] cursor in
            guard let self else { return }
            self.model.drag(to: cursor, dt: 1.0 / 40.0)
            if self.model.isPulling() {
                self.updatePull(cursor: cursor)
            }
        }
        view.onMouseUp = { [weak self] cursor, wasClick in
            guard let self else { return }
            if self.model.isPulling() {
                self.puller.end()
            }
            self.model.endDrag(wasClick: wasClick)
            self.pullCursorStart = nil
            if wasClick {
                self.registerPat()
            } else if self.model.state == .tossed {
                self.brainState.apply(event: .tossed, now: self.clock)
            }
        }
        view.onRightMouseDown = { [weak self] cursor in
            self?.openActionRing(at: cursor)
        }
    }

    /// 摸头/连戳（三时间尺度的前两级）：
    /// 单击 = 摸头（亲密度↑）；12s 内戳满 3 下 = 应激（stress↑ + 躲开 +
    /// 事件进环 + 行动脑提前，决策脑下一轮可能形成 complain_to_user 目标）。
    private func registerPat() {
        lastInteractionAt = clock
        pokeTimes.append(clock)
        pokeTimes = pokeTimes.filter { clock - $0 < 12 }
        if pokeTimes.count >= 3 {
            pokeTimes = []
            brainState.apply(event: .poked, now: clock)
            pushRecentEvent("user poked the pet repeatedly")
            needle.expedite()
            flee(distance: 160)
            if settings.speechEnabled { speak(intent: .complain) }
        } else {
            brainState.apply(event: .patted, now: clock)
        }
    }

    /// 「鼠标突然靠近」即时反射（game.md §13 第一层）：
    /// 光标高速逼近到身边 → 惊一下（stress 微涨 + 后撤）。慢速靠近不触发。
    /// 场景运行中让位（正在演戏的宠物注意力在戏上）；睡着不惊（真惊醒太吵）。
    private func tickStartle() {
        guard !isDeparting else {
            startle.reset()
            return
        }
        guard sceneRunner == nil,
              model.state == .grounded || model.state == .perched else {
            startle.reset()
            return
        }
        let mouse = NSEvent.mouseLocation
        let cursor = CGPoint(x: mouse.x, y: Screens.primaryTopY - mouse.y)  // → 翻转坐标
        let bodyCenter = CGPoint(x: model.x, y: model.yFeet - settings.displayHeight * 0.5)
        if startle.update(cursor: cursor, pet: bodyCenter, now: clock) {
            brainState.apply(event: .startled, now: clock)
            pushRecentEvent("startled by a fast cursor")
            flee(distance: 90)
        }
    }

    /// 光标逼近检测器（纯逻辑，Game/Startle.swift）。
    var startle = StartleDetector()

    /// 后撤反射：从当前位置快速挪开一段距离（用户召唤逻辑反向用）。
    private func flee(distance: CGFloat) {
        guard model.state == .grounded || model.state == .perched else { return }
        let span = world.floorSpan(near: model.x, footY: model.yFeet)
        let away = model.x + (model.x < (span.left + span.right) / 2 ? -distance : distance)
        let target = min(max(away, span.left + 40), span.right - 40)
        if abs(target - model.x) > 40 {
            actions.inject(.moveTo(target))
        }
    }

    // ---- 拉窗 ----

    private var pullWindow: WindowEntity?

    private func beginPull() {
        guard settings.windowPullEnabled else { return }
        guard let perch = model.perch, let w = world.window(perch.id) else { return }
        guard WindowPuller.isTrusted() else {
            promptAccessibility()
            return
        }
        pullWindow = w
        puller.begin(windowID: w.id, pid: w.pid)
    }

    private func updatePull(cursor: CGPoint) {
        guard let w = pullWindow, let start = pullCursorStart else { return }
        puller.update(cursor: cursor, cursorStart: start, mass: WindowPuller.windowMass(forApp: w.owner))
    }

    /// 请求辅助功能授权（两级权限的第二级，只由用户主动开启）。
    func promptAccessibility() {
        WindowPuller.promptForTrust()
    }

    // ============ 全局召唤 ============

    /// 全局菜单「召唤道具」（用户指令）：宠物变出指定道具——手上（拿着）或
    /// 面前（placed 落地，原地待着后自然淡出）。正做的场景让位。
    func summonProp(_ id: String, placed: Bool) {
        guard settings.propsEnabled, PropCatalog.def(id) != nil else { return }
        model.wake()
        model.stopWalk()
        cancelGoalAndScene(reason: "user command")
        // 变出节拍：happy/jump 候选降级（素材缺失就静默出现，不挡召唤）。
        if let beat = library.action(named: "happy") ?? library.action(named: "jump") {
            actions.inject(.perform(beat), userInitiated: true)
        }
        if placed {
            let front = model.x + (model.facingRight ? 1 : -1) * settings.displayHeight * 0.45
            props.spawnPlaced(id, at: front, footY: model.yFeet, now: clock)
        } else {
            props.spawnHeld(id, petX: model.x, petYFeet: model.yFeet,
                            facingRight: model.facingRight, now: clock)
        }
        pushRecentEvent("user summoned \(id)")
    }

    // MARK: 菜单状态报告

    struct StatusReport {
        var pet = ""
        var goal = ""
        var scene = ""
        var needs = ""
        var brains = ""
        var lastSpeech = ""
    }

    /// 菜单「当前状态」子菜单的内容（打开菜单时刷新）。
    func statusReport() -> StatusReport {
        var r = StatusReport()
        r.pet = runtimeActorID.raw
        if let goal = currentGoal {
            r.goal = "\(goal.kind.rawValue)\(goal.activity.map { " · \($0.rawValue)" } ?? "")（\(goal.source)）"
        } else {
            r.goal = "（规划中）"
        }
        r.scene = sceneRunner.map { "\($0.recipe.label)" } ?? "—"
        let pct = { (v: Double) -> String in String(Int((v * 100).rounded())) }
        r.needs = "能量 \(pct(brainState.energy)) · 无聊 \(pct(brainState.boredom)) · 社交 \(pct(brainState.socialNeed)) · 应激 \(pct(brainState.stress))"
        let local = settings.localBrainEnabled
            ? (LocalBrainModel.isInstalled ? "本地 0.8B" : "缺模型") : "关闭"
        let teacher = settings.teacherBrainEnabled
            ? (teacherBrain.isAvailable ? "Qwen VLM（\(settings.teacherBrainModel)）" : "未配置") : "关闭"
        let action = settings.actionBrainEnabled
            ? (needle.isAvailable ? "Needle 3" : "缺模型") : "关闭"
        r.brains = "行动脑 \(action) · 本地决策脑 \(local) · 高阶教师脑 \(teacher) · 场景 \(settings.scenesEnabled ? "开" : "关")"
        r.lastSpeech = brainState.lastSpeech ?? "—"
        return r
    }
}

/// PetController 的场景舞台身份（协议在 Game/Scene.swift）。
extension PetController: SceneStaging {
    var petX: CGFloat { model.x }
    var petYFeet: CGFloat { model.yFeet }
}
