import XCTest
import MyPetCombat
@testable import MyPetApp

final class ManualControlMappingStoreTests: XCTestCase {
    func testLegacyKeyboardMappingsMigrateOnceWithoutOverwritingSettings() throws {
        let suite = "ManualControlMappingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ManualControlMappingStore(defaults: defaults, key: "test")
        var catalog = store.load()
        catalog.set(ManualControlMapping(
            id: "lin-daiyu",
            bindings: [.keyA: .buttonX, .keyD: .buttonD]), for: "lin_daiyu")

        store.save(catalog)
        var current = ManualControlMappingCatalog()
        current.set(ManualControlMapping(
            id: "explicit", bindings: [.keyA: .buttonD]), for: "explicit")
        let migrationStore = ManualControlMappingStore(defaults: defaults, key: "test")
        let restored = try XCTUnwrap(migrationStore.migrate(into: current))

        XCTAssertEqual(restored.mapping(for: "lin_daiyu").id, "lin-daiyu")
        XCTAssertEqual(restored.mapping(for: "lin_daiyu").bindings[.keyA], .buttonX)
        XCTAssertEqual(restored.mapping(for: "explicit").id, "explicit")
        XCTAssertNil(migrationStore.migrate(into: restored))
    }
}
