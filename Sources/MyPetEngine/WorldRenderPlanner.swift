import Foundation
import MyPetCore

/// Immutable placement input assembled by platform adapters. The planner may
/// adjust the visual panel inside desktop bounds, but never mutates BodyWorld.
public struct WorldRenderPlacementRequest: Equatable, Sendable {
    public let actorID: EntityID
    public let pose: BodyPose
    public let visualWidth: Double
    public let visualHeight: Double
    public let baselineRatio: Double
    public let bounds: LayoutRect
    public let groupID: String
    public let authoredFrame: LayoutRect?
    public let bypassSafety: Bool

    public init(
        actorID: EntityID, pose: BodyPose,
        visualWidth: Double, visualHeight: Double,
        baselineRatio: Double, bounds: LayoutRect,
        groupID: String, authoredFrame: LayoutRect? = nil,
        bypassSafety: Bool = false
    ) {
        self.actorID = actorID
        self.pose = pose
        self.visualWidth = visualWidth
        self.visualHeight = visualHeight
        self.baselineRatio = baselineRatio
        self.bounds = bounds
        self.groupID = groupID
        self.authoredFrame = authoredFrame
        self.bypassSafety = bypassSafety
    }
}

/// World-side visual placement policy. Render backends consume its result and
/// cannot clamp, separate or write coordinates back into the simulation.
@MainActor
public final class WorldRenderPlanner {
    private let layout: SpatialLayoutCoordinator?

    public init(layout: SpatialLayoutCoordinator? = nil) {
        self.layout = layout
    }

    public func frame(for request: WorldRenderPlacementRequest) -> LayoutRect {
        let raw = LayoutRect(
            x: request.pose.x - request.visualWidth / 2,
            y: request.pose.yFeet - request.visualHeight * request.baselineRatio,
            width: request.visualWidth,
            height: request.visualHeight)
        if request.bypassSafety { return raw }
        if let authoredFrame = request.authoredFrame {
            return SpatialSafety.fit(authoredFrame, in: request.bounds)
        }
        let safe = SpatialSafety.placeActor(
            id: request.actorID,
            anchorX: request.pose.x,
            feetY: request.pose.yFeet,
            width: request.visualWidth,
            height: request.visualHeight,
            baselineRatio: request.baselineRatio,
            in: request.bounds)
        return layout?.update(safe, in: request.bounds, groupID: request.groupID).frame
            ?? safe.frame
    }

    public func remove(_ actorID: EntityID) {
        layout?.remove(actorID)
    }
}
