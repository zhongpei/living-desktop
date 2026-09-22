import Foundation
import MyPetCore
import MyPetEngine

/// 运行时只认语义动作；具体 clip 名是素材实现细节。
///
/// 每个角色不必一次拥有全部专属素材。解析器按这里的优先级寻找当前
/// petpack 中存在的动作，所以新增专属 clip 只需入包，不需要改场景或大脑。
enum ActionIntent: String, CaseIterable, Hashable {
    // 身体基线与基础表演。
    case idle
    case walk
    case run
    case turn
    case jumpStart
    case airborne
    case land
    case fall
    case sit
    case standUp
    case look
    case lookAround
    case point
    case beckon
    case greet
    case tease
    case happy
    case think
    case complain
    case surprised
    case annoyed
    case talk
    case listen
    case nod
    case shakeHead
    case sleep
    case rest
    case recover
    case crouch
    case stretch
    case yawn
    case enterScene
    case exitScene
    case perchWindow
    // 调侃与正式战斗分开；这些动作只对声明 combat 能力的参与者开放。
    case taunt
    case combatReady
    case attack
    case defend
    case dodge
    case hitReact
    case victory
    case defeat
    case retreat
    // 窗口地形：强接触动作优先使用专属 clip，没有时回退到可见的基础姿态。
    case windowJumpToSill
    case windowClimb
    case windowClimbDown
    case windowPullUp
    case windowHang
    case windowPeek
    case windowSit
    case windowLean
    case windowLookOut
    case windowDropFromSill
    // 道具与社交动作先声明语义，具体素材按角色能力降级。
    case propReach
    case propTake
    case propHold
    case propCarry
    case propInspect
    case propRead
    case propType
    case propDrink
    case propEat
    case propPlay
    case propUse
    case propPlace
    case propPush
    case propPull
    case propThrow
    case propGive
    case propReceive
    case socialFace
    case socialLookAt
    case socialApproach
    case socialTalk
    case socialListen
    case socialFollow
    case socialGreet
    case socialHighFive
    case socialTouch
    case socialComfort
    case socialTease
    case socialHug
    case socialArgue
    case socialPlay
    // 机甲不是普通道具，但仍共享同一套语义动作解析。
    case mechStandby
    case mechActivate
    case mechDeactivate
    case mechSignal
    case mechMove
    case mechDamage
    case mechGuard
    case mechRespond
    case mechEnterCockpit
    case mechExitCockpit
}

enum ActionCatalog {

    static func requiredCapability(for intent: ActionIntent) -> String? {
        switch intent {
        case .taunt, .combatReady, .attack, .defend, .dodge, .hitReact,
             .victory, .defeat, .retreat:
            return "combat"
        case .perchWindow, .windowJumpToSill, .windowClimb, .windowClimbDown,
             .windowPullUp, .windowHang, .windowPeek, .windowSit, .windowLean,
             .windowLookOut, .windowDropFromSill:
            return "window"
        case .propReach, .propTake, .propHold, .propCarry, .propInspect, .propRead,
             .propType, .propDrink, .propEat, .propPlay, .propUse, .propPlace,
             .propPush, .propPull, .propThrow, .propGive, .propReceive:
            return "prop"
        case .socialFace, .socialLookAt, .socialApproach, .socialTalk, .socialListen,
             .socialFollow, .socialGreet, .socialHighFive, .socialTouch,
             .socialComfort, .socialTease, .socialHug, .socialArgue, .socialPlay:
            return "social"
        case .mechStandby, .mechActivate, .mechDeactivate, .mechSignal, .mechMove,
             .mechDamage, .mechGuard, .mechRespond, .mechEnterCockpit,
             .mechExitCockpit:
            return "mech"
        default:
            return nil
        }
    }

    /// 右键环形菜单的一个直接入口。
    ///
    /// 菜单文案和语义动作都在这里维护，渲染层不写死角色动作，也不再把
    /// “动作”做成一个中间层级。`aliases` 只用于聊天输入里的快速指令匹配。
    struct MenuItem: Equatable {
        let intent: ActionIntent
        let labels: LocalizedLabel
        let aliases: [String]

