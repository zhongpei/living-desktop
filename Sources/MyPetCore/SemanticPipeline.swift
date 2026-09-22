import Foundation

// MARK: - Goal

/// The public, data-only counterpart of the production GoalBrain vocabulary.
/// A goal says what the actor wants; it never contains a verb, coordinate or
/// platform operation.
public enum SimulationGoalKind: String, Codable, CaseIterable, Sendable {
    case joinUserActivity = "join_user_activity"
    case watchWithUser = "watch_with_user"
    case seekAttention = "seek_attention"
    case explore
    case rest
    case wander
    case teaseUser = "tease_user"
    case complainToUser = "complain_to_user"
}

public struct SimulationGoalDecision: Codable, Equatable, Sendable {
    public var goal: SimulationGoalKind
    public var target: String?
    public var activity: String?
    public var style: String?
    public var issuedAtTick: Int64
    public var source: String

    public init(
        goal: SimulationGoalKind,
        target: String? = nil,
        activity: String? = nil,
        style: String? = nil,
        issuedAtTick: Int64 = 0,
        source: String = "policy"
    ) {
        self.goal = goal
        self.target = target
        self.activity = activity
        self.style = style
        self.issuedAtTick = issuedAtTick
        self.source = source
    }
}

public struct SimulationGoalCommand: Codable, Equatable, Sendable {
    public var atTick: Int64
    public var decision: SimulationGoalDecision

    public init(atTick: Int64, decision: SimulationGoalDecision) {
        self.atTick = atTick
        self.decision = decision
    }
}

public enum SimulationGoalBrainMode: String, Codable, Sendable {
    case policy
    case replay
}

public enum SimulationProviderExecution: String, Codable, Sendable {
    case runtimeImmediate
    case requiresPrefetch
}

/// Small seam for replacing the deterministic GoalBrain with a real provider.
/// Providers return a goal only; they never create a BehaviorRequest.
public protocol SimulationGoalProvider: AnyObject {
    var providerID: String { get }
    var execution: SimulationProviderExecution { get }
    var missPolicy: SimulationNeedleMissPolicy { get }
    func setStoryScope(_ scope: String?)

    func decide(
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationGoalDecision?
}

public extension SimulationGoalProvider {
    var execution: SimulationProviderExecution { .runtimeImmediate }
    var missPolicy: SimulationNeedleMissPolicy { .reject }
    func setStoryScope(_ scope: String?) {}
}

public struct SimulationGoalBrainSnapshot: Codable, Equatable, Sendable {
    public var mode: SimulationGoalBrainMode
    public var replayCommands: [SimulationGoalCommand]
    public var initialGoalConsumed: Bool

    public init(mode: SimulationGoalBrainMode, replayCommands: [SimulationGoalCommand], initialGoalConsumed: Bool) {
        self.mode = mode
        self.replayCommands = replayCommands
        self.initialGoalConsumed = initialGoalConsumed
    }
}

/// Deterministic policy/replay adapter. A live HTTP/MLX adapter can supply
/// SimulationGoalCommand values at this seam; the rest of the simulation stays the same.
public final class GoalBrain {
    public let mode: SimulationGoalBrainMode
    private var replayCommands: [SimulationGoalCommand]
    private let initialGoal: SimulationGoalDecision?
    private var initialGoalConsumed = false

    public init(
        mode: SimulationGoalBrainMode = .policy,
        replayCommands: [SimulationGoalCommand] = [],
        initialGoal: SimulationGoalDecision? = nil
    ) {
        self.mode = mode
        self.replayCommands = replayCommands.sorted {
            $0.atTick == $1.atTick ? $0.decision.goal.rawValue < $1.decision.goal.rawValue : $0.atTick < $1.atTick
        }
        self.initialGoal = initialGoal
    }

    public func decide(tick: Int64, context: RuntimeContext, world: WorldState, actorID: EntityID) -> SimulationGoalDecision? {
        guard world.isAlive(actorID) else { return nil }
        if !initialGoalConsumed, let initialGoal {
            initialGoalConsumed = true
            var decision = initialGoal
            decision.issuedAtTick = tick
            return decision
        }
        if mode == .replay {
            guard let index = replayCommands.firstIndex(where: { $0.atTick <= tick }) else { return nil }
            return replayCommands.remove(at: index).decision
        }

        if let window = context.focus {
            return SimulationGoalDecision(
                goal: .joinUserActivity,
                target: window.id.raw,
                activity: window.activity ?? "unknown",
                style: "quiet_companion",
                issuedAtTick: tick,
                source: "policy")
        }
        return SimulationGoalDecision(
            goal: .wander,
            style: "easygoing",
            issuedAtTick: tick,
            source: "policy")
    }

    public func snapshot() -> SimulationGoalBrainSnapshot {
        SimulationGoalBrainSnapshot(
            mode: mode,
            replayCommands: replayCommands,
            initialGoalConsumed: initialGoalConsumed)
    }

