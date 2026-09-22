import Foundation

/// Async model adapters prepare values outside GameRuntime.step. Inside the
/// runtime lock this provider only validates scope and consumes a cached value.
public final class PreparedSemanticProvider: SimulationGoalProvider, SimulationNeedleProvider {
    public let actorID: EntityID
    public let providerID = "prepared-semantic"
    public let execution: SimulationProviderExecution = .runtimeImmediate
    public let missPolicy: SimulationNeedleMissPolicy = .waitForPrefetch

    private struct Prepared<Value> {
        let epoch: Int64
        let context: RuntimeContext
        let value: Value
    }

    private let lock = NSLock()
    private var goal: Prepared<SimulationGoalDecision>?
    private var scene: Prepared<(SimulationGoalDecision, SimulationSceneSelection)>?
    private var decision: Prepared<(SimulationGoalDecision, SimulationSceneStep, SimulationDecisionPointChoice)>?
    private var allowsProps = true

    public func setPropsEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        allowsProps = enabled
    }

    public init(actorID: EntityID) {
        self.actorID = actorID
    }

    public func setStoryScope(_ scope: String?) {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        goal = nil
        scene = nil
        decision = nil
    }

    public func prepareGoal(
        _ value: SimulationGoalDecision,
        planEpoch: Int64,
        context: RuntimeContext
    ) {
        lock.lock()
        defer { lock.unlock() }
        goal = Prepared(epoch: planEpoch, context: context, value: value)
    }

    public func prepareSceneSelection(
        _ value: SimulationSceneSelection,
        goal: SimulationGoalDecision,
        planEpoch: Int64,
        context: RuntimeContext
    ) {
        lock.lock()
        defer { lock.unlock() }
        scene = Prepared(epoch: planEpoch, context: context, value: (goal, value))
    }

    public func prepareDecision(
        _ value: SimulationDecisionPointChoice,
        goal: SimulationGoalDecision,
        step: SimulationSceneStep,
        planEpoch: Int64,
        context: RuntimeContext
    ) {
        lock.lock()
        defer { lock.unlock() }
        decision = Prepared(epoch: planEpoch, context: context, value: (goal, step, value))
    }

    public func decide(
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationGoalDecision? {
        lock.lock()
        defer { lock.unlock() }
        defer { goal = nil }
        guard actorID == self.actorID, let goal,
              goal.epoch == world.planEpochs[actorID.raw, default: 0],
              goal.context == context else { return nil }
        return goal.value
    }

    public func chooseScene(
        goal: SimulationGoalDecision,
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationSceneSelection {
        lock.lock()
        defer { lock.unlock() }
        defer { scene = nil }
        guard actorID == self.actorID, let scene,
              scene.epoch == world.planEpochs[actorID.raw, default: 0],
              scene.context == context,
              scene.value.0 == goal else { return .waitForPrefetch }
        return scene.value.1
    }

    public func decide(
        step: SimulationSceneStep,
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationNeedleAction? {
        lock.lock()
        let propsEnabled = allowsProps
        lock.unlock()
        if !propsEnabled {
            switch step.operation {
            case .spawnProp, .clearProps, .putDown, .pickUp: return .wait(1)
            default: break
            }
        }
        return NeedleBrain().decide(
            step: step, tick: tick, context: context,
            world: world, actorID: actorID)
    }

    public func decideAtPoint(
        step: SimulationSceneStep,
        goal: SimulationGoalDecision,
        tick: Int64,
        context: RuntimeContext,
        world: WorldState,
        actorID: EntityID
    ) -> SimulationDecisionPointChoice {
        lock.lock()
        defer { lock.unlock() }
        defer { decision = nil }
        guard actorID == self.actorID, let decision,
              decision.epoch == world.planEpochs[actorID.raw, default: 0],
              decision.context == context,
              decision.value.0 == goal,
              decision.value.1 == step else { return .waitForPrefetch }
        return decision.value.2
    }
}
