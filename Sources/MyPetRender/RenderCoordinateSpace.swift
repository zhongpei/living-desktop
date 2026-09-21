import AppKit

/// Coordinate conversion is injected so views do not reach into game-world
/// screen state and can be tested without the production Screens singleton.
@MainActor
public protocol RenderCoordinateSpace: AnyObject {
    var primaryTopY: CGFloat { get }
    func appKitRect(
        flippedTop: CGFloat,
        x: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect
    func flippedWorkArea(containing point: CGPoint) -> CGRect
}

@MainActor
public final class AppKitRenderCoordinateSpace: RenderCoordinateSpace {
    public init() {}

    public var primaryTopY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    public func appKitRect(
        flippedTop: CGFloat,
        x: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        CGRect(x: x, y: primaryTopY - flippedTop - height, width: width, height: height)
    }

    public func flippedWorkArea(containing point: CGPoint) -> CGRect {
        let candidates = NSScreen.screens.map { screen -> CGRect in
            let frame = screen.visibleFrame
            return CGRect(
                x: frame.minX,
                y: primaryTopY - frame.maxY,
                width: frame.width,
                height: frame.height)
        }
        return candidates.first(where: { $0.contains(point) })
            ?? candidates.first
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
