import AppKit
import CoreGraphics

/// Thin rendering seam between presentation/game state and the concrete macOS renderer.
/// A future Metal renderer only needs to implement this surface contract; combat, story,
/// simulation and content code remain unchanged.
@MainActor
public protocol ActorRenderSurface: AnyObject {
    var alphaValue: CGFloat { get set }
    var onMouseDown: ((CGPoint) -> Void)? { get set }
    var onMouseDragged: ((CGPoint) -> Void)? { get set }
    var onMouseUp: ((CGPoint, Bool) -> Void)? { get set }
    var onRightMouseDown: ((CGPoint) -> Void)? { get set }

    func display(image: CGImage, mirrored: Bool)
    func displayProp(image: CGImage?, rect: CGRect)
    func setFrame(_ frame: CGRect)
    func show()
    func hide()
}

@MainActor
public protocol ActorRenderBackend: AnyObject {
    func makeActorSurface(
        initialFrame: CGRect,
        coordinateSpace: any RenderCoordinateSpace
    ) -> any ActorRenderSurface
}

/// First renderer: native AppKit window composition backed by CALayer.
/// This keeps transparent desktop windows cheap and avoids a game-engine dependency,
/// while the protocol above leaves a clean path to Metal/MTKView batching later.
@MainActor
public final class CoreAnimationRenderBackend: ActorRenderBackend {
    public init() {}

    public func makeActorSurface(
        initialFrame: CGRect,
        coordinateSpace: any RenderCoordinateSpace
    ) -> any ActorRenderSurface {
        CoreAnimationActorSurface(initialFrame: initialFrame, coordinateSpace: coordinateSpace)
    }
}

@MainActor
final class CoreAnimationActorSurface: ActorRenderSurface {
    private let panel: OverlayPanel
    private let view: PetView

    init(initialFrame: CGRect, coordinateSpace: any RenderCoordinateSpace) {
        view = PetView(frame: CGRect(origin: .zero, size: initialFrame.size),
                       coordinateSpace: coordinateSpace)
        panel = OverlayPanel(contentView: view, initialFrame: initialFrame)
    }

    var alphaValue: CGFloat {
        get { panel.alphaValue }
        set { panel.alphaValue = newValue }
    }

    var onMouseDown: ((CGPoint) -> Void)? {
        get { view.onMouseDown }
        set { view.onMouseDown = newValue }
    }
    var onMouseDragged: ((CGPoint) -> Void)? {
        get { view.onMouseDragged }
        set { view.onMouseDragged = newValue }
    }
    var onMouseUp: ((CGPoint, Bool) -> Void)? {
        get { view.onMouseUp }
        set { view.onMouseUp = newValue }
    }
    var onRightMouseDown: ((CGPoint) -> Void)? {
        get { view.onRightMouseDown }
        set { view.onRightMouseDown = newValue }
    }

    func display(image: CGImage, mirrored: Bool) {
        view.display(image: image, mirrored: mirrored)
    }

    func displayProp(image: CGImage?, rect: CGRect) {
        view.displayProp(image: image, rect: rect)
    }

    func setFrame(_ frame: CGRect) {
        panel.setFrame(frame, display: false)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
