import Foundation

public struct LayoutRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }

    public func intersection(_ other: LayoutRect) -> LayoutRect? {
        let left = max(minX, other.minX)
        let top = max(minY, other.minY)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return LayoutRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public func contains(_ other: LayoutRect, epsilon: Double = 0.001) -> Bool {
        other.minX >= minX - epsilon && other.minY >= minY - epsilon &&
            other.maxX <= maxX + epsilon && other.maxY <= maxY + epsilon
    }
}

public struct LayoutActor: Codable, Equatable, Sendable {
    public var id: EntityID
    public var frame: LayoutRect
    public var zIndex: Int
    public var allowsOverlap: Bool

    public init(id: EntityID, frame: LayoutRect, zIndex: Int = 100, allowsOverlap: Bool = false) {
        self.id = id
        self.frame = frame
        self.zIndex = zIndex
        self.allowsOverlap = allowsOverlap
    }
}

public struct LayoutOccluder: Codable, Equatable, Sendable {
    public var id: EntityID
    public var frame: LayoutRect
    public var zIndex: Int

    public init(id: EntityID, frame: LayoutRect, zIndex: Int = 0) {
        self.id = id
        self.frame = frame
        self.zIndex = zIndex
    }
}

public struct SpatialSnapshot: Codable, Equatable, Sendable {
    public var virtualBounds: LayoutRect
    public var actors: [LayoutActor]
    public var occluders: [LayoutOccluder]

    public init(virtualBounds: LayoutRect, actors: [LayoutActor] = [], occluders: [LayoutOccluder] = []) {
        self.virtualBounds = virtualBounds
        self.actors = actors
        self.occluders = occluders
    }
}

public struct SpatialViolation: Codable, Equatable, Sendable {
    public let code: String
    public let subject: String
    public let other: String?
    public let detail: String

    public init(code: String, subject: String, other: String? = nil, detail: String) {
        self.code = code
        self.subject = subject
        self.other = other
        self.detail = detail
    }
}

public enum SpatialSafety {
    /// Converts a foot anchor into a fully visible actor frame. The raw anchor may
    /// be above a maximized window or outside a visible work area; placement is
    /// allowed to shift the visual panel, never to render a clipped character.
    public static func placeActor(
        id: EntityID,
        anchorX: Double,
        feetY: Double,
        width: Double,
        height: Double,
        baselineRatio: Double,
        in bounds: LayoutRect,
        zIndex: Int = 100,
        occluders: [LayoutOccluder] = []
    ) -> LayoutActor {
        let raw = LayoutRect(
            x: anchorX - width / 2,
            y: feetY - height * baselineRatio,
            width: width,
            height: height)
        var actor = LayoutActor(id: id, frame: fit(raw, in: bounds), zIndex: zIndex)
        guard !occluders.isEmpty else { return actor }

        let visible = check(SpatialSnapshot(virtualBounds: bounds, actors: [actor], occluders: occluders))
        guard visible.contains(where: { $0.code == "actor_occluded" }) else { return actor }

        // 先尝试离原位置最近的上下左右候选。最大化窗口可能把角色的上下路径
        // 都挡住；只尝试“在遮挡物上方”会让角色继续停在窗口里面，所以必须
        // 同时尝试左右边缘和工作区四角。
        let candidates = occluders.flatMap { occluder in
            [
                LayoutRect(x: actor.frame.x, y: occluder.frame.minY - height - 1,
                           width: actor.frame.width, height: actor.frame.height),
                LayoutRect(x: actor.frame.x, y: occluder.frame.maxY + 1,
                           width: actor.frame.width, height: actor.frame.height),
                LayoutRect(x: occluder.frame.minX - actor.frame.width - 1, y: actor.frame.y,
                           width: actor.frame.width, height: actor.frame.height),
                LayoutRect(x: occluder.frame.maxX + 1, y: actor.frame.y,
                           width: actor.frame.width, height: actor.frame.height),
            ]
        } + [
            LayoutRect(x: bounds.minX, y: bounds.minY, width: actor.frame.width, height: actor.frame.height),
            LayoutRect(x: bounds.maxX - actor.frame.width, y: bounds.minY,
                       width: actor.frame.width, height: actor.frame.height),
            LayoutRect(x: bounds.minX, y: bounds.maxY - actor.frame.height,
                       width: actor.frame.width, height: actor.frame.height),
            LayoutRect(x: bounds.maxX - actor.frame.width, y: bounds.maxY - actor.frame.height,
                       width: actor.frame.width, height: actor.frame.height),
        ]
        let origin = actor.frame
        let fitted = candidates.map { fit($0, in: bounds) }
        let safe = fitted.compactMap { candidate -> (LayoutRect, Double)? in
            let probe = LayoutActor(id: id, frame: candidate, zIndex: zIndex)
            let violations = check(SpatialSnapshot(virtualBounds: bounds, actors: [probe], occluders: occluders))
            guard !violations.contains(where: { $0.code == "actor_occluded" }) else { return nil }
            let distance = abs(candidate.x - origin.x) + abs(candidate.y - origin.y)
            return (candidate, distance)
        }.min { $0.1 < $1.1 }
        if let safe { actor.frame = safe.0 }
        else if let best = fitted.max(by: { visibleFraction($0, zIndex: zIndex, occluders: occluders)
            < visibleFraction($1, zIndex: zIndex, occluders: occluders) }) {
            // 整个工作区都被遮挡时不可能制造“全可见”位置；仍选择可见面积
            // 最大的位置，并保留 check() 的违例，让 Harness/诊断明确暴露环境限制。
            actor.frame = best
        }
        return actor
    }

