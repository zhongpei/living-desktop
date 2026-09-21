import CoreGraphics
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

    func testPresentationRendererOnlyConsumesValues() {
        let renderer = RecordingRenderer()
        let snapshot = PresentationSnapshot(tick: 4, entities: [])

        renderer.apply(snapshot: snapshot)
        renderer.consume([])

        XCTAssertEqual(renderer.snapshots, [snapshot])
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
private final class RecordingRenderer: PresentationRenderer {
    var snapshots: [PresentationSnapshot] = []

    func apply(snapshot: PresentationSnapshot) { snapshots.append(snapshot) }
    func consume(_ effects: [PresentationEffect]) {}
    func close(entityID: String) {}
}