        var label: String { labels.defaultText }
        var englishLabel: String { labels.en }

        init(_ intent: ActionIntent, _ label: String, _ englishLabel: String,
             aliases: [String] = []) {
            self.intent = intent
            self.labels = LocalizedLabel(zhHans: label, en: englishLabel)
            self.aliases = aliases
        }
    }

    /// 右键后直接显示的常用／主要动作。这里没有“动作”父按钮：每一项
    /// 都是一次点击即可执行的具体动作；按钮可以分布在环形菜单的多圈上。
    static let primaryMenuItems: [MenuItem] = [
        MenuItem(.greet, "打招呼", "Greet", aliases: ["问候", "挥手"]),
        MenuItem(.happy, "开心", "Happy", aliases: ["高兴"]),
        MenuItem(.think, "思考", "Think"),
        MenuItem(.complain, "抱怨", "Complain", aliases: ["抗议"]),
        MenuItem(.tease, "调皮", "Tease", aliases: ["使坏"]),
        MenuItem(.rest, "休息", "Rest", aliases: ["睡觉"]),
        MenuItem(.sit, "坐下", "Sit"),
        MenuItem(.look, "观察", "Look", aliases: ["看看"]),
        MenuItem(.run, "跑动", "Run", aliases: ["跑起来"]),
        MenuItem(.turn, "转身", "Turn"),
        MenuItem(.jumpStart, "跳跃", "Jump", aliases: ["跳一下"]),
        MenuItem(.perchWindow, "停驻窗台", "Perch at Window", aliases: ["坐窗台", "爬窗口", "看窗外"]),
        MenuItem(.propTake, "拿起", "Take", aliases: ["拿"]),
        MenuItem(.propHold, "拿着", "Hold"),
        MenuItem(.propRead, "阅读", "Read", aliases: ["看书"]),
        MenuItem(.propType, "打字", "Type", aliases: ["编码"]),
        MenuItem(.propDrink, "喝", "Drink"),
        MenuItem(.propEat, "吃", "Eat"),
        MenuItem(.propUse, "使用", "Use"),
        MenuItem(.propPlace, "放下", "Place", aliases: ["放置"]),
        MenuItem(.propThrow, "投掷", "Throw", aliases: ["扔"]),
        MenuItem(.socialTalk, "交谈", "Talk", aliases: ["和别人聊天"]),
        MenuItem(.socialListen, "倾听", "Listen"),
        MenuItem(.socialFollow, "跟随", "Follow"),
        MenuItem(.socialComfort, "安慰", "Comfort"),
        MenuItem(.socialArgue, "争执", "Argue", aliases: ["吵架"]),
    ]