    public func restore(_ snapshot: SimulationGoalBrainSnapshot) {
        replayCommands = snapshot.replayCommands
        initialGoalConsumed = snapshot.initialGoalConsumed
    }
}

extension GoalBrain: SimulationGoalProvider {
    public var providerID: String {
        mode == .replay ? "replay-goal" : "policy-goal"
    }
}

// MARK: - Scene

public enum SimulationSceneOperation: Equatable, Sendable {
    case moveTo(String)
    case perform(String)
    case performCandidates([String])
    case spawnProp(String)
    case clearProps
    case putDown
    case pickUp
    case wait(Int64)
    case say(String)
    case sleep
}

extension SimulationSceneOperation: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value, ticks }
    private enum Kind: String, Codable {
        case moveTo, perform, performCandidates, spawnProp, clearProps, putDown, pickUp, wait, say, sleep
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .moveTo(let value):
            try container.encode(Kind.moveTo, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .perform(let value):
            try container.encode(Kind.perform, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .performCandidates(let values):
            try container.encode(Kind.performCandidates, forKey: .kind)
            try container.encode(values, forKey: .value)
        case .spawnProp(let value):
            try container.encode(Kind.spawnProp, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .clearProps:
            try container.encode(Kind.clearProps, forKey: .kind)
        case .putDown:
            try container.encode(Kind.putDown, forKey: .kind)
        case .pickUp:
            try container.encode(Kind.pickUp, forKey: .kind)
        case .wait(let ticks):
            try container.encode(Kind.wait, forKey: .kind)
            try container.encode(ticks, forKey: .ticks)
        case .say(let value):
            try container.encode(Kind.say, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .sleep:
            try container.encode(Kind.sleep, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .moveTo: self = .moveTo(try container.decode(String.self, forKey: .value))
        case .perform: self = .perform(try container.decode(String.self, forKey: .value))
        case .performCandidates: self = .performCandidates(try container.decode([String].self, forKey: .value))
        case .spawnProp: self = .spawnProp(try container.decode(String.self, forKey: .value))
        case .clearProps: self = .clearProps
        case .putDown: self = .putDown
        case .pickUp: self = .pickUp
        case .wait: self = .wait(try container.decode(Int64.self, forKey: .ticks))
        case .say: self = .say(try container.decode(String.self, forKey: .value))
        case .sleep: self = .sleep
        }
    }
}

public struct SimulationSceneStep: Codable, Equatable, Sendable {
    public var operation: SimulationSceneOperation
    public var decisionPoint: Bool

    public init(_ operation: SimulationSceneOperation, decisionPoint: Bool = false) {
        self.operation = operation
        self.decisionPoint = decisionPoint
    }
}

public struct SimulationSceneRecipe: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var goals: [SimulationGoalKind]
    public var activities: [String]
    public var needsUser: Bool
    public var steps: [SimulationSceneStep]
    public var loopFrom: Int?

    public init(
        id: String,
        label: String? = nil,
        goals: [SimulationGoalKind],
        activities: [String] = [],
        needsUser: Bool = false,
        steps: [SimulationSceneStep],
        loopFrom: Int? = nil
    ) {
        self.id = id
        self.label = label ?? id
        self.goals = goals
        self.activities = activities
        self.needsUser = needsUser
        self.steps = steps
        self.loopFrom = loopFrom
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, goals, activities, needsUser, steps, loopFrom
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? id
        goals = try values.decode([SimulationGoalKind].self, forKey: .goals)
        activities = try values.decodeIfPresent([String].self, forKey: .activities) ?? []
        needsUser = try values.decodeIfPresent(Bool.self, forKey: .needsUser) ?? false
        steps = try values.decode([SimulationSceneStep].self, forKey: .steps)
        loopFrom = try values.decodeIfPresent(Int.self, forKey: .loopFrom)
    }
}

public enum SimulationSceneRunStatus: String, Codable, Sendable {
    case idle
    case running
    case completed
    case cancelled
}

public struct SimulationSceneRunnerSnapshot: Codable, Equatable, Sendable {
    public var status: SimulationSceneRunStatus
    public var currentGoal: SimulationGoalDecision?
    public var recipeID: String?
    public var stepIndex: Int

    public init(
        status: SimulationSceneRunStatus,
        currentGoal: SimulationGoalDecision?,
        recipeID: String?,
        stepIndex: Int
    ) {
        self.status = status
        self.currentGoal = currentGoal
        self.recipeID = recipeID
        self.stepIndex = stepIndex
    }
}

/// Pure-data recipe interpreter. It owns scene cursors, not WorldState or
/// rendering; ActionRuntime is the only stage allowed to create a behavior.
public final class SceneRunner {
    public let recipes: [SimulationSceneRecipe]
    public private(set) var status: SimulationSceneRunStatus = .idle
    public private(set) var currentGoal: SimulationGoalDecision?
    public private(set) var recipeID: String?
    public private(set) var stepIndex = 0

    public init(recipes: [SimulationSceneRecipe] = SceneRunner.defaultRecipes) {
        self.recipes = recipes
    }

    public static let defaultRecipes: [SimulationSceneRecipe] = [
        SimulationSceneRecipe(
            id: "coding_companion",
            label: "陪用户编码",
            goals: [.joinUserActivity],
            activities: ["coding", "writing", "designing"],
            steps: [
                SimulationSceneStep(.moveTo("@activity.topRight")),
                SimulationSceneStep(.spawnProp("laptop")),
                SimulationSceneStep(.performCandidates(["think", "read", "sit_idle", "nod", "look"])),
                SimulationSceneStep(.wait(120), decisionPoint: true),
            ], loopFrom: 2),
        SimulationSceneRecipe(
            id: "quiet_observer", label: "安静旁观",
            goals: [.joinUserActivity, .watchWithUser],
            steps: [
                SimulationSceneStep(.moveTo("@activity.topLeft")),
                SimulationSceneStep(.performCandidates(["think", "read", "sit_idle", "nod", "look"])),
                SimulationSceneStep(.wait(160), decisionPoint: true),
            ], loopFrom: 2),
        SimulationSceneRecipe(
            id: "watch_with_user", label: "一起看",
            goals: [.watchWithUser], activities: ["watching", "browsing", "chatting"],
            steps: [
                SimulationSceneStep(.moveTo("@activity.topCenter")),
                SimulationSceneStep(.performCandidates(["happy", "celebrate", "jump", "tail_wag", "wave", "nod"])),
                SimulationSceneStep(.spawnProp("popcorn")),
                SimulationSceneStep(.wait(200), decisionPoint: true),
            ], loopFrom: 3),
        SimulationSceneRecipe(
            id: "read_near_user", label: "在旁边看书",
            goals: [.joinUserActivity, .wander],
            steps: [
                SimulationSceneStep(.moveTo("floor_near")),
                SimulationSceneStep(.spawnProp("book")),
                SimulationSceneStep(.performCandidates(["think", "read", "sit_idle", "nod", "look"])),
                SimulationSceneStep(.wait(180), decisionPoint: true),
                SimulationSceneStep(.putDown),
            ], loopFrom: 3),
        SimulationSceneRecipe(
            id: "tea_break", label: "喝口茶休息",
            goals: [.rest, .wander],
            steps: [
                SimulationSceneStep(.moveTo("floor_near")),
                SimulationSceneStep(.spawnProp("tea")),
                SimulationSceneStep(.performCandidates(["sleep_loop", "sleep", "doze", "yawn", "sit_idle"])),
                SimulationSceneStep(.wait(160)),
                SimulationSceneStep(.putDown),
            ]),
        SimulationSceneRecipe(
            id: "window_sleep", label: "趴窗台上睡",
            goals: [.rest],
            steps: [SimulationSceneStep(.moveTo("@activity.topCenter")), SimulationSceneStep(.sleep)]),
        SimulationSceneRecipe(
            id: "seek_attention", label: "求关注",
            goals: [.seekAttention], needsUser: true,
            steps: [
                SimulationSceneStep(.moveTo("floor_near")),
                SimulationSceneStep(.performCandidates(["greet", "greet_wave", "wave", "happy", "nod"])),
                SimulationSceneStep(.say("greet")),
                SimulationSceneStep(.performCandidates(["tease", "taunt", "mock_turn", "flirt", "tail_wag", "nod", "happy", "wave"]), decisionPoint: true),
            ], loopFrom: 3),
        SimulationSceneRecipe(
            id: "tease_user", label: "毒舌嘲讽",
            goals: [.teaseUser], needsUser: true,
            steps: [
                SimulationSceneStep(.moveTo("floor_near")),
                SimulationSceneStep(.performCandidates(["tease", "taunt", "mock_turn", "flirt", "tail_wag", "nod", "happy", "wave"])),
                SimulationSceneStep(.say("tease")),
                SimulationSceneStep(.wait(80), decisionPoint: true),
            ]),
        SimulationSceneRecipe(
            id: "complain", label: "表达不满",
            goals: [.complainToUser], needsUser: true,
            steps: [
                SimulationSceneStep(.moveTo("floor_near")),
                SimulationSceneStep(.say("complain")),
                SimulationSceneStep(.performCandidates(["complain", "annoyed", "nod", "think", "wave"])),
                SimulationSceneStep(.wait(80), decisionPoint: true),
            ]),
        SimulationSceneRecipe(
            id: "wander", label: "到处逛逛", goals: [.wander, .explore],
            steps: [
                SimulationSceneStep(.moveTo("floor_near")),
                SimulationSceneStep(.performCandidates(["happy", "celebrate", "jump", "tail_wag", "wave", "nod"])),
                SimulationSceneStep(.wait(60), decisionPoint: true),
            ], loopFrom: 0),
        SimulationSceneRecipe(
            id: "window_climb_and_peek", label: "爬上窗沿探头",
            goals: [.explore, .seekAttention], needsUser: true,
            steps: [
                SimulationSceneStep(.moveTo("@activity.topCenter")),
                SimulationSceneStep(.performCandidates(["climb_up", "jump_to_sill", "pull_up", "jump", "happy", "wave"])),
                SimulationSceneStep(.performCandidates(["peek_over", "peek", "peek_at_user", "look_out", "think", "wave"])),
                SimulationSceneStep(.wait(120), decisionPoint: true),
            ], loopFrom: 2),
        SimulationSceneRecipe(
            id: "peek_at_user", label: "扒着窗沿看你",
            goals: [.explore, .seekAttention], needsUser: true,
            steps: [
                SimulationSceneStep(.moveTo("@activity.topLeft")),
                SimulationSceneStep(.performCandidates(["peek_over", "peek", "peek_at_user", "look_out", "think", "wave"])),
                SimulationSceneStep(.wait(120), decisionPoint: true),
            ], loopFrom: 2),
    ]

    @discardableResult
    public func start(_ goal: SimulationGoalDecision) -> Bool {
        guard status != .running else { return false }
        let candidates = recipes.filter { recipe in
            recipe.goals.contains(goal.goal) &&
                (recipe.activities.isEmpty || goal.activity == nil || recipe.activities.contains(goal.activity!))
        }
        guard let recipe = candidates.sorted(by: { $0.id < $1.id }).first else {
            status = .cancelled
            return false
        }
        return activate(recipe: recipe, goal: goal)
    }

    /// Start an already selected catalog recipe. Production CNeedle and the
    /// deterministic harness both use this cursor; selection may happen in a
    /// different adapter, but step/loop semantics stay in one implementation.
    @discardableResult
    public func start(recipeID: String, goal: SimulationGoalDecision) -> Bool {
        guard status != .running,
              let recipe = recipes.first(where: { $0.id == recipeID }),
              recipe.goals.contains(goal.goal),
              (recipe.activities.isEmpty || goal.activity == nil
                  || recipe.activities.contains(goal.activity!)) else {
            status = .cancelled
            return false
        }
        return activate(recipe: recipe, goal: goal)
    }

    private func activate(recipe: SimulationSceneRecipe, goal: SimulationGoalDecision) -> Bool {
        currentGoal = goal
        recipeID = recipe.id
        stepIndex = 0
        status = .running
        return true
    }

    public var currentStep: SimulationSceneStep? {
        guard status == .running, let recipeID,
              let recipe = recipes.first(where: { $0.id == recipeID }),
              recipe.steps.indices.contains(stepIndex) else { return nil }
        return recipe.steps[stepIndex]
    }

    @discardableResult
    public func completeStep() -> Bool {
        guard status == .running else { return status == .completed }
        stepIndex += 1
        guard let recipeID,
              let recipe = recipes.first(where: { $0.id == recipeID }) else {
            status = .cancelled
            return false
        }
        if stepIndex >= recipe.steps.count {
            if let loopFrom = recipe.loopFrom, recipe.steps.indices.contains(loopFrom) {
                stepIndex = loopFrom
                return false
            }
            status = .completed
            return true
        }
        return false
    }

    public func cancel() {
        status = .cancelled
    }

    public func finishEarly() {
        guard status == .running else { return }
        status = .completed
    }

    public func reset() {
        status = .idle
        currentGoal = nil
        recipeID = nil
        stepIndex = 0
    }

    public func snapshot() -> SimulationSceneRunnerSnapshot {
        SimulationSceneRunnerSnapshot(status: status, currentGoal: currentGoal, recipeID: recipeID, stepIndex: stepIndex)
    }

    public func restore(_ snapshot: SimulationSceneRunnerSnapshot) {
        status = snapshot.status
        currentGoal = snapshot.currentGoal
        recipeID = snapshot.recipeID
        stepIndex = snapshot.stepIndex
    }
}

// MARK: - Needle and action runtime

public enum SimulationBodyAction: Codable, Equatable, Sendable {
    case moveToPoint(Double)
    case walkAlong
    case perch(String)
    case hop
    case dropOff
}

public enum SimulationNeedleAction: Equatable, Sendable {
    case chooseScene(String)
    case moveTo(String)
    case perform(String)
    case performCandidates([String])
    case spawnProp(String)
    case clearProps
    case putDown
    case pickUp
    case leaveScene
    case wait(Int64)
    case say(String)
    case sleep
    case body(SimulationBodyAction)
}

extension SimulationNeedleAction: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable {
        case chooseScene, moveTo, perform, performCandidates, spawnProp, clearProps, putDown, pickUp, leaveScene
        case wait, say, sleep, body
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chooseScene(let value):
            try container.encode(Kind.chooseScene, forKey: .kind); try container.encode(value, forKey: .value)
        case .moveTo(let value):
            try container.encode(Kind.moveTo, forKey: .kind); try container.encode(value, forKey: .value)
        case .perform(let value):
            try container.encode(Kind.perform, forKey: .kind); try container.encode(value, forKey: .value)
        case .performCandidates(let values):
            try container.encode(Kind.performCandidates, forKey: .kind); try container.encode(values, forKey: .value)
        case .spawnProp(let value):
            try container.encode(Kind.spawnProp, forKey: .kind); try container.encode(value, forKey: .value)
        case .clearProps:
            try container.encode(Kind.clearProps, forKey: .kind)
        case .putDown:
            try container.encode(Kind.putDown, forKey: .kind)
        case .pickUp:
            try container.encode(Kind.pickUp, forKey: .kind)
        case .leaveScene:
            try container.encode(Kind.leaveScene, forKey: .kind)
        case .wait(let ticks):
            try container.encode(Kind.wait, forKey: .kind)
            try container.encode(ticks, forKey: .value)
        case .say(let value):
            try container.encode(Kind.say, forKey: .kind); try container.encode(value, forKey: .value)
        case .sleep:
            try container.encode(Kind.sleep, forKey: .kind)
        case .body(let value):
            try container.encode(Kind.body, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .chooseScene: self = .chooseScene(try container.decode(String.self, forKey: .value))
        case .moveTo: self = .moveTo(try container.decode(String.self, forKey: .value))
        case .perform: self = .perform(try container.decode(String.self, forKey: .value))
        case .performCandidates: self = .performCandidates(try container.decode([String].self, forKey: .value))
        case .spawnProp: self = .spawnProp(try container.decode(String.self, forKey: .value))
        case .clearProps: self = .clearProps
        case .putDown: self = .putDown
        case .pickUp: self = .pickUp
        case .leaveScene: self = .leaveScene
        case .wait: self = .wait(try container.decodeIfPresent(Int64.self, forKey: .value) ?? 1)
        case .say: self = .say(try container.decode(String.self, forKey: .value))
        case .sleep: self = .sleep
        case .body: self = .body(try container.decode(SimulationBodyAction.self, forKey: .value))
        }
    }
}

public struct SimulationNeedleCommand: Codable, Equatable, Sendable {
    public var atTick: Int64
    public var action: SimulationNeedleAction

    public init(atTick: Int64, action: SimulationNeedleAction) {
        self.atTick = atTick
        self.action = action
    }
}

public enum SimulationNeedleBrainMode: String, Codable, Sendable {
    case deterministic
    case replay
}

public enum SimulationNeedleMissPolicy: String, Codable, Sendable {
    case reject
    case waitForPrefetch
}

public enum SimulationSceneSelection: Equatable, Sendable {
    case automatic
    case selected(String)
    case waitForPrefetch
}

public enum SimulationDecisionPointChoice: Equatable, Sendable {
    case continueScene
    case leaveScene
    case say(String)
    case performCandidates([String])
    case waitForPrefetch
}

/// Small seam for replacing the deterministic NeedleBrain with a real C/API
/// provider. Providers return a semantic action only; ActionRuntime remains the
/// sole producer of BehaviorRequest values.
public protocol SimulationNeedleProvider: AnyObject {
    var providerID: String { get }
    var execution: SimulationProviderExecution { get }
    var missPolicy: SimulationNeedleMissPolicy { get }
    func setStoryScope(_ scope: String?)

    func chooseScene(
        goal: SimulationGoalDecision,
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationSceneSelection

    func decideAtPoint(
        step: SimulationSceneStep,
        goal: SimulationGoalDecision,
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationDecisionPointChoice

    func decide(
        step: SimulationSceneStep,
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationNeedleAction?
}

public extension SimulationNeedleProvider {
    var execution: SimulationProviderExecution { .runtimeImmediate }
    var missPolicy: SimulationNeedleMissPolicy { .reject }
    func setStoryScope(_ scope: String?) {}
    func chooseScene(
        goal: SimulationGoalDecision, tick: Int64, context: RuntimeContext,
        world: WorldState, actorID: EntityID
    ) -> SimulationSceneSelection { .automatic }
    func decideAtPoint(
        step: SimulationSceneStep, goal: SimulationGoalDecision,
        tick: Int64, context: RuntimeContext, world: WorldState,
        actorID: EntityID
    ) -> SimulationDecisionPointChoice { .continueScene }
}

public struct SimulationNeedleBrainSnapshot: Codable, Equatable, Sendable {
    public var mode: SimulationNeedleBrainMode
    public var replayCommands: [SimulationNeedleCommand]

    public init(mode: SimulationNeedleBrainMode, replayCommands: [SimulationNeedleCommand]) {
        self.mode = mode
        self.replayCommands = replayCommands
    }
}

public final class NeedleBrain {
    public let mode: SimulationNeedleBrainMode
    private var replayCommands: [SimulationNeedleCommand]

    public init(mode: SimulationNeedleBrainMode = .deterministic, replayCommands: [SimulationNeedleCommand] = []) {
        self.mode = mode
        self.replayCommands = replayCommands.sorted {
            $0.atTick == $1.atTick ? String(describing: $0.action) < String(describing: $1.action) : $0.atTick < $1.atTick
        }
    }

    public func decide(
        step: SimulationSceneStep,
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationNeedleAction? {
        guard world.isAlive(actorID) else { return nil }
        if mode == .replay {
            guard let index = replayCommands.firstIndex(where: { $0.atTick <= tick }) else { return nil }
            return replayCommands.remove(at: index).action
        }
        switch step.operation {
        case .moveTo(let anchor):
            // Only activity-relative anchors need a live focused window.
            // Stable world anchors such as `floor_near` remain legal in a
            // headless/no-window scenario, matching the production resolver.
            if anchor.hasPrefix("@activity."), context.focus == nil { return nil }
            return .moveTo(anchor)
        case .perform(let action): return .perform(action)
        case .performCandidates(let actions): return .performCandidates(actions)
        case .spawnProp(let id): return .spawnProp(id)
        case .clearProps: return .clearProps
        case .putDown: return .putDown
        case .pickUp: return .pickUp
        case .wait(let ticks): return .wait(ticks)
        case .say(let intent): return .say(intent)
        case .sleep: return .sleep
        }
    }

    public func snapshot() -> SimulationNeedleBrainSnapshot {
        SimulationNeedleBrainSnapshot(mode: mode, replayCommands: replayCommands)
    }

    public func restore(_ snapshot: SimulationNeedleBrainSnapshot) {
        replayCommands = snapshot.replayCommands
    }
}

extension NeedleBrain: SimulationNeedleProvider {
    public var providerID: String {
        mode == .replay ? "replay-needle" : "deterministic-needle"
    }
}

public enum SimulationAssetResolutionKind: String, Codable, Sendable {
    case exact
    case fallback
    case missing
}

public struct SimulationAssetResolution: Codable, Equatable, Sendable {
    public var action: String
    public var kind: SimulationAssetResolutionKind
    public var resolvedAction: String?

    public init(action: String, kind: SimulationAssetResolutionKind, resolvedAction: String? = nil) {
        self.action = action
        self.kind = kind
        self.resolvedAction = resolvedAction
    }

    public var usedFallback: Bool { kind == .fallback }
}

public struct AssetCatalog: Codable, Equatable, Sendable {
    public var exactActions: Set<String>
    public var fallbackActions: [String: [String]]

    public init(exactActions: Set<String> = [], fallbackActions: [String: [String]] = [:]) {
        self.exactActions = exactActions
        self.fallbackActions = fallbackActions
    }

    public func resolve(_ action: String) -> SimulationAssetResolution {
        if exactActions.contains(action) {
            return SimulationAssetResolution(action: action, kind: .exact, resolvedAction: action)
        }
        if let fallback = fallbackActions[action]?.first {
            return SimulationAssetResolution(action: action, kind: .fallback, resolvedAction: fallback)
        }
        return SimulationAssetResolution(action: action, kind: .missing)
    }
}

public struct SimulationContentFinding: Codable, Equatable, Sendable {
    public var action: String
    public var resolution: SimulationAssetResolutionKind
    public var resolvedAction: String?

    public init(action: String, resolution: SimulationAssetResolutionKind, resolvedAction: String? = nil) {
        self.action = action
        self.resolution = resolution
        self.resolvedAction = resolvedAction
    }

    public var usedFallback: Bool { resolution == .fallback }
}

public struct ContentVerdict: Codable, Equatable, Sendable {
    public var findings: [SimulationContentFinding]

    public init(findings: [SimulationContentFinding] = []) {
        self.findings = findings
    }

    public var complete: Bool { findings.allSatisfy { $0.resolution == .exact } }
}

public struct LogicVerdict: Codable, Equatable, Sendable {
    public var failures: [String]

    public init(failures: [String] = []) {
        self.failures = failures
    }

    public var passed: Bool { failures.isEmpty }
}

public struct PipelineTraceEntry: Codable, Equatable, Sendable {
    public var tick: Int64
    public var stage: String
    public var detail: String

    public init(tick: Int64, stage: String, detail: String) {
        self.tick = tick
        self.stage = stage
        self.detail = detail
    }
}

public struct ActionExecution: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let reason: String?
    public let request: BehaviorRequest?
    public let resolution: SimulationAssetResolution?

    init(
        accepted: Bool,
        reason: String? = nil,
        request: BehaviorRequest? = nil,
        resolution: SimulationAssetResolution? = nil
    ) {
        self.accepted = accepted
        self.reason = reason
        self.request = request
        self.resolution = resolution
    }
}

/// The data-only body adapter. It translates a valid semantic action into a
/// normal BehaviorRequest; it never moves a sprite or calls an OS API.
public final class ActionRuntime {
    private let assetCatalog: AssetCatalog
    private var sequence = 0

    public init(assetCatalog: AssetCatalog = AssetCatalog()) {
        self.assetCatalog = assetCatalog
    }

    /// A menu click is resolved against the world *after* its userInteraction
    /// event has advanced the plan epoch. It uses the same body command path
    /// as other semantic actions, with direct-user arbitration priority.
    public func executeUserDirect(
        _ actionName: String?,
        tick: Int64,
        actorID: EntityID,
        world: WorldState
    ) -> ActionExecution {
        let resolution = actionName.map(assetCatalog.resolve)
        if resolution?.kind == .missing {
            return ActionExecution(accepted: false, reason: "action_missing", resolution: resolution)
        }
        let id = "user-\(actorID.raw)-\(tick)-\(sequence)"
        sequence += 1
        return ActionExecution(accepted: true, request: BehaviorRequest(
            id: id, actorID: actorID,
            intent: actionName.map { "perform:\(resolution?.resolvedAction ?? $0)" } ?? "rest",
            priority: .userDirect,
            planEpoch: world.planEpochs[actorID.raw, default: 0],
            completionMode: .body, durationTicks: 1, timeoutTicks: 400),
            resolution: resolution)
    }

    public func execute(
        _ action: SimulationNeedleAction,
        tick: Int64,
        actorID: EntityID,
        world: WorldState,
        context: RuntimeContext
    ) -> ActionExecution {
        let epoch = world.planEpochs[actorID.raw, default: 0]
        let id = "semantic-\(actorID.raw)-\(tick)-\(sequence)"
        sequence += 1
        switch action {
        case .chooseScene(let sceneID):
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "choose_scene:\(sceneID)", priority: .brainReactive,
                planEpoch: epoch, completionMode: .body, durationTicks: 1, timeoutTicks: 400))
        case .moveTo(let anchor):
            let slot = slot(for: anchor, world: world, context: context)
            if anchor.isEmpty || (anchor.hasPrefix("@activity.") && context.focus == nil) {
                return ActionExecution(accepted: false, reason: "anchor_missing")
            }
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "move_to:\(anchor)", priority: .brainReactive,
                planEpoch: epoch, slot: slot, completionMode: .body,
                durationTicks: 1, timeoutTicks: 400, occupySlotOnSuccess: false))
        case .perform(let actionName):
            let resolution = assetCatalog.resolve(actionName)
            guard resolution.kind != .missing else {
                return ActionExecution(accepted: true, resolution: resolution)
            }
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID,
                intent: "perform:\(resolution.resolvedAction ?? actionName)",
                priority: .brainReactive, planEpoch: epoch, completionMode: .body,
                durationTicks: 1, timeoutTicks: 400), resolution: resolution)
        case .performCandidates(let candidates):
            let resolutions = candidates.map(assetCatalog.resolve)
            guard let resolution = resolutions.first(where: { $0.kind != .missing }) else {
                return ActionExecution(
                    accepted: true,
                    resolution: candidates.first.map {
                        SimulationAssetResolution(action: $0, kind: .missing)
                    })
            }
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID,
                intent: "perform:\(resolution.resolvedAction ?? resolution.action)",
                priority: .brainReactive, planEpoch: epoch, completionMode: .body,
                durationTicks: 1, timeoutTicks: 400), resolution: resolution)
        case .spawnProp(let propID):
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "spawn_prop:\(propID)", priority: .brainReactive,
                planEpoch: epoch, claims: ["manipulator"], completionMode: .body,
                durationTicks: 1, timeoutTicks: 400))
        case .clearProps:
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "clear_props", priority: .brainReactive,
                planEpoch: epoch, claims: ["manipulator"], completionMode: .body,
                durationTicks: 1, timeoutTicks: 400))
        case .putDown:
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "put_down", priority: .brainReactive,
                planEpoch: epoch, claims: ["manipulator"], completionMode: .body,
                durationTicks: 1, timeoutTicks: 400))
        case .pickUp:
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "pick_up", priority: .brainReactive,
                planEpoch: epoch, claims: ["manipulator"], completionMode: .body,
                durationTicks: 1, timeoutTicks: 400))
        case .leaveScene:
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "leave_scene", priority: .brainReactive,
                planEpoch: epoch, completionMode: .body, durationTicks: 1, timeoutTicks: 400))
        case .wait(let ticks):
            let duration = max(1, ticks)
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "wait", priority: .brainReactive,
                planEpoch: epoch, completionMode: .body,
                durationTicks: duration,
                timeoutTicks: max(400, duration == Int64.max ? duration : duration + 1)))
        case .say(let intent):
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "say:\(intent)", priority: .brainReactive,
                planEpoch: epoch, completionMode: .body, durationTicks: 1, timeoutTicks: 400))
        case .sleep:
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "sleep", priority: .ambient,
                planEpoch: epoch, completionMode: .body, durationTicks: 2, timeoutTicks: 400))
        case .body(let body):
            let intent: String
            switch body {
            case .moveToPoint(let point): intent = "move_to_point:\(point)"
            case .walkAlong: intent = "walk_along"
            case .perch(let entityID): intent = "perch:\(entityID)"
            case .hop: intent = "hop"
            case .dropOff: intent = "drop_off"
            }
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: intent, priority: .brainReactive,
                planEpoch: epoch, completionMode: .body, durationTicks: 1, timeoutTicks: 400))
        }
    }

    /// Story actions carry narrative priority/claims and therefore need a
    /// small context in addition to the ordinary free-play action. The
    /// semantic action is still resolved here; this method is the only place
    /// where the story planner is allowed to obtain its BehaviorRequest.
    public func executeStory(
        _ action: SimulationNeedleAction,
        tick: Int64,
        actorID: EntityID,
        world: WorldState,
        requestID: String,
        storyIntent: String,
        target: EntityRef?,
        slot: SlotRef?,
        claims: [String],
        durationTicks: Int64,
        occupySlotOnSuccess: Bool
    ) -> ActionExecution {
        // A Story beat is authored, not a free-play decision point. Needle may
        // confirm that beat, but a different action cannot be logged as chosen
        // while the body still performs the authored intent.
        guard action == .perform(storyIntent) else {
            return ActionExecution(accepted: false, reason: "story_action_mismatch")
        }
        let resolution = assetCatalog.resolve(storyIntent)
        let epoch = world.planEpochs[actorID.raw, default: 0]
        return ActionExecution(
            accepted: true,
            request: BehaviorRequest(
                id: requestID,
                actorID: actorID,
                intent: storyIntent,
                priority: .story,
                planEpoch: epoch,
                target: target,
                slot: slot,
                claims: claims,
                completionMode: .body,
                durationTicks: max(1, durationTicks),
                timeoutTicks: max(400, durationTicks),
                occupySlotOnSuccess: occupySlotOnSuccess),
            resolution: resolution)
    }

    public func snapshot() -> Int { sequence }

    public func restore(sequence: Int) { self.sequence = sequence }

    private func slot(for anchor: String, world: WorldState, context: RuntimeContext) -> SlotRef? {
        guard anchor.hasPrefix("@activity."), let window = context.focus else { return nil }
        let authored = String(anchor.dropFirst("@activity.".count))
        let candidates: [String]
        switch authored {
        case "topLeft": candidates = ["top.left"]
        case "topRight": candidates = ["top.right"]
        case "topCenter": candidates = ["top.center", "top.right", "top.left"]
        default: candidates = [authored]
        }
        return candidates.lazy.compactMap { world.slots["\(window.id.raw)/\($0)"]?.ref }.first
    }
}

