import MyPetContent
import XCTest

final class PackageManifestTests: XCTestCase {
    func testStoryRequiresTargetGroupAndPrimaryContent() {
        let files = [ContentPackageFile(path: "content/story.json", sha256: String(repeating: "a", count: 64))]
        let valid = ContentPackageManifest(
            formatVersion: 1, kind: .story, id: "journey.main", revision: 1,
            name: "Journey", content: "content/story.json", targetGroupID: "journey_west",
            files: files)
        XCTAssertNoThrow(try valid.validate())
        var missingGroup = valid
        missingGroup.targetGroupID = nil
        XCTAssertThrowsError(try missingGroup.validate())
        var missingContent = valid
        missingContent.content = "content/other.json"
        XCTAssertThrowsError(try missingContent.validate())
    }

    func testManifestRejectsUnsafeOrDuplicateFilePaths() {
        let digest = String(repeating: "b", count: 64)
        for path in ["../escape", "/absolute", "a//b", "a/./b", "a/../b", "a\\b"] {
            let manifest = ContentPackageManifest(
                formatVersion: 1, kind: .role, id: "role", revision: 1,
                name: "Role", content: path, files: [.init(path: path, sha256: digest)])
            XCTAssertThrowsError(try manifest.validate(), path)
        }
        let duplicate = ContentPackageManifest(
            formatVersion: 1, kind: .role, id: "role", revision: 1,
            name: "Role", content: "content/role.json", files: [
                .init(path: "content/role.json", sha256: digest),
                .init(path: "content/role.json", sha256: digest)])
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testAudioIsOnlyAllowedBesideRoleOrGroupActionFrames() {
        let digest = String(repeating: "c", count: 64)
        let audio = ContentPackageFile(path: "petpack/actor/actions/heroic_wave/voice.mp3",
                                       sha256: digest)
        let role = ContentPackageManifest(
            formatVersion: 1, kind: .role, id: "actor", revision: 1,
            name: "Actor", content: "content/role.json", files: [
                .init(path: "content/role.json", sha256: digest), audio])
        XCTAssertNoThrow(try role.validate())
        var story = role
        story.kind = .story
        story.targetGroupID = "group"
        XCTAssertThrowsError(try story.validate())
        var script = role
        script.files.append(.init(path: "scripts/start.sh", sha256: digest))
        XCTAssertThrowsError(try script.validate())
    }
}
