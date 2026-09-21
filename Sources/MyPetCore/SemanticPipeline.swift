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

/// Small seam for replacing the deterministic GoalBrain with a real provider.
/// Providers return a goal only; they never create a BehaviorRequest.
public protocol SimulationGoalProvider: AnyObject {
    var providerID: String { get }

    func decide(
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationGoalDecision?
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
    case wait(Int64)
    case say(String)
    case sleep
}

extension SimulationSceneOperation: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value, ticks }
    private enum Kind: String, Codable { case moveTo, perform, wait, say, sleep }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .moveTo(let value):
            try container.encode(Kind.moveTo, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .perform(let value):
            try container.encode(Kind.perform, forKey: .kind)
            try container.encode(value, forKey: .value)
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
    public var goals: [SimulationGoalKind]
    public var activities: [String]
    public var steps: [SimulationSceneStep]

    public init(id: String, goals: [SimulationGoalKind], activities: [String] = [], steps: [SimulationSceneStep]) {
        self.id = id
        self.goals = goals
        self.activities = activities
        self.steps = steps
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
            goals: [.joinUserActivity, .watchWithUser],
            activities: ["coding", "writing", "reading", "browsing", "unknown"],
            steps: [
                SimulationSceneStep(.moveTo("@activity.top.right")),
                SimulationSceneStep(.perform("think")),
                SimulationSceneStep(.wait(1), decisionPoint: true),
            ]),
        SimulationSceneRecipe(
            id: "wander",
            goals: [.wander, .explore, .rest],
            steps: [
                SimulationSceneStep(.moveTo("floor")),
                SimulationSceneStep(.perform("think")),
                SimulationSceneStep(.wait(1), decisionPoint: true),
            ]),
        SimulationSceneRecipe(
            id: "seek_attention",
            goals: [.seekAttention],
            steps: [
                SimulationSceneStep(.moveTo("floor")),
                SimulationSceneStep(.perform("greet")),
                SimulationSceneStep(.say("greet")),
                SimulationSceneStep(.wait(1), decisionPoint: true),
            ]),
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
            status = .completed
            return true
        }
        return false
    }

    public func cancel() {
        status = .cancelled
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

public enum SimulationNeedleAction: Equatable, Sendable {
    case moveTo(String)
    case perform(String)
    case wait
    case say(String)
    case sleep
}

extension SimulationNeedleAction: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case moveTo, perform, wait, say, sleep }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .moveTo(let value):
            try container.encode(Kind.moveTo, forKey: .kind); try container.encode(value, forKey: .value)
        case .perform(let value):
            try container.encode(Kind.perform, forKey: .kind); try container.encode(value, forKey: .value)
        case .wait:
            try container.encode(Kind.wait, forKey: .kind)
        case .say(let value):
            try container.encode(Kind.say, forKey: .kind); try container.encode(value, forKey: .value)
        case .sleep:
            try container.encode(Kind.sleep, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .moveTo: self = .moveTo(try container.decode(String.self, forKey: .value))
        case .perform: self = .perform(try container.decode(String.self, forKey: .value))
        case .wait: self = .wait
        case .say: self = .say(try container.decode(String.self, forKey: .value))
        case .sleep: self = .sleep
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

/// Small seam for replacing the deterministic NeedleBrain with a real C/API
/// provider. Providers return a semantic action only; ActionRuntime remains the
/// sole producer of BehaviorRequest values.
public protocol SimulationNeedleProvider: AnyObject {
    var providerID: String { get }

    func decide(
        step: SimulationSceneStep,
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationNeedleAction?
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
            if anchor == "floor" { return .moveTo(anchor) }
            guard context.focus != nil else { return nil }
            return .moveTo(anchor)
        case .perform(let action): return .perform(action)
        case .wait: return .wait
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
    public var accepted: Bool
    public var reason: String?
    public var request: BehaviorRequest?
    public var resolution: SimulationAssetResolution?

    public init(
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

    /// Production and headless adapters share this final request gate. An
    /// adapter may choose a semantic intent, but it cannot construct its own
    /// plan epoch, request identity, claims or duration outside MyPetCore.
    public func executeIntent(
        _ intent: String,
        tick: Int64,
        actorID: EntityID,
        world: WorldState,
        priority: PriorityBand = .brainReactive,
        claims: [String] = ["body"],
        durationTicks: Int64 = 1
    ) -> ActionExecution {
        let request = BehaviorRequest(
            id: "semantic-\(actorID.raw)-\(tick)-\(sequence)",
            actorID: actorID,
            intent: intent,
            priority: priority,
            planEpoch: world.planEpochs[actorID.raw, default: 0],
            claims: claims,
            durationTicks: durationTicks)
        sequence += 1
        return ActionExecution(accepted: true, request: request)
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
        case .moveTo(let anchor):
            let slot = slot(for: anchor, world: world, context: context)
            if anchor != "floor" && slot == nil {
                return ActionExecution(accepted: false, reason: "anchor_missing")
            }
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "move_to:\(anchor)", priority: .brainReactive,
                planEpoch: epoch, slot: slot, durationTicks: 1, occupySlotOnSuccess: false))
        case .perform(let actionName):
            let resolution = assetCatalog.resolve(actionName)
            guard resolution.kind != .missing else {
                return ActionExecution(accepted: true, resolution: resolution)
            }
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID,
                intent: "perform:\(resolution.resolvedAction ?? actionName)",
                priority: .brainReactive, planEpoch: epoch, durationTicks: 1), resolution: resolution)
        case .wait:
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "wait", priority: .brainReactive,
                planEpoch: epoch, durationTicks: 1))
        case .say(let intent):
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "say:\(intent)", priority: .brainReactive,
                planEpoch: epoch, durationTicks: 1))
        case .sleep:
            return ActionExecution(accepted: true, request: BehaviorRequest(
                id: id, actorID: actorID, intent: "sleep", priority: .ambient,
                planEpoch: epoch, durationTicks: 2))
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
        let resolution: SimulationAssetResolution?
        switch action {
        case .perform(let actionName):
            resolution = assetCatalog.resolve(actionName)
        default:
            resolution = nil
        }
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
                durationTicks: max(1, durationTicks),
                occupySlotOnSuccess: occupySlotOnSuccess),
            resolution: resolution)
    }

    public func snapshot() -> Int { sequence }

    public func restore(sequence: Int) { self.sequence = sequence }

    private func slot(for anchor: String, world: WorldState, context: RuntimeContext) -> SlotRef? {
        guard anchor.hasPrefix("@activity."), let window = context.focus else { return nil }
        let slotID = String(anchor.dropFirst("@activity.".count))
        return world.slots["\(window.id.raw)/\(slotID)"]?.ref
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
    public var trace: [PipelineTraceEntry]
    public var findings: [SimulationContentFinding]
    public var logicFailures: [String]
    public var actionSequence: Int

    public init(
        goalBrain: SimulationGoalBrainSnapshot,
        sceneRunner: SimulationSceneRunnerSnapshot,
        needleBrain: SimulationNeedleBrainSnapshot,
        pendingActionID: String?,
        trace: [PipelineTraceEntry],
        findings: [SimulationContentFinding],
        logicFailures: [String],
        actionSequence: Int
    ) {
        self.goalBrain = goalBrain
        self.sceneRunner = sceneRunner
        self.needleBrain = needleBrain
        self.pendingActionID = pendingActionID
        self.trace = trace
        self.findings = findings
        self.logicFailures = logicFailures
        self.actionSequence = actionSequence
    }
}

