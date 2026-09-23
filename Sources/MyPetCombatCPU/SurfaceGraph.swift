import Foundation
import MyPet2D

public struct SurfaceMobility: Codable, Equatable, Sendable {
    public var walkSpeed: Double
    public var jumpVelocity: Double
    public var maximumJumpGap: Double
    public var maximumJumpRise: Double

    public init(
        walkSpeed: Double,
        jumpVelocity: Double,
        maximumJumpGap: Double = 260,
        maximumJumpRise: Double = 220
    ) {
        self.walkSpeed = max(0.1, walkSpeed)
        self.jumpVelocity = jumpVelocity
        self.maximumJumpGap = max(0, maximumJumpGap)
        self.maximumJumpRise = max(0, maximumJumpRise)
    }
}

public enum SurfaceNavigationAction: String, Codable, Sendable {
    case walk, jump, drop
}

public struct SurfaceNavigationEdge: Codable, Equatable, Sendable {
    public var fromSurfaceID: String
    public var toSurfaceID: String
    public var action: SurfaceNavigationAction
    public var launchX: Double
    public var landingLeft: Double
    public var landingRight: Double
    public var expectedFrames: Int
    public var risk: Double

    public init(
        fromSurfaceID: String, toSurfaceID: String,
        action: SurfaceNavigationAction, launchX: Double,
        landingLeft: Double, landingRight: Double,
        expectedFrames: Int, risk: Double
    ) {
        self.fromSurfaceID = fromSurfaceID
        self.toSurfaceID = toSurfaceID
        self.action = action
        self.launchX = launchX
        self.landingLeft = landingLeft
        self.landingRight = landingRight
        self.expectedFrames = max(1, expectedFrames)
        self.risk = max(0, risk)
    }

    public var cost: Double { Double(expectedFrames) + risk }
}

public struct SurfacePath: Codable, Equatable, Sendable {
    public var edges: [SurfaceNavigationEdge]
    public var totalCost: Double

    public init(edges: [SurfaceNavigationEdge], totalCost: Double) {
        self.edges = edges
        self.totalCost = totalCost
    }

    public var surfaceIDs: [String] {
        guard let first = edges.first else { return [] }
        return [first.fromSurfaceID] + edges.map(\.toSurfaceID)
    }
}

/// Deterministic surface-level graph inspired by Surfacer's MIT-licensed
/// surface/trajectory split (SnoringCatGames/surfacer, parent of 336acda).
/// The desktop adaptation intentionally keeps only walk/jump/drop reachability.
public struct DynamicSurfaceGraph: Codable, Equatable, Sendable {
    public var surfaces: [Surface]
    public var edges: [SurfaceNavigationEdge]
    public var fingerprint: String

    public static func build(
        environment: BodyEnvironment,
        mobility: SurfaceMobility
    ) -> DynamicSurfaceGraph {
        let surfaces = environment.surfaces.sorted { $0.id < $1.id }
        var edges: [SurfaceNavigationEdge] = []
        for from in surfaces {
            for to in surfaces where from.id != to.id {
                if let edge = makeEdge(from: from, to: to, mobility: mobility) {
                    edges.append(edge)
                }
            }
        }
        edges.sort {
            ($0.fromSurfaceID, $0.toSurfaceID, $0.action.rawValue) <
            ($1.fromSurfaceID, $1.toSurfaceID, $1.action.rawValue)
        }
        let fingerprint = fingerprint(environment: environment, mobility: mobility)
        return DynamicSurfaceGraph(
            surfaces: surfaces, edges: edges, fingerprint: fingerprint)
    }

    public static func fingerprint(
        environment: BodyEnvironment,
        mobility: SurfaceMobility
    ) -> String {
        environment.surfaces.sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.kind.rawValue):\($0.left):\($0.right):\($0.y)"
        }.joined(separator: "|") +
            "|mobility:\(mobility.walkSpeed):\(mobility.jumpVelocity):" +
            "\(mobility.maximumJumpGap):\(mobility.maximumJumpRise)"
    }

    public func path(from start: String, to goal: String) -> SurfacePath? {
        guard surfaces.contains(where: { $0.id == start }),
              surfaces.contains(where: { $0.id == goal }) else { return nil }
        let indexed = Dictionary(uniqueKeysWithValues: edges.map {
            ("\($0.fromSurfaceID)\u{0}\($0.toSurfaceID)", $0)
        })
        let referenceEdges = edges.map {
            SurfacerPathCompatibility.Edge(
                from: $0.fromSurfaceID, to: $0.toSurfaceID, cost: $0.cost)
        }
        guard let path = SurfacerPathCompatibility.shortestPath(
            from: start, to: goal, edges: referenceEdges) else { return nil }
        let resolved = path.compactMap { indexed["\($0.from)\u{0}\($0.to)"] }
        guard resolved.count == path.count else { return nil }
        return SurfacePath(
            edges: resolved,
            totalCost: resolved.reduce(0) { $0 + $1.cost })
    }

    public func surface(containingX x: Double, nearY y: Double) -> Surface? {
        surfaces.filter { $0.contains(x: x) }.min {
            abs($0.y - y) < abs($1.y - y)
        }
    }

    private static func makeEdge(
        from: Surface, to: Surface, mobility: SurfaceMobility
    ) -> SurfaceNavigationEdge? {
        let overlapLeft = max(from.left, to.left)
        let overlapRight = min(from.right, to.right)
        let overlap = overlapRight - overlapLeft
        let horizontalGap = max(0, max(to.left - from.right, from.left - to.right))
        let rise = from.y - to.y
        let centerFrom = (from.left + from.right) * 0.5
        let centerTo = (to.left + to.right) * 0.5
        if abs(from.y - to.y) <= 4, horizontalGap <= 8 {
            let distance = abs(centerTo - centerFrom)
            return SurfaceNavigationEdge(
                fromSurfaceID: from.id, toSurfaceID: to.id, action: .walk,
                launchX: centerFrom, landingLeft: to.left, landingRight: to.right,
                expectedFrames: Int(ceil(distance / mobility.walkSpeed)), risk: 0)
        }
        if rise >= -20, rise <= mobility.maximumJumpRise,
           horizontalGap <= mobility.maximumJumpGap {
            let flight = max(12, Int(ceil(abs(mobility.jumpVelocity) * 2 /
                BodyWorld.gravityPerFrame)))
            let risk = horizontalGap * 0.12 + max(0, rise) * 0.08
            return SurfaceNavigationEdge(
                fromSurfaceID: from.id, toSurfaceID: to.id, action: .jump,
                launchX: to.left > from.right ? from.right :
                    (to.right < from.left ? from.left : (overlapLeft + overlapRight) * 0.5),
                landingLeft: to.left, landingRight: to.right,
                expectedFrames: flight, risk: risk)
        }
        if to.y > from.y + 4, overlap > 0 {
            let fallFrames = max(1, Int(ceil(sqrt(
                2 * (to.y - from.y) / BodyWorld.gravityPerFrame))))
            return SurfaceNavigationEdge(
                fromSurfaceID: from.id, toSurfaceID: to.id, action: .drop,
                launchX: (overlapLeft + overlapRight) * 0.5,
                landingLeft: overlapLeft, landingRight: overlapRight,
                expectedFrames: fallFrames, risk: max(0, to.y - from.y) * 0.05)
        }
        return nil
    }
}