// MARK: - Pipeline and simulation

public struct SemanticPipelineConfiguration: Codable, Equatable, Sendable {
    public var actorID: EntityID
    public var enabled: Bool
    public var assetCatalog: AssetCatalog
    public var goalMode: SimulationGoalBrainMode
    public var goalCommands: [SimulationGoalCommand]
    public var needleMode: SimulationNeedleBrainMode
    public var needleCommands: [SimulationNeedleCommand]
    public var initialGoal: SimulationGoalDecision?

    public init(
        actorID: EntityID,
        enabled: Bool = true,
        assetCatalog: AssetCatalog = AssetCatalog(),
        goalMode: SimulationGoalBrainMode = .policy,
        goalCommands: [SimulationGoalCommand] = [],
        needleMode: SimulationNeedleBrainMode = .deterministic,
        needleCommands: [SimulationNeedleCommand] = [],
        initialGoal: SimulationGoalDecision? = nil
    ) {
        self.actorID = actorID
        self.enabled = enabled
        self.assetCatalog = assetCatalog
        self.goalMode = goalMode
        self.goalCommands = goalCommands
        self.needleMode = needleMode
        self.needleCommands = needleCommands
        self.initialGoal = initialGoal
    }
}

public struct SemanticPipelineSnapshot: Codable, Equatable, Sendable {
    public var goalBrain: SimulationGoalBrainSnapshot
    public var sceneRunner: SimulationSceneRunnerSnapshot
    public var needleBrain: SimulationNeedleBrainSnapshot
    public var pendingActionID: String?
    public var pendingSceneGoal: SimulationGoalDecision?
    public var pendingSceneEpoch: Int64?
    public var pendingSceneContext: RuntimeContext?
    public var sceneEpoch: Int64?
    public var sleepingEpoch: Int64?
    public var pendingDecisionSinceTick: Int64?
    public var pendingDecisionAction: SimulationNeedleAction?
    public var trace: [PipelineTraceEntry]
    public var findings: [SimulationContentFinding]
    public var logicFailures: [String]
    public var actionSequence: Int

