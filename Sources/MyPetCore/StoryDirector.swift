import Foundation

public struct StoryDirectorConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// 完成一段后是否允许自动再次选择剧情；关闭后不会自动启动下一段。
    public var repeatEpisodes: Bool
    /// Minimum gap between episode starts; zero means no extra gap.
    public var intervalTicks: Int64
    /// One minute at the default 50ms simulation clock.
    public var maxDurationTicks: Int64
    public var interruptOnForeground: Bool
    public var interruptOnContent: Bool
    public var relationshipEffectsEnabled: Bool

    public init(
        enabled: Bool = true,
        repeatEpisodes: Bool = true,
        intervalTicks: Int64 = 0,
        maxDurationTicks: Int64 = 1_200,
        interruptOnForeground: Bool = true,
        interruptOnContent: Bool = true,
        relationshipEffectsEnabled: Bool = true
    ) {
        self.enabled = enabled
        self.repeatEpisodes = repeatEpisodes
        self.intervalTicks = max(0, intervalTicks)
        self.maxDurationTicks = max(1, maxDurationTicks)
        self.interruptOnForeground = interruptOnForeground
        self.interruptOnContent = interruptOnContent
        self.relationshipEffectsEnabled = relationshipEffectsEnabled
    }

    public var interruptionPolicy: StoryInterruptionPolicy {
        StoryInterruptionPolicy(
            foreground: interruptOnForeground,
            content: interruptOnContent)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, repeatEpisodes, intervalTicks, maxDurationTicks
        case interruptOnForeground, interruptOnContent, relationshipEffectsEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            repeatEpisodes: try values.decodeIfPresent(Bool.self, forKey: .repeatEpisodes) ?? true,
            intervalTicks: try values.decodeIfPresent(Int64.self, forKey: .intervalTicks) ?? 0,
            maxDurationTicks: try values.decodeIfPresent(Int64.self, forKey: .maxDurationTicks) ?? 1_200,
            interruptOnForeground: try values.decodeIfPresent(Bool.self, forKey: .interruptOnForeground) ?? true,
            interruptOnContent: try values.decodeIfPresent(Bool.self, forKey: .interruptOnContent) ?? true,
            relationshipEffectsEnabled: try values.decodeIfPresent(
                Bool.self, forKey: .relationshipEffectsEnabled) ?? true)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(repeatEpisodes, forKey: .repeatEpisodes)
        try values.encode(intervalTicks, forKey: .intervalTicks)
        try values.encode(maxDurationTicks, forKey: .maxDurationTicks)
        try values.encode(interruptOnForeground, forKey: .interruptOnForeground)
        try values.encode(interruptOnContent, forKey: .interruptOnContent)
        try values.encode(relationshipEffectsEnabled, forKey: .relationshipEffectsEnabled)
    }
}

public struct StoryAction: Codable, Equatable, Sendable {
    /// Links this presentation request to the Kernel-authorized body command.
    public let behaviorID: String?
    public let episodeID: String
    public let beatID: String
    public let actorID: EntityID
    public let intent: String
    public let durationTicks: Int64
    /// Cast changes are emitted once with the first actor's action. The runtime
    /// consumes them through CastDirector so invitations stay on the same event
    /// and capacity path as menu-driven invitations.
    public let inviteMemberIDs: [String]?
    public let targetID: String?
    public let slotID: String?
    public let branchID: String?

    public init(behaviorID: String? = nil,
                episodeID: String, beatID: String, actorID: EntityID,
                intent: String, durationTicks: Int64,
                inviteMemberIDs: [String]? = nil,
                targetID: String? = nil,
                slotID: String? = nil,
                branchID: String? = nil) {
        self.behaviorID = behaviorID
        self.episodeID = episodeID
        self.beatID = beatID
        self.actorID = actorID
        self.intent = intent
        self.durationTicks = durationTicks
        self.inviteMemberIDs = inviteMemberIDs?.filter { !$0.isEmpty }
        self.targetID = targetID
        self.slotID = slotID
        self.branchID = branchID
    }
}

