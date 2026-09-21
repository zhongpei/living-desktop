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

/// The single owner of event ordering and `GameKernel` time for one world.
/// Platform and model adapters may submit immutable events; only `step` moves
/// the world clock. A nested/concurrent pulse is dropped instead of advancing
/// the same world twice.
public final class GameRuntime {
    public private(set) var kernel: GameKernel
    private let platformIngress: PlatformEventBuffer

    // Semantic work is allowed to submit late events from inside `step`, hence
    // a recursive lock. The lock is held for the entire pulse so background
    // model callbacks cannot mutate the inbox while Kernel is draining it.
    private let stateLock = NSRecursiveLock()
    private var stepping = false

    public init(kernel: GameKernel = GameKernel(), platformIngressCapacity: Int = 256) {
        self.kernel = kernel
        self.platformIngress = PlatformEventBuffer(capacity: platformIngressCapacity)
    }

    public convenience init(snapshot: KernelSnapshot) {
        self.init(kernel: GameKernel(snapshot: snapshot))
    }

    public var world: WorldState { withState { kernel.world } }
    public var clock: SimClock { withState { kernel.clock } }
    public var trace: [TraceEntry] { withState { kernel.trace } }
    public var pendingEventCount: Int { withState { kernel.inbox.count + platformIngress.count } }

    public func submit(_ event: GameEvent, atTick: Int64? = nil) {
        withState { kernel.enqueue(event, atTick: atTick) }
    }

    /// Thread-safe external ingress. Unlike `submit`, this never waits for an
    /// active pulse; events become visible at the next tick boundary.
    public func submitPlatform(_ event: PlatformEvent) {
        platformIngress.publish(event)
    }

    /// One atomic runtime pulse: external events, semantic work, late events,
    /// behavior advancement, then the clock increment.
    @discardableResult
    public func step(
        events: [GameEvent] = [],
        semanticWork: ((GameRuntime) -> Void)? = nil
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
            platformIngress.publish(PlatformEvent(event))
        }
        for event in platformIngress.drain() {
            kernel.enqueue(event.gameEvent, atTick: tick)
        }
        return kernel.tick {
            semanticWork?(self)
        }
    }

    public func snapshot() -> KernelSnapshot { withState { kernel.snapshot() } }

    public func restore(_ snapshot: KernelSnapshot) {
        withState {
            guard !stepping else { return }
            kernel = GameKernel(snapshot: snapshot)
            platformIngress.removeAll()
        }
    }

    @discardableResult
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
