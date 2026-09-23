import XCTest
import MyPetCore
@testable import MyPetEngine
import MyPetSimulation
@testable import MyPetApp

final class PersonalityCatalogTests: XCTestCase {
    func testGeneratedCatalogKeepsHumanSemanticProfileBesideInternalNumbers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/characters/catalog.json"))
        let catalog = try JSONDecoder().decode(CharacterCatalog.self, from: data)
        let daiyu = try XCTUnwrap(catalog.characters.first { $0.id == "lin_daiyu" })
        let wukong = try XCTUnwrap(catalog.characters.first { $0.id == "sun_wukong" })
        let pan = try XCTUnwrap(catalog.characters.first { $0.id == "pan_jinlian" })

        XCTAssertTrue(try XCTUnwrap(daiyu.semanticProfile).personalityTypes.contains("敏感克制型"))
        XCTAssertEqual(try XCTUnwrap(wukong.semanticProfile).signatureBehaviors["destruction"]?.label, "破坏障碍")
        XCTAssertEqual(try XCTUnwrap(pan.semanticProfile).signatureBehaviors["charm"]?.label, "魅力试探")
        XCTAssertEqual(wukong.semanticProfile?.personality["risk_style"], "无畏型")
        XCTAssertEqual(daiyu.semanticProfile?.personality["sensitivity_style"], "易感型")
        XCTAssertTrue(daiyu.capabilities.contains("combat"))
        XCTAssertTrue(
            try XCTUnwrap(daiyu.semanticProfile).playCapabilities["combat"]?
                .contains("项目玩法改编") == true)
        let runtimeWukong = Personality.forDefinition(wukong)
        XCTAssertTrue(runtimeWukong.promptSection.contains("无畏探索型"))
        XCTAssertTrue(runtimeWukong.signatureActions.contains("prop_push"))
    }

    func testLogicalCharacterDefinitionOverridesReusedVisualPackPersonality() {
        let definition = CharacterDefinition(
            id: "jia_baoyu",
            displayNames: .init(zhHans: "贾宝玉", en: "Jia Baoyu"),
            background: .init(zhHans: "角色背景", en: "Background"),
            personality: CharacterPersonality(
                social: 88, curiosity: 74, playfulness: 72, diligence: 28,
                empathy: 86, independence: 34, teasing: 52),
            aptitudes: CharacterAptitudes(),
            performancePrompt: .init(zhHans: "表演", en: "Perform"))

        let personality = Personality.forDefinition(definition)

        XCTAssertEqual(personality.social, 0.88)
        XCTAssertEqual(personality.teasing, 0.52)
        XCTAssertNotEqual(personality, Personality.forCharacter("mochi_cat"))
    }
}
