import Foundation

/// Platform-neutral facts needed by the semantic chain. Real macOS input and
/// `VirtualDesktop` both project into this value; neither platform leaks into
/// Goal, Scene, Needle or Action.
public struct RuntimeContext: Codable, Equatable, Sendable {
    public struct Focus: Codable, Equatable, Sendable {
        public var id: EntityID
        public var app: String
        public var title: String
        public var activity: String?

        public init(id: EntityID, app: String = "", title: String = "", activity: String? = nil) {
            self.id = id
            self.app = app
            self.title = title
            self.activity = activity
        }
    }

    public var focus: Focus?

    public init(focus: Focus? = nil) {
        self.focus = focus
    }
}

/// Complete checkpoint for pausing or moving a Runtime. `KernelSnapshot` is a
/// read-only world inspection value; it intentionally does not replace this.
public struct GameRuntimeCheckpoint: Codable, Equatable, Sendable {
    public var kernel: KernelSnapshot
    public var storyInterruptionPolicy: StoryInterruptionPolicy
    public var platformIngress: PlatformEventBufferSnapshot
    public var body: BodyRuntimeSnapshot

    public init(
        kernel: KernelSnapshot,
        storyInterruptionPolicy: StoryInterruptionPolicy,
        platformIngress: PlatformEventBufferSnapshot,
        body: BodyRuntimeSnapshot
    ) {
        self.kernel = kernel
        self.storyInterruptionPolicy = storyInterruptionPolicy
        self.platformIngress = platformIngress
        self.body = body
    }
}

/// The single owner of event ordering and `GameKernel` time for one world.
/// Platform and model adapters may submit immutable events; only `step` moves
/// the world clock. A nested/concurrent pulse is dropped instead of advancing
/// the same world twice.
public final class GameRuntime {
    /// Mutable kernel ownership never crosses the Runtime boundary. Core
    /// coordinators may use it while a pulse holds `stateLock`; adapters only
    /// receive the read-only projections below.
    private(set) var kernel: GameKernel
    private let platformIngress: PlatformEventBuffer
    private let bodyRuntime: BodyRuntime

    // Semantic work is allowed to submit late events from inside `step`, hence
    // a recursive lock. The lock is held for the entire pulse so background
    // model callbacks cannot mutate the inbox while Kernel is draining it.
    private let stateLock = NSRecursiveLock()
    private var stepping = false

    public init(
        kernel: GameKernel = GameKernel(),
        platformIngressCapacity: Int = 256,
        bodyExecutionMode: BodyExecutionMode = .headless
    ) {
        let ownedKernel = GameKernel(snapshot: kernel.snapshot())
        ownedKernel.storyInterruptionPolicy = kernel.storyInterruptionPolicy
        self.kernel = ownedKernel
        self.platformIngress = PlatformEventBuffer(capacity: platformIngressCapacity)
        self.bodyRuntime = BodyRuntime(mode: bodyExecutionMode)
    }

    public convenience init(snapshot: KernelSnapshot) {
        self.init(kernel: GameKernel(snapshot: snapshot))
    }

    public convenience init(checkpoint: GameRuntimeCheckpoint) {
        let kernel = GameKernel(snapshot: checkpoint.kernel)
        kernel.storyInterruptionPolicy = checkpoint.storyInterruptionPolicy
        self.init(
            kernel: kernel,
            platformIngressCapacity: checkpoint.platformIngress.capacity,
            bodyExecutionMode: checkpoint.body.mode)
        platformIngress.restore(checkpoint.platformIngress)
        bodyRuntime.restore(checkpoint.body)
    }

    public var world: WorldState { withState { kernel.world } }
    public var clock: SimClock { withState { kernel.clock } }
    public var trace: [TraceEntry] { withState { kernel.trace } }
    public var manualViolations: [InvariantViolation] { withState { kernel.manualViolations } }
    public var pendingEventCount: Int { withState { kernel.inbox.count + platformIngress.count } }
    public var storyInterruptionPolicy: StoryInterruptionPolicy {
        withState { kernel.storyInterruptionPolicy }
    }

    /// Submit ordinary lifecycle/control input. Behavior requests must come
    /// from ActionRuntime through `submitAction`; replay/fault tools use the
    /// explicitly named low-level seam below.
    @discardableResult
    public func submit(_ event: GameEvent, atTick: Int64? = nil) -> Bool {
        guard event.kind != .behaviorRequest else { return false }
        withState { kernel.enqueue(event, atTick: atTick) }
        return true
    }

