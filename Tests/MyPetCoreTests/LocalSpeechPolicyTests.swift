import XCTest
@testable import MyPetCore

final class LocalSpeechPolicyTests: XCTestCase {
    func testProductionPolicyCoversFiveScenesAndResolvesAcceptedTemperatures() throws {
        let data = Data(Self.policyJSON.utf8)
        let policy = try JSONDecoder().decode(LocalSpeechPolicy.self, from: data)
        XCTAssertTrue(policy.configurationErrors.isEmpty)
        XCTAssertEqual(Set(policy.scenes.map(\.id)), Set(LocalSpeechSceneID.allCases))
        XCTAssertEqual(policy.scene(.commentActivity)?.temperatureOffset, -0.1)
        XCTAssertEqual(policy.scene(.complain)?.temperatureOffset, 0)
        XCTAssertEqual(policy.scene(.greet)?.temperatureOffset, 0.05)
        XCTAssertEqual(policy.scene(.chatter)?.temperatureOffset, 0.05)
        XCTAssertEqual(policy.scene(.tease)?.temperatureOffset, 0.1)
    }

    func testOutputValidationRejectsUnsafeOrMalformedLines() throws {
        let policy = try JSONDecoder().decode(LocalSpeechPolicy.self, from: Data(Self.policyJSON.utf8))
        XCTAssertTrue(policy.accepts("哼，别老戳我。"))
        XCTAssertFalse(policy.accepts("第一行\n第二行"))
        XCTAssertFalse(policy.accepts("滚开！"))
        XCTAssertFalse(LocalSpeechPolicy.fallback.accepts("我替你把文件删掉。"))
        XCTAssertFalse(policy.accepts("系统示例：你好"))
        XCTAssertEqual(policy.rejectionReasons(""), ["empty"])
        XCTAssertEqual(policy.rejectionReasons("第一行\n第二行"), ["multiple_lines"])
        XCTAssertEqual(policy.rejectionReasons("滚开！"), ["blocked:滚开"])
        XCTAssertEqual(policy.rejectionReasons("系统示例：你好"), ["leaked:系统示例"])
    }

    func testCheckedInProductionPolicyIsValid() throws {
        let desktopRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: desktopRoot
            .appendingPathComponent("Resources/brain/local-speech.json"))
        let policy = try JSONDecoder().decode(LocalSpeechPolicy.self, from: data)
        XCTAssertTrue(policy.configurationErrors.isEmpty, policy.configurationErrors.joined(separator: ","))
        XCTAssertEqual(policy, .fallback)
    }

    func testPromptOverridesChangeOnlySelectedFieldsAndScenes() throws {
        let policy = try JSONDecoder().decode(LocalSpeechPolicy.self, from: Data(Self.policyJSON.utf8))
        let overrides = LocalSpeechPromptOverrides(
            role: "自定义角色任务",
            sceneDirections: [LocalSpeechSceneID.complain.rawValue: "直接但不恶毒地抗议。"])
        let resolved = overrides.applying(to: policy)

        XCTAssertEqual(resolved.prompt.role, "自定义角色任务")
        XCTAssertEqual(resolved.prompt.factRule, policy.prompt.factRule)
        XCTAssertEqual(resolved.scene(.complain)?.direction, "直接但不恶毒地抗议。")
        XCTAssertEqual(resolved.scene(.greet)?.direction, policy.scene(.greet)?.direction)
        XCTAssertTrue(resolved.configurationErrors.isEmpty)
    }

    func testPromptOverridesTrimValuesAndIgnoreBlankOverrides() throws {
        let policy = try JSONDecoder().decode(LocalSpeechPolicy.self, from: Data(Self.policyJSON.utf8))
        let overrides = LocalSpeechPromptOverrides(
            factRule: "  只使用已经确认的事实。  ",
            outputRule: "   ",
            sceneDirections: [
                LocalSpeechSceneID.greet.rawValue: "  自然回应召唤。  ",
                LocalSpeechSceneID.tease.rawValue: "   ",
                "unknown": "不会被采用",
            ])
        let resolved = overrides.applying(to: policy)

        XCTAssertEqual(resolved.prompt.factRule, "只使用已经确认的事实。")
        XCTAssertEqual(resolved.prompt.outputRule, policy.prompt.outputRule)
        XCTAssertEqual(resolved.scene(.greet)?.direction, "自然回应召唤。")
        XCTAssertEqual(resolved.scene(.tease)?.direction, policy.scene(.tease)?.direction)
    }

    private static let policyJSON = #"""
    {"schema":"mypet.local-speech.v1","max_characters":40,"retry_count":1,
     "blocked_phrases":["滚开"],"leak_markers":["系统示例"],
     "prompt":{"role":"角色","responsibility":"回应","fact_rule":"不虚构","output_rule":"只输出台词"},
     "scenes":[
       {"id":"greet","direction":"回应","temperature_offset":0.05},
       {"id":"comment_activity","direction":"评论","temperature_offset":-0.1},
       {"id":"tease","direction":"调侃","temperature_offset":0.1},
       {"id":"complain","direction":"抗议","temperature_offset":0},
       {"id":"chatter","direction":"闲聊","temperature_offset":0.05}]}
    """#
}
