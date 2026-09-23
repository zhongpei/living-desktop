import Foundation
import MyPetCore

public struct CombatPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
}

public struct CombatRect: Codable, Equatable, Sendable {
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

    public func overlaps(_ other: CombatRect) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }
}

public enum CombatFacing: Int, Codable, Sendable {
    case left = -1
    case right = 1
    public var sign: Double { Double(rawValue) }
    public var flipped: CombatFacing { self == .right ? .left : .right }
}

public enum CombatSurfaceKind: String, Codable, Sendable {
    case floor
    case windowTop
    case windowBottom
    case platform
}

public struct CombatSurface: Codable, Equatable, Sendable {
    public var id: String
    public var kind: CombatSurfaceKind
    public var left: Double
    public var right: Double
    public var y: Double
    public var hostID: EntityID?

    public init(id: String, kind: CombatSurfaceKind, left: Double, right: Double, y: Double,
                hostID: EntityID? = nil) {
        self.id = id
        self.kind = kind
        self.left = min(left, right)
        self.right = max(left, right)
        self.y = y
        self.hostID = hostID
    }

    public func contains(x: Double, margin: Double = 0) -> Bool {
        x >= left + margin && x <= right - margin
    }
}

public struct CombatEnvironment: Codable, Equatable, Sendable {
    public var bounds: CombatRect
    public var surfaces: [CombatSurface]

    public init(bounds: CombatRect, surfaces: [CombatSurface]) {
        self.bounds = bounds
        self.surfaces = surfaces.sorted {
            if $0.y == $1.y { return $0.id < $1.id }
            return $0.y < $1.y
        }
    }

    public func surface(id: String?) -> CombatSurface? {
        guard let id else { return nil }
        return surfaces.first { $0.id == id }
    }

    public func landingSurface(x: Double, previousFeetY: Double, nextFeetY: Double) -> CombatSurface? {
        surfaces
            .filter { $0.contains(x: x) && previousFeetY <= $0.y && nextFeetY >= $0.y }
            .min { lhs, rhs in
                if lhs.y == rhs.y { return lhs.id < rhs.id }
                return lhs.y < rhs.y
            }
    }
}
