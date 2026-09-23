import Foundation

public struct PointerActor: Codable, Equatable, Sendable {
    public var id: EntityID
    public var x: Double
    public var yFeet: Double
    public var displayHeight: Double
    public var availableClips: Set<String>
    public var interactive: Bool
    public var ambient: Bool
    public var allowsStartle: Bool

    public init(id: EntityID, x: Double, yFeet: Double, displayHeight: Double,
                availableClips: Set<String>, interactive: Bool = true,
                ambient: Bool = true, allowsStartle: Bool = true) {
        self.id = id
        self.x = x
        self.yFeet = yFeet
        self.displayHeight = displayHeight
        self.availableClips = availableClips
        self.interactive = interactive
        self.ambient = ambient
        self.allowsStartle = allowsStartle
    }
}

public struct PointerReflexConfig: Codable, Equatable, Sendable {
    public var enterRadius: Double = 1.5
    public var exitRadius: Double = 1.8
    public var startleRadius: Double = 1.0
    public var approachSpeed: Double = 700
    public var cooldown: Double = 6
    public var maxSampleGap: Double = 0.25

    public init() {}
}

public enum PointerResponseKind: String, Codable, Sendable {
    case cursorAttention = "cursor_attention"
    case fastApproach = "fast_approach"
}

public struct PointerResponsePlan: Codable, Equatable, Sendable {
    public var actorID: EntityID
    public var kind: PointerResponseKind
    public var faceRight: Bool
    public var initialClip: String?
    public var retreatX: Double?
    public var recoveryClip: String?

    public var clips: [String] { [initialClip, recoveryClip].compactMap { $0 } }
}

/// Pure pointer state. Coordinates and time are supplied by either VirtualDesktop or AppKit.
public struct PointerReflex: Codable, Equatable, Sendable {
    public var config: PointerReflexConfig
    private var lastX: Double?
    private var lastY: Double?
    private var lastTime: Double?
    private var selectedID: EntityID?
    private var attended = false
    private var lastFacingRight: Bool?
    private var lastStartleAt: Double?

    public var targetID: EntityID? { selectedID }
    public func cooldownRemaining(at time: Double) -> Double {
        guard let lastStartleAt else { return 0 }
        return max(0, config.cooldown - (time - lastStartleAt))
    }

    public init(config: PointerReflexConfig = PointerReflexConfig()) { self.config = config }

    public mutating func reset() {
        lastX = nil
        lastY = nil
        lastTime = nil
        selectedID = nil
        attended = false
        lastFacingRight = nil
    }

    public mutating func sample(x: Double, y: Double, time: Double, buttonDown: Bool = false,
                                actors: [PointerActor]) -> PointerResponsePlan? {
        guard x.isFinite, y.isFinite, time.isFinite, !buttonDown else {
            reset()
            return nil
        }
        let previous = (lastX, lastY, lastTime)
        defer { lastX = x; lastY = y; lastTime = time }
        let candidates = actors.filter { $0.interactive && $0.displayHeight > 0 && $0.displayHeight.isFinite }
        let selected: PointerActor? = {
            if let selectedID,
               let locked = candidates.first(where: { $0.id == selectedID }),
               distance(to: locked, x: x, y: y) < config.exitRadius * locked.displayHeight {
                return locked
            }
            return candidates.filter { distance(to: $0, x: x, y: y) < config.enterRadius * $0.displayHeight }
                .sorted { lhs, rhs in
                    let leftHit = bodyHit(lhs, x: x, y: y)
                    let rightHit = bodyHit(rhs, x: x, y: y)
                    if leftHit != rightHit { return leftHit }
                    let left = distance(to: lhs, x: x, y: y) / lhs.displayHeight
                    let right = distance(to: rhs, x: x, y: y) / rhs.displayHeight
                    return left == right ? lhs.id.raw < rhs.id.raw : left < right
                }.first
        }()
        guard let actor = selected else {
            selectedID = nil
            attended = false
            lastFacingRight = nil
            return nil
        }
        if selectedID != actor.id {
            selectedID = actor.id
            attended = false
            lastFacingRight = nil
        }
        let faceRight = x >= actor.x
        let interval = previous.2.map { time - $0 } ?? 0
        if actor.allowsStartle, interval > 0, interval <= config.maxSampleGap,
           lastStartleAt.map({ time - $0 >= config.cooldown }) ?? true,
           distance(to: actor, x: x, y: y) < config.startleRadius * actor.displayHeight,
           let oldX = previous.0, let oldY = previous.1,
           (distance(to: actor, x: oldX, y: oldY) - distance(to: actor, x: x, y: y)) / interval
                > config.approachSpeed {
            lastStartleAt = time
            attended = true
            lastFacingRight = faceRight
            return PointerResponsePlan(
                actorID: actor.id, kind: .fastApproach, faceRight: faceRight,
                initialClip: ["surprised", "startle"].first { actor.availableClips.contains($0) },
                retreatX: actor.x + (x >= actor.x ? -1 : 1) * actor.displayHeight * 0.9,
                recoveryClip: actor.availableClips.contains("recover") ? "recover" : nil)
        }
        guard actor.ambient else { return nil }
        let newlyAttended = !attended
        let changedFacing = lastFacingRight != faceRight
        attended = true
        lastFacingRight = faceRight
        guard newlyAttended || changedFacing else { return nil }
        return PointerResponsePlan(
            actorID: actor.id, kind: .cursorAttention, faceRight: faceRight,
            initialClip: newlyAttended
                ? ["look", "observe"].first { actor.availableClips.contains($0) } : nil,
            retreatX: nil, recoveryClip: nil)
    }

    private func distance(to actor: PointerActor, x: Double, y: Double) -> Double {
        hypot(x - actor.x, y - (actor.yFeet - actor.displayHeight * 0.5))
    }

    private func bodyHit(_ actor: PointerActor, x: Double, y: Double) -> Bool {
        let dx = (x - actor.x) / (actor.displayHeight * 0.42)
        let dy = (y - (actor.yFeet - actor.displayHeight * 0.5)) / (actor.displayHeight * 0.5)
        return dx * dx + dy * dy <= 1
    }
}
