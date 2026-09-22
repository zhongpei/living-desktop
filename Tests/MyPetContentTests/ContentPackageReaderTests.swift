import CryptoKit
import Foundation
import MyPetContent
import MyPetCore
@testable import MyPetEngine
import XCTest
import ZIPFoundation

final class ContentPackageReaderTests: XCTestCase {
    private let validPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    private let validMP3 = Data(base64Encoded: "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYyLjEyLjEwMAAAAAAAAAAAAAAA/+MoxAAAAANIAAAAAExBTUVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MoxHwAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV")!
    func testPrivatePublishedPackagesRoundTripWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["MYPET_TEST_PACKAGE_ROOT"] else {
            throw XCTSkip("private published packages are not available in the public checkout")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let packages = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "mypetpack" }
        XCTAssertGreaterThanOrEqual(packages.count, 39)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var kinds = [ContentPackageKind: Int]()
        for package in packages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let candidate = try ContentPackageReader.inspect(at: package)
            kinds[candidate.kind, default: 0] += 1
            let destination = staging.appendingPathComponent(package.deletingPathExtension().lastPathComponent)
            XCTAssertEqual(try ContentPackageReader.extract(at: package, to: destination), candidate)
            if candidate.kind == .group {
                let data = try Data(contentsOf: destination.appendingPathComponent("content/group.json"))
                let payload = try JSONDecoder().decode(GroupPackagePayload.self, from: data)
                XCTAssertTrue(payload.cast.episodes.isEmpty)
                let runtime = CastRuntime(packs: [payload.cast], stories: [],
                    selection: CastSelection())
                XCTAssertFalse(runtime.start().isEmpty)
                for _ in 0..<10 { _ = runtime.tick() }
                XCTAssertTrue(runtime.consumeStoryActions().isEmpty)
            }
        }
        XCTAssertEqual(kinds[.role], 19)
        XCTAssertEqual(kinds[.group], 4)
        XCTAssertEqual(kinds[.story], 16)
    }

    private struct SampleEntry {
        let path: String
        let data: Data
        let type: Entry.EntryType

        init(_ path: String, _ data: Data, type: Entry.EntryType = .file) {
            self.path = path
            self.data = data
            self.type = type
        }
    }

    private func fixture(
        id: String = "story", payloadID: String = "story",
        digestOverride: String? = nil,
        extras: [SampleEntry] = []
    ) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-package-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let archiveURL = root.appendingPathComponent("test.mypetpack")
        let payload = Data(#"{"id":"\#(payloadID)","groupID":"group","episodes":[]}"#.utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = ContentPackageManifest(
            formatVersion: 1, kind: .story, id: id, revision: 1,
            name: "Story", content: "content/story.json", targetGroupID: "group",
            files: [.init(path: "content/story.json", sha256: digestOverride ?? digest)])
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try add([SampleEntry("package.json", try JSONEncoder().encode(manifest)),
                 SampleEntry("content/story.json", payload)] + extras, to: archive)
        return (root, archiveURL)
    }

    private func add(_ entries: [SampleEntry], to archive: Archive) throws {
        for entry in entries {
            try archive.addEntry(with: entry.path, type: entry.type,
                                 uncompressedSize: Int64(entry.data.count)) { position, size in
                let start = Int(position)
                return entry.data.subdata(in: start..<min(start + size, entry.data.count))
            }
        }
    }

    private func roleDefinition() -> CharacterDefinition {
        CharacterDefinition(
            id: "actor", displayNames: .init("Actor"), background: .init("Background"),
            personality: CharacterPersonality(), aptitudes: CharacterAptitudes(),
            performancePrompt: .init("Act"), capabilities: ["social"])
    }

    func testRoleRequiresRealIdleAndWalkFrameEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-role-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("role.mypetpack")
        let role = try JSONEncoder().encode(roleDefinition())
        let visual = Data(#"{"id":"actor","format":"petpack-v2","sprite":{"cell_width":192,"cell_height":208},"clips":{"base/idle":{"frames":1,"fps":8},"base/walk":{"frames":1,"fps":8}}}"#.utf8)
        let files = [SampleEntry("content/role.json", role),
                     SampleEntry("petpack/actor/manifest.json", visual)]
        let listed = files.map { entry in
            ContentPackageFile(path: entry.path,
                sha256: SHA256.hash(data: entry.data).map { String(format: "%02x", $0) }.joined())
        }
        let manifest = ContentPackageManifest(
            formatVersion: 1, kind: .role, id: "actor", revision: 1,
            name: "Actor", content: "content/role.json", files: listed)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try add([SampleEntry("package.json", try JSONEncoder().encode(manifest))] + files,
                to: archive)
        XCTAssertThrowsError(try ContentPackageReader.inspect(at: archiveURL))
    }

    func testRoleVoiceMustBeDeclaredByMatchingActionClip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-voice-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func makeArchive(_ name: String, voicePath: String,
                         voiceData: Data? = nil, frameData: Data? = nil) throws -> URL {
            let archiveURL = root.appendingPathComponent("\(name).mypetpack")
            let visual = Data("""
                {"id":"actor","format":"petpack-v2","sprite":{"cell_width":192,"cell_height":208},
                 "clips":{"base/idle":{"frames":1,"fps":8},"base/walk":{"frames":1,"fps":8},
                 "actions/taunt":{"frames":1,"fps":8,
                   "voice":{"path":"\(voicePath)","language":"zh-Hans","duration_seconds":1.5}}}}
                """.utf8)
            let files = [
                SampleEntry("content/role.json", try JSONEncoder().encode(roleDefinition())),
                SampleEntry("petpack/actor/manifest.json", visual),
                SampleEntry("petpack/actor/base/idle/frame_00.png", frameData ?? validPNG),
                SampleEntry("petpack/actor/base/walk/frame_00.png", validPNG),
                SampleEntry("petpack/actor/actions/taunt/frame_00.png", validPNG),
                SampleEntry("petpack/actor/actions/taunt/voice.mp3", voiceData ?? validMP3),
            ]
            let listed = files.map { file in ContentPackageFile(path: file.path,
                sha256: SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()) }
            let manifest = ContentPackageManifest(formatVersion: 1, kind: .role, id: "actor",
                revision: 1, name: "Actor", content: "content/role.json", files: listed)
            let archive = try Archive(url: archiveURL, accessMode: .create)
            try add([SampleEntry("package.json", try JSONEncoder().encode(manifest))] + files,
                    to: archive)
            return archiveURL
        }
        XCTAssertEqual(try ContentPackageReader.inspect(at:
            makeArchive("valid", voicePath: "actions/taunt/voice.mp3")).id, "actor")
        XCTAssertThrowsError(try ContentPackageReader.inspect(at:
            makeArchive("mismatch", voicePath: "actions/wave/voice.mp3")))
        XCTAssertThrowsError(try ContentPackageReader.inspect(at:
            makeArchive("bad-audio", voicePath: "actions/taunt/voice.mp3", voiceData: Data([1]))))
        XCTAssertThrowsError(try ContentPackageReader.inspect(at:
            makeArchive("bad-frame", voicePath: "actions/taunt/voice.mp3", frameData: Data([1]))))
    }

    func testGroupPayloadMustCarryAllMemberProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-group-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("group.mypetpack")
        let group = CharacterGroup(id: "group", categoryID: "sample",
                                   displayNames: .init("Group"), descriptions: .init("Group"),
                                   memberIDs: ["actor"])
        let cast = CastPack(id: "group", groupID: "group", displayName: "Group", summary: "",
                            members: [CastMember(id: "actor", kind: .character,
                                                 displayName: "Actor", role: "lead")])
        let payload = try JSONEncoder().encode(
            GroupPackagePayload(group: group, cast: cast, characters: []))
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = ContentPackageManifest(
            formatVersion: 1, kind: .group, id: "group", revision: 1,
            name: "Group", content: "content/group.json", files: [
                .init(path: "content/group.json", sha256: digest)])
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try add([SampleEntry("package.json", try JSONEncoder().encode(manifest)),
                 SampleEntry("content/group.json", payload)], to: archive)
        XCTAssertThrowsError(try ContentPackageReader.inspect(at: archiveURL))
    }

    func testValidStoryArchiveCanInspectThenExtract() throws {
        let (root, archive) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try ContentPackageReader.inspect(at: archive).id, "story")
        let destination = root.appendingPathComponent("unpacked")
        XCTAssertEqual(try ContentPackageReader.extract(at: archive, to: destination).kind, .story)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("content/story.json").path))
        XCTAssertThrowsError(try ContentPackageReader.extract(at: archive, to: destination))
    }

    func testUnsafeArchivesLeaveNoExtractedDirectory() throws {
        let cases: [(String, () throws -> (URL, URL))] = [
            ("traversal", { try self.fixture(extras: [.init("../escape", Data([1]))]) }),
            ("symlink", { try self.fixture(extras: [.init("link", Data("target".utf8), type: .symlink)]) }),
            ("case duplicate", { try self.fixture(extras: [.init("content/Story.json", Data([1]))]) }),
            ("undeclared", { try self.fixture(extras: [.init("extra.json", Data([1]))]) }),
            ("bad hash", { try self.fixture(digestOverride: String(repeating: "0", count: 64)) }),
            ("forged ID", { try self.fixture(id: "forged") }),
        ]
        for (name, make) in cases {
            let (root, archive) = try make()
            defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("unpacked")
            XCTAssertThrowsError(try ContentPackageReader.extract(at: archive, to: destination), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), name)
        }
    }

    func testCorruptZipAndOversizedJSONAreRejectedBeforeExtraction() throws {
        let corruptRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-corrupt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corrupt = corruptRoot.appendingPathComponent("corrupt.mypetpack")
        try Data([0, 1, 2]).write(to: corrupt)
        XCTAssertThrowsError(try ContentPackageReader.inspect(at: corrupt))

        let (root, archiveURL) = try fixture(extras: [
            .init("large.json", Data(repeating: 65, count: 16_777_217))])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ContentPackageReader.inspect(at: archiveURL))
    }

    func testUnknownUnixEntryTypeAndOversizedDeclaredArchiveAreRejected() throws {
        let (root, archiveURL) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: archiveURL)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let header = try XCTUnwrap(original.range(of: signature)?.lowerBound)

        var fifo = original
        // External attributes: Unix FIFO (0010000) rather than regular file.
        fifo[header + 38] = 0
        fifo[header + 39] = 0
        fifo[header + 40] = 0
        fifo[header + 41] = 0x10
        try fifo.write(to: archiveURL)
        XCTAssertThrowsError(try ContentPackageReader.inspect(at: archiveURL))

        var oversized = original
        // Central-directory uncompressed-size field: 1 GiB + 1 byte.
        oversized[header + 24] = 1
        oversized[header + 25] = 0
        oversized[header + 26] = 0
        oversized[header + 27] = 0x40
        try oversized.write(to: archiveURL)
        XCTAssertThrowsError(try ContentPackageReader.inspect(at: archiveURL))
    }
}