    public init(
        goalBrain: SimulationGoalBrainSnapshot,
        sceneRunner: SimulationSceneRunnerSnapshot,
        needleBrain: SimulationNeedleBrainSnapshot,
        pendingActionID: String?,
        pendingSceneGoal: SimulationGoalDecision? = nil,
        pendingSceneEpoch: Int64? = nil,
        pendingSceneContext: RuntimeContext? = nil,
        sceneEpoch: Int64? = nil,
        sleepingEpoch: Int64? = nil,
        pendingDecisionSinceTick: Int64? = nil,
        pendingDecisionAction: SimulationNeedleAction? = nil,
        trace: [PipelineTraceEntry],
        findings: [SimulationContentFinding],
        logicFailures: [String],
        actionSequence: Int
    ) {
        self.goalBrain = goalBrain
        self.sceneRunner = sceneRunner
        self.needleBrain = needleBrain
        self.pendingActionID = pendingActionID
        self.pendingSceneGoal = pendingSceneGoal
        self.pendingSceneEpoch = pendingSceneEpoch
        self.pendingSceneContext = pendingSceneContext
        self.sceneEpoch = sceneEpoch
        self.sleepingEpoch = sleepingEpoch
        self.pendingDecisionSinceTick = pendingDecisionSinceTick
        self.pendingDecisionAction = pendingDecisionAction
        self.trace = trace
        self.findings = findings
        self.logicFailures = logicFailures
        self.actionSequence = actionSequence
    }
}

