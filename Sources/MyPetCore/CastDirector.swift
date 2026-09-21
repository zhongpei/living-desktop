import Foundation

public struct CastDirectorSnapshot: Codable, Equatable, Sendable {
    public let selection: CastSelection
    public let seed: UInt64
    public let arrivalDelayTicks: Int64
    public let pendingArrivals: [String]
    public let pendingDepartures: [String]
    public let nextRotationTick: Int64?
    public let rotationCounter: Int

    public init(
        selection: CastSelection,
        seed: UInt64,
        arrivalDelayTicks: Int64,
        pendingArrivals: [String],
        pendingDepartures: [String] = [],
        nextRotationTick: Int64? = nil,
        rotationCounter: Int = 0
    ) {
        self.selection = selection
        self.seed = seed
        self.arrivalDelayTicks = arrivalDelayTicks
        self.pendingArrivals = pendingArrivals
        self.pendingDepartures = pendingDepartures
        self.nextRotationTick = nextRotationTick
        self.rotationCounter = max(0, rotationCounter)
    }

    private enum CodingKeys: String, CodingKey {
        case selection, seed, arrivalDelayTicks, pendingArrivals
        case pendingDepartures, nextRotationTick, rotationCounter
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selection: try values.decode(CastSelection.self, forKey: .selection),
            seed: try values.decode(UInt64.self, forKey: .seed),
            arrivalDelayTicks: try values.decode(Int64.self, forKey: .arrivalDelayTicks),
            pendingArrivals: try values.decode([String].self, forKey: .pendingArrivals),
            pendingDepartures: try values.decodeIfPresent([String].self, forKey: .pendingDepartures) ?? [],
            nextRotationTick: try values.decodeIfPresent(Int64.self, forKey: .nextRotationTick),
            rotationCounter: try values.decodeIfPresent(Int.self, forKey: .rotationCounter) ?? 0)
    }
}

/// CastPack 到 GameKernel 的生命周期适配器。
///
/// 它只负责把“选择、邀请、入场、离场”翻译成可记录、可回放的事件；
/// 角色是否真的活着、是否占据机甲插槽，仍由 GameKernel 在 tick 边界确认。
public final class CastDirector {
    public let packs: [CastPack]
    public private(set) var selection: CastSelection
    public let seed: UInt64
    public let arrivalDelayTicks: Int64

    private var members: [String: CastMember] = [:]
    private var memberPacks: [String: CastPack] = [:]
    private var pendingArrivals = Set<String>()
    private var pendingDepartures = Set<String>()
    private var nextRotationTick: Int64?
    private var rotationCounter = 0

    public init(
        packs: [CastPack],
        selection: CastSelection = CastSelection(),
        seed: UInt64 = 0,
        arrivalDelayTicks: Int64 = 2
    ) {
        self.packs = packs
        self.selection = selection.normalized(availablePacks: packs)
        self.seed = seed
        self.arrivalDelayTicks = max(1, arrivalDelayTicks)
        for pack in packs {
            for member in pack.members where members[member.id] == nil {
                members[member.id] = member
                memberPacks[member.id] = pack
            }
        }
    }

    public var availableMemberIDs: [String] {
        selection.activeMembers(from: packs).map(\.id).sorted()
    }

    public var declaredMemberIDs: [String] {
        members.keys.sorted()
    }

