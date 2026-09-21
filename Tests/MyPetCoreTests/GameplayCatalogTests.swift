import XCTest
@testable import MyPetCore

final class GameplayCatalogTests: XCTestCase {
    func testBundledGameplayCatalogLoadsOnlyKnownBuiltInAdapters() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        let catalog = try GameplayCatalogLibrary.load(resourcesRoot: resources)

        XCTAssertEqual(catalog.groups.map(\.id), ["desktop", "interaction"])
        XCTAssertEqual(Set(catalog.plugins.map(\.id)), Set([
            "speech", "scenes", "props", "perching", "foreground-follow", "window-pull"
        ]))
        XCTAssertTrue(catalog.configurationErrors.isEmpty)
        XCTAssertTrue(catalog.plugins.allSatisfy {
            GameplayImplementationID(rawValue: $0.implementationID) != nil
        })
    }

    func testGameplayCatalogRejectsUnknownAdapterAndReference() {
        let catalog = GameplayCatalog(
            groups: [GameplayGroup(id: "desktop", displayNames: .init("Desktop"), order: 0)],
            plugins: [GameplayPlugin(
                id: "bad", groupID: "missing", displayNames: .init("Bad"), order: 0,
                implementationID: "arbitrary-code")])

        XCTAssertEqual(Set(catalog.configurationErrors), Set([
            "gameplay plugin bad references unknown group missing",
            "gameplay plugin bad uses unknown implementation arbitrary-code"
        ]))
    }
}