    /// “更多”二级菜单：低频、扩展和专用动作。一级菜单不依赖它才能完成
    /// 常见玩法；新增语义动作时先放这里，验证稳定后再提升到一级。
    static let extendedMenuItems: [MenuItem] = [
        MenuItem(.airborne, "空中", "Airborne"),
        MenuItem(.land, "落地", "Land"),
        MenuItem(.fall, "跌落", "Fall"),
        MenuItem(.recover, "恢复", "Recover"),
        MenuItem(.crouch, "蹲伏", "Crouch"),
        MenuItem(.stretch, "伸展", "Stretch"),
        MenuItem(.yawn, "打哈欠", "Yawn"),
        MenuItem(.taunt, "嘲讽", "Taunt"),
        MenuItem(.combatReady, "战斗准备", "Combat Ready"),
        MenuItem(.attack, "攻击", "Attack"),
        MenuItem(.defend, "防御", "Defend"),
        MenuItem(.dodge, "闪避", "Dodge"),
        MenuItem(.hitReact, "受击", "Hit React"),
        MenuItem(.victory, "胜利", "Victory"),
        MenuItem(.defeat, "败北", "Defeat"),
        MenuItem(.retreat, "撤退", "Retreat"),
        MenuItem(.windowJumpToSill, "跳上窗台", "Jump to Sill"),
        MenuItem(.windowClimb, "攀爬", "Climb"),
        MenuItem(.windowClimbDown, "下爬", "Climb Down"),
        MenuItem(.windowPullUp, "拉上窗口", "Pull Up"),
        MenuItem(.windowHang, "挂边", "Hang from Edge"),
        MenuItem(.windowPeek, "探头", "Peek"),
        MenuItem(.windowSit, "坐窗台", "Sit on Sill"),
        MenuItem(.windowLean, "倚靠窗边", "Lean on Window"),
        MenuItem(.windowLookOut, "看窗外", "Look Out"),
        MenuItem(.windowDropFromSill, "从窗台跳下", "Drop from Sill"),
        MenuItem(.propReach, "伸手", "Reach"),
        MenuItem(.propCarry, "搬运", "Carry"),
        MenuItem(.propInspect, "检查", "Inspect"),
        MenuItem(.propPlay, "玩道具", "Play with Prop"),
        MenuItem(.propPush, "推动", "Push"),
        MenuItem(.propPull, "拉动", "Pull"),
        MenuItem(.propGive, "递给", "Give"),
        MenuItem(.propReceive, "接过", "Receive"),
        MenuItem(.socialFace, "面向他人", "Face Other"),
        MenuItem(.socialLookAt, "看向他人", "Look at Other"),
        MenuItem(.socialApproach, "靠近他人", "Approach Other"),
        MenuItem(.socialGreet, "向他人问候", "Greet Other"),
        MenuItem(.socialHighFive, "击掌", "High Five"),
        MenuItem(.socialTouch, "触碰", "Touch"),
        MenuItem(.socialTease, "调侃", "Tease Other", aliases: ["逗他"]),
        MenuItem(.socialHug, "拥抱", "Hug"),
        MenuItem(.socialPlay, "一起玩", "Play Together"),
        MenuItem(.mechStandby, "机甲待机", "Mech Standby"),
        MenuItem(.mechActivate, "启动机甲", "Activate Mech", aliases: ["启动"]),
        MenuItem(.mechDeactivate, "关闭机甲", "Deactivate Mech"),
        MenuItem(.mechSignal, "机甲示意", "Mech Signal"),
        MenuItem(.mechMove, "机甲移动", "Move Mech"),
        MenuItem(.mechDamage, "机甲受损", "Mech Damage"),
        MenuItem(.mechGuard, "机甲保护", "Mech Guard", aliases: ["保护"]),
        MenuItem(.mechRespond, "机甲回应", "Mech Respond"),
        MenuItem(.mechEnterCockpit, "进入驾驶舱", "Enter Cockpit"),
        MenuItem(.mechExitCockpit, "离开驾驶舱", "Exit Cockpit"),
    ]

    /// Right click is a short character menu, not an action-catalog browser.
    /// Keep universal interactions plus semantics backed by this pack's own
    /// preferred clips; fallback-only actions remain available to brains and
    /// authored scenes without flooding the user menu.
    static func rightClickMenuItems(available: Set<String>) -> [MenuItem] {
        let common: Set<ActionIntent> = [.greet, .happy, .tease, .think, .rest]
        let catalog = primaryMenuItems + extendedMenuItems
        let commonItems = catalog.filter {
            common.contains($0.intent) && resolve($0.intent, available: available) != nil
        }
        let distinctive = catalog.filter { item in
            guard !common.contains(item.intent) else { return false }
            guard let preferred = mapping[item.intent]?.first else { return false }
            return available.contains(preferred)
        }
        return commonItems + distinctive.prefix(7)
    }

    /// 这些语义动作必须能在每个已发布角色包中解析出一个可播放动作。
    /// `rest` 主要由身体线的 sleep() 负责，不作为核心表演验收项。
    static let requiredPerformanceIntents: [ActionIntent] = [
        .greet, .tease, .happy, .think, .complain,
    ]