/// Result of resolving one story actor through the semantic action chain.
public struct StoryBehaviorPlan: Sendable {
    public let request: BehaviorRequest
    public let semanticAction: SimulationNeedleAction

    public init(request: BehaviorRequest, semanticAction: SimulationNeedleAction) {
        self.request = request
        self.semanticAction = semanticAction
    }
}

/// Seam between narrative scheduling and action selection. StoryDirector owns
/// episode/beat lifecycle; the provider owns Goal/Needle/Action translation.
public protocol StoryExecutionProvider: AnyObject {
    var runtimeSafe: Bool { get }
    var waitingForPrefetch: Bool { get }
    func setStoryScope(_ scope: String?)

    func plan(
        requestID: String,
        beat: StoryBeat,
        actorID: EntityID,
        target: EntityRef?,
        slot: SlotRef?,
        world: WorldState,
        tick: Int64
    ) -> StoryBehaviorPlan?
}

public extension StoryExecutionProvider {
    var runtimeSafe: Bool { false }
    var waitingForPrefetch: Bool { false }
    func setStoryScope(_ scope: String?) {}
}

/// Pure-data story implementation. A real Harness provider can replace the
/// Needle provider while keeping this same StoryDirector interface.
public final class SemanticStoryExecutionProvider: StoryExecutionProvider {
    private let goalProvider: any SimulationGoalProvider
    private let needleProvider: any SimulationNeedleProvider
    private let engine: SemanticEngine
    private let context: RuntimeContext
    private var cachedGoalKey: String?
    private var cachedGoal: SimulationGoalDecision?
    private var storyScope: String?
    public private(set) var trace: [PipelineTraceEntry] = []
    public private(set) var waitingForPrefetch = false
    public var runtimeSafe: Bool {
        goalProvider.execution == .runtimeImmediate &&
            needleProvider.execution == .runtimeImmediate
    }

    public init(
        goalProvider: (any SimulationGoalProvider)? = nil,
        needleProvider: (any SimulationNeedleProvider)? = nil,
        engine: SemanticEngine = SemanticEngine(),
        context: RuntimeContext = RuntimeContext()
    ) {
        self.goalProvider = goalProvider ?? GoalBrain()
        self.needleProvider = needleProvider ?? NeedleBrain()
        self.engine = engine
        self.context = context
    }

    public func setStoryScope(_ scope: String?) {
        guard storyScope != scope else { return }
        storyScope = scope
        cachedGoalKey = nil
        cachedGoal = nil
        waitingForPrefetch = false
        goalProvider.setStoryScope(scope)
        needleProvider.setStoryScope(scope)
    }

