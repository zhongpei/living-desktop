import CoreGraphics
import MyPetContent
import MyPetCore
@testable import MyPetRender
import XCTest

@MainActor
final class RenderBoundaryTests: XCTestCase {
    func testScreenSelectionUsesFullFrameOutsideVisibleWorkArea() {
        let screens = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 800, y: 0, width: 800, height: 600),
        ]
        let dockStripPoint = CGPoint(x: 900, y: 590)
        XCTAssertEqual(AppKitRenderCoordinateSpace.screenIndex(
            containing: dockStripPoint, frames: screens, primaryTopY: 600), 1)
    }

    func testCastOverlayPresentationOwnsProjectedOverlayLifecycle() {
        let presentation = CastOverlayPresentation(coordinateSpace: StubCoordinateSpace())
        let frame = LayoutRect(x: 100, y: 120, width: 64, height: 64)
        presentation.apply(
            props: [CastPropVisual(id: "tea", visualID: "tea", emoji: "🍵", frame: frame)],
            mechs: [CastMechVisual(id: "mech", title: "机甲", frame: frame, pilotName: "pilot")],
            now: 1)
        XCTAssertEqual(presentation.visiblePropIDs, ["tea"])
        XCTAssertEqual(presentation.visibleMechIDs, ["mech"])

        presentation.apply(props: [], mechs: [], now: 2)
        XCTAssertTrue(presentation.visiblePropIDs.isEmpty)
        XCTAssertTrue(presentation.visibleMechIDs.isEmpty)
        presentation.close()
    }

    func testAnimatorConsumesInjectedClipSource() {
        let image = makeImage()
        let source = StubClipSource(
            clips: ["idle": SpriteClip(frames: [image, image], fps: 10, looping: true)]
        )
        let animator = SpriteAnimator(source: source)

        animator.play("idle")
        _ = animator.tick(dt: 0.11)

        XCTAssertEqual(animator.frameIndex, 1)
    }

    func testActorPresentationUsesCoreSnapshotForClipChoice() {
        let image = makeImage()
        let source = StubClipSource(
            clips: [
                "idle": SpriteClip(frames: [image, image], fps: 10, looping: true),
                "walk": SpriteClip(frames: [image, image], fps: 10, looping: true),
                "wave": SpriteClip(frames: [image, image], fps: 10, looping: true),
            ])
        let presentation = ActorPresentation(
            source: source,
            initialFrame: CGRect(x: 0, y: 0, width: 32, height: 32),
            appearance: ActorAppearance(
                idle: "idle", walk: "walk", run: "walk", airborne: "idle",
                drag: "idle", sleep: "idle", idlePool: ["idle"]),
            actorID: EntityID("pet"))
        let actor = EntityID("pet")
        let runtime = GameRuntime(bodyExecutionMode: .external)
        _ = runtime.step(events: [GameEvent(
            kind: .registerEntity, entity: EntityState(id: actor, kind: .actor))])
        runtime.updateBodyPose(BodyPose(
            actorID: actor, x: 10, yFeet: 20, facingRight: true,
            motion: "walking"))
        presentation.apply(snapshot: runtime.presentationSnapshot(),
                           effects: [], dt: 0.11, now: 1)
        XCTAssertEqual(presentation.clipName, "walk")
        runtime.updateBodyPose(BodyPose(
            actorID: actor, x: 10, yFeet: 20, facingRight: true,
            motion: "grounded", action: "wave"))
        presentation.apply(snapshot: runtime.presentationSnapshot(),
                           effects: [], dt: 0.11, now: 1.1)
        XCTAssertEqual(presentation.clipName, "wave")
        runtime.updateBodyPose(BodyPose(
            actorID: actor, x: 10, yFeet: 20, facingRight: true,
            motion: "grounded"))
        presentation.apply(snapshot: runtime.presentationSnapshot(),
                           effects: [], dt: 0.11, now: 1.2)
        XCTAssertEqual(presentation.clipName, "idle")
    }

    func testActorPresentationOwnsSafeCastAndDirectDragPlacement() {
        let image = makeImage()
        let actor = EntityID("pet")
        let source = StubClipSource(clips: [
            "idle": SpriteClip(frames: [image], fps: 5, looping: true)
        ])
        let presentation = ActorPresentation(
            source: source,
            initialFrame: CGRect(x: 0, y: 0, width: 80, height: 100),
            appearance: ActorAppearance(
                idle: "idle", walk: "idle", run: "idle", airborne: "idle",
                drag: "idle", sleep: "idle", idlePool: ["idle"]),
            actorID: actor,
            coordinateSpace: StubCoordinateSpace())
        let runtime = GameRuntime(bodyExecutionMode: .external)
        _ = runtime.step(events: [GameEvent(
            kind: .registerEntity, entity: EntityState(id: actor, kind: .actor))])
        runtime.updateBodyPose(BodyPose(
            actorID: actor, x: 790, yFeet: 590, facingRight: true, motion: "grounded"))
        presentation.apply(snapshot: runtime.presentationSnapshot(),
                           effects: [], dt: 0, now: 1)
        XCTAssertLessThanOrEqual(presentation.projectedFrame!.maxX, 800)
        presentation.setCastFrame(LayoutRect(x: 100, y: 100, width: 80, height: 100))
        presentation.apply(snapshot: runtime.presentationSnapshot(),
                           effects: [], dt: 0, now: 2)
        XCTAssertEqual(presentation.projectedFrame!.x, 100)
        presentation.detachFromCastLayout()
        runtime.updateBodyPose(BodyPose(
            actorID: actor, x: 900, yFeet: 590, facingRight: true, motion: "dragged"))
        presentation.apply(snapshot: runtime.presentationSnapshot(),
                           effects: [], dt: 0, now: 3)
        XCTAssertEqual(presentation.projectedFrame!.x, 860)
    }

    private func makeImage() -> CGImage {
        CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data([0, 0, 0, 0]) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

private struct StubClipSource: SpriteClipSource {
    let clips: [String: SpriteClip]

    func spriteClip(for name: String) -> SpriteClip? { clips[name] }
}

@MainActor
private final class StubCoordinateSpace: RenderCoordinateSpace {
    let primaryTopY: CGFloat = 900
    func appKitRect(flippedTop: CGFloat, x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: primaryTopY - flippedTop - height, width: width, height: height)
    }
    func flippedWorkArea(containing point: CGPoint) -> CGRect {
        CGRect(x: 0, y: 0, width: 800, height: 600)
    }
}
