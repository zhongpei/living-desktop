import CoreGraphics
import Foundation
import MyPet2D
import MyPetContent

/// AppKit 身体动作 driver：只执行 Runtime 已提交的身体指令。
/// 大脑（过渡期 RandomBrain，将来 Needle）、菜单、前台跟随都只说 verbs；
/// 身体反射（拖拽/抛掷/点击弹跳）不经这里——它们直接操作 PetModel。
///
/// 表演取消规则（唯一，取代旧的各路径各自处理）：
/// 1. 身体离开 grounded/perched（跳/拖/抛/睡）→ 取消，**不补演**；
/// 2. 走路开始 → 取消（表演只发生在原地）；
/// 3. loop 型表演到 endsAt → 自然收尾；once 型由控制器播完（animator.isFinished）后清掉。
final class PetBodyDriver {

    enum Verb: Equatable {
        case moveTo(CGFloat)      // 走向目标 x
        case perform(String)      // 播一段表演（actions/ clip 键）
        case interact(WindowEntity)
        case sleep
        case wait                 // 停走、清表演
    }

    struct Performance: Equatable {
        let clipKey: String
        /// loop 型的收尾时刻；once 型为 nil（播完即止，控制器负责清理）。
        let endsAt: Double?
    }

    private let model: PetModel
    private let library: ClipLibrary
    var actionTimeline: ActionTimeline? { model.actionTimeline }
    private var actionStartedAt: Double = 0
    private var nextActionInstanceID: Int64 = 0
    private var lastTimelineTick: Double?
    private var timelineFrameRemainder: Double = 0
    var performance: Performance? {
        guard let timeline = actionTimeline,
              timeline.definition.locomotionPolicy == .stationary else { return nil }
        let endsAt = timeline.definition.durationFrames.map {
            actionStartedAt + Double($0) / Double(BodyWorld.framesPerSecond)
        }
        return Performance(
            clipKey: timeline.definition.animationBinding,
            endsAt: endsAt)
    }
    /// moveTo 的散步目标；到达（±24pt）自动停步。
    private(set) var strollTarget: CGFloat?
    /// 运行时自己的时钟（由 tick 喂），用于 loop 型表演的收尾时刻。
    private var clock: Double = 0
    /// 最近表演记录（动作名 → 时刻），供大脑快照的 recent 字段。
    private(set) var lastPerformAt: [String: Double] = [:]
    /// 用户指令排队：身体不可用时（空中/抛掷中）点菜单，落地即执行。
    /// 用户抓起宠物即作废（clearPendingUserActions）。
    private(set) var pendingSummon: CGFloat?
    private(set) var pendingPerform: String?

    init(model: PetModel, library: ClipLibrary) {
        self.model = model
        self.library = library
    }

    private var canAct: Bool {
        model.state == .grounded || model.state == .perched
    }

    /// 注入一条指令。userInitiated = 用户/系统反射（菜单、前台跟随），
    /// 与大脑指令同权——v1 不做优先级队列，身体反射永远更高。
    func inject(_ verb: Verb, userInitiated: Bool = false) {
        switch verb {
        case .moveTo(let target):
            guard canAct else {
                if userInitiated { pendingSummon = target } // 空中点「过来」：落地即执行
                return
            }
            cancelPerformance()
            if userInitiated {
                // 用户召唤：快走 / 跨屏空降，可靠到达。
                model.summonTo(targetX: target)
                strollTarget = target
            } else {
                model.strollTo(target)
                strollTarget = abs(target - model.x) >= 24 ? target : nil
            }
            if strollTarget != nil {
                startAction(ActionDefinition(
                    actionID: "move_to",
                    durationFrames: nil,
                    animationBinding: "base/walk",
                    domain: .locomotion,
                    locomotionPolicy: .authored,
                    endState: .locomotion))
            }
        case .perform(let clipKey):
            guard canAct else {
                if userInitiated { pendingPerform = clipKey } // 空中点动作：落地即演
                return
            }
            startPerformance(clipKey)
        case .interact(let window):
            guard canAct else { return }
            cancelAction()
            model.leapTo(window: window)
            startAction(ActionDefinition(
                actionID: "jump",
                durationFrames: nil,
                animationBinding: "base/jump",
                domain: .locomotion,
                locomotionPolicy: .authored,
                endState: .locomotion))
        case .sleep:
            cancelAction()
            model.sleep()
            startAction(ActionDefinition(
                actionID: "sleep",
                durationFrames: nil,
                animationBinding: "base/sleep",
                locomotionPolicy: .stationary,
                endState: .hold))
        case .wait:
            model.stopWalk()
            strollTarget = nil
            cancelAction()
        }
    }