    /// 语义动作 → 角色 clip 候选，顺序就是降级优先级。
    private static let mapping: [ActionIntent: [String]] = [
        .idle: ["idle", "idle_neutral", "sleep_loop"],
        .walk: ["walk", "walk_right", "run", "idle"],
        .run: ["run", "walk", "happy", "wave"],
        .turn: ["turn", "walk", "think", "wave"],
        .jumpStart: ["jump_start", "jump", "happy", "wave"],
        .airborne: ["airborne", "jump", "fall", "happy"],
        .land: ["land", "jump", "happy", "wave"],
        .fall: ["fall", "airborne", "jump", "sit_idle"],
        .sit: ["sit", "sit_idle", "perch", "think", "wave"],
        .standUp: ["stand_up", "recover", "idle", "walk"],
        .look: ["look", "observe", "think", "wave"],
        .lookAround: ["look_around", "look", "observe", "think"],
        .point: ["point", "beckon", "wave", "look"],
        .beckon: ["beckon", "wave", "greet_wave", "point"],
        .greet: ["greet", "greet_wave", "wave", "happy", "nod"],
        // 最后两个是迁移期兜底：旧角色包还没有专属嘲讽 clip 时，至少仍能
        // 完成「靠近 → 表演 → 说话」的完整交互闭环。
        .tease: ["tease", "taunt", "mock_turn", "flirt", "tail_wag", "nod", "happy", "wave"],
        .happy: ["happy", "celebrate", "jump", "tail_wag", "wave", "nod"],
        // `wave` 是旧人类包中最稳定的通用上半身动作，优先级低于真正思考动作。
        .think: ["think", "read", "sit_idle", "nod", "look"],
        .complain: ["complain", "annoyed", "nod", "think", "wave"],
        .surprised: ["surprised", "startle", "airborne", "happy"],
        .annoyed: ["annoyed", "complain", "shake_head", "think"],
        .talk: ["talk", "greet_other", "greet", "wave"],
        .listen: ["listen", "look_at", "look", "nod"],
        .nod: ["nod", "greet", "wave", "look"],
        .shakeHead: ["shake_head", "complain", "annoyed", "think"],
        .sleep: ["sleep", "sleep_loop", "doze", "yawn", "sit_idle"],
        .rest: ["sleep_loop", "sleep", "doze", "yawn", "sit_idle"],
        .recover: ["recover", "stand_up", "land", "idle"],
        .crouch: ["crouch", "sit", "sit_idle", "think"],
        .stretch: ["stretch", "yawn", "happy", "idle"],
        .yawn: ["yawn", "stretch", "sleep_loop", "idle"],
        .enterScene: ["enter_scene", "walk", "idle"],
        .exitScene: ["exit_scene", "walk", "idle"],
        .perchWindow: ["perch_window", "sit_sill", "lean_sill", "climb_up", "sit_idle"],
        .taunt: ["taunt", "tease", "complain", "wave"],
        .combatReady: ["combat_ready", "guard", "standby", "idle"],
        .attack: ["attack", "strike", "prop_use", "happy"],
        .defend: ["defend", "guard", "crouch", "idle"],
        .dodge: ["dodge", "airborne", "jump", "run"],
        .hitReact: ["hit_react", "damage", "fall", "complain"],
        .victory: ["victory", "happy", "celebrate", "wave"],
        .defeat: ["defeat", "fall", "sit", "complain"],
        .retreat: ["retreat", "run", "walk", "dodge"],
        .windowJumpToSill: ["jump_to_sill", "jump", "climb_up", "happy", "wave"],
        .windowClimb: ["climb_up", "jump_to_sill", "pull_up", "jump", "happy", "wave"],
        .windowClimbDown: ["climb_down", "drop_from_sill", "fall", "walk", "wave"],
        .windowPullUp: ["pull_up", "climb_up", "jump_to_sill", "jump", "wave"],
        .windowHang: ["hang_edge", "hang", "peek_over", "peek", "think", "wave"],
        .windowPeek: ["peek_over", "peek", "peek_at_user", "look_out", "think", "wave"],
        .windowSit: ["sit_sill", "sit_idle", "perch", "think", "wave"],
        .windowLean: ["lean_sill", "lean", "look_out", "think", "wave"],
        .windowLookOut: ["look_out", "observe", "peek_over", "think", "wave"],
        .windowDropFromSill: ["drop_from_sill", "climb_down", "fall", "jump", "walk"],
        .propReach: ["reach", "take", "pick_up", "happy", "wave"],
        .propTake: ["take", "pick_up", "reach", "happy", "wave"],
        .propHold: ["hold", "carry", "take", "pick_up", "wave"],
        .propCarry: ["carry", "hold", "walk", "take", "wave"],
        .propInspect: ["inspect", "read", "think", "nod", "wave"],
        .propRead: ["read", "inspect", "think", "nod", "wave"],
        .propType: ["type", "use", "think", "wave"],
        .propDrink: ["drink", "use", "happy", "think", "wave"],
        .propEat: ["eat", "use", "happy", "think", "wave"],
        .propPlay: ["play", "use", "happy", "wave"],
        .propUse: ["use", "type", "drink", "eat", "play", "happy", "think", "wave"],
        .propPlace: ["place", "put_down", "drop", "take", "wave"],
        .propPush: ["push", "use", "walk", "happy", "wave"],
        .propPull: ["pull", "use", "walk", "happy", "wave"],
        .propThrow: ["throw", "toss", "use", "happy", "wave"],
        .propGive: ["give", "hand_over", "offer", "greet_wave", "wave", "happy"],
        .propReceive: ["receive", "take", "happy", "greet_wave", "wave"],
        .socialFace: ["face_other", "look_at", "turn", "think", "wave"],
        .socialLookAt: ["look_at", "face_other", "observe", "think", "wave"],
        .socialApproach: ["approach_other", "walk", "follow", "look_at", "wave"],
        .socialTalk: ["talk", "greet_other", "greet_wave", "wave", "think"],
        .socialListen: ["listen", "look_at", "think", "nod", "wave"],
        .socialFollow: ["follow", "walk", "look_at", "think", "wave"],
        .socialGreet: ["greet_other", "greet_wave", "wave", "happy"],
        .socialHighFive: ["high_five", "wave", "happy", "touch"],
        .socialTouch: ["touch", "comfort", "greet_wave", "happy", "wave"],
        .socialComfort: ["comfort", "hug", "touch", "greet_wave", "happy", "wave"],
        .socialTease: ["tease_other", "tease", "taunt", "mock_turn", "happy", "wave"],
        .socialHug: ["hug", "comfort", "touch", "happy", "wave"],
        .socialArgue: ["argue", "challenge", "complain", "tease", "nod", "think", "wave"],
        .socialPlay: ["play", "happy", "greet_wave", "wave"],
        .mechStandby: ["standby", "idle", "think", "wave"],
        .mechActivate: ["activate", "launch", "happy", "wave"],
        .mechDeactivate: ["deactivate", "standby", "idle", "think", "wave"],
        .mechSignal: ["signal", "wave", "respond", "standby", "think"],
        .mechMove: ["move", "walk", "run", "standby", "wave"],
        .mechDamage: ["damage", "fall", "complain", "standby", "think"],
        .mechGuard: ["guard", "protect", "standby", "think", "wave"],
        .mechRespond: ["respond", "signal", "guard", "standby", "think"],
        .mechEnterCockpit: ["enter_cockpit", "climb_up", "walk", "think", "wave"],
        .mechExitCockpit: ["exit_cockpit", "climb_down", "walk", "think", "wave"],
    ]

    static func candidates(for intent: ActionIntent) -> [String] {
        mapping[intent] ?? []
    }

    static func resolve<S: Sequence>(_ intent: ActionIntent, available: S) -> String?
    where S.Element == String {
        let available = Set(available)
        return candidates(for: intent).first { available.contains($0) }
    }

    /// 聊天输入中的短指令只解析到已经存在的语义动作；自然语言则交给
    /// 聊天脑，不在菜单层自行发明第二套动作协议。
    static func menuIntent(for text: String) -> ActionIntent? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        return (primaryMenuItems + extendedMenuItems).first { item in
            let words = [item.label, item.intent.rawValue] + item.aliases
            return words.contains { word in
                let candidate = word.lowercased()
                return normalized == candidate || normalized.contains(candidate)
            }
        }?.intent
    }
}