/// Shared Goal/Scene/Needle body of both production and simulation. Adapters
/// decide when a Goal or Needle result arrives; scene cursor and action
/// authorization live here exactly once.
public final class SemanticEngine {
    public let sceneRunner: SceneRunner
    public let actionRuntime: ActionRuntime

    public init(
        recipes: [SimulationSceneRecipe] = SceneRunner.defaultRecipes,
        assetCatalog: AssetCatalog = AssetCatalog()
    ) {
        self.sceneRunner = SceneRunner(recipes: recipes)
        self.actionRuntime = ActionRuntime(assetCatalog: assetCatalog)
    }

    /// Authored story beats already are scene intents. Keep their conversion
    /// inside the same semantic engine without creating a second SceneRunner
    /// or a second action authority.
    public func storyStep(for beat: StoryBeat) -> SimulationSceneStep {
        SimulationSceneStep(.perform(beat.intent))
    }
}

public final class SemanticPipeline {
    public let configuration: SemanticPipelineConfiguration
    public let goalBrain: GoalBrain
    public let needleBrain: NeedleBrain
    public let engine: SemanticEngine
    public var sceneRunner: SceneRunner { engine.sceneRunner }
    public var actionRuntime: ActionRuntime { engine.actionRuntime }
    public private(set) var trace: [PipelineTraceEntry] = []
    public private(set) var findings: [SimulationContentFinding] = []
    public private(set) var logicFailures: [String] = []
    public private(set) var pendingActionID: String?
    public var isAwaitingDecision: Bool { pendingDecisionSinceTick != nil }
    private var pendingSceneGoal: SimulationGoalDecision?
    private var pendingSceneEpoch: Int64?
    private var pendingSceneContext: RuntimeContext?
    private var sceneEpoch: Int64?
    private var sleepingEpoch: Int64?
    private var pendingDecisionSinceTick: Int64?
    private var pendingDecisionAction: SimulationNeedleAction?
    private var currentAction: SimulationNeedleAction?
    private let goalProvider: (any SimulationGoalProvider)?
    private let needleProvider: (any SimulationNeedleProvider)?