    public func plan(
        requestID: String,
        beat: StoryBeat,
        actorID: EntityID,
        target: EntityRef?,
        slot: SlotRef?,
        world: WorldState,
        tick: Int64
    ) -> StoryBehaviorPlan? {
        waitingForPrefetch = false
        // StoryDirector chooses the authored beat, but it still enters the
        // same semantic chain as free play: GoalBrain supplies motivation,
        // SceneRunner materializes the beat as a scene recipe, then Needle
        // selects the semantic action and ActionRuntime creates the request.
        let goalKey = (storyScope ?? "-") + ":" + beat.id + ":" + actorID.raw + ":" + String(tick)
        let goal: SimulationGoalDecision?
        if cachedGoalKey == goalKey, let cachedGoal {
            goal = cachedGoal
        } else {
            goal = goalProvider.decide(
                tick: tick, context: context, world: world, actorID: actorID)
            cachedGoalKey = goalKey
            cachedGoal = goal
        }
        guard let goal else {
            waitingForPrefetch = goalProvider.missPolicy == .waitForPrefetch
            trace.append(PipelineTraceEntry(
                tick: tick, stage: "story.goal",
                detail: goalProvider.providerID + ":missing:" + beat.id))
            return nil
        }
        trace.append(PipelineTraceEntry(
            tick: tick, stage: "story.goal",
            detail: goalProvider.providerID + ":" + goal.goal.rawValue + ":" + beat.id))

        // A cast beat is already an authored scene intent; the shared engine
        // translates it without creating another mutable SceneRunner.
        let step = engine.storyStep(for: beat)
        trace.append(PipelineTraceEntry(
            tick: tick, stage: "story.scene", detail: "story/" + beat.id))
        guard let action = needleProvider.decide(
            step: step,
            tick: tick,
            context: context,
                world: world,
                actorID: actorID) else {
            waitingForPrefetch = needleProvider.missPolicy == .waitForPrefetch
            trace.append(PipelineTraceEntry(
                tick: tick, stage: "story.needle",
                detail: needleProvider.providerID + ":missing:" + beat.id))
            return nil
        }
        trace.append(PipelineTraceEntry(
            tick: tick, stage: "story.needle",
            detail: needleProvider.providerID + ":" + Self.describe(action) + ":" + beat.id))
        let execution = engine.actionRuntime.executeStory(
            action,
            tick: tick,
            actorID: actorID,
            world: world,
            requestID: requestID,
            storyIntent: beat.intent,
            target: target,
            slot: slot,
            claims: beat.claims ?? ["body"],
            durationTicks: beat.durationTicks,
            occupySlotOnSuccess: beat.occupySlotOnSuccess)
        trace.append(PipelineTraceEntry(
            tick: tick, stage: "story.action",
            detail: execution.accepted
                ? "accepted:" + beat.id
                : "rejected:" + (execution.reason ?? "unknown")))
        guard execution.accepted, let request = execution.request else { return nil }
        return StoryBehaviorPlan(request: request, semanticAction: action)
    }

    private static func describe(_ action: SimulationNeedleAction) -> String {
        switch action {
        case .chooseScene(let value): return "choose_scene:" + value
        case .moveTo(let value): return "move_to:" + value
        case .perform(let value): return "perform:" + value
        case .performCandidates(let values): return "perform_candidates:" + values.joined(separator: ",")
        case .spawnProp(let value): return "spawn_prop:" + value
        case .clearProps: return "clear_props"
        case .putDown: return "put_down"
        case .pickUp: return "pick_up"
        case .leaveScene: return "leave_scene"
        case .wait: return "wait"
        case .say(let value): return "say:" + value
        case .sleep: return "sleep"
        case .body(let value): return "body:" + String(describing: value)
        }
    }
}

/// A replayable presentation cue emitted exactly when a successful release
/// boundary authorizes a following receive beat. It never mutates world state;
/// the kernel's slot/attachment facts remain the only ownership truth.
public struct StoryHandoffEvent: Codable, Equatable, Sendable {
    public let episodeID: String
    public let beatID: String
    public let handoff: StoryHandoff
    public let atTick: Int64
    public let branchID: String?

    public init(
        episodeID: String,
        beatID: String,
        handoff: StoryHandoff,
        atTick: Int64,
        branchID: String? = nil
    ) {
        self.episodeID = episodeID
        self.beatID = beatID
        self.handoff = handoff
        self.atTick = atTick
        self.branchID = branchID
    }
}

/// 剧情编排器的可回放检查点。它与 GameKernelSnapshot 分开保存：
/// kernel 记录世界/行为，director 记录当前剧情游标，二者必须成对恢复。
public struct StoryDirectorSnapshot: Codable, Equatable, Sendable {
    public let configuration: StoryDirectorConfiguration
    public let currentEpisode: StoryEpisode?
    public let currentEpisodeID: String?
    public let currentBeatID: String?
    public let currentBranchID: String?
    public let interruptedEpisodeID: String?
    public let beatIndex: Int
    public let requestIDs: [String]
    public let cooldownUntil: [String: Int64]
    public let runCounter: Int
    public let queuedActions: [StoryAction]
    public let queuedHandoffEvents: [StoryHandoffEvent]
    public let nextEpisodeTick: Int64
    public let currentStartedAtTick: Int64?
    /// Historical completions in this director run. This is intentionally
    /// separate from the expiring world completion fact so long-running
    /// harness reports can answer whether an episode ever completed.
    public let completedEpisodeCount: Int

