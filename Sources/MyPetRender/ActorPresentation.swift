import AppKit
import MyPetContent

/// Owns one actor's primary AppKit surface, sprite timeline and speech bubble.
/// Body/game code still chooses semantic clips and frames during migration.
@MainActor
public final class ActorPresentation {
    private let animator: SpriteAnimator
    private let panel: OverlayPanel
    private let view: PetView
    private let bubble: SpeechBubble

    public var onMouseDown: ((CGPoint) -> Void)? {
        get { view.onMouseDown }
        set { view.onMouseDown = newValue }
    }
    public var onMouseDragged: ((CGPoint) -> Void)? {
        get { view.onMouseDragged }
        set { view.onMouseDragged = newValue }
    }
    public var onMouseUp: ((CGPoint, Bool) -> Void)? {
        get { view.onMouseUp }
        set { view.onMouseUp = newValue }
    }
    public var onRightMouseDown: ((CGPoint) -> Void)? {
        get { view.onRightMouseDown }
        set { view.onRightMouseDown = newValue }
    }

    public init(source: any SpriteClipSource, initialFrame: CGRect) {
        animator = SpriteAnimator(source: source)
        view = PetView(frame: CGRect(origin: .zero, size: initialFrame.size))
        panel = OverlayPanel(contentView: view, initialFrame: initialFrame)
        bubble = SpeechBubble()
    }

    public var clipName: String { animator.clipName }
    public var animationFinished: Bool { animator.isFinished }

    public func play(_ clip: String, restart: Bool = false) {
        animator.play(clip, restart: restart)
    }

    public func showInitial(image: CGImage, mirrored: Bool = false) {
        view.display(image: image, mirrored: mirrored)
    }

    public func advance(dt: Double, mirrored: Bool) {
        let (image, changed) = animator.tick(dt: dt)
        if changed, let image { view.display(image: image, mirrored: mirrored) }
    }

    public func displayProp(image: CGImage?, rect: CGRect) {
        view.displayProp(image: image, rect: rect)
    }

    public func setFrame(_ frame: CGRect, display: Bool = false) {
        panel.setFrame(frame, display: display)
    }

    public func setOpacity(_ opacity: CGFloat) { panel.alphaValue = opacity }
    public func show() { panel.orderFrontRegardless() }
    public func hide() { panel.orderOut(nil); bubble.dismiss() }
    public func speak(_ text: String, headX: CGFloat, headY: CGFloat) {
        bubble.show(text, headX: headX, headY: headY)
    }
}