public final class SemanticPipeline {
    public let configuration: SemanticPipelineConfiguration
    public let goalBrain: GoalBrain
    public let sceneRunner: SceneRunner
    public let needleBrain: NeedleBrain
    public let actionRuntime: ActionRuntime
    public private(set) var trace: [PipelineTraceEntry] = []
    public private(set) var findings: [SimulationContentFinding] = []
    public private(set) var logicFailures: [String] = []
    public private(set) var pendingActionID: String?
    private var currentAction: SimulationNeedleAction?
    private let goalProvider: (any SimulationGoalProvider)?
    private let needleProvider: (any SimulationNeedleProvider)?

    public init(
        configuration: SemanticPipelineConfiguration,
        goalProvider: (any SimulationGoalProvider)? = nil,
        needleProvider: (any SimulationNeedleProvider)? = nil
    ) {
        self.configuration = configuration
        self.goalProvider = goalProvider
        self.needleProvider = needleProvider
        self.goalBrain = GoalBrain(
            mode: configuration.goalMode,
            replayCommands: configuration.goalCommands,
            initialGoal: configuration.initialGoal)
        self.sceneRunner = SceneRunner()
        self.needleBrain = NeedleBrain(
            mode: configuration.needleMode,
            replayCommands: configuration.needleCommands)
        self.actionRuntime = ActionRuntime(assetCatalog: configuration.assetCatalog)
    }

