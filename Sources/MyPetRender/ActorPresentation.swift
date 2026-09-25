import AppKit
import AVFoundation
import MyPetContent
import MyPetCore
import MyPetEngine

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
    private let surface: any ActorRenderSurface
    private let renderBackend: any ActorRenderBackend
    private let worldPlanner: WorldRenderPlanner
    private let bubble: SpeechBubble
    private let appearance: ActorAppearance
    private let actorID: EntityID
    private let coordinateSpace: any RenderCoordinateSpace
    private let baselineRatio: Double
    private let stepMilliseconds: Int64
    private let visualSize: CGSize
    private var idleClip: String
    private var idleSwapAt = 0.0
    private var opacity: CGFloat = 1
    private var propImage: CGImage?
    private var propFrame = CGRect.zero
    private var lastRenderSnapshot: RenderSnapshot?
    private var castFrame: LayoutRect?
    private var detachedFromCastLayout = false
    private var transition: (plan: CastTransitionPlan, startedAt: Double)?
    private var delayedCombatHP: Int?
    private var combatOffscreenDirection: CombatHUDSnapshot.OffscreenDirection?
    private var lastCombatActionInstanceID: Int64?
    public private(set) var projectedFrame: LayoutRect?
    public var voicePlaybackEnabled = true {
        didSet { if !voicePlaybackEnabled { stopVoice() } }
    }

    public var onMouseDown: ((CGPoint) -> Void)? {
        get { surface.onMouseDown }
        set { surface.onMouseDown = newValue }
    }
    public var onMouseDragged: ((CGPoint) -> Void)? {
        get { surface.onMouseDragged }
        set { surface.onMouseDragged = newValue }
    }
    public var onMouseUp: ((CGPoint, Bool) -> Void)? {
        get { surface.onMouseUp }
        set { surface.onMouseUp = newValue }
    }
    public var onRightMouseDown: ((CGPoint) -> Void)? {
        get { surface.onRightMouseDown }
        set { surface.onRightMouseDown = newValue }
    }

    public init(
        source: any SpriteClipSource, initialFrame: CGRect,
        appearance: ActorAppearance, actorID: EntityID,
        baselineRatio: Double = 0.88,
        layoutCoordinator: SpatialLayoutCoordinator? = nil,
        stepMilliseconds: Int64 = 50,
        coordinateSpace: (any RenderCoordinateSpace)? = nil,
        renderBackend: (any ActorRenderBackend)? = nil
    ) {
        let space = coordinateSpace ?? AppKitRenderCoordinateSpace()
        animator = SpriteAnimator(source: source)
        voiceURL = (source as? ClipLibrary)?.voiceURL(for:) ?? { _ in nil }
        let backend = renderBackend ?? CoreAnimationRenderBackend()
        self.renderBackend = backend
        surface = backend.makeActorSurface(
            actorID: actorID, initialFrame: initialFrame, coordinateSpace: space)
        bubble = SpeechBubble()
        self.appearance = appearance
        self.actorID = actorID
        self.coordinateSpace = space
        self.worldPlanner = WorldRenderPlanner(layout: layoutCoordinator)
        self.baselineRatio = baselineRatio
        self.stepMilliseconds = max(1, stepMilliseconds)
        visualSize = initialFrame.size
        idleClip = appearance.idle
        animator.play(appearance.idle)
        if let image = animator.currentImage { surface.display(image: image, mirrored: false) }
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
        let combatInstanceChanged = pose?.actionInstanceID.map {
            $0 != lastCombatActionInstanceID
        } ?? false
        let restart = effects.contains { $0.actorID == actorID } || combatInstanceChanged
        animator.play(clip, restart: restart)
        lastCombatActionInstanceID = pose?.actionInstanceID
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
        let image: CGImage?
        if let pose,
           let actionFrame = pose.actionFrame,
           let totalFrames = pose.actionTotalFrames,
           pose.combatPhase != nil {
            image = animator.sample(
                frame: actionFrame,
                totalFrames: max(1, totalFrames)).image
        } else {
            image = animator.tick(dt: dt).image
        }
        if let frame = projectedFrame {
            let combatHUD = pose.flatMap { pose -> CombatHUDSnapshot? in
                guard pose.combatRole != nil else {
                    delayedCombatHP = nil
                    return nil
                }
                guard let hp = pose.hp, let maxHP = pose.maxHP,
                      let energy = pose.energy, let maxEnergy = pose.maxEnergy,
                      pose.combatRole != "bench"
                else { return nil }
                if let delayedCombatHP {
                    let decay = Int(ceil(Double(maxHP) / 6 * max(0, dt)))
                    self.delayedCombatHP = max(hp, delayedCombatHP - decay)
                } else {
                    delayedCombatHP = hp
                }
                let teammates = snapshot.entities.compactMap { entity -> CombatTeammateHUDSnapshot? in
                    guard let teammate = entity.pose,
                          entity.id != actorID,
                          teammate.combatTeamID == pose.combatTeamID,
                          teammate.combatRole == "bench",
                          let teammateHP = teammate.hp,
                          let teammateMaxHP = teammate.maxHP else { return nil }
                    return CombatTeammateHUDSnapshot(
                        identity: entity.id.raw, hp: teammateHP, maxHP: teammateMaxHP,
                        knockedOut: teammateHP == 0)
                }.sorted { $0.identity < $1.identity }
                return CombatHUDSnapshot(
                    identity: actorID.raw,
                    teamID: pose.combatTeamID,
                    hp: hp, delayedHP: delayedCombatHP, maxHP: maxHP,
                    energy: energy, maxEnergy: maxEnergy,
                    active: pose.combatRole == "active",
                    offscreenDirection: combatOffscreenDirection,
                    knockedOut: hp == 0, teammates: teammates)
            }
            let renderSnapshot = RenderSnapshot(
                actorID: actorID, frame: frame, image: image,
                mirrored: mirrored, opacity: opacity,
                propImage: propImage, propFrame: propFrame, visible: true,
                combatHUD: combatHUD)
            renderBackend.render(snapshot: renderSnapshot, interpolation: 0)
            lastRenderSnapshot = renderSnapshot
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
        opacity = 1
        if let snapshot = lastRenderSnapshot {
            let updated = RenderSnapshot(
                actorID: snapshot.actorID, frame: snapshot.frame,
                image: snapshot.image, mirrored: snapshot.mirrored,
                opacity: 1, propImage: snapshot.propImage,
                propFrame: snapshot.propFrame, visible: snapshot.visible,
                combatHUD: snapshot.combatHUD)
            renderBackend.render(snapshot: updated, interpolation: 0)
            lastRenderSnapshot = updated
        }
    }

    public func stop() {
        stopVoice()
        cancelTransition()
        worldPlanner.remove(actorID)
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
        let work = coordinateSpace.flippedWorkArea(containing: CGPoint(
            x: CGFloat(pose.x), y: CGFloat(pose.yFeet)))
        let bounds = LayoutRect(
            x: Double(work.minX), y: Double(work.minY),
            width: Double(work.width), height: Double(work.height))
        let groupID = "screen:\(Int(work.minX)):\(Int(work.minY)):\(Int(work.width))x\(Int(work.height))"
        if pose.x < bounds.minX {
            combatOffscreenDirection = .left
        } else if pose.x > bounds.maxX {
            combatOffscreenDirection = .right
        } else if pose.yFeet < bounds.minY {
            combatOffscreenDirection = .up
        } else if pose.yFeet > bounds.maxY {
            combatOffscreenDirection = .down
        } else {
            combatOffscreenDirection = nil
        }
        var frame = worldPlanner.frame(for: WorldRenderPlacementRequest(
            actorID: actorID,
            pose: pose,
            visualWidth: width,
            visualHeight: height,
            baselineRatio: baselineRatio,
            bounds: bounds,
            groupID: groupID,
            authoredFrame: transition == nil ? castFrame : nil,
            bypassSafety: pose.authoritativePlacement || pose.motion == "dragged" ||
                detachedFromCastLayout))
        if let transition {
            let duration = max(0.025,
                Double(transition.plan.durationTicks) * Double(stepMilliseconds) / 1_000)
            let progress = (now - transition.startedAt) / duration
            if progress >= 1 {
                self.transition = nil
                opacity = 1
            } else {
                let cue = transition.plan.presentation(
                    at: progress, leadingEdge: pose.x <= (bounds.minX + bounds.maxX) / 2)
                frame.x += frame.width * cue.offsetXRatio
                frame.y += frame.height * cue.offsetYRatio
                opacity = CGFloat(cue.opacity)
            }
        } else {
            opacity = 1
        }
        show(frame: frame)
    }

    private func show(frame: LayoutRect) {
        projectedFrame = frame
    }

    private func selectedClip(for pose: BodyPose?, now: Double) -> String {
        guard let pose else { return appearance.idle }
        switch pose.motion {
        case "dragged": return appearance.drag
        case "tossed": return appearance.airborne
        default: break
        }
        // Combat state owns presentation while the combat authority owns the
        // body. This keeps knockdown and airborne attacks from being replaced
        // by generic locomotion clips.
        if pose.combatPhase != nil || pose.healthState != nil,
           let action = pose.action {
            return action
        }
        switch pose.motion {
        case "asleep": return appearance.sleep
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
        propImage = image
        propFrame = rect
        if let snapshot = lastRenderSnapshot {
            let updated = RenderSnapshot(
                actorID: snapshot.actorID, frame: snapshot.frame,
                image: snapshot.image, mirrored: snapshot.mirrored,
                opacity: snapshot.opacity, propImage: image,
                propFrame: rect, visible: snapshot.visible,
                combatHUD: snapshot.combatHUD)
            renderBackend.render(snapshot: updated, interpolation: 0)
            lastRenderSnapshot = updated
        }
    }

    public func show() { surface.show() }
    public func hide() { stopVoice(); surface.hide(); bubble.dismiss() }
    public func speak(_ text: String, headX: CGFloat, headY: CGFloat) {
        bubble.show(text, headX: headX, headY: headY)
    }
}
