import Foundation
import MyPet2D

public struct SurfaceMobility: Codable, Equatable, Sendable {
    public var walkSpeed: Double
    public var runSpeedMultiplier: Double
    public var jumpVelocity: Double
    public var maximumJumpCount: Int

    public init(
        walkSpeed: Double,
        runSpeedMultiplier: Double = 1.65,
        jumpVelocity: Double,
        maximumJumpCount: Int = 3
    ) {
        self.walkSpeed = max(0.1, walkSpeed)
        self.runSpeedMultiplier = min(3, max(1, runSpeedMultiplier))
        self.jumpVelocity = min(-0.1, jumpVelocity)
        self.maximumJumpCount = min(6, max(1, maximumJumpCount))
    }

    public var airborneHorizontalSpeed: Double {
        walkSpeed * max(1.15, runSpeedMultiplier * 0.9)
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
    /// Total jumps required by this traversal, including the initial takeoff.
    /// Walk/drop edges use zero.
    public var requiredJumpCount: Int?

    public init(
        fromSurfaceID: String, toSurfaceID: String,
        action: SurfaceNavigationAction, launchX: Double,
        landingLeft: Double, landingRight: Double,
        expectedFrames: Int, risk: Double,
        requiredJumpCount: Int = 0
    ) {
        self.fromSurfaceID = fromSurfaceID
        self.toSurfaceID = toSurfaceID
        self.action = action
        self.launchX = launchX
        self.landingLeft = landingLeft
        self.landingRight = landingRight
        self.expectedFrames = max(1, expectedFrames)
        self.risk = max(0, risk)
        self.requiredJumpCount = max(0, requiredJumpCount)
    }

    public var effectiveRequiredJumpCount: Int {
        requiredJumpCount ?? (action == .jump ? 1 : 0)
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

/// Dynamic desktop traversal graph.
///
/// Floors and window tops are first-class terrain. Window bottoms remain
/// collision geometry only. Jump links are validated against the same fixed
/// gravity used by BodyWorld and may consume several authored air jumps.
public struct DynamicSurfaceGraph: Codable, Equatable, Sendable {
    public var surfaces: [Surface]
    public var edges: [SurfaceNavigationEdge]
    public var fingerprint: String

    public static func build(
        environment: BodyEnvironment,
        mobility: SurfaceMobility
    ) -> DynamicSurfaceGraph {
        let surfaces = traversableSurfaces(environment).sorted { $0.id < $1.id }
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
        return DynamicSurfaceGraph(
            surfaces: surfaces,
            edges: edges,
            fingerprint: fingerprint(environment: environment, mobility: mobility))
    }

    public static func fingerprint(
        environment: BodyEnvironment,
        mobility: SurfaceMobility
    ) -> String {
        traversableSurfaces(environment).sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.kind.rawValue):\($0.left):\($0.right):\($0.y)"
        }.joined(separator: "|") +
            "|mobility:\(mobility.walkSpeed):\(mobility.runSpeedMultiplier):" +
            "\(mobility.jumpVelocity):\(mobility.maximumJumpCount)"
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

    public func surface(id: String) -> Surface? {
        surfaces.first { $0.id == id }
    }

    public func surface(containingX x: Double, nearY y: Double) -> Surface? {
        surfaces.filter { $0.contains(x: x) }.min {
            abs($0.y - y) < abs($1.y - y)
        }
    }

    public var tacticalSurfaces: [Surface] {
        surfaces.filter { $0.kind == .windowTop }
    }

    private static func traversableSurfaces(_ environment: BodyEnvironment) -> [Surface] {
        environment.surfaces.filter { $0.kind == .floor || $0.kind == .windowTop }
    }

    private static func makeEdge(
        from: Surface, to: Surface, mobility: SurfaceMobility
    ) -> SurfaceNavigationEdge? {
        let overlapLeft = max(from.left, to.left)
        let overlapRight = min(from.right, to.right)
        let overlap = overlapRight - overlapLeft
        let horizontalGap = max(0, max(to.left - from.right, from.left - to.right))
        let centerFrom = (from.left + from.right) * 0.5
        let centerTo = (to.left + to.right) * 0.5

        if abs(from.y - to.y) <= 4, horizontalGap <= 8 {
            let distance = abs(centerTo - centerFrom)
            return SurfaceNavigationEdge(
                fromSurfaceID: from.id, toSurfaceID: to.id, action: .walk,
                launchX: centerFrom,
                landingLeft: to.left, landingRight: to.right,
                expectedFrames: Int(ceil(distance / mobility.walkSpeed)),
                risk: 0)
        }

        // A vertical overlap to a lower surface is a real drop only from a
        // window/platform. Floor edges are clamped by BodyWorld, so crossing
        // monitor floors always uses an explicit jump link.
        if from.kind != .floor, to.y > from.y + 4, overlap > 0 {
            let fallFrames = max(1, Int(ceil(sqrt(
                2 * (to.y - from.y) / BodyWorld.gravityPerFrame))))
            return SurfaceNavigationEdge(
                fromSurfaceID: from.id, toSurfaceID: to.id, action: .drop,
                launchX: (overlapLeft + overlapRight) * 0.5,
                landingLeft: overlapLeft, landingRight: overlapRight,
                expectedFrames: fallFrames,
                risk: max(0, to.y - from.y) * 0.04)
        }

        guard let jump = jumpTraversal(
            verticalDelta: to.y - from.y,
            horizontalGap: horizontalGap,
            mobility: mobility) else { return nil }

        let launchX: Double
        if to.left > from.right {
            launchX = from.right
        } else if to.right < from.left {
            launchX = from.left
        } else {
            launchX = (overlapLeft + overlapRight) * 0.5
        }
        let heightRisk = max(0, from.y - to.y) * 0.05
        let gapRisk = horizontalGap * 0.08
        let multiJumpRisk = Double(max(0, jump.jumps - 1)) * 10
        return SurfaceNavigationEdge(
            fromSurfaceID: from.id, toSurfaceID: to.id, action: .jump,
            launchX: launchX,
            landingLeft: to.left, landingRight: to.right,
            expectedFrames: jump.frames,
            risk: heightRisk + gapRisk + multiJumpRisk,
            requiredJumpCount: jump.jumps)
    }

    /// Simulate the vertical component with the same per-frame gravity used by
    /// BodyWorld. Additional jumps are spent at each apex; this maximizes both
    /// reachable height and horizontal traversal time without teleportation.
    private static func jumpTraversal(
        verticalDelta: Double,
        horizontalGap: Double,
        mobility: SurfaceMobility
    ) -> (frames: Int, jumps: Int)? {
        let horizontalSpeed = mobility.airborneHorizontalSpeed
        for desiredJumps in 1...mobility.maximumJumpCount {
            var y = 0.0
            var velocityY = mobility.jumpVelocity
            var jumpsUsed = 1
            var previousY = y
            for frame in 1...360 {
                if jumpsUsed < desiredJumps, velocityY >= 0 {
                    velocityY = mobility.jumpVelocity
                    jumpsUsed += 1
                }
                previousY = y
                velocityY += BodyWorld.gravityPerFrame
                y += velocityY
                let descending = velocityY >= 0
                if jumpsUsed == desiredJumps,
                   descending,
                   previousY <= verticalDelta,
                   y >= verticalDelta {
                    let reachableX = horizontalSpeed * Double(frame)
                    if horizontalGap <= reachableX + 12 {
                        return (frame, desiredJumps)
                    }
                    break
                }
                // If the simulated fighter falls far below every realistic
                // desktop landing height, this jump count cannot help.
                if y > max(1_800, verticalDelta + 600) { break }
            }
        }
        return nil
    }
}