    public init(
        configuration: SemanticPipelineConfiguration,
        goalProvider: (any SimulationGoalProvider)? = nil,
        needleProvider: (any SimulationNeedleProvider)? = nil,
        recipes: [SimulationSceneRecipe] = SceneRunner.defaultRecipes
    ) {
        self.configuration = configuration
        self.goalProvider = goalProvider
        self.needleProvider = needleProvider
        self.goalBrain = GoalBrain(
            mode: configuration.goalMode,
            replayCommands: configuration.goalCommands,
            initialGoal: configuration.initialGoal)
        self.engine = SemanticEngine(recipes: recipes, assetCatalog: configuration.assetCatalog)
        self.needleBrain = NeedleBrain(
            mode: configuration.needleMode,
            replayCommands: configuration.needleCommands)
    }

    /// Run the four semantic stages after this tick's environment events have
    /// been applied and before behavior advancement. Only the final
    /// ActionRuntime output crosses the GameEvent boundary.
    func beforeTick(kernel: GameKernel, context: RuntimeContext) {
        guard configuration.enabled, kernel.world.isAlive(configuration.actorID) else { return }
        let tick = kernel.clock.tick
        let epoch = kernel.world.planEpochs[configuration.actorID.raw, default: 0]
        if sceneRunner.status == .running, let sceneEpoch, sceneEpoch != epoch {
            sceneRunner.cancel()
            pendingDecisionSinceTick = nil
            pendingDecisionAction = nil
            sleepingEpoch = nil
            trace.append(PipelineTraceEntry(tick: tick, stage: "scene", detail: "preempted"))
            return
        }
        guard pendingActionID == nil else { return }
        if sleepingEpoch != nil { return }
        if sceneRunner.status != .running {
            if pendingSceneEpoch != kernel.world.planEpochs[configuration.actorID.raw, default: 0]
                || pendingSceneContext != context {
                pendingSceneGoal = nil
                pendingSceneEpoch = nil
                pendingSceneContext = nil
            }
            let provider = goalProvider ?? goalBrain
            guard provider.execution == .runtimeImmediate else {
                logicFailures.append("blocking_goal_provider_requires_prefetch")
                return
            }
            let goal: SimulationGoalDecision
            if let pendingSceneGoal {
                goal = pendingSceneGoal
            } else {
                guard let chosen = provider.decide(
                    tick: tick, context: context, world: kernel.world,
                    actorID: configuration.actorID) else { return }
                goal = chosen
                pendingSceneGoal = chosen
                pendingSceneEpoch = kernel.world.planEpochs[configuration.actorID.raw, default: 0]
                pendingSceneContext = context
                trace.append(PipelineTraceEntry(
                    tick: tick, stage: "goal", detail: "\(provider.providerID):\(goal.goal.rawValue)"))
            }
            let selector = needleProvider ?? needleBrain
            guard selector.execution == .runtimeImmediate else {
                logicFailures.append("blocking_scene_provider_requires_prefetch")
                return
            }
            let selection = selector.chooseScene(
                goal: goal, tick: tick, context: context,
                world: kernel.world, actorID: configuration.actorID)
            if selection == .waitForPrefetch { return }
            let started: Bool
            switch selection {
            case .automatic: started = sceneRunner.start(goal)
            case .selected(let id): started = sceneRunner.start(recipeID: id, goal: goal)
            case .waitForPrefetch: return
            }
            guard started else {
                pendingSceneGoal = nil
                pendingSceneEpoch = nil
                pendingSceneContext = nil
                logicFailures.append("scene_missing:\(goal.goal.rawValue)")
                trace.append(PipelineTraceEntry(tick: tick, stage: "scene", detail: "missing"))
                return
            }
            pendingSceneGoal = nil
            pendingSceneEpoch = nil
            pendingSceneContext = nil
            sceneEpoch = epoch
            trace.append(PipelineTraceEntry(tick: tick, stage: "scene", detail: sceneRunner.recipeID ?? "-"))
        }
        if let since = pendingDecisionSinceTick {
            let provider = needleProvider ?? needleBrain
            guard provider.execution == .runtimeImmediate else {
                logicFailures.append("blocking_decision_provider_requires_prefetch")
                return
            }
            guard let step = sceneRunner.currentStep,
                  let goal = sceneRunner.currentGoal else {
                sceneRunner.cancel()
                pendingDecisionSinceTick = nil
                return
            }
            var choice = provider.decideAtPoint(
                step: step, goal: goal, tick: tick, context: context,
                world: kernel.world, actorID: configuration.actorID)
            if choice == .waitForPrefetch {
                guard tick - since >= 400 else { return }
                choice = .continueScene
                trace.append(PipelineTraceEntry(tick: tick, stage: "decision", detail: "timeout_continue"))
            }
            pendingDecisionSinceTick = nil
            switch choice {
            case .continueScene:
                trace.append(PipelineTraceEntry(tick: tick, stage: "decision", detail: "continue"))
                completeCurrentStep(tick: tick)
            case .leaveScene, .say, .performCandidates:
                let action: SimulationNeedleAction
                switch choice {
                case .leaveScene: action = .leaveScene
                case .say(let intent): action = .say(intent)
                case .performCandidates(let candidates): action = .performCandidates(candidates)
                default: return
                }
                let execution = actionRuntime.execute(
                    action, tick: tick, actorID: configuration.actorID,
                    world: kernel.world, context: context)
                guard execution.accepted else {
                    sceneRunner.cancel()
                    return
                }
                trace.append(PipelineTraceEntry(
                    tick: tick, stage: "decision", detail: describe(action)))
                guard let request = execution.request else {
                    completeCurrentStep(tick: tick)
                    return
                }
                pendingDecisionAction = action
                pendingActionID = request.id
                kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: tick)
                return
            case .waitForPrefetch: return
            }
        }
        guard sceneRunner.status == .running else { return }
        guard let step = sceneRunner.currentStep else {
            logicFailures.append("scene_step_missing")
            sceneRunner.cancel()
            return
        }
        let provider = needleProvider ?? needleBrain
        guard provider.execution == .runtimeImmediate else {
            logicFailures.append("blocking_needle_provider_requires_prefetch")
            return
        }
        guard let action = provider.decide(
                step: step, tick: tick, context: context,
                world: kernel.world, actorID: configuration.actorID) else {
            if provider.missPolicy == .waitForPrefetch { return }
            logicFailures.append("needle_no_legal_action")
            sceneRunner.cancel()
            return
        }
        currentAction = action
        trace.append(PipelineTraceEntry(
            tick: tick, stage: "needle", detail: "\(provider.providerID):\(describe(action))"))
        let execution = actionRuntime.execute(
            action, tick: tick, actorID: configuration.actorID,
            world: kernel.world, context: context)
        if let resolution = execution.resolution {
            findings.append(SimulationContentFinding(
                action: resolution.action,
                resolution: resolution.kind,
                resolvedAction: resolution.resolvedAction))
            trace.append(PipelineTraceEntry(
                tick: tick, stage: "action",
                detail: "\(resolution.action):\(resolution.kind.rawValue):\(resolution.resolvedAction ?? "-" )"))
        } else {
            trace.append(PipelineTraceEntry(
                tick: tick, stage: "action",
                detail: execution.accepted ? "accepted" : "rejected:\(execution.reason ?? "unknown")"))
        }
        guard execution.accepted else {
            logicFailures.append("action_rejected:\(execution.reason ?? "unknown")")
            sceneRunner.cancel()
            return
        }
        guard let request = execution.request else {
            completeCurrentStep(tick: tick)
            return
        }
        pendingActionID = request.id
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: tick)
    }

    /// Consume the kernel result after the tick boundary. The pipeline never
    /// edits behavior state directly.
    func afterTick(kernel: GameKernel) {
        guard let actionID = pendingActionID,
              let state = kernel.world.behaviors[actionID] else { return }
        switch state.status {
        case .completed:
            trace.append(PipelineTraceEntry(tick: kernel.clock.tick - 1, stage: "action", detail: "completed"))
            pendingActionID = nil
            if let decisionAction = pendingDecisionAction {
                pendingDecisionAction = nil
                if case .leaveScene = decisionAction {
                    sceneRunner.finishEarly()
                    trace.append(PipelineTraceEntry(
                        tick: kernel.clock.tick - 1, stage: "scene", detail: "completed"))
                } else {
                    completeCurrentStep(tick: kernel.clock.tick - 1)
                }
            } else if case .sleep = sceneRunner.currentStep?.operation {
                sleepingEpoch = sceneEpoch
                trace.append(PipelineTraceEntry(
                    tick: kernel.clock.tick - 1, stage: "scene", detail: "sleeping"))
            } else if sceneRunner.currentStep?.decisionPoint == true {
                pendingDecisionSinceTick = kernel.clock.tick - 1
                trace.append(PipelineTraceEntry(
                    tick: kernel.clock.tick - 1, stage: "decision", detail: "pending"))
            } else {
                completeCurrentStep(tick: kernel.clock.tick - 1)
            }
        case .cancelled, .rejected:
            trace.append(PipelineTraceEntry(tick: kernel.clock.tick - 1, stage: "action", detail: "aborted:\(state.status.rawValue)"))
            logicFailures.append("action_\(state.status.rawValue):\(actionID)")
            pendingActionID = nil
            pendingDecisionAction = nil
            pendingDecisionSinceTick = nil
            sleepingEpoch = nil
            sceneRunner.cancel()
        case .running:
            break
        }
    }

    public func snapshot() -> SemanticPipelineSnapshot {
        SemanticPipelineSnapshot(
            goalBrain: goalBrain.snapshot(),
            sceneRunner: sceneRunner.snapshot(),
            needleBrain: needleBrain.snapshot(),
            pendingActionID: pendingActionID,
            pendingSceneGoal: pendingSceneGoal,
            pendingSceneEpoch: pendingSceneEpoch,
            pendingSceneContext: pendingSceneContext,
            sceneEpoch: sceneEpoch,
            sleepingEpoch: sleepingEpoch,
            pendingDecisionSinceTick: pendingDecisionSinceTick,
            pendingDecisionAction: pendingDecisionAction,
            trace: trace,
            findings: findings,
            logicFailures: logicFailures,
            actionSequence: actionRuntime.snapshot())
    }

    public func restore(_ snapshot: SemanticPipelineSnapshot) {
        goalBrain.restore(snapshot.goalBrain)
        sceneRunner.restore(snapshot.sceneRunner)
        needleBrain.restore(snapshot.needleBrain)
        pendingActionID = snapshot.pendingActionID
        pendingSceneGoal = snapshot.pendingSceneGoal
        pendingSceneEpoch = snapshot.pendingSceneEpoch
        pendingSceneContext = snapshot.pendingSceneContext
        sceneEpoch = snapshot.sceneEpoch
        sleepingEpoch = snapshot.sleepingEpoch
        pendingDecisionSinceTick = snapshot.pendingDecisionSinceTick
        pendingDecisionAction = snapshot.pendingDecisionAction
        trace = snapshot.trace
        findings = snapshot.findings
        logicFailures = snapshot.logicFailures
        actionRuntime.restore(sequence: snapshot.actionSequence)
    }

    func logicVerdict(kernel: GameKernel, expectations: ScenarioExpectations) -> LogicVerdict {
        var failures = logicFailures
        failures.append(contentsOf: expectations.check(kernel: kernel, pipelineTrace: trace))
        return LogicVerdict(failures: Array(Set(failures)).sorted())
    }

    public func contentVerdict() -> ContentVerdict {
        ContentVerdict(findings: findings)
    }

    private func completeCurrentStep(tick: Int64) {
        if sceneRunner.completeStep() {
            trace.append(PipelineTraceEntry(tick: tick, stage: "scene", detail: "completed"))
        }
        currentAction = nil
    }

    private func describe(_ action: SimulationNeedleAction) -> String {
        switch action {
        case .chooseScene(let value): return "choose_scene:\(value)"
        case .moveTo(let value): return "move_to:\(value)"
        case .perform(let value): return "perform:\(value)"
        case .performCandidates(let values): return "perform_candidates:\(values.joined(separator: ","))"
        case .spawnProp(let value): return "spawn_prop:\(value)"
        case .clearProps: return "clear_props"
        case .putDown: return "put_down"
        case .pickUp: return "pick_up"
        case .leaveScene: return "leave_scene"
        case .wait(let ticks): return "wait:\(ticks)"
        case .say(let value): return "say:\(value)"
        case .sleep: return "sleep"
        case .body(let value): return "body:\(String(describing: value))"
        }
    }
}

