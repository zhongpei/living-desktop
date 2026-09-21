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
        // Select by the full screen, then return its visible work area. A pet
        // can briefly enter the Dock/menu-bar strip without jumping screens.
        let screens = NSScreen.screens
        let index = Self.screenIndex(containing: point, frames: screens.map(\.frame),
                                     primaryTopY: primaryTopY)
        let screen = index.map { screens[$0] } ?? NSScreen.main ?? screens.first
        guard let screen else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let frame = screen.visibleFrame
        return CGRect(
            x: frame.minX, y: primaryTopY - frame.maxY,
            width: frame.width, height: frame.height)
    }

    static func screenIndex(containing point: CGPoint, frames: [CGRect],
                            primaryTopY: CGFloat) -> Int? {
        frames.firstIndex { frame in
            CGRect(x: frame.minX, y: primaryTopY - frame.maxY,
                   width: frame.width, height: frame.height).contains(point)
        }
    }
}
