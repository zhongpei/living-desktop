import Foundation
import MyPetCore

public enum SurfaceKind: String, Codable, Sendable {
    case floor
    case windowTop
    case windowBottom
    case platform
}

public struct Surface: Codable, Equatable, Sendable {
    public var id: String
    public var kind: SurfaceKind
    public var left: Double
    public var right: Double
    public var y: Double
    public var hostID: EntityID?

    public init(
        id: String,
        kind: SurfaceKind,
        left: Double,
        right: Double,
        y: Double,
        hostID: EntityID? = nil
    ) {
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

public struct BodyEnvironment: Codable, Equatable, Sendable {
    public var bounds: Rect2D
    public var surfaces: [Surface]

    public init(bounds: Rect2D, surfaces: [Surface]) {
        self.bounds = bounds
        self.surfaces = surfaces.sorted { $0.id < $1.id }
    }

    public func surface(id: String?) -> Surface? {
        guard let id else { return nil }
        return surfaces.first { $0.id == id }
    }

    public func landingSurface(x: Double, previousFeetY: Double, nextFeetY: Double) -> Surface? {
        surfaces
            .filter { $0.contains(x: x) && previousFeetY <= $0.y && nextFeetY >= $0.y }
            .min { lhs, rhs in
                lhs.y == rhs.y ? lhs.id < rhs.id : lhs.y < rhs.y
            }
    }
}
