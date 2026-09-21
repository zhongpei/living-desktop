import AppKit
import XCTest

@testable import MyPet

/// 步态朝向修复的回归测试：rei_chibi 的步态像素实为朝左（H3 未按声明出图），
/// 运行时必须按 manifest.facing 镜像，否则倒着走。
final class AuthoredFacingTests: XCTestCase {

    // ---- 镜像判定四象限 ----

    func testMirrorMatrix() {
        typealias F = ClipLibrary.AuthoredFacing
        // 素材朝右：向右走不镜像，向左走镜像。
        XCTAssertFalse(ClipLibrary.mirrorNeeded(authored: .right, movingRight: true))
        XCTAssertTrue(ClipLibrary.mirrorNeeded(authored: .right, movingRight: false))
        // 素材朝左（rei_chibi 步态实况）：向右走镜像，向左走不镜像。
        XCTAssertTrue(ClipLibrary.mirrorNeeded(authored: .left, movingRight: true))
        XCTAssertFalse(ClipLibrary.mirrorNeeded(authored: .left, movingRight: false))
        // 正面素材按右向处理（正面镜像近似无损）。
        XCTAssertFalse(ClipLibrary.mirrorNeeded(authored: .down, movingRight: true))
    }

    // ---- manifest facing 解码 ----

    private func makePackDir(in root: URL, id: String, facing: String?) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let clips = dir.appendingPathComponent("base/walk", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("base/idle", isDirectory: true), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: clips.appendingPathComponent("frame_00.png"))
        try png.write(to: dir.appendingPathComponent("base/idle/frame_00.png"))
        var clip: [String: Any] = ["frames": 1, "fps": 5.0, "playback": "loop"]
        if let facing { clip["facing"] = facing }
        let manifest: [String: Any] = [
            "id": id, "format": "petpack-v2", "generator": "test",
            "sprite": ["cell_width": 192, "cell_height": 208],
            "clips": [
                "base/idle": ["frames": 1, "fps": 5.0, "playback": "loop"],
                "base/walk": clip,
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    func testManifestFacingDecoded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("facing-\(UUID().uuidString)", isDirectory: true)
        let left = try makePackDir(in: root, id: "a", facing: "left")
        let none = try makePackDir(in: root, id: "b", facing: nil)

        XCTAssertEqual(try ClipLibrary.load(from: left).facing(for: "base/walk"), .left)
        XCTAssertEqual(try ClipLibrary.load(from: none).facing(for: "base/walk"), .right) // 缺省 = 右
    }

}