// MARK: - Deterministic execution / fuzz seams

public struct SeededRNG: RandomNumberGenerator, Codable, Equatable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    public mutating func index(count: Int) -> Int? {
        guard count > 0 else { return nil }
        return Int(next() % UInt64(count))
    }
}

public enum ChaosFault: String, Codable, CaseIterable, Sendable {
    case moveFocusedWindow
    case closeFocusedWindow
    case expireObservation
    case userDrag
}

public struct ChaosProfile: Codable, Equatable, Sendable {
    public var faults: [ChaosFault]
    public var atTicks: [Int64]

    public init(faults: [ChaosFault] = [], atTicks: [Int64] = []) {
        self.faults = faults
        self.atTicks = atTicks
    }
}

public enum ChaosSimulator {
    public static func apply(
        to scenario: HarnessScenario,
        seed: UInt64,
        profile: ChaosProfile
    ) -> HarnessScenario {
        guard !scenario.desktop.windows.isEmpty, !profile.faults.isEmpty else { return scenario }
        var result = scenario
        var rng = SeededRNG(seed: seed)
        let windowIDs = result.desktop.windows.values.filter(\.alive).map(\.id).sorted { $0.raw < $1.raw }
        for tick in profile.atTicks.sorted() {
            guard !windowIDs.isEmpty else { continue }
            let windowID = windowIDs[rng.index(count: windowIDs.count) ?? 0]
            for fault in profile.faults {
                switch fault {
                case .moveFocusedWindow:
                    result.desktop.schedule(VirtualDesktopEvent(
                        atTick: tick,
                        action: .moveWindow(windowID, LayoutRect(x: Double(tick), y: 10, width: 600, height: 400))))
                case .closeFocusedWindow:
                    result.desktop.schedule(VirtualDesktopEvent(atTick: tick, action: .closeWindow(windowID)))
                case .expireObservation:
                    let observation = InputObservation(
                        id: "chaos-\(tick)", pluginID: "browser-content", channel: .browser,
                        appName: "Browser", text: "chaos", capturedAtTick: tick, expiresAtTick: tick)
                    result.desktop.schedule(VirtualDesktopEvent(atTick: tick, action: .emitObservation(
                        VirtualSensorObservation(observation: observation))))
                case .userDrag:
                    result.desktop.schedule(VirtualDesktopEvent(atTick: tick, action: .user(
                        VirtualUserAction(kind: .dragActor, actorID: result.pipeline?.actorID))))
                }
            }
        }
        return result
    }
}