    public init(
        configuration: StoryDirectorConfiguration = StoryDirectorConfiguration(),
        currentEpisode: StoryEpisode?,
        currentEpisodeID: String?,
        currentBeatID: String?,
        currentBranchID: String? = nil,
        interruptedEpisodeID: String?,
        beatIndex: Int,
        requestIDs: [String],
        cooldownUntil: [String: Int64],
        runCounter: Int,
        queuedActions: [StoryAction],
        queuedHandoffEvents: [StoryHandoffEvent] = [],
        nextEpisodeTick: Int64 = 0,
        currentStartedAtTick: Int64? = nil,
        completedEpisodeCount: Int = 0
    ) {
        self.configuration = configuration
        self.currentEpisode = currentEpisode
        self.currentEpisodeID = currentEpisodeID
        self.currentBeatID = currentBeatID
        self.currentBranchID = currentBranchID
        self.interruptedEpisodeID = interruptedEpisodeID
        self.beatIndex = max(0, beatIndex)
        self.requestIDs = requestIDs
        self.cooldownUntil = cooldownUntil
        self.runCounter = max(0, runCounter)
        self.queuedActions = queuedActions
        self.queuedHandoffEvents = queuedHandoffEvents
        self.nextEpisodeTick = max(0, nextEpisodeTick)
        self.currentStartedAtTick = currentStartedAtTick
        self.completedEpisodeCount = max(0, completedEpisodeCount)
    }

    private enum CodingKeys: String, CodingKey {
        case configuration, currentEpisode, currentEpisodeID, currentBeatID, currentBranchID
        case interruptedEpisodeID, beatIndex, requestIDs, cooldownUntil
        case runCounter, queuedActions, queuedHandoffEvents, nextEpisodeTick, currentStartedAtTick
        case completedEpisodeCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            configuration: try values.decodeIfPresent(
                StoryDirectorConfiguration.self, forKey: .configuration)
                ?? StoryDirectorConfiguration(),
            currentEpisode: try values.decodeIfPresent(StoryEpisode.self, forKey: .currentEpisode),
            currentEpisodeID: try values.decodeIfPresent(String.self, forKey: .currentEpisodeID),
            currentBeatID: try values.decodeIfPresent(String.self, forKey: .currentBeatID),
            currentBranchID: try values.decodeIfPresent(String.self, forKey: .currentBranchID),
            interruptedEpisodeID: try values.decodeIfPresent(String.self, forKey: .interruptedEpisodeID),
            beatIndex: try values.decodeIfPresent(Int.self, forKey: .beatIndex) ?? 0,
            requestIDs: try values.decodeIfPresent([String].self, forKey: .requestIDs) ?? [],
            cooldownUntil: try values.decodeIfPresent([String: Int64].self, forKey: .cooldownUntil) ?? [:],
            runCounter: try values.decodeIfPresent(Int.self, forKey: .runCounter) ?? 0,
            queuedActions: try values.decodeIfPresent([StoryAction].self, forKey: .queuedActions) ?? [],
            queuedHandoffEvents: try values.decodeIfPresent(
                [StoryHandoffEvent].self, forKey: .queuedHandoffEvents) ?? [],
            nextEpisodeTick: try values.decodeIfPresent(Int64.self, forKey: .nextEpisodeTick) ?? 0,
            currentStartedAtTick: try values.decodeIfPresent(Int64.self, forKey: .currentStartedAtTick),
            completedEpisodeCount: try values.decodeIfPresent(
                Int.self, forKey: .completedEpisodeCount) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(configuration, forKey: .configuration)
        try values.encodeIfPresent(currentEpisode, forKey: .currentEpisode)
        try values.encodeIfPresent(currentEpisodeID, forKey: .currentEpisodeID)
        try values.encodeIfPresent(currentBeatID, forKey: .currentBeatID)
        try values.encodeIfPresent(currentBranchID, forKey: .currentBranchID)
        try values.encodeIfPresent(interruptedEpisodeID, forKey: .interruptedEpisodeID)
        try values.encode(beatIndex, forKey: .beatIndex)
        try values.encode(requestIDs, forKey: .requestIDs)
        try values.encode(cooldownUntil, forKey: .cooldownUntil)
        try values.encode(runCounter, forKey: .runCounter)
        try values.encode(queuedActions, forKey: .queuedActions)
        try values.encode(queuedHandoffEvents, forKey: .queuedHandoffEvents)
        try values.encode(nextEpisodeTick, forKey: .nextEpisodeTick)
        try values.encodeIfPresent(currentStartedAtTick, forKey: .currentStartedAtTick)
        try values.encode(completedEpisodeCount, forKey: .completedEpisodeCount)
    }
}

