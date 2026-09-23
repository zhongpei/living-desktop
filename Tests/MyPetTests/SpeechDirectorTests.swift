import XCTest
@testable import MyPetApp

final class SpeechDirectorTests: XCTestCase {
    func testPersonalityDeterminesDefaultSpeakingChanceAndUserCanOverrideIt() {
        let outgoing = Personality(social: 0.95, curiosity: 0.8, playfulness: 0.8,
                                   independence: 0.2, chattiness: 0.7)
        let reserved = Personality(social: 0.2, curiosity: 0.3, playfulness: 0.2,
                                   independence: 0.9, chattiness: 1.8)

        let outgoingProfile = SpeechBehaviorProfile.resolve(personality: outgoing, override: nil)
        let reservedProfile = SpeechBehaviorProfile.resolve(personality: reserved, override: nil)
        XCTAssertGreaterThan(outgoingProfile.baseChance, reservedProfile.baseChance)

        let overridden = SpeechBehaviorProfile.resolve(
            personality: outgoing,
            override: CharacterSpeechSettings(chance: 0.23, minimumInterval: 17))
        XCTAssertEqual(overridden.baseChance, 0.23, accuracy: 0.0001)
        XCTAssertEqual(overridden.minimumInterval, 17, accuracy: 0.0001)
    }

    func testOpportunityUsesChannelProbabilityCooldownAndNovelty() {
        let director = SpeechDirector()
        let profile = SpeechBehaviorProfile(
            baseChance: 0.5, minimumInterval: 10,
            ambientEnabled: true, characterEnabled: true, windowEnabled: false,
            environmentEnabled: true, propEnabled: true)
        let window = SpeechOpportunity(
            kind: .window, actorID: "a", intent: .commentActivity,
            confirmedContext: "用户刚切换到浏览器。", noveltyKey: "window:browser", now: 10)
        XCTAssertNil(director.accept(window, profile: profile, roll: 0))

        let ambient = SpeechOpportunity(
            kind: .ambient, actorID: "a", intent: .chatter,
            confirmedContext: "桌面暂时很安静。", noveltyKey: "ambient", now: 10)
        XCTAssertNotNil(director.accept(ambient, profile: profile, roll: 0.1))
        XCTAssertNil(director.accept(
            SpeechOpportunity(kind: .prop, actorID: "b", intent: .commentActivity,
                              confirmedContext: "你正拿着一本书。", noveltyKey: "prop:book", now: 10.5),
            profile: profile, roll: 0.1), "共享调度器不应让多个角色同时播报环境")
        XCTAssertNil(director.accept(
            SpeechOpportunity(kind: .prop, actorID: "a", intent: .commentActivity,
                              confirmedContext: "你正拿着一本书。", noveltyKey: "prop:book", now: 15),
            profile: profile, roll: 0.1), "同一角色仍在冷却")
        XCTAssertNil(director.accept(
            SpeechOpportunity(kind: .ambient, actorID: "a", intent: .chatter,
                              confirmedContext: "桌面暂时很安静。", noveltyKey: "ambient", now: 50),
            profile: profile, roll: 0.1), "相同机会在较长去重窗口内不重复")
        XCTAssertNil(director.accept(
            SpeechOpportunity(kind: .prop, actorID: "b", intent: .commentActivity,
                              confirmedContext: "你正拿着一本书。", noveltyKey: "prop:book", now: 10),
            profile: profile, roll: 0.9), "随机数高于有效概率时不说")
    }

    func testCharacterSpeechSettingsDecodeMissingFieldsWithSafeDefaults() throws {
        let decoded = try JSONDecoder().decode(
            CharacterSpeechSettings.self,
            from: Data(#"{"chance":0.4}"#.utf8))
        XCTAssertEqual(decoded.chance, 0.4)
        XCTAssertTrue(decoded.ambientEnabled)
        XCTAssertTrue(decoded.characterEnabled)
        XCTAssertTrue(decoded.windowEnabled)
        XCTAssertTrue(decoded.environmentEnabled)
        XCTAssertTrue(decoded.propEnabled)
    }
}
