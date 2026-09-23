import Foundation

public struct Vec2: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

public struct CollisionMask: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let environment = CollisionMask(rawValue: 1 << 0)
    public static let body = CollisionMask(rawValue: 1 << 1)
    public static let sensor = CollisionMask(rawValue: 1 << 2)
    public static let hit = CollisionMask(rawValue: 1 << 3)
    public static let hurt = CollisionMask(rawValue: 1 << 4)
}

public struct SweepHit: Codable, Equatable, Sendable {
    public var time: Double
    public var normal: Vec2

    public init(time: Double, normal: Vec2) {
        self.time = time
        self.normal = normal
    }
}

public struct Rect2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = min(x, x + width)
        self.y = min(y, y + height)
        self.width = abs(width)
        self.height = abs(height)
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }

    public func overlaps(_ other: Rect2D) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }

    public func placed(at axis: Vec2, facing: Facing2D, scale: Double = 1) -> Rect2D {
        let x1 = minX * scale * facing.sign + axis.x
        let x2 = maxX * scale * facing.sign + axis.x
        return Rect2D(
            x: min(x1, x2),
            y: axis.y + minY * scale,
            width: abs(x2 - x1),
            height: height * scale)
    }

    /// Returns the first normalized time in 0...1 at which this AABB reaches `target`.
    public func sweep(
        displacement: Vec2,
        against target: Rect2D,
        epsilon: Double = 1e-9
    ) -> SweepHit? {
        if overlaps(target) { return SweepHit(time: 0, normal: Vec2()) }

        func axisTimes(
            movingMin: Double,
            movingMax: Double,
            targetMin: Double,
            targetMax: Double,
            delta: Double
        ) -> (entry: Double, exit: Double)? {
            if abs(delta) <= epsilon {
                guard movingMax >= targetMin - epsilon, movingMin <= targetMax + epsilon else {
                    return nil
                }
                return (-Double.infinity, Double.infinity)
            }
            let near = delta > 0 ? targetMin - movingMax : targetMax - movingMin
            let far = delta > 0 ? targetMax - movingMin : targetMin - movingMax
            return (near / delta, far / delta)
        }

        guard let xTimes = axisTimes(
            movingMin: minX, movingMax: maxX,
            targetMin: target.minX, targetMax: target.maxX,
            delta: displacement.x),
              let yTimes = axisTimes(
                movingMin: minY, movingMax: maxY,
                targetMin: target.minY, targetMax: target.maxY,
                delta: displacement.y) else { return nil }
        let entry = max(xTimes.entry, yTimes.entry)
        let exit = min(xTimes.exit, yTimes.exit)
        guard entry <= exit + epsilon, exit >= -epsilon, entry <= 1 + epsilon else { return nil }

        let time = min(1, max(0, entry))
        if xTimes.entry > yTimes.entry {
            return SweepHit(time: time, normal: Vec2(x: displacement.x > 0 ? -1 : 1, y: 0))
        }
        return SweepHit(time: time, normal: Vec2(x: 0, y: displacement.y > 0 ? -1 : 1))
    }
}

public enum Facing2D: Int, Codable, Sendable {
    case left = -1
    case right = 1

    public var sign: Double { Double(rawValue) }
    public var flipped: Facing2D { self == .right ? .left : .right }
}