/// 多角色剧情节拍编排器。
///
/// 它不直接改角色位置，也不让 LLM 写关系数值；每个节拍只向
/// `GameKernel` 投递带 actorID 的行为请求。一个节拍的所有参与者都成功后，
/// 才一次性提交该节拍的声明式效果；取消、抢占、拒绝或参与者退场都会中断
/// 当前剧情且不提交未完成效果。
public final class StoryDirector {
    public let episodes: [StoryEpisode]
    private let executionProvider: any StoryExecutionProvider
    public private(set) var configuration: StoryDirectorConfiguration
    public private(set) var currentEpisodeID: String?
    public private(set) var currentBeatID: String?
    public private(set) var currentBranchID: String?
    public private(set) var interruptedEpisodeID: String?
    /// Historical episode completions for this run. Completion facts in the
    /// world are deliberately TTL-bound and are not a durable run counter.
    public private(set) var completedEpisodeCount = 0

    /// Diagnostic-only trace of the semantic provider. It is intentionally
    /// separate from Kernel trace so model inputs/outputs stay in the Harness
    /// provider records while stage ordering remains visible in cast reports.
    public var executionTrace: [PipelineTraceEntry] {
        (executionProvider as? SemanticStoryExecutionProvider)?.trace ?? []
    }

    private var currentEpisode: StoryEpisode?
    private var beatIndex = 0
    private var requestIDs: [String] = []
    private var cooldownUntil: [String: Int64] = [:]
    private var runCounter = 0
    private var queuedActions: [StoryAction] = []
    private var queuedHandoffEvents: [StoryHandoffEvent] = []
    private var nextEpisodeTick: Int64 = 0
    private var currentStartedAtTick: Int64?

    public init(
        episodes: [StoryEpisode],
        configuration: StoryDirectorConfiguration = StoryDirectorConfiguration(),
        executionProvider: (any StoryExecutionProvider)? = nil
    ) {
        self.episodes = episodes.sorted { $0.id < $1.id }
        self.configuration = configuration
        self.executionProvider = executionProvider ?? SemanticStoryExecutionProvider()
    }

    @discardableResult
    func startNext(in kernel: GameKernel) -> String? {
        guard currentEpisode == nil else { return nil }
        guard executionProvider.runtimeSafe else { return nil }
        guard configuration.enabled, kernel.clock.tick >= nextEpisodeTick else { return nil }
        guard !kernel.runningBehaviorStates.contains(where: {
            $0.status == .running && $0.request.priority == .story
        }) else { return nil }
        let available = Set(kernel.world.entities.values.filter(\.alive).map { $0.id.raw })
        let eligible = StoryCatalog.eligible(
            episodes: episodes,
            world: kernel.world,
            tick: kernel.clock.tick,
            availableMembers: available)
            .filter { cooldownUntil[$0.id, default: 0] <= kernel.clock.tick }
        guard let episode = eligible.first else { return nil }
        let branch = StoryCatalog.branch(
            for: episode,
            world: kernel.world,
            tick: kernel.clock.tick,
            availableMembers: available)
        var resolvedEpisode = episode
        if let branch { resolvedEpisode.beats = branch.beats }
        guard !resolvedEpisode.beats.isEmpty else { return nil }
        guard StoryCatalog.firstBeatCanStart(
            resolvedEpisode.beats[0], world: kernel.world, availableMembers: available) else {
            return nil
        }
        currentEpisode = resolvedEpisode
        currentEpisodeID = episode.id
        currentBranchID = branch?.id
        interruptedEpisodeID = nil
        beatIndex = 0
        runCounter += 1
        currentStartedAtTick = kernel.clock.tick
        scheduleCurrentBeat(in: kernel)
        return episode.id
    }

