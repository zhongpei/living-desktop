import XCTest
@testable import MyPetCore

final class WindowEffectsTests: XCTestCase {
    func testCatalogDecodesAllWindowEffectsAndResolvesEvents() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/effects/catalog.json"))
        let catalog = try JSONDecoder().decode(EffectCatalog.self, from: data)

        XCTAssertEqual(Set(catalog.effects.map(\.id)), Set(WindowDamageKind.allCases))
        XCTAssertEqual(catalog.configurationErrors, [])
        XCTAssertEqual(
            Set(catalog.effects.compactMap(\.asset)),
            Set(["window_crack.webp", "window_bullet_hole.webp"])
        )
        let event = WindowDamageEvent(
            kind: .crack,
            targetWindowID: "frontmost",
            normalizedX: 2,
            normalizedY: -1,
            tick: 42
        )
        XCTAssertEqual(event.normalizedX, 1)
        XCTAssertEqual(event.normalizedY, 0)
        XCTAssertEqual(catalog.definition(for: event)?.displayNames.en, "Window Crack")
    }

    func testSemanticDamageAssetsCannotSilentlyFallBackToParticles() throws {
        let labels = LocalizedLabel(zhHans: "裂痕", en: "Window Crack")
        let missing = EffectDefinition(
            id: .crack,
            displayNames: labels,
            descriptions: labels,
            anchor: .impactPoint,
            ttlSeconds: 1,
            maxStack: 1,
            clickThrough: true,
            asset: nil,
            fallback: .particles
        )
        XCTAssertEqual(
            EffectCatalog(effects: [missing]).configurationErrors,
            ["window_crack requires an independent asset"]
        )
    }
}
