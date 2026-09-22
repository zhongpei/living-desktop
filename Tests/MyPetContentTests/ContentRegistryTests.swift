import CryptoKit
import Foundation
import MyPetContent
import XCTest
import ZIPFoundation

final class ContentRegistryTests: XCTestCase {
    private func package(at url: URL, id: String = "plot", revision: Int = 1,
                         groupID: String = "cast") throws {
        let payload = Data("{\"id\":\"\(id)\",\"groupID\":\"\(groupID)\",\"episodes\":[]}".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = ContentPackageManifest(formatVersion: 1, kind: .story, id: id,
            revision: revision, name: id, content: "content/story.json", targetGroupID: groupID,
            files: [.init(path: "content/story.json", sha256: hash)])
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in [("package.json", try JSONEncoder().encode(manifest)),
                             ("content/story.json", payload)] {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
                position, size in
                data.subdata(in: Int(position)..<min(Int(position) + size, data.count))
            }
        }
    }

    func testInstallEnableUpdateAndBuiltInFallbackSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-registry-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("builtin")
        let appSupport = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        try package(at: builtIn.appendingPathComponent("plot.mypetpack"))
        let registry = try ContentRegistry(builtInDirectory: builtIn, appSupportDirectory: appSupport)
        XCTAssertEqual(registry.list().first?.source, .builtIn)
        let imported = root.appendingPathComponent("new.mypetpack")
        try package(at: imported, revision: 2)
        XCTAssertThrowsError(try registry.importPackage(at: imported, confirmUpdate: false))
        XCTAssertEqual(try registry.importPackage(at: imported, confirmUpdate: true).revision, 2)
        XCTAssertEqual(registry.list().first?.source, .user)
        let unpacked = try registry.resolve(kind: .story, id: "plot")
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            unpacked.appendingPathComponent("content/story.json").path))
        try FileManager.default.removeItem(at: unpacked.appendingPathComponent("content/story.json"))
        let rebuilt = try registry.resolve(kind: .story, id: "plot")
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            rebuilt.appendingPathComponent("content/story.json").path))
        let broken = root.appendingPathComponent("broken.mypetpack")
        try Data([0, 1, 2]).write(to: broken)
        XCTAssertThrowsError(try registry.importPackage(at: broken, confirmUpdate: true))
        XCTAssertEqual(registry.list().first?.manifest?.revision, 2)
        try registry.setEnabled(false, kind: .story, id: "plot")
        let restarted = try ContentRegistry(builtInDirectory: builtIn, appSupportDirectory: appSupport)
        XCTAssertEqual(restarted.list().first?.status, .disabled)
        try restarted.setEnabled(true, kind: .story, id: "plot")
        let retired = try restarted.removeUserPackage(kind: .story, id: "plot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retired.path))
        XCTAssertEqual(restarted.list().first?.source, .builtIn)
        try restarted.purgeCache(kind: .story, id: "plot", source: .user)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.path))
        try restarted.finalizeRemoval(at: retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
    }

    func testTamperedCachedContentIsRebuiltFromThePackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-cache-integrity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        try package(at: builtIn.appendingPathComponent("plot.mypetpack"))
        let registry = try ContentRegistry(builtInDirectory: builtIn,
            appSupportDirectory: root.appendingPathComponent("support"))
        let cache = try registry.resolve(kind: .story, id: "plot")
        let story = cache.appendingPathComponent("content/story.json")
        let original = try Data(contentsOf: story)
        try Data("corrupt".utf8).write(to: story)
        XCTAssertEqual(try Data(contentsOf: registry.resolve(kind: .story, id: "plot")
            .appendingPathComponent("content/story.json")), original)

        try FileManager.default.removeItem(at: story)
        let outside = root.appendingPathComponent("outside.json")
        try Data("external".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: story, withDestinationURL: outside)
        XCTAssertEqual(try Data(contentsOf: registry.resolve(kind: .story, id: "plot")
            .appendingPathComponent("content/story.json")), original)
    }

    func testPackageChangedAfterRefreshCannotResolveAsStaleRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-stale-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        let source = builtIn.appendingPathComponent("plot.mypetpack")
        try package(at: source)
        let registry = try ContentRegistry(builtInDirectory: builtIn,
            appSupportDirectory: root.appendingPathComponent("support"))
        try FileManager.default.removeItem(at: source)
        try package(at: source, revision: 2)
        XCTAssertThrowsError(try registry.resolve(kind: .story, id: "plot"))
        registry.refresh()
        XCTAssertEqual(registry.list().first?.manifest?.revision, 2)
        XCTAssertNoThrow(try registry.resolve(kind: .story, id: "plot"))
    }

    func testCorruptUserPackageCanBeRetiredWithoutTouchingUnregisteredFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-corrupt-removal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = root.appendingPathComponent("builtin")
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        let registry = try ContentRegistry(builtInDirectory: builtIn,
            appSupportDirectory: root.appendingPathComponent("support"))
        let outside = root.appendingPathComponent("outside.mypetpack")
        try Data([0, 1, 2]).write(to: outside)
        XCTAssertThrowsError(try registry.removeCorruptUserPackage(at: outside))
        let corrupt = root.appendingPathComponent("support/packages/broken.mypetpack")
        try Data([0, 1, 2]).write(to: corrupt)
        registry.refresh()
        XCTAssertEqual(registry.list().first?.status, .corrupt)
        XCTAssertEqual(registry.list().first?.url.resolvingSymlinksInPath().path,
                       corrupt.resolvingSymlinksInPath().path)
        XCTAssertEqual(corrupt.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       root.appendingPathComponent("support/packages", isDirectory: true)
                           .resolvingSymlinksInPath().path)
        let retired = try registry.removeCorruptUserPackage(at: corrupt)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retired.appendingPathComponent("broken.mypetpack").path))
        XCTAssertTrue(registry.list().isEmpty)
        try registry.finalizeRemoval(at: retired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testPrivatePackagesResolveAsIndependentRolesGroupsAndStories() throws {
        guard let path = ProcessInfo.processInfo.environment["MYPET_TEST_PACKAGE_ROOT"] else {
            throw XCTSkip("private packages are unavailable")
        }
        let root = URL(fileURLWithPath: path)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("mypet-catalog-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let registry = try ContentRegistry(builtInDirectory: root, appSupportDirectory: support)
        let content = ContentCatalogLoader.load(registry: registry,
            relationshipCatalogURL: root.deletingLastPathComponent()
                .appendingPathComponent("relationships/catalog.json"))
        XCTAssertEqual(content.roles.count, 19)
        XCTAssertEqual(content.groups.count, 4)
        XCTAssertEqual(content.stories.count, 16)
        XCTAssertTrue(content.diagnostics.isEmpty, "\(content.diagnostics)")
        XCTAssertNotNil(content.visualsByActor["rei"])
        XCTAssertNotEqual(content.roles.first { $0.id == "rei" }?.visualURL,
                          content.visualsByActor["rei"])

        let extra = support.appendingPathComponent("extra.mypetpack")
        try package(at: extra, id: "extra", groupID: "journey_west")
        try registry.importPackage(at: extra)
        let withExtra = ContentCatalogLoader.load(registry: registry,
            relationshipCatalogURL: root.deletingLastPathComponent()
                .appendingPathComponent("relationships/catalog.json"))
        XCTAssertEqual(withExtra.stories.count, 17)
        try registry.setEnabled(false, kind: .story, id: "extra")
        let disabled = ContentCatalogLoader.load(registry: registry,
            relationshipCatalogURL: root.deletingLastPathComponent()
                .appendingPathComponent("relationships/catalog.json"))
        XCTAssertEqual(disabled.stories.count, 16)
    }
}