    /// 在 Runtime 的语义阶段调用，观察上一轮已经确认的行为终态。
    func tick(in kernel: GameKernel) {
        guard let episode = currentEpisode else { return }
        guard !requestIDs.isEmpty else {
            if executionProvider.waitingForPrefetch {
                if let startedAt = currentStartedAtTick,
                   kernel.clock.tick - startedAt >= configuration.maxDurationTicks {
                    abort(episode: episode, in: kernel)
                    return
                }
                scheduleCurrentBeat(in: kernel)
                return
            }
            abort(episode: episode, in: kernel)
            return
        }
        let states = requestIDs.compactMap { kernel.world.behaviors[$0] }
        guard states.count == requestIDs.count else {
            abort(episode: episode, in: kernel)
            return
        }
        if states.contains(where: { $0.status == .cancelled || $0.status == .rejected }) {
            abort(episode: episode, in: kernel)
            return
        }
        if states.contains(where: { $0.status == .running }) {
            if let startedAt = currentStartedAtTick,
               kernel.clock.tick - startedAt >= configuration.maxDurationTicks {
                abort(episode: episode, in: kernel)
            }
            return
        }
        guard states.allSatisfy({ $0.status == .completed }) else {
            abort(episode: episode, in: kernel)
            return
        }

        if let beat = episode.beats[safe: beatIndex] {
            if beat.releaseSlotOnSuccess {
                releaseBeatSlots(for: beat, in: kernel)
                queueHandoffEvent(for: beat, in: episode, kernel: kernel)
            }
            if !beat.effectsOnSuccess.isEmpty {
                commitEffects(beat.effectsOnSuccess, in: kernel)
            }
        }
        beatIndex += 1
        guard beatIndex < episode.beats.count else {
            commitEffects([.setFact(
                "episode/\(episode.id)/completed", ttl: episode.cooldownTicks > 0
                    ? episode.cooldownTicks : nil)], in: kernel)
            completedEpisodeCount += 1
            cooldownUntil[episode.id] = kernel.clock.tick + episode.cooldownTicks
            nextEpisodeTick = kernel.clock.tick + configuration.intervalTicks
            if !configuration.repeatEpisodes { nextEpisodeTick = Int64.max }
            currentEpisode = nil
            currentEpisodeID = nil
            currentBeatID = nil
            currentBranchID = nil
            requestIDs.removeAll()
            currentStartedAtTick = nil
            executionProvider.setStoryScope(nil)
            return
        }
        scheduleCurrentBeat(in: kernel)
    }

    public func drainActions() -> [StoryAction] {
        defer { queuedActions.removeAll() }
        return queuedActions
    }

    public func drainStoryHandoffEvents() -> [StoryHandoffEvent] {
        defer { queuedHandoffEvents.removeAll() }
        return queuedHandoffEvents
    }

    public func snapshot() -> StoryDirectorSnapshot {
        StoryDirectorSnapshot(
            configuration: configuration,
            currentEpisode: currentEpisode,
            currentEpisodeID: currentEpisodeID,
            currentBeatID: currentBeatID,
            currentBranchID: currentBranchID,
            interruptedEpisodeID: interruptedEpisodeID,
            beatIndex: beatIndex,
            requestIDs: requestIDs,
            cooldownUntil: cooldownUntil,
            runCounter: runCounter,
            queuedActions: queuedActions,
            queuedHandoffEvents: queuedHandoffEvents,
            nextEpisodeTick: nextEpisodeTick,
            currentStartedAtTick: currentStartedAtTick,
            completedEpisodeCount: completedEpisodeCount)
    }