    /// 当前选择范围内的道具。道具和角色共享 CastSelection 的组过滤，
    /// 避免未启用的剧组把实体、关系或视觉投影偷偷带入世界。
    public var availableProps: [CastProp] {
        var seen = Set<String>()
        return selection.activePacks(from: packs)
            .flatMap { $0.props ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }

    public func prop(_ id: String) -> CastProp? {
        availableProps.first { $0.id == id }
    }

    public func member(_ id: String) -> CastMember? {
        members[id]
    }

    /// 为渲染层提供与生命周期状态相同来源的表现计划。
    /// 不存在的角色不生成默认计划，避免 UI 为未知成员凭空创建过渡。
    public func transitionPlan(
        for memberID: String,
        phase: CastTransitionPhase
    ) -> CastTransitionPlan? {
        guard let member = members[memberID] else { return nil }
        switch phase {
        case .arrival:
            return .arrival(for: member.entryProfile ?? member.arrivalStyle)
        case .departure:
            return .departure(for: member.exitProfile ?? member.arrivalStyle)
        }
    }

    public func snapshot() -> CastDirectorSnapshot {
        CastDirectorSnapshot(
            selection: selection,
            seed: seed,
            arrivalDelayTicks: arrivalDelayTicks,
            pendingArrivals: pendingArrivals.sorted(),
            pendingDepartures: pendingDepartures.sorted(),
            nextRotationTick: nextRotationTick,
            rotationCounter: rotationCounter)
    }

    public func restore(from snapshot: CastDirectorSnapshot) {
        selection = snapshot.selection.normalized(availablePacks: packs)
        pendingArrivals = Set(snapshot.pendingArrivals.filter { members[$0] != nil })
        pendingDepartures = Set(snapshot.pendingDepartures.filter { members[$0] != nil })
        nextRotationTick = snapshot.nextRotationTick
        rotationCounter = max(0, snapshot.rotationCounter)
    }

    public func expandCapacity(to count: Int) {
        selection.maxActiveMembers = max(selection.maxActiveMembers, count)
    }

    /// 安装关系初值并安排第一批角色入场。
    @discardableResult
    public func install(in kernel: GameKernel, atTick: Int64? = nil) -> [String] {
        let activePacks = selection.activePacks(from: packs)
        kernel.seedRelations(activePacks.reduce(into: [:]) { result, pack in
            for (key, value) in pack.initialRelationValues() { result[key] = value }
        })
        let tick = atTick ?? kernel.clock.tick
        let chosen = chooseInitialMembers()
        for pack in activePacks {
            for prop in pack.props ?? [] {
                kernel.enqueue(GameEvent(
                    kind: .registerEntity,
                    entity: EntityState(id: EntityID(prop.id), kind: .prop)),
                    atTick: tick)
                for slot in pack.initialSlots() where slot.entityID == EntityID(prop.id) {
                    kernel.enqueue(GameEvent(kind: .createSlot, slot: slot), atTick: tick)
                }
            }
        }
        if nextRotationTick == nil, rotationIsEnabled {
            nextRotationTick = tick + selection.rotationIntervalTicks
        }
        if selection.automaticArrivalsEnabled {
            for id in chosen { scheduleArrival(id, in: kernel, atTick: tick) }
        }
        return chosen
    }

    /// Advances opt-in cast rotation after a kernel tick. The director only
    /// schedules lifecycle events; the kernel remains the sole authority that
    /// confirms an actor alive or departed.
    public func tick(in kernel: GameKernel) {
        pendingArrivals = Set(pendingArrivals.filter { kernel.world.isAlive(EntityID($0)) == false })
        pendingDepartures = Set(pendingDepartures.filter { kernel.world.isAlive(EntityID($0)) })
        guard rotationIsEnabled,
              selection.invitationsEnabled,
              let nextRotationTick,
              kernel.clock.tick >= nextRotationTick else { return }

        // Story beats own their participants while active. Delaying rotation
        // by one tick prevents a background setting from tearing a scene down.
        if kernel.runningBehaviorStates.contains(where: {
            $0.status == .running && $0.request.priority == .story
        }) {
            self.nextRotationTick = kernel.clock.tick + 1
            return
        }

        let active = availableMemberIDs.filter { kernel.world.isAlive(EntityID($0)) }
        let candidates = availableMemberIDs.filter {
            !kernel.world.isAlive(EntityID($0)) &&
                !pendingArrivals.contains($0) &&
                !pendingDepartures.contains($0)
        }
        guard let replacement = orderedForRotation(candidates).first else {
            self.nextRotationTick = kernel.clock.tick + selection.rotationIntervalTicks
            return
        }

        if let departing = orderedForRotation(active).first {
            _ = depart(memberID: departing, in: kernel, atTick: kernel.clock.tick)
        }
        _ = invite(
            memberID: replacement,
            from: nil,
            in: kernel,
            atTick: kernel.clock.tick)
        rotationCounter += 1
        self.nextRotationTick = kernel.clock.tick + selection.rotationIntervalTicks
    }

    /// 邀请一个已在候选名单中的角色。返回 false 表示被设置或状态拒绝。
    @discardableResult
    public func invite(
        memberID: String,
        from sourceActorID: EntityID? = nil,
        in kernel: GameKernel,
        atTick: Int64? = nil
    ) -> Bool {
        guard selection.invitationsEnabled,
              let member = members[memberID],
              availableMemberIDs.contains(memberID),
              !pendingArrivals.contains(memberID),
              !kernel.world.isAlive(EntityID(memberID)) else { return false }
        let activeCount = availableMemberIDs.filter {
            kernel.world.isAlive(EntityID($0)) && !pendingDepartures.contains($0)
        }.count
        let queuedCount = pendingArrivals.filter { !kernel.world.isAlive(EntityID($0)) }.count
        guard activeCount + queuedCount < selection.maxActiveMembers else { return false }
        let tick = atTick ?? kernel.clock.tick
        kernel.enqueue(GameEvent(
            kind: .castInvite,
            castMemberID: memberID,
            sourceActorID: sourceActorID), atTick: tick)
        scheduleArrival(member.id, in: kernel, atTick: tick + arrivalDelayTicks)
        return true
    }

    /// A tray click is an explicit user command, not a story invitation. It may
    /// summon any declared member even when automatic/story invitations are
    /// disabled or the member is outside the configured candidate subset.
    @discardableResult
    public func inviteManually(
        memberID: String,
        in kernel: GameKernel,
        atTick: Int64? = nil
    ) -> Bool {
        guard let member = members[memberID],
              !pendingArrivals.contains(memberID),
              !kernel.world.isAlive(EntityID(memberID)) else { return false }
        let activeCount = members.keys.filter {
            kernel.world.isAlive(EntityID($0)) && !pendingDepartures.contains($0)
        }.count
        let queuedCount = pendingArrivals.filter { !kernel.world.isAlive(EntityID($0)) }.count
        guard activeCount + queuedCount < selection.maxActiveMembers else { return false }
        let tick = atTick ?? kernel.clock.tick
        kernel.enqueue(GameEvent(kind: .castInvite, castMemberID: memberID), atTick: tick)
        scheduleArrival(member.id, in: kernel, atTick: tick + arrivalDelayTicks)
        return true
    }

    @discardableResult
    public func depart(memberID: String, in kernel: GameKernel, atTick: Int64? = nil) -> Bool {
        guard members[memberID] != nil, kernel.world.isAlive(EntityID(memberID)) else { return false }
        let tick = atTick ?? kernel.clock.tick
        kernel.enqueue(GameEvent(
            kind: .castDepart,
            entityID: EntityID(memberID),
            castMemberID: memberID), atTick: tick)
        pendingArrivals.remove(memberID)
        pendingDepartures.insert(memberID)
        return true
    }

    private func chooseInitialMembers() -> [String] {
        let candidates = selection.activeMembers(from: packs)
        let limit: Int
        switch selection.mode {
        case .manual:
            limit = selection.maxActiveMembers
        case .random:
            limit = min(selection.maxActiveMembers, selection.randomCount)
        }
        let ordered: [CastMember]
        if selection.mode == .random {
            ordered = candidates.sorted { score($0.id) < score($1.id) }
        } else {
            // Missing-art members remain inviteable, but must not silently
            // consume the initial visible-character budget merely because
            // their ids sort first.
            ordered = candidates.sorted {
                if ($0.visualPackID != nil) != ($1.visualPackID != nil) {
                    return $0.visualPackID != nil
                }
                return $0.id < $1.id
            }
        }
        return ordered.prefix(max(0, limit)).map(\.id)
    }

    private func scheduleArrival(_ memberID: String, in kernel: GameKernel, atTick: Int64) {
        guard let member = members[memberID], let pack = memberPacks[memberID] else { return }
        pendingArrivals.insert(memberID)
        pendingDepartures.remove(memberID)
        kernel.enqueue(GameEvent(
            kind: .castArrive,
            entity: EntityState(
                id: EntityID(member.id),
                kind: member.kind == .mech ? .mech : .actor),
            castMemberID: member.id,
            arrivalStyle: member.entryProfile ?? member.arrivalStyle), atTick: atTick)
        for slot in pack.initialSlots() where slot.entityID == EntityID(member.id) {
            kernel.enqueue(GameEvent(kind: .createSlot, slot: slot), atTick: atTick)
        }
    }

    private func score(_ id: String) -> UInt64 {
        var hash = 1469598103934665603 ^ seed
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private var rotationIsEnabled: Bool {
        selection.automaticRotationEnabled && selection.rotationIntervalTicks > 0
    }

    private func orderedForRotation(_ ids: [String]) -> [String] {
        if selection.mode == .random {
            return ids.sorted { rotationScore($0) < rotationScore($1) }
        }
        return ids.sorted()
    }

    private func rotationScore(_ id: String) -> UInt64 {
        var hash = score(id) ^ UInt64(rotationCounter &* 16777619)
        hash ^= hash >> 32
        hash &*= 1099511628211
        return hash
    }
}
