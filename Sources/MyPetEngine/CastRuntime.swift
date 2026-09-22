import Foundation
import MyPetCore

public struct CastRuntimeSnapshot: Codable, Equatable, Sendable {
    public let kernel: KernelSnapshot
    public let runtimeCheckpoint: GameRuntimeCheckpoint?
    public let director: CastDirectorSnapshot
    public let storyDirector: StoryDirectorSnapshot
    public let started: Bool

    public init(
        kernel: KernelSnapshot,
        runtimeCheckpoint: GameRuntimeCheckpoint? = nil,
        director: CastDirectorSnapshot,
        storyDirector: StoryDirectorSnapshot,
        started: Bool
    ) {
        self.kernel = kernel
        self.runtimeCheckpoint = runtimeCheckpoint
        self.director = director
        self.storyDirector = storyDirector
        self.started = started
    }
}

/// 桌面角色组的最小运行时。
///
/// `CastDirector` 负责把选择和邀请翻译成事件，`GameKernel` 负责在 tick
/// 边界确认实体的生死；这个类型只提供一个稳定的生命周期门面，让 AppKit
/// 面板、harness 和未来的剧情调度器都从同一个“已确认在场名单”读取状态。
public final class CastRuntime {
    public let runtime: GameRuntime
    public var world: WorldState { runtime.world }
    public var clock: SimClock { runtime.clock }
    public var trace: [TraceEntry] { runtime.trace }
    public var manualViolations: [InvariantViolation] { runtime.manualViolations }
    public let director: CastDirector
    public let storyDirector: StoryDirector
    private let lifecycleLock = NSLock()
    private var isStarted = false
    public var started: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return isStarted
    }
    private let characterDefinitions: [String: CharacterDefinition]

    public convenience init(
        resolvedPacks: [ResolvedCastPack],
        stories: [StoryPack] = [],
        selection: CastSelection,
        seed: UInt64 = 0,
        bodyExecutionMode: BodyExecutionMode = .headless,
        arrivalDelayTicks: Int64 = 2,
        storyConfiguration: StoryDirectorConfiguration = StoryDirectorConfiguration(),
        storyExecutionProvider: (any StoryExecutionProvider)? = nil
    ) {
        self.init(
            packs: resolvedPacks.map(\.pack), stories: stories, selection: selection, seed: seed,
            bodyExecutionMode: bodyExecutionMode, arrivalDelayTicks: arrivalDelayTicks,
            storyConfiguration: storyConfiguration,
            storyExecutionProvider: storyExecutionProvider,
            characterDefinitions: resolvedPacks.reduce(into: [:]) { result, resolved in
                result.merge(resolved.characters) { first, _ in first }
            })
    }

    public init(
        packs: [CastPack],
        stories: [StoryPack] = [],
        selection: CastSelection,
        seed: UInt64 = 0,
        bodyExecutionMode: BodyExecutionMode = .headless,
        arrivalDelayTicks: Int64 = 2,
        storyConfiguration: StoryDirectorConfiguration = StoryDirectorConfiguration(),
        storyExecutionProvider: (any StoryExecutionProvider)? = nil,
        characterDefinitions: [String: CharacterDefinition] = [:]
    ) {
        self.characterDefinitions = characterDefinitions
        runtime = GameRuntime(kernel: GameKernel(
            seed: seed,
            storyInterruptionPolicy: storyConfiguration.interruptionPolicy),
            bodyExecutionMode: bodyExecutionMode)
        director = CastDirector(
            packs: packs,
            selection: selection,
            seed: seed,
            arrivalDelayTicks: arrivalDelayTicks)
        storyDirector = StoryDirector(
            episodes: packs.flatMap(\.episodes) + stories
                .filter { pack in packs.contains { $0.groupID == pack.groupID } }
                .flatMap(\.runtimeEpisodes),
            configuration: storyConfiguration,
            executionProvider: storyExecutionProvider)
    }

    public init(
        snapshot: CastRuntimeSnapshot,
        packs: [CastPack],
        stories: [StoryPack] = [],
        storyExecutionProvider: (any StoryExecutionProvider)? = nil
    ) {
        characterDefinitions = [:]
        runtime = snapshot.runtimeCheckpoint.map(GameRuntime.init(checkpoint:))
            ?? GameRuntime(snapshot: snapshot.kernel)
        director = CastDirector(
            packs: packs,
            selection: snapshot.director.selection,
            seed: snapshot.director.seed,
            arrivalDelayTicks: snapshot.director.arrivalDelayTicks)
        director.restore(from: snapshot.director)
        storyDirector = StoryDirector(
            episodes: packs.flatMap(\.episodes) + stories
                .filter { pack in packs.contains { $0.groupID == pack.groupID } }
                .flatMap(\.runtimeEpisodes),
            configuration: snapshot.storyDirector.configuration,
            executionProvider: storyExecutionProvider)
        if snapshot.runtimeCheckpoint == nil {
            runtime.configureStoryInterruptionPolicy(
                snapshot.storyDirector.configuration.interruptionPolicy)
        }
        storyDirector.restore(from: snapshot.storyDirector)
        isStarted = snapshot.started
    }

    /// 安装关系和第一批事件；不会越过 tick 边界替内核“偷改”状态。
    @discardableResult
    public func start() -> [String] {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isStarted else {
            let world = runtime.world
            return director.declaredMemberIDs.filter { world.isAlive(EntityID($0)) }
        }
        isStarted = true
        return runtime.installCast(director)
    }

    @discardableResult
    public func tick() -> TickReport {
        _ = start()
        return runtime.step(storyDirector: storyDirector, castDirector: director)!
    }

    public var activeMemberIDs: [String] {
        let world = runtime.world
        return director.declaredMemberIDs.filter { world.isAlive(EntityID($0)) }
    }

    public var activeMembers: [CastMember] {
        activeMemberIDs.compactMap(director.member)
    }

    public func characterDefinition(for memberID: String) -> CharacterDefinition? {
        characterDefinitions[memberID]
    }

    /// 已被 CastDirector 安装且仍存活的道具。它们是世界中的实体，
    /// 但不参加角色轮换；表现层可据此建立独立的 prop adapter。
    public var activeProps: [CastProp] {
        let world = runtime.world
        return director.availableProps.filter { world.isAlive(EntityID($0.id)) }
    }

    /// Registered props are world resources, not stage decorations.  Only a
    /// prop currently claimed by a behavior/slot or attached to an actor is
    /// part of the visual cast projection.
    public var presentedProps: [CastProp] {
        let world = runtime.world
        return activeProps.filter { prop in
            let id = EntityID(prop.id)
            if world.spatialAttachments[id.raw] != nil { return true }
            if world.slots.values.contains(where: {
                $0.entityID == id && ($0.status == .occupied || !$0.occupants.isEmpty)
            }) { return true }
            return world.behaviors.values.contains {
                $0.status == .running && $0.request.target?.entityID == id
            }
        }
    }

    @discardableResult
    public func invite(memberID: String, from sourceActorID: EntityID? = nil) -> Bool {
        _ = start()
        return runtime.invite(director, memberID: memberID, from: sourceActorID)
    }

    @discardableResult
    public func inviteManually(memberID: String) -> Bool {
        _ = start()
        return runtime.invite(director, memberID: memberID, manually: true)
    }

    public func expandCapacity(to count: Int) {
        director.expandCapacity(to: count)
    }

    @discardableResult
    public func depart(memberID: String) -> Bool {
        _ = start()
        return runtime.depart(director, memberID: memberID)
    }

    public func consumeStoryActions() -> [StoryAction] {
        runtime.consumeStoryActions(storyDirector: storyDirector, castDirector: director)
    }

    public func consumeStoryHandoffEvents() -> [StoryHandoffEvent] {
        storyDirector.drainStoryHandoffEvents()
    }

    public func snapshot() -> CastRuntimeSnapshot {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return runtime.checkpointCast(
            director: director,
            storyDirector: storyDirector,
            started: isStarted)
    }
}