    /// loop 型播 2 个循环后收尾；once 型由控制器播完（isFinished）清掉。
    /// clip 不存在直接忽略——否则性能会挂在"永远播不完"的表演上。
    private func startPerformance(_ clipKey: String) {
        guard library.clip(clipKey) != nil else { return }
        model.stopWalk()
        strollTarget = nil
        cancelAction()
        lastPerformAt[clipKey] = clock
        let durationFrames: Int?
        if library.playback(for: clipKey) == .loop, let meta = library.meta(for: clipKey) {
            durationFrames = Int(ceil(
                2.0 * Double(meta.frames) / max(meta.fps, 0.001) *
                Double(BodyWorld.framesPerSecond)))
        } else {
            durationFrames = nil
        }
        startAction(ActionDefinition(
            actionID: clipKey,
            durationFrames: durationFrames,
            animationBinding: clipKey,
            locomotionPolicy: .stationary))
    }

    /// 每帧推进：落实取消规则、收尾到期的散步/表演、执行排队的用户指令。
    func tick(now: Double) {
        clock = now

        // 排队的用户指令：一落地（重新可行动）立刻执行。
        if canAct {
            if let target = pendingSummon {
                pendingSummon = nil
                model.summonTo(targetX: target)
                strollTarget = target
                startAction(ActionDefinition(
                    actionID: "move_to",
                    durationFrames: nil,
                    animationBinding: "base/walk",
                    domain: .locomotion,
                    locomotionPolicy: .authored,
                    endState: .locomotion))
            }
            if let clip = pendingPerform {
                pendingPerform = nil
                startPerformance(clip)
            }
        }

        if let target = strollTarget, abs(model.x - target) < 24 {
            model.stopWalk()
            strollTarget = nil
            if actionTimeline?.definition.locomotionPolicy == .authored {
                cancelAction()
            }
        }

        advanceTimeline(to: now)
        guard performance != nil else { return }
        // 规则 1/2：身体动了，表演立刻取消（不补演）。
        guard canAct, !model.walking else {
            cancelAction()
            return
        }
    }

    /// once 型表演播完由控制器调用（运行时不持有动画器）；
    /// 用户触摸等反射也可直接调用来取消当前表演。
    func cancelPerformance() {
        guard actionTimeline?.definition.locomotionPolicy == .stationary else { return }
        cancelAction()
    }

    private func startAction(_ definition: ActionDefinition) {
        model.setActionTimeline(ActionTimeline(
            instanceID: nextActionInstanceID,
            definition: definition))
        nextActionInstanceID += 1
        actionStartedAt = clock
        lastTimelineTick = clock
        timelineFrameRemainder = 0
    }

    private func cancelAction() {
        if var timeline = actionTimeline { _ = timeline.cancel() }
        model.setActionTimeline(nil)
        timelineFrameRemainder = 0
    }

    private func advanceTimeline(to now: Double) {
        let previous = lastTimelineTick ?? now
        lastTimelineTick = now
        timelineFrameRemainder += max(0, now - previous) * Double(BodyWorld.framesPerSecond)
        let frames = Int(timelineFrameRemainder)
        guard frames > 0, var timeline = actionTimeline else { return }
        timelineFrameRemainder -= Double(frames)
        if timeline.advance(frames: frames) == .finished {
            model.setActionTimeline(nil)
        } else {
            model.setActionTimeline(timeline)
        }
    }

    /// 用户抓起宠物 = 接管控制，之前排队的菜单指令作废。
    func clearPendingUserActions() {
        pendingSummon = nil
        pendingPerform = nil
    }
}
