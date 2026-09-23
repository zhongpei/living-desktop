import AppKit
import CoreGraphics
import MyPetContent
import MyPetCore
@testable import MyPetRender
import XCTest

@MainActor
final class RenderBackendInjectionTests: XCTestCase {
    func testNullRendererConsumesReadOnlySnapshotWithoutWorldMutation() {
        let renderer = NullRenderer()
        let snapshot = RenderSnapshot(
            actorID: EntityID("actor"),
            frame: LayoutRect(x: 10, y: 20, width: 40, height: 50),
            image: makeImage(), mirrored: true, opacity: 0.75,
            propImage: nil, propFrame: .zero, visible: true,
            combatHUD: CombatHUDSnapshot(
                hp: 700, maxHP: 1000, energy: 120, maxEnergy: 300, active: true))

        renderer.render(snapshot: snapshot, interpolation: 0.5)

        XCTAssertEqual(renderer.lastSnapshot?.actorID, EntityID("actor"))
        XCTAssertEqual(renderer.lastSnapshot?.frame,
                       LayoutRect(x: 10, y: 20, width: 40, height: 50))
        XCTAssertEqual(renderer.lastInterpolation, 0.5)
        XCTAssertEqual(renderer.renderCount, 1)
        XCTAssertEqual(renderer.lastSnapshot?.combatHUD?.energy, 120)
    }

    func testPresentationUsesInjectedBackendSurface() {
        let image = makeImage()
        let backend = FakeBackend()
        let source = OneClipSource(image: image)
        let actor = EntityID("actor")
        let presentation = ActorPresentation(
            source: source,
            initialFrame: CGRect(x: 0, y: 0, width: 40, height: 50),
            appearance: ActorAppearance(
                idle: "idle", walk: "idle", run: "idle", airborne: "idle",
                drag: "idle", sleep: "idle", idlePool: ["idle"]),
            actorID: actor,
            coordinateSpace: FakeCoordinateSpace(),
            renderBackend: backend)

        XCTAssertEqual(backend.makeCount, 1)
        presentation.show()
        XCTAssertTrue(backend.surface.shown)
        presentation.hide()
        XCTAssertFalse(backend.surface.shown)
    }

    private func makeImage() -> CGImage {
        CGImage(
            width: 1, height: 1,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data([0, 0, 0, 0]) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

private struct OneClipSource: SpriteClipSource {
    let image: CGImage
    func spriteClip(for name: String) -> SpriteClip? {
        name == "idle" ? SpriteClip(frames: [image], fps: 5, looping: true) : nil
    }
}

@MainActor
private final class FakeBackend: ActorRenderBackend {
    let surface = FakeSurface()
    var makeCount = 0
    func makeActorSurface(actorID: EntityID, initialFrame: CGRect,
                          coordinateSpace: any RenderCoordinateSpace) -> any ActorRenderSurface {
        makeCount += 1
        surface.frame = initialFrame
        return surface
    }
    func render(snapshot: RenderSnapshot, interpolation: Double) {
        surface.render(snapshot: snapshot, interpolation: interpolation)
    }
}

@MainActor
private final class FakeSurface: ActorRenderSurface {
    var alphaValue: CGFloat = 1
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint, Bool) -> Void)?
    var onRightMouseDown: ((CGPoint) -> Void)?
    var shown = false
    var frame = CGRect.zero
    var combatHUD: CombatHUDSnapshot?
    func display(image: CGImage, mirrored: Bool) {}
    func displayProp(image: CGImage?, rect: CGRect) {}
    func displayCombatHUD(_ snapshot: CombatHUDSnapshot?) { combatHUD = snapshot }
    func setFrame(_ frame: CGRect) { self.frame = frame }
    func show() { shown = true }
    func hide() { shown = false }
    func render(snapshot: RenderSnapshot, interpolation: Double) {
        frame = CGRect(
            x: snapshot.frame.x, y: snapshot.frame.y,
            width: snapshot.frame.width, height: snapshot.frame.height)
        alphaValue = snapshot.opacity
        shown = snapshot.visible
    }
}

@MainActor
private final class FakeCoordinateSpace: RenderCoordinateSpace {
    var primaryTopY: CGFloat { 900 }
    func appKitRect(flippedTop: CGFloat, x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: primaryTopY - flippedTop - height, width: width, height: height)
    }
    func flippedWorkArea(containing point: CGPoint) -> CGRect {
        CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
