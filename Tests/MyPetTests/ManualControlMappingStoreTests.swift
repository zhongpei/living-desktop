import XCTest
import MyPetCombat
@testable import MyPetApp

final class ManualControlMappingStoreTests: XCTestCase {
    func testPerCharacterKeyboardMappingsPersistAcrossPanelLifetimes() throws {
        let suite = "ManualControlMappingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ManualControlMappingStore(defaults: defaults, key: "test")
        var catalog = store.load()
        catalog.set(ManualControlMapping(
            id: "lin-daiyu",
            bindings: [.keyA: .buttonX, .keyD: .buttonD]), for: "lin_daiyu")

        store.save(catalog)
        let restored = ManualControlMappingStore(
            defaults: defaults, key: "test").load()

        XCTAssertEqual(restored.mapping(for: "lin_daiyu").id, "lin-daiyu")
        XCTAssertEqual(restored.mapping(for: "lin_daiyu").bindings[.keyA], .buttonX)
        XCTAssertEqual(restored.mapping(for: "other"), .standard)
    }
}
