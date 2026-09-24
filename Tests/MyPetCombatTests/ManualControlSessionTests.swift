import XCTest
@testable import MyPetCombat

final class ManualControlSessionTests: XCTestCase {
    func testSixButtonsAndDirectionsReleaseAtomicallyOnFocusLoss() {
        var session = ManualControlSession()
        XCTAssertEqual(session.begin(), .neutral)
        for key in KeyboardControlKey.allCases {
            _ = session.press(key)
        }

        XCTAssertEqual(
            session.input,
            FighterInputFrame(
                left: true, right: true, up: true, down: true,
                buttons: Set(CombatButton.allCases),
                systemControls: Set(CombatSystemControl.allCases)))

        XCTAssertEqual(session.focusLost(), .neutral)
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(session.pressedKeys.isEmpty)
        XCTAssertEqual(session.end(), .neutral)
        XCTAssertFalse(session.isActive)
    }

    func testInactiveSessionIgnoresLateKeyEvents() {
        var session = ManualControlSession()

        XCTAssertEqual(session.press(.keyZ), .neutral)
        XCTAssertEqual(session.release(.keyZ), .neutral)
        XCTAssertTrue(session.pressedKeys.isEmpty)
    }

    func testPerCharacterMappingChangesPhysicalKeysWithoutChangingLogicalCommands() throws {
        let alternate = ManualControlMapping(
            id: "alternate",
            bindings: [.keyD: .buttonX, .keyA: .buttonD])
        var catalog = ManualControlMappingCatalog()
        catalog.set(alternate, for: "lin-daiyu")
        var session = ManualControlSession()
        _ = session.begin(mapping: catalog.mapping(for: "lin-daiyu"))

        XCTAssertEqual(session.press(.keyD).buttons, [.x])
        _ = session.focusLost()
        XCTAssertEqual(session.press(.keyA).buttons, [.d])
        XCTAssertEqual(catalog.mapping(for: "other"), .standard)

        let restored = try JSONDecoder().decode(
            ManualControlMappingCatalog.self,
            from: JSONEncoder().encode(catalog))
        XCTAssertEqual(restored, catalog)
    }

    func testRebindingSwapsConflictingLogicalControls() {
        var mapping = ManualControlMapping.standard

        mapping.rebind(.keyZ, to: .buttonY)

        XCTAssertEqual(mapping.bindings[.keyZ], .buttonY)
        XCTAssertEqual(mapping.bindings[.keyX], .buttonX)
        XCTAssertEqual(Set(mapping.bindings.values).count, mapping.bindings.count)
    }

    func testHotMappingWaitsUntilAllPhysicalKeysAreReleased() {
        var session = ManualControlSession()
        _ = session.begin()
        _ = session.press(.keyZ)
        let alternate = ManualControlMapping(
            id: "alternate", bindings: [.keyZ: .buttonD])

        XCTAssertFalse(session.applyMappingIfIdle(alternate))
        XCTAssertEqual(session.input.buttons, [.x])
        _ = session.release(.keyZ)
        XCTAssertTrue(session.applyMappingIfIdle(alternate))
        XCTAssertEqual(session.press(.keyZ).buttons, [.d])
    }
}
