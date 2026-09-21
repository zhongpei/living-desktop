import AppKit
import XCTest

@testable import MyPet

final class ClipLibraryAndAnimatorTests: XCTestCase {

    // ---- 测试素材工厂 ----

    private func makeTinyPNG(_ url: URL) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: url)
    }

    /// v2 petpack：base/idle 3 帧 5fps、base/walk 2 帧 10fps、
    /// actions/wave 2 帧 once、actions/tail 2 帧 loop。
    /// withWalk = false 时去掉 base/walk（触发契约错误）；加 idle 变体测池子。
    private func makePack(withWalk: Bool = true, idleVariant: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("petpack-test-\(UUID().uuidString)", isDirectory: true)

        func writeFrames(_ rel: String, _ n: Int) throws {
            let d = dir.appendingPathComponent(rel, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for i in 0..<n {
                try makeTinyPNG(d.appendingPathComponent(String(format: "frame_%02d.png", i)))
            }
        }
        try writeFrames("base/idle", 3)
        if withWalk { try writeFrames("base/walk", 2) }
        if idleVariant { try writeFrames("base/idle_2", 2) }
        try writeFrames("actions/wave", 2)
        try writeFrames("actions/tail", 2)
        try writeFrames("actions/sleep_loop", 1)

        var clips: [String: Any] = [
            "base/idle": ["frames": 3, "fps": 5.0, "facing": "right", "playback": "loop"],
            "actions/wave": ["frames": 2, "fps": 2.0, "facing": "down", "playback": "once"],
            "actions/tail": ["frames": 2, "fps": 2.0, "facing": "down", "playback": "loop"],
            "actions/sleep_loop": ["frames": 1, "fps": 2.0, "facing": "down", "playback": "loop"],
        ]
        if withWalk {
            clips["base/walk"] = ["frames": 2, "fps": 10.0, "facing": "right", "playback": "loop"]
        }
        if idleVariant {
            clips["base/idle_2"] = ["frames": 2, "fps": 5.0, "facing": "right", "playback": "loop"]
        }
        let manifest: [String: Any] = [
            "id": "test_cat",
            "format": "petpack-v2",
            "generator": "unit-test",
            "sprite": ["cell_width": 192, "cell_height": 208],
            "clips": clips,
        ]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    // ---- ClipLibrary 加载 ----

    func testLoadDecodesManifest() throws {
        let library = try ClipLibrary.load(from: makePack())
        XCTAssertEqual(library.characterID, "test_cat")
        XCTAssertEqual(library.cellSize, CGSize(width: 192, height: 208))
        XCTAssertEqual(library.clipCount, 5)
        XCTAssertEqual(library.base(.walk), "base/walk")
        XCTAssertEqual(library.meta(for: "base/idle")?.fps ?? 0, 5.0, accuracy: 0.001)
        XCTAssertEqual(library.playback(for: "actions/wave"), .once)
        XCTAssertEqual(library.playback(for: "actions/tail"), .loop)
        XCTAssertEqual(library.facing(for: "actions/wave"), .down)
        XCTAssertEqual(library.actionNames, ["sleep_loop", "tail", "wave"])
        XCTAssertEqual(library.action(named: "wave"), "actions/wave")
        XCTAssertEqual(library.sleepActionKey(), "actions/sleep_loop")
    }

    func testMissingBaseWalkThrows() throws {
        // 身体线必需槽位缺失 → 契约错误，指名缺什么。
        XCTAssertThrowsError(try ClipLibrary.load(from: makePack(withWalk: false))) { error in
            guard case PetPackError.missingBase(_, let motion) = error else {
                return XCTFail("应为 missingBase，实际 \(error)")
            }
            XCTAssertEqual(motion, .walk)
        }
    }

    func testStaleFormatThrows() throws {
        let dir = try makePack()
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var stale = json
        stale["format"] = "petpack-v1"
        try JSONSerialization.data(withJSONObject: stale).write(to: manifestURL)
        XCTAssertThrowsError(try ClipLibrary.load(from: dir)) { error in
            guard case PetPackError.staleFormat = error else {
                return XCTFail("应为 staleFormat，实际 \(error)")
            }
        }
    }

    func testBaseOrFallbackChain() throws {
        let library = try ClipLibrary.load(from: makePack())
        // run 缺 → 回退 walk；airborne/drag 缺 → 回退 idle。
        XCTAssertEqual(library.baseOrFallback(.run), "base/walk")
        XCTAssertEqual(library.baseOrFallback(.airborne), "base/idle")
        XCTAssertEqual(library.baseOrFallback(.drag), "base/idle")
        XCTAssertEqual(library.baseOrFallback(.walk), "base/walk")
    }

    func testIdlePoolIncludesVariants() throws {
        let library = try ClipLibrary.load(from: makePack(idleVariant: true))
        XCTAssertEqual(library.idlePool, ["base/idle", "base/idle_2"])
    }

    func testLazyDecodeAndLRUEviction() throws {
        // 缓存上限 2：访问第 3 个 clip 时最旧的被淘汰；再访问重新解码。
        let library = try ClipLibrary.load(from: makePack(), cacheLimit: 2)
        XCTAssertEqual(library.frames(for: "base/idle")?.count, 3)
        XCTAssertEqual(library.frames(for: "base/walk")?.count, 2)
        XCTAssertEqual(library.debugCachedClipCount, 2)
        _ = library.frames(for: "actions/wave")          // 挤掉 base/idle
        XCTAssertEqual(library.debugCachedClipCount, 2)
        XCTAssertNil(library.frames(for: "actions/nope")) // 未知 clip 不入缓存
        XCTAssertEqual(library.frames(for: "base/idle")?.count, 3) // 重新解码照常工作
    }

    // ---- SpriteAnimator 时间线 ----

    func testFrameHoldsPerFps() throws {
        let library = try ClipLibrary.load(from: makePack())
        let animator = SpriteAnimator(library: library)
        animator.play("base/idle", restart: true) // 5fps = 200ms/帧

        _ = animator.tick(dt: 0.1)
        XCTAssertEqual(animator.frameIndex, 0)
        _ = animator.tick(dt: 0.11)
        XCTAssertEqual(animator.frameIndex, 1)
    }

    func testOnceClipFinishesAndHoldsLastFrame() throws {
        let library = try ClipLibrary.load(from: makePack())
        let animator = SpriteAnimator(library: library)
        animator.play("actions/wave", restart: true) // once，2 帧 @2fps

        var finishedClip = ""
        animator.onFinish = { finishedClip = $0 }

        var image = animator.currentImage
        for _ in 0..<40 {
            (image, _) = animator.tick(dt: 0.05) // 总计 2s，足够播完 2 帧 × 500ms
        }
        XCTAssertTrue(animator.isFinished)
        XCTAssertEqual(finishedClip, "actions/wave")
        XCTAssertEqual(animator.frameIndex, 1) // 停在末帧
        _ = image
    }

    func testLoopClipNeverFinishes() throws {
        let library = try ClipLibrary.load(from: makePack())
        let animator = SpriteAnimator(library: library)
        animator.play("actions/tail", restart: true)
        for _ in 0..<40 { _ = animator.tick(dt: 0.05) }
        XCTAssertFalse(animator.isFinished)
        XCTAssertEqual(library.playback(for: animator.clipName), .loop)
    }

    func testReplayingSameClipDoesNotReset() throws {
        let library = try ClipLibrary.load(from: makePack())
        let animator = SpriteAnimator(library: library)
        animator.play("base/walk", restart: true) // 10fps = 100ms/帧
        _ = animator.tick(dt: 0.15)
        XCTAssertEqual(animator.frameIndex, 1)
        animator.play("base/walk") // 同名：不重置
        XCTAssertEqual(animator.frameIndex, 1)
    }
}
