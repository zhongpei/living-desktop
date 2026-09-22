import AppKit
import AVFoundation
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
    private let voiceURL: (String) -> URL?
    private var voicePlayer: AVAudioPlayer?
    private let panel: OverlayPanel
    private let view: PetView
    private let bubble: SpeechBubble
    private let appearance: ActorAppearance
    private let actorID: EntityID
    private let coordinateSpace: any RenderCoordinateSpace
    private let layoutCoordinator: SpatialLayoutCoordinator?
    private let baselineRatio: Double
    private let stepMilliseconds: Int64
    private let visualSize: CGSize
    private var idleClip: String
    private var idleSwapAt = 0.0
    private var displayedMirrored = false
    private var castFrame: LayoutRect?
    private var detachedFromCastLayout = false
    private var transition: (plan: CastTransitionPlan, startedAt: Double)?
    public private(set) var projectedFrame: LayoutRect?
    public var voicePlaybackEnabled = true {
        didSet { if !voicePlaybackEnabled { stopVoice() } }
    }

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

    public init(
        source: any SpriteClipSource, initialFrame: CGRect,
        appearance: ActorAppearance, actorID: EntityID,
        baselineRatio: Double = 0.88,
        layoutCoordinator: SpatialLayoutCoordinator? = nil,
        stepMilliseconds: Int64 = 50,
        coordinateSpace: (any RenderCoordinateSpace)? = nil
    ) {
        let space = coordinateSpace ?? AppKitRenderCoordinateSpace()
        animator = SpriteAnimator(source: source)
        voiceURL = (source as? ClipLibrary)?.voiceURL(for:) ?? { _ in nil }
        view = PetView(frame: CGRect(origin: .zero, size: initialFrame.size), coordinateSpace: space)
        panel = OverlayPanel(contentView: view, initialFrame: initialFrame)
        bubble = SpeechBubble()
        self.appearance = appearance
        self.actorID = actorID
        self.coordinateSpace = space
        self.layoutCoordinator = layoutCoordinator
        self.baselineRatio = baselineRatio
        self.stepMilliseconds = max(1, stepMilliseconds)
        visualSize = initialFrame.size
        idleClip = appearance.idle
        animator.play(appearance.idle)
        if let image = animator.currentImage { view.display(image: image, mirrored: false) }
    }

    public var clipName: String { animator.clipName }
    public var animationFinished: Bool { animator.isFinished }

    public func apply(
        snapshot: PresentationSnapshot,
        effects: [PresentationEffect], dt: Double, now: Double
    ) {
        let pose = snapshot.entities.first { $0.id == actorID }?.pose
        if let pose { place(pose: pose, now: ProcessInfo.processInfo.systemUptime) }
        let clip = selectedClip(for: pose, now: now)
        let previous = animator.clipName
        let restart = effects.contains { $0.actorID == actorID }
        animator.play(clip, restart: restart)
        if previous != animator.clipName || restart {
            stopVoice()
            if voicePlaybackEnabled, animator.clipName == clip,
               Self.shouldStartVoice(previous: previous, current: clip,
                                     effects: effects, actorID: actorID),
               let url = voiceURL(clip) {
                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.numberOfLoops = 0
                    player.play()
                    voicePlayer = player
                } catch {
                    NSLog("MyPet: 动作语音播放失败 %@: %@", url.lastPathComponent, String(describing: error))
                }
            }
        }
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

    public func setCastFrame(_ frame: LayoutRect?) {
        guard !detachedFromCastLayout else { return }
        castFrame = frame
    }

    public func detachFromCastLayout() {
        if castFrame != nil { detachedFromCastLayout = true }
        castFrame = nil
    }

    public func beginTransition(_ plan: CastTransitionPlan) {
        transition = (plan, ProcessInfo.processInfo.systemUptime)
    }

    public func cancelTransition() {
        transition = nil
        panel.alphaValue = 1
    }

    public func stop() {
        stopVoice()
        cancelTransition()
        layoutCoordinator?.remove(actorID)
    }

    private func stopVoice() {
        voicePlayer?.stop()
        voicePlayer = nil
    }

    static func shouldStartVoice(previous: String, current: String,
                                 effects: [PresentationEffect], actorID: EntityID) -> Bool {
        previous != current || effects.contains {
            $0.actorID == actorID && $0.kind == .behaviorStarted
        }
    }

    private func place(pose: BodyPose, now: Double) {
        let width = Double(visualSize.width)
        let height = Double(visualSize.height)
        let raw = LayoutRect(
            x: pose.x - width / 2,
            y: pose.yFeet - height * baselineRatio,
            width: width, height: height)
        if pose.motion == "dragged" || detachedFromCastLayout {
            show(frame: raw)
            return
        }
        let work = coordinateSpace.flippedWorkArea(containing: CGPoint(
            x: CGFloat(pose.x), y: CGFloat(pose.yFeet)))
        let bounds = LayoutRect(
            x: Double(work.minX), y: Double(work.minY),
            width: Double(work.width), height: Double(work.height))
        let safe = SpatialSafety.placeActor(
            id: actorID, anchorX: pose.x, feetY: pose.yFeet,
            width: width, height: height, baselineRatio: baselineRatio, in: bounds)
        if transition == nil, let castFrame {
            panel.alphaValue = 1
            show(frame: SpatialSafety.fit(castFrame, in: bounds))
            return
        }
        let groupID = "screen:\(Int(work.minX)):\(Int(work.minY)):\(Int(work.width))x\(Int(work.height))"
        let placed = layoutCoordinator?.update(safe, in: bounds, groupID: groupID) ?? safe
        var frame = placed.frame
        if let transition {
            let duration = max(0.025,
                Double(transition.plan.durationTicks) * Double(stepMilliseconds) / 1_000)
            let progress = (now - transition.startedAt) / duration
            if progress >= 1 {
                self.transition = nil
                panel.alphaValue = 1
            } else {
                let cue = transition.plan.presentation(
                    at: progress, leadingEdge: pose.x <= (bounds.minX + bounds.maxX) / 2)
                frame.x += frame.width * cue.offsetXRatio
                frame.y += frame.height * cue.offsetYRatio
                panel.alphaValue = CGFloat(cue.opacity)
            }
        } else {
            panel.alphaValue = 1
        }
        show(frame: frame)
    }

    private func show(frame: LayoutRect) {
        projectedFrame = frame
        panel.setFrame(coordinateSpace.appKitRect(
            flippedTop: CGFloat(frame.y), x: CGFloat(frame.x),
            width: CGFloat(frame.width), height: CGFloat(frame.height)), display: false)
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

    public func show() { panel.orderFrontRegardless() }
    public func hide() { stopVoice(); panel.orderOut(nil); bubble.dismiss() }
    public func speak(_ text: String, headX: CGFloat, headY: CGFloat) {
        bubble.show(text, headX: headX, headY: headY)
    }
}