    public func restore(from snapshot: StoryDirectorSnapshot) {
        configuration = snapshot.configuration
        currentEpisode = snapshot.currentEpisode
        currentEpisodeID = snapshot.currentEpisodeID
        currentBeatID = snapshot.currentBeatID
        currentBranchID = snapshot.currentBranchID
        interruptedEpisodeID = snapshot.interruptedEpisodeID
        beatIndex = snapshot.beatIndex
        requestIDs = snapshot.requestIDs
        cooldownUntil = snapshot.cooldownUntil
        runCounter = snapshot.runCounter
        queuedActions = snapshot.queuedActions
        queuedHandoffEvents = snapshot.queuedHandoffEvents
        nextEpisodeTick = snapshot.nextEpisodeTick
        currentStartedAtTick = snapshot.currentStartedAtTick
        completedEpisodeCount = snapshot.completedEpisodeCount
        if let episode = currentEpisode, let beat = episode.beats[safe: beatIndex] {
            executionProvider.setStoryScope(
                "\(episode.id)/\(runCounter)/\(beat.id)/\(beatIndex)")
        } else {
            executionProvider.setStoryScope(nil)
        }
    }

    func abortCurrent(in kernel: GameKernel) {
        guard let episode = currentEpisode else { return }
        abort(episode: episode, in: kernel)
    }

    private func scheduleCurrentBeat(in kernel: GameKernel) {
        guard let episode = currentEpisode, let beat = episode.beats[safe: beatIndex] else { return }
        executionProvider.setStoryScope(
            "\(episode.id)/\(runCounter)/\(beat.id)/\(beatIndex)")
        currentBeatID = beat.id
        requestIDs.removeAll()
        queuedActions.removeAll()
        let run = runCounter
        var planned: [(requestID: String, plan: StoryBehaviorPlan, action: StoryAction)] = []
        for (index, actorID) in beat.actorIDs.enumerated() {
            let entityID = EntityID(actorID)
            guard kernel.world.isAlive(entityID) else {
                abort(episode: episode, in: kernel)
                return
            }
            let requestID = "story/\(episode.id)/run-\(run)/beat-\(beat.id)/\(actorID)"
            let inferredTargetID: String? = beat.targetID ?? {
                guard beat.actorIDs.count == 2 else { return nil }
                return beat.actorIDs.first { $0 != actorID }
            }()
            let target = inferredTargetID.flatMap { kernel.world.entity(EntityID($0))?.ref }
            let resolvedSlot = inferredTargetID.flatMap { targetID in
                beat.slotID.flatMap { slotID in kernel.world.slots["\(targetID)/\(slotID)"]?.ref }
            }
            // A release-only beat still points at its target, but must not try
            // to claim the already occupied slot before releasing it.
            let slot = beat.releaseSlotOnSuccess && !beat.occupySlotOnSuccess
                ? nil : resolvedSlot
            guard let plan = executionProvider.plan(
                requestID: requestID,
                beat: beat,
                actorID: entityID,
                target: target,
                slot: slot,
                world: kernel.world,
                tick: kernel.clock.tick) else {
                if executionProvider.waitingForPrefetch {
                    requestIDs.removeAll()
                    queuedActions.removeAll()
                    return
                }
                abort(episode: episode, in: kernel)
                return
            }
            var action = StoryAction(
                behaviorID: requestID,
                episodeID: episode.id,
                beatID: beat.id,
                actorID: entityID,
                intent: beat.intent,
                durationTicks: beat.durationTicks,
                targetID: inferredTargetID,
                slotID: beat.slotID,
                branchID: currentBranchID)
            if index == 0, let inviteMemberIDs = beat.inviteMemberIDs, !inviteMemberIDs.isEmpty {
                action = StoryAction(
                    behaviorID: requestID,
                    episodeID: episode.id,
                    beatID: beat.id,
                    actorID: entityID,
                    intent: beat.intent,
                    durationTicks: beat.durationTicks,
                    inviteMemberIDs: inviteMemberIDs,
                    targetID: inferredTargetID,
                    slotID: beat.slotID,
                    branchID: currentBranchID)
            }
            planned.append((requestID, plan, action))
        }
        for item in planned {
            requestIDs.append(item.requestID)
            kernel.enqueue(
                GameEvent(kind: .behaviorRequest, request: item.plan.request),
                atTick: kernel.clock.tick)
            queuedActions.append(item.action)
        }
    }