    private static func visibleFraction(
        _ frame: LayoutRect,
        zIndex: Int,
        occluders: [LayoutOccluder]
    ) -> Double {
        guard frame.area > 0 else { return 0 }
        let hidden = occluders
            .filter { zIndex <= $0.zIndex }
            .compactMap { frame.intersection($0.frame)?.area }
            .reduce(0, +)
        return max(0, 1 - min(frame.area, hidden) / frame.area)
    }

    public static func check(_ snapshot: SpatialSnapshot) -> [SpatialViolation] {
        var violations: [SpatialViolation] = []
        for actor in snapshot.actors {
            if actor.frame.width <= 0 || actor.frame.height <= 0 {
                violations.append(SpatialViolation(code: "actor_frame_invalid", subject: actor.id.raw, detail: "non-positive frame"))
                continue
            }
            if !snapshot.virtualBounds.contains(actor.frame) {
                violations.append(SpatialViolation(code: "actor_outside_virtual_bounds", subject: actor.id.raw, detail: "frame is outside virtual screen"))
            }
            for occluder in snapshot.occluders where actor.zIndex <= occluder.zIndex {
                guard let overlap = actor.frame.intersection(occluder.frame), actor.frame.area > 0 else { continue }
                let visible = 1 - overlap.area / actor.frame.area
                if visible < 0.85 {
                    violations.append(SpatialViolation(
                        code: "actor_occluded",
                        subject: actor.id.raw,
                        other: occluder.id.raw,
                        detail: "visible_fraction=\(visible)"
                    ))
                }
            }
        }

        for i in snapshot.actors.indices {
            for j in snapshot.actors.indices where j > i {
                let lhs = snapshot.actors[i]
                let rhs = snapshot.actors[j]
                guard !lhs.allowsOverlap && !rhs.allowsOverlap,
                      let overlap = lhs.frame.intersection(rhs.frame), overlap.area > 1 else { continue }
                violations.append(SpatialViolation(
                    code: "actor_overlap",
                    subject: lhs.id.raw,
                    other: rhs.id.raw,
                    detail: "overlap_area=\(overlap.area)"
                ))
            }
        }
        return violations
    }

    /// 将面板/角色框压回虚拟屏幕内，宁可缩小也不允许角色越过屏幕边界。
    public static func fit(_ frame: LayoutRect, in bounds: LayoutRect) -> LayoutRect {
        let width = min(max(0, frame.width), max(0, bounds.width))
        let height = min(max(0, frame.height), max(0, bounds.height))
        let x = min(max(frame.x, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.y, bounds.minY), bounds.maxY - height)
        return LayoutRect(x: x, y: y, width: width, height: height)
    }