public struct ScenarioGenerator {
    public init() {}

    public func variants(of scenario: HarnessScenario, count: Int, seed: UInt64) -> [HarnessScenario] {
        guard count > 0 else { return [] }
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { index in
            var variant = scenario
            variant.id = "\(scenario.id)-variant-\(index)"
            let offset = Int64(rng.next() % 4)
            variant.events = scenario.events.map { event in
                var shifted = event
                shifted.atTick += offset
                return shifted
            }
            if let window = variant.desktop.windows.values.sorted(by: { $0.id.raw < $1.id.raw }).first {
                variant.desktop.schedule(VirtualDesktopEvent(
                    atTick: offset,
                    action: .moveWindow(window.id, LayoutRect(
                        x: Double(rng.next() % 80), y: 20,
                        width: window.frame.width, height: window.frame.height))))
            }
            return variant
        }
    }
}

public struct DataSimulationSnapshot: Codable, Equatable, Sendable {
    public var scenario: HarnessScenario
    public let runtimeCheckpoint: GameRuntimeCheckpoint?
    public var desktop: VirtualDesktop
    public var pipeline: SemanticPipelineSnapshot?
    private var legacyKernel: KernelSnapshot?

    public var kernel: KernelSnapshot { runtimeCheckpoint?.kernel ?? legacyKernel! }

    public init(
        scenario: HarnessScenario,
        runtimeCheckpoint: GameRuntimeCheckpoint,
        desktop: VirtualDesktop,
        pipeline: SemanticPipelineSnapshot?
    ) {
        self.scenario = scenario
        self.runtimeCheckpoint = runtimeCheckpoint
        self.desktop = desktop
        self.pipeline = pipeline
        self.legacyKernel = nil
    }

    public init(
        scenario: HarnessScenario,
        kernel: KernelSnapshot,
        desktop: VirtualDesktop,
        pipeline: SemanticPipelineSnapshot?
    ) {
        self.scenario = scenario
        self.runtimeCheckpoint = nil
        self.desktop = desktop
        self.pipeline = pipeline
        self.legacyKernel = kernel
    }

    private enum CodingKeys: String, CodingKey {
        case scenario, runtimeCheckpoint, kernel, desktop, pipeline
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scenario = try values.decode(HarnessScenario.self, forKey: .scenario)
        runtimeCheckpoint = try values.decodeIfPresent(GameRuntimeCheckpoint.self, forKey: .runtimeCheckpoint)
        legacyKernel = try values.decodeIfPresent(KernelSnapshot.self, forKey: .kernel)
        guard runtimeCheckpoint != nil || legacyKernel != nil else {
            throw DecodingError.keyNotFound(CodingKeys.runtimeCheckpoint,
                .init(codingPath: values.codingPath, debugDescription: "Missing runtime checkpoint"))
        }
        desktop = try values.decode(VirtualDesktop.self, forKey: .desktop)
        pipeline = try values.decodeIfPresent(SemanticPipelineSnapshot.self, forKey: .pipeline)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scenario, forKey: .scenario)
        if let runtimeCheckpoint {
            try values.encode(runtimeCheckpoint, forKey: .runtimeCheckpoint)
        } else if let legacyKernel {
            try values.encode(legacyKernel, forKey: .kernel)
        }
        try values.encode(desktop, forKey: .desktop)
        try values.encodeIfPresent(pipeline, forKey: .pipeline)
    }
}

/// One deterministic, rewindable execution of VirtualDesktop → GameKernel →
/// GoalBrain → SceneRunner → NeedleBrain → ActionRuntime.
public final class DataSimulation {
    public let scenario: HarnessScenario
    public private(set) var runtime: GameRuntime
    public var kernel: KernelSnapshot { runtime.snapshot() }
    public private(set) var desktop: VirtualDesktop
    public let pipeline: SemanticPipeline?

    public init(scenario: HarnessScenario) {
        self.scenario = scenario
        self.runtime = GameRuntime(kernel: GameKernel(scenario: scenario))
        self.desktop = scenario.desktop
        self.pipeline = scenario.pipeline.map { SemanticPipeline(configuration: $0) }
    }

    public init(snapshot: DataSimulationSnapshot) {
        self.scenario = snapshot.scenario
        self.runtime = snapshot.runtimeCheckpoint.map(GameRuntime.init(checkpoint:))
            ?? GameRuntime(snapshot: snapshot.kernel)
        self.desktop = snapshot.desktop
        if let configuration = snapshot.scenario.pipeline {
            let pipeline = SemanticPipeline(configuration: configuration)
            if let snapshot = snapshot.pipeline { pipeline.restore(snapshot) }
            self.pipeline = pipeline
        } else {
            self.pipeline = nil
        }
    }

    @discardableResult
    public func step() -> TickReport {
        let tick = runtime.clock.tick
        let events = desktop.advance(to: tick)
        if let pipeline {
            return runtime.step(
                events: events,
                pipeline: pipeline,
                context: desktop.runtimeContext)!
        }
        return runtime.step(events: events)!
    }

    @discardableResult
    public func run(ticks: Int64) -> [TickReport] {
        guard ticks > 0 else { return [] }
        return (0..<ticks).map { _ in step() }
    }

    public func snapshot() -> DataSimulationSnapshot {
        DataSimulationSnapshot(
            scenario: scenario,
            runtimeCheckpoint: runtime.checkpoint(),
            desktop: desktop,
            pipeline: pipeline?.snapshot())
    }
}