    @discardableResult
    public func submitAction(_ execution: ActionExecution, atTick: Int64? = nil) -> String? {
        guard execution.accepted, let request = execution.request else { return nil }
        withState {
            kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: atTick)
        }
        return request.id
    }

    /// Deliberately bypasses semantic resolution for cassette replay and
    /// hostile fault injection only. Production adapters must not call this.
    public func submitReplayOrFault(_ event: GameEvent, atTick: Int64? = nil) {
        withState { kernel.enqueue(event, atTick: atTick) }
    }

    /// Thread-safe external ingress. Unlike `submit`, this never waits for an
    /// active pulse; events become visible at the next tick boundary.
    @discardableResult
    public func submitPlatform(_ event: PlatformEvent) -> Bool {
        guard event.gameEvent.kind != .behaviorRequest else { return false }
        platformIngress.publish(event)
        return true
    }

    /// One atomic runtime pulse: external events, semantic work, late events,
    /// behavior advancement, then the clock increment.
    @discardableResult
    public func step(
        events: [GameEvent] = [],
        semanticWork: ((GameRuntime) -> Void)? = nil
    ) -> TickReport? {
        step(events: events, allowRawBehavior: false, semanticWork: semanticWork)
    }

    /// Explicit low-level pulse for deterministic cassette replay and hostile
    /// tests. Ordinary platform/gameplay callers must use `step`.
    @discardableResult
    public func stepReplayOrFault(events: [GameEvent]) -> TickReport? {
        step(events: events, allowRawBehavior: true, semanticWork: nil)
    }

    @discardableResult
    private func step(
        events: [GameEvent],
        allowRawBehavior: Bool,
        semanticWork: ((GameRuntime) -> Void)?
    ) -> TickReport? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stepping else {
            return nil
        }
        stepping = true
        defer { stepping = false }

        let tick = kernel.clock.tick
        for event in events {
            guard allowRawBehavior || event.kind != .behaviorRequest else { continue }
            platformIngress.publish(PlatformEvent(event))
        }
        for event in platformIngress.drain() {
            kernel.enqueue(event.gameEvent, atTick: tick)
        }
        let report = kernel.tick(
            afterEvents: { semanticWork?(self) },
            beforeBehaviorAdvance: {
                self.bodyRuntime.reconcile(world: self.kernel.world, tick: tick)
                for result in self.bodyRuntime.dueResults(at: tick) {
                    if let event = self.bodyRuntime.event(for: result) {
                        self.kernel.enqueue(event, atTick: tick)
                    }
                }
            })
        bodyRuntime.reconcile(world: kernel.world, tick: tick)
        return report
    }

    /// Public semantic pulse used by real and virtual adapters. The pipeline
    /// never receives a mutable kernel outside the locked Runtime step.
    @discardableResult
    public func step(
        events: [GameEvent] = [],
        pipeline: SemanticPipeline,
        context: RuntimeContext,
        afterSemanticWork: (() -> Void)? = nil
    ) -> TickReport? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let report = step(events: events) { _ in
            pipeline.beforeTick(kernel: self.kernel, context: context)
            afterSemanticWork?()
        }
        guard report != nil else { return nil }
        pipeline.afterTick(kernel: kernel)
        return report
    }

    /// Story orchestration is a Core coordinator, but it still executes only
    /// while Runtime owns the pulse. App and Harness never receive the kernel.
    @discardableResult
    public func startStory(_ director: StoryDirector) -> String? {
        withState { director.startNext(in: kernel) }
    }

    @discardableResult
    public func step(
        events: [GameEvent] = [],
        storyDirector: StoryDirector
    ) -> TickReport? {
        step(events: events) { _ in storyDirector.tick(in: self.kernel) }
    }

    public func abortStory(_ director: StoryDirector) {
        withState { director.abortCurrent(in: kernel) }
    }

    func configureStoryInterruptionPolicy(_ policy: StoryInterruptionPolicy) {
        withState { kernel.storyInterruptionPolicy = policy }
    }

    @discardableResult
    func installCast(_ director: CastDirector) -> [String] {
        withState { director.install(in: kernel) }
    }

    @discardableResult
    func step(storyDirector: StoryDirector, castDirector: CastDirector) -> TickReport? {
        step { _ in
            if storyDirector.currentEpisodeID == nil {
                _ = storyDirector.startNext(in: self.kernel)
            } else {
                storyDirector.tick(in: self.kernel)
            }
            castDirector.tick(in: self.kernel)
        }
    }

    @discardableResult
    func invite(
        _ director: CastDirector,
        memberID: String,
        from sourceActorID: EntityID? = nil,
        manually: Bool = false
    ) -> Bool {
        withState {
            if manually {
                return director.inviteManually(memberID: memberID, in: kernel)
            }
            return director.invite(memberID: memberID, from: sourceActorID, in: kernel)
        }
    }

    @discardableResult
    func depart(_ director: CastDirector, memberID: String) -> Bool {
        withState { director.depart(memberID: memberID, in: kernel) }
    }

    func consumeStoryActions(
        storyDirector: StoryDirector,
        castDirector: CastDirector
    ) -> [StoryAction] {
        withState {
            let actions = storyDirector.drainActions()
            for action in actions {
                for memberID in action.inviteMemberIDs ?? [] {
                    _ = castDirector.invite(
                        memberID: memberID,
                        from: action.actorID,
                        in: kernel,
                        atTick: kernel.clock.tick)
                }
            }
            return actions
        }
    }

    func checkpointCast(
        director: CastDirector,
        storyDirector: StoryDirector,
        started: Bool
    ) -> CastRuntimeSnapshot {
        withState {
            let kernelSnapshot = kernel.snapshot()
            return CastRuntimeSnapshot(
                kernel: kernelSnapshot,
                runtimeCheckpoint: GameRuntimeCheckpoint(
                    kernel: kernelSnapshot,
                    storyInterruptionPolicy: kernel.storyInterruptionPolicy,
                    platformIngress: platformIngress.snapshot(),
                    body: bodyRuntime.checkpoint()),
                director: director.snapshot(),
                storyDirector: storyDirector.snapshot(),
                started: started)
        }
    }

    @discardableResult
    public func submitBodyResult(_ result: BodyResult) -> Bool {
        withState {
            guard let event = bodyRuntime.event(for: result) else { return false }
            platformIngress.publish(PlatformEvent(event, delivery: .mustDeliver))
            return true
        }
    }

    public func cancelBodyBehavior(_ behaviorID: String) {
        withState {
            kernel.enqueue(GameEvent(kind: .cancelBehavior, behaviorID: behaviorID))
        }
    }

    public func drainBodyCommands(for actorID: EntityID? = nil) -> [BodyCommand] {
        withState { bodyRuntime.drainCommands(actorID: actorID) }
    }

    public func takeBodyCommand(behaviorID: String) -> BodyCommand? {
        withState { bodyRuntime.takeCommand(behaviorID: behaviorID) }
    }

    public func updateBodyPose(_ pose: BodyPose) {
        withState { bodyRuntime.update(pose) }
    }

    public func presentationSnapshot() -> PresentationSnapshot {
        withState { bodyRuntime.snapshot(world: kernel.world, tick: kernel.clock.tick) }
    }

    public func drainPresentationEffects() -> [PresentationEffect] {
        withState { bodyRuntime.drainEffects() }
    }

    /// Read-only Kernel projection for reports and deterministic comparisons.
    /// Use `checkpoint()` when pending adapter/body work must survive restore.
    public func snapshot() -> KernelSnapshot { withState { kernel.snapshot() } }

    public func checkpoint() -> GameRuntimeCheckpoint {
        withState {
            GameRuntimeCheckpoint(
                kernel: kernel.snapshot(),
                storyInterruptionPolicy: kernel.storyInterruptionPolicy,
                platformIngress: platformIngress.snapshot(),
                body: bodyRuntime.checkpoint())
        }
    }

    /// Read-only deterministic projection of the next tick for slow adapters.
    /// Model work can inspect the post-input world without holding this
    /// Runtime's state lock; the real pulse still revalidates epochs/refs.
    public func previewWorld(events: [GameEvent] = []) -> WorldState {
        let clone = GameRuntime(checkpoint: checkpoint())
        var afterEvents: WorldState?
        _ = clone.step(events: events) { runtime in
            afterEvents = runtime.kernel.world
        }
        return afterEvents ?? clone.world
    }

    public func terminalViolations() -> [InvariantViolation] {
        withState { kernel.terminalViolations() }
    }

    public func traceJSONL() throws -> Data {
        try withState { try kernel.traceJSONL() }
    }

    public func restore(_ snapshot: KernelSnapshot) {
        withState {
            guard !stepping else { return }
            let interruptionPolicy = kernel.storyInterruptionPolicy
            let restoredKernel = GameKernel(snapshot: snapshot)
            restoredKernel.storyInterruptionPolicy = interruptionPolicy
            kernel = restoredKernel
            platformIngress.removeAll()
            bodyRuntime.reset()
            bodyRuntime.reconcile(world: kernel.world, tick: kernel.clock.tick)
        }
    }

    public func restore(_ checkpoint: GameRuntimeCheckpoint) {
        withState {
            guard !stepping, checkpoint.body.mode == bodyRuntime.mode else { return }
            let restoredKernel = GameKernel(snapshot: checkpoint.kernel)
            restoredKernel.storyInterruptionPolicy = checkpoint.storyInterruptionPolicy
            kernel = restoredKernel
            platformIngress.restore(checkpoint.platformIngress)
            bodyRuntime.restore(checkpoint.body)
        }
    }

    @discardableResult
    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}
