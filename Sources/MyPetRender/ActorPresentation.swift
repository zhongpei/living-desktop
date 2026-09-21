import AppKit
import MyPetContent
import MyPetCore

/// Petpack-only visual choices. Kernel supplies the body facts; this value
/// supplies the available clips without teaching Core about image assets.
public struct ActorAppearance {
    public let idle: String
    public let walk: String
    public let run: String
    public let airborne: String
    public let drag: String
    public let sleep: String
    public let idlePool: [String]
    public let leftAuthoredClips: Set<String>

    public init(
        idle: String, walk: String, run: String, airborne: String,
        drag: String, sleep: String, idlePool: [String],
        leftAuthoredClips: Set<String> = []
    ) {
        self.idle = idle
        self.walk = walk
        self.run = run
        self.airborne = airborne
        self.drag = drag
        self.sleep = sleep
        self.idlePool = idlePool
        self.leftAuthoredClips = leftAuthoredClips
    }

    public init(library: ClipLibrary) {
        let idle = library.baseOrFallback(.idle)
        let walk = library.baseOrFallback(.walk)
        let run = library.baseOrFallback(.run)
        let airborne = library.baseOrFallback(.airborne)
        let drag = library.baseOrFallback(.drag)
        let sleep = library.sleepActionKey() ?? idle
        let keys = Set([idle, walk, run, airborne, drag, sleep] + library.idlePool +
            library.actionNames.compactMap(library.action(named:)))
        self.init(
            idle: idle, walk: walk, run: run, airborne: airborne,
            drag: drag, sleep: sleep, idlePool: library.idlePool,
            leftAuthoredClips: Set(keys.filter { library.facing(for: $0) == .left }))
    }
}

/// Owns one actor's primary AppKit surface, sprite timeline and speech bubble.
/// The body adapter reports pose; this module chooses the visual clip from
/// Core's read-only snapshot and never reports behavior completion.
@MainActor
public final class ActorPresentation {
    private let animator: SpriteAnimator
    private let panel: OverlayPanel
    private let view: PetView
    private let bubble: SpeechBubble
    private let appearance: ActorAppearance
    private var idleClip: String
    private var idleSwapAt = 0.0
    private var displayedMirrored = false

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

    public init(source: any SpriteClipSource, initialFrame: CGRect,
                appearance: ActorAppearance) {
        animator = SpriteAnimator(source: source)
        view = PetView(frame: CGRect(origin: .zero, size: initialFrame.size))
        panel = OverlayPanel(contentView: view, initialFrame: initialFrame)
        bubble = SpeechBubble()
        self.appearance = appearance
        idleClip = appearance.idle
        animator.play(appearance.idle)
        if let image = animator.currentImage { view.display(image: image, mirrored: false) }
    }

    public var clipName: String { animator.clipName }
    public var animationFinished: Bool { animator.isFinished }

    public func apply(
        snapshot: PresentationSnapshot, actorID: EntityID,
        effects: [PresentationEffect], dt: Double, now: Double
    ) {
        let pose = snapshot.entities.first { $0.id == actorID }?.pose
        let clip = selectedClip(for: pose, now: now)
        let previous = animator.clipName
        let restart = effects.contains { $0.actorID == actorID }
        animator.play(clip, restart: restart)
        let mirrored = pose.map {
            appearance.leftAuthoredClips.contains(animator.clipName)
                ? $0.facingRight : !$0.facingRight
        } ?? false
        let (image, changed) = animator.tick(dt: dt)
        if (changed || previous != animator.clipName || restart || mirrored != displayedMirrored),
           let image {
            view.display(image: image, mirrored: mirrored)
            displayedMirrored = mirrored
        }
    }

    private func selectedClip(for pose: BodyPose?, now: Double) -> String {
        guard let pose else { return appearance.idle }
        switch pose.motion {
        case "asleep": return appearance.sleep
        case "dragged": return appearance.drag
        case "tossed": return appearance.airborne
        case "airborne": return abs(pose.horizontalSpeed) > 200
            ? appearance.run : appearance.airborne
        case "walking": return appearance.walk
        default:
            if let action = pose.action { return action }
            let movement = [appearance.walk, appearance.run, appearance.sleep]
            if movement.contains(animator.clipName), animator.clipName != idleClip {
                idleClip = appearance.idle
            }
            if now > idleSwapAt {
                idleSwapAt = now + Double.random(in: 4...9)
                idleClip = appearance.idlePool.randomElement() ?? appearance.idle
            }
            return idleClip
        }
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