    /// Run the four semantic stages after this tick's environment events have
    /// been applied and before behavior advancement. Only the final
    /// ActionRuntime output crosses the GameEvent boundary.
    public func beforeTick(kernel: GameKernel, context: RuntimeContext) {
        guard configuration.enabled, pendingActionID == nil,
              kernel.world.isAlive(configuration.actorID) else { return }
        let tick = kernel.clock.tick
        if sceneRunner.status != .running {
            let provider = goalProvider ?? goalBrain
            guard let goal = provider.decide(
                tick: tick, context: context, world: kernel.world, actorID: configuration.actorID) else { return }
            trace.append(PipelineTraceEntry(
                tick: tick, stage: "goal", detail: "\(provider.providerID):\(goal.goal.rawValue)"))
            guard sceneRunner.start(goal) else {
                logicFailures.append("scene_missing:\(goal.goal.rawValue)")
                trace.append(PipelineTraceEntry(tick: tick, stage: "scene", detail: "missing"))
                return
            }
            trace.append(PipelineTraceEntry(tick: tick, stage: "scene", detail: sceneRunner.recipeID ?? "-"))
        }
        guard let step = sceneRunner.currentStep else {
            logicFailures.append("scene_step_missing")
            sceneRunner.cancel()
            return
        }
        let provider = needleProvider ?? needleBrain
        guard let action = provider.decide(
                step: step, tick: tick, context: context,
                world: kernel.world, actorID: configuration.actorID) else {
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
    public func afterTick(kernel: GameKernel) {
        guard let actionID = pendingActionID,
              let state = kernel.world.behaviors[actionID] else { return }
        switch state.status {
        case .completed:
            trace.append(PipelineTraceEntry(tick: kernel.clock.tick - 1, stage: "action", detail: "completed"))
            pendingActionID = nil
            completeCurrentStep(tick: kernel.clock.tick - 1)
        case .cancelled, .rejected:
            trace.append(PipelineTraceEntry(tick: kernel.clock.tick - 1, stage: "action", detail: "aborted:\(state.status.rawValue)"))
            logicFailures.append("action_\(state.status.rawValue):\(actionID)")
            pendingActionID = nil
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
        trace = snapshot.trace
        findings = snapshot.findings
        logicFailures = snapshot.logicFailures
        actionRuntime.restore(sequence: snapshot.actionSequence)
    }

    public func logicVerdict(kernel: GameKernel, expectations: ScenarioExpectations) -> LogicVerdict {
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
        case .moveTo(let value): return "move_to:\(value)"
        case .perform(let value): return "perform:\(value)"
        case .wait: return "wait"
        case .say(let value): return "say:\(value)"
        case .sleep: return "sleep"
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
    public var kernel: KernelSnapshot
    public var desktop: VirtualDesktop
    public var pipeline: SemanticPipelineSnapshot?

    public init(
        scenario: HarnessScenario,
        kernel: KernelSnapshot,
        desktop: VirtualDesktop,
        pipeline: SemanticPipelineSnapshot?
    ) {
        self.scenario = scenario
        self.kernel = kernel
        self.desktop = desktop
        self.pipeline = pipeline
    }
}

/// One deterministic, rewindable execution of VirtualDesktop → GameKernel →
/// GoalBrain → SceneRunner → NeedleBrain → ActionRuntime.
public final class DataSimulation {
    public let scenario: HarnessScenario
    public private(set) var runtime: GameRuntime
    public var kernel: GameKernel { runtime.kernel }
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
        self.runtime = GameRuntime(snapshot: snapshot.kernel)
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
        let report = runtime.step(events: events) { runtime in
            self.pipeline?.beforeTick(kernel: runtime.kernel, context: self.desktop.runtimeContext)
        }!
        pipeline?.afterTick(kernel: runtime.kernel)
        return report
    }

    @discardableResult
    public func run(ticks: Int64) -> [TickReport] {
        guard ticks > 0 else { return [] }
        return (0..<ticks).map { _ in step() }
    }

    public func snapshot() -> DataSimulationSnapshot {
        DataSimulationSnapshot(
            scenario: scenario,
            kernel: runtime.snapshot(),
            desktop: desktop,
            pipeline: pipeline?.snapshot())
    }
}