    /// 在同一层的角色重叠时，按期望的横向位置排序后连续打包，再整体回移
    /// 到可见区域。这样两个角色从同一点入场时也不会出现“向右越界、向左
    /// 回推后仍然重叠”的缺口；总宽度超出屏幕时先按比例缩小，仍保持可见。
    public static func separate(_ actors: [LayoutActor], in bounds: LayoutRect, gap: Double = 4) -> [LayoutActor] {
        var prepared = actors.map { actor -> LayoutActor in
            var copy = actor
            copy.frame = fit(copy.frame, in: bounds)
            return copy
        }
        let movable = prepared.filter { !$0.allowsOverlap }
        let movableWidth = movable.reduce(0) { $0 + $1.frame.width }
        let totalWidth = movableWidth + max(0, Double(movable.count - 1)) * gap
        if totalWidth > bounds.width, movableWidth > 0 {
            let availableWidth = max(1, bounds.width - max(0, Double(movable.count - 1)) * gap)
            let scale = availableWidth / movableWidth
            prepared = prepared.map { actor in
                guard !actor.allowsOverlap else { return actor }
                var copy = actor
                copy.frame.width *= scale
                copy.frame.height *= scale
                copy.frame.y = min(max(copy.frame.y, bounds.minY), bounds.maxY - copy.frame.height)
                return copy
            }
        }

        let movableIndices = prepared.indices.filter { !prepared[$0].allowsOverlap }
        let orderedIndices = movableIndices.sorted {
            let lhs = prepared[$0]
            let rhs = prepared[$1]
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.id.raw < rhs.id.raw
        }
        var packedX: [EntityID: Double] = [:]
        if !orderedIndices.isEmpty {
            // Preserve raw authored anchors whenever the requested composition
            // already fits. Only the overflow path uses centered compaction;
            // this keeps normal desktop positions stable while fixing the old
            // narrow-screen case where clamping only the last actor reintroduced
            // an overlap with its predecessor.
            var rawPacked: [EntityID: Double] = [:]
            var rawCursor: Double?
            for index in orderedIndices {
                let actor = prepared[index]
                let x = max(actor.frame.minX, rawCursor ?? actor.frame.minX)
                rawPacked[actor.id] = x
                rawCursor = x + actor.frame.width + gap
            }
            let rawFirst = rawPacked[prepared[orderedIndices[0]].id] ?? bounds.minX
            let rawLast = prepared[orderedIndices[orderedIndices.count - 1]]
            let rawLastEnd = (rawPacked[rawLast.id] ?? rawLast.frame.minX) + rawLast.frame.width
            if rawFirst >= bounds.minX && rawLastEnd <= bounds.maxX {
                packedX = rawPacked
            } else {
                let preferredCenter = orderedIndices
                    .map { prepared[$0].frame.minX + prepared[$0].frame.width / 2 }
                    .reduce(0, +) / Double(orderedIndices.count)
                let contentWidth = movableWidth + max(0, Double(orderedIndices.count - 1)) * gap
                let firstX = min(
                    max(preferredCenter - contentWidth / 2, bounds.minX),
                    max(bounds.minX, bounds.maxX - contentWidth))
                var cursor = firstX
                for index in orderedIndices {
                    let actor = prepared[index]
                    packedX[actor.id] = cursor
                    cursor += actor.frame.width + gap
                }
            }
        }

        var result = prepared
        for index in result.indices where !result[index].allowsOverlap {
            result[index].frame.x = min(
                max(packedX[result[index].id] ?? result[index].frame.minX, bounds.minX),
                bounds.maxX - result[index].frame.width)
        }
        return result
    }
}

/// 桌面端所有可见角色共用的空间登记表。
///
/// `PetController` 各自拥有自己的面板和身体状态，但不能各自决定屏幕上的
/// 最终位置，否则第二个角色出现时必然会和第一个角色重叠。协调器只保存
/// 最近一次登记的安全框，把真正的分离规则集中交给 `SpatialSafety`；它不
/// 触碰 AppKit，因此可以直接在 harness 和单元测试中复现。
public final class SpatialLayoutCoordinator {
    private var actors: [EntityID: LayoutActor] = [:]
    private var actorGroups: [EntityID: String] = [:]
    private var groupBounds: [String: LayoutRect] = [:]

    public init() {}

    /// 登记或更新一个角色，并返回该角色本轮应该使用的安全框。
    @discardableResult
    public func update(
        _ actor: LayoutActor,
        in bounds: LayoutRect,
        groupID: String = "default",
        gap: Double = 4
    ) -> LayoutActor {
        let groupID = groupID.isEmpty ? "default" : groupID
        if let oldGroup = actorGroups[actor.id], oldGroup != groupID {
            actorGroups.removeValue(forKey: actor.id)
        }
        actors[actor.id] = actor
        actorGroups[actor.id] = groupID
        groupBounds[groupID] = bounds
        // 只在同一个屏幕工作区内重新打包。Dictionary 的遍历顺序不是契约；
        // 按 id 固定顺序，保证多角色布局可复现，同时不会把另一块屏幕的角色
        // 钳进当前屏幕。
        let ordered = actors.values
            .filter { actorGroups[$0.id] == groupID }
            .sorted { $0.id.raw < $1.id.raw }
        let separated = SpatialSafety.separate(ordered, in: bounds, gap: gap)
        for placed in separated {
            actors[placed.id] = placed
        }
        let result = separated.first(where: { $0.id == actor.id }) ?? actor
        return result
    }

    /// 角色退场后移除登记。其他角色下一次更新时会重新获得可用空间。
    public func remove(_ id: EntityID) {
        actors.removeValue(forKey: id)
        if let group = actorGroups.removeValue(forKey: id),
           !actorGroups.values.contains(group) {
            groupBounds.removeValue(forKey: group)
        }
    }

    public func actor(_ id: EntityID) -> LayoutActor? {
        actors[id]
    }

    public var snapshot: [LayoutActor] {
        actors.values.sorted { $0.id.raw < $1.id.raw }
    }
}
