import CoreGraphics
import MyPetContent
import MyPetCore
@testable import MyPetRender
import XCTest

@MainActor
final class RenderBoundaryTests: XCTestCase {
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
                drag: "idle", sleep: "idle", idlePool: ["idle"]))
        let actor = EntityID("pet")
        let runtime = GameRuntime(bodyExecutionMode: .external)
        _ = runtime.step(events: [GameEvent(
            kind: .registerEntity, entity: EntityState(id: actor, kind: .actor))])
        runtime.updateBodyPose(BodyPose(
            actorID: actor, x: 10, yFeet: 20, facingRight: true,
            motion: "walking"))
        presentation.apply(snapshot: runtime.presentationSnapshot(), actorID: actor,
                           effects: [], dt: 0.11, now: 1)
        XCTAssertEqual(presentation.clipName, "walk")
        runtime.updateBodyPose(BodyPose(
            actorID: actor, x: 10, yFeet: 20, facingRight: true,
            motion: "grounded", action: "wave"))
        presentation.apply(snapshot: runtime.presentationSnapshot(), actorID: actor,
                           effects: [], dt: 0.11, now: 1.1)
        XCTAssertEqual(presentation.clipName, "wave")
        runtime.updateBodyPose(BodyPose(
            actorID: actor, x: 10, yFeet: 20, facingRight: true,
            motion: "grounded"))
        presentation.apply(snapshot: runtime.presentationSnapshot(), actorID: actor,
                           effects: [], dt: 0.11, now: 1.2)
        XCTAssertEqual(presentation.clipName, "idle")
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