    private func abort(episode: StoryEpisode, in kernel: GameKernel) {
        for id in requestIDs {
            // A request may still be in the inbox, not yet visible in World.
            // The cancellation is sequenced after that request at this tick;
            // already-terminal or absent requests are harmless no-ops.
            kernel.enqueue(GameEvent(kind: .cancelBehavior, behaviorID: id), atTick: kernel.clock.tick)
        }
        commitEffects([.setFact(
            "episode/\(episode.id)/interrupted", ttl: max(1, episode.cooldownTicks))], in: kernel)
        interruptedEpisodeID = episode.id
        currentEpisode = nil
        currentEpisodeID = nil
        currentBeatID = nil
        currentBranchID = nil
        requestIDs.removeAll()
        queuedActions.removeAll()
        // A handoff event is emitted only after the source beat completed and
        // its release boundary was queued. A later interruption may cancel the
        // receiver beat, but it must not erase an already-observable event
        // that a delayed recorder still needs to consume.
        currentStartedAtTick = nil
        executionProvider.setStoryScope(nil)
        nextEpisodeTick = kernel.clock.tick + configuration.intervalTicks
        cooldownUntil[episode.id] = kernel.clock.tick + max(1, episode.cooldownTicks)
    }

    private func commitEffects(_ effects: [SuccessEffect], in kernel: GameKernel) {
        guard configuration.relationshipEffectsEnabled else {
            kernel.commitStoryEffects(effects.filter { $0.kind != .relationDelta })
            return
        }
        kernel.commitStoryEffects(effects)
    }

    /// Queue release events instead of mutating the world during director
    /// inspection. The next kernel tick therefore owns the hand-off boundary,
    /// keeps replay ordering explicit, and lets the following beat claim the
    /// same slot deterministically.
    private func releaseBeatSlots(for beat: StoryBeat, in kernel: GameKernel) {
        var released = Set<SlotRef>()
        for requestID in requestIDs {
            let request = kernel.world.behaviors[requestID]?.request
            let slot = request?.slot ?? beat.targetID.flatMap { targetID in
                beat.slotID.flatMap { slotID in kernel.world.slots["\(targetID)/\(slotID)"]?.ref }
            }
            guard let slot, released.insert(slot).inserted else { continue }
            let scopeActor = request?.slot == nil
                ? beat.actorIDs.first.map(EntityID.init)
                : nil
            kernel.enqueue(GameEvent(
                kind: .releaseSlot,
                behaviorID: request?.slot == nil ? nil : requestID,
                actorID: scopeActor,
                slotRef: slot), atTick: kernel.clock.tick)
        }
    }

    /// Emits a cue only for a complete, explicit release → receive pair. This
    /// keeps malformed or partial story data from making the renderer invent a
    /// destination, while leaving ordinary slot release behavior unchanged.
    private func queueHandoffEvent(
        for beat: StoryBeat,
        in episode: StoryEpisode,
        kernel: GameKernel
    ) {
        guard let handoff = beat.handoff,
              beat.targetID == handoff.propID,
              beat.slotID == handoff.fromSlotID,
              beat.actorIDs.contains(handoff.fromActorID),
              let nextBeat = episode.beats[safe: beatIndex + 1],
              nextBeat.actorIDs.contains(handoff.toActorID),
              nextBeat.targetID == handoff.propID,
              nextBeat.slotID == handoff.toSlotID,
              nextBeat.occupySlotOnSuccess else { return }

        let matchesSourceRequest = requestIDs.contains { requestID in
            guard let request = kernel.world.behaviors[requestID]?.request else { return false }
            return request.actorID.raw == handoff.fromActorID &&
                request.slot?.key == "\(handoff.propID)/\(handoff.fromSlotID)"
        }
        guard matchesSourceRequest else { return }

        queuedHandoffEvents.append(StoryHandoffEvent(
            episodeID: episode.id,
            beatID: beat.id,
            handoff: handoff,
            atTick: kernel.clock.tick,
            branchID: currentBranchID))
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
