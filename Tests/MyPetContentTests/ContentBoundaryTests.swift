import MyPetContent
import XCTest

final class ContentBoundaryTests: XCTestCase {
    func testMissingPackReportsContractError() {
        XCTAssertThrowsError(try ClipLibrary.load(from: URL(fileURLWithPath: "/missing/petpack")))
    }

    func testPropFramesTakePrecedenceOverSingleImageInCharacterPack() throws {
        let pack = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pack) }
        let frames = pack.appendingPathComponent("props/tea", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let frame = frames.appendingPathComponent("frame_00.webp")
        try Data([1]).write(to: frame)
        try Data([2]).write(to: pack.appendingPathComponent("props/tea.webp"))

        XCTAssertEqual(PropSpriteLibrary.frameURLs(for: "tea", packURL: pack)
            .map { $0.resolvingSymlinksInPath() }, [frame.resolvingSymlinksInPath()])
    }
}
