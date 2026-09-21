import XCTest
@testable import MyPet
import struct MyPetCore.DialogueProfile
import struct MyPetCore.LocalizedLabel

/// 本地大脑两段式 prompt：九段前缀 / 动态消息 / 决策解析 / 6 词表映射
///（brain-local.md §4；全部离线纯函数）。
final class BrainPrefixTests: XCTestCase {

    private func makeWorld() -> WorldState {
        WorldState(
            capturedAt: 1_860,   // 31 分钟
            activeApp: "Codex",
            windowTitle: "main.swift",
            appActivity: "coding",
            userActivity: "editing_text",
            focusRole: "textarea",
            visibleContext: ["let x = 1"],
            salientUI: ["button:发送"],
            nearbyWindows: [
                "window_12 (Codex, coding)",
                "window_34 (Chrome, browsing)",
            ],
            recentEvents: ["18s ago user switched to Codex"])
    }

    // MARK: 静态前缀（A 段）

    func testPrefixMessagesContainNineSegmentsInOrder() {
        let messages = BrainPrefixBuilder.prefixMessages(
            personality: .linDaiyu, profile: .fallback)
        // 1 system + 8 组 few-shot（user+assistant 各 8）+ 空 user 边界
        XCTAssertEqual(messages.count, 1 + 8 * 2 + 1)
        XCTAssertEqual(messages[0]["role"], "system")

        let system = messages[0]["content"] ?? ""
        let markers = [
            "high-level brain",                    // 1 SYSTEM
            "WORLD MODEL:",                        // 2
            "RESPONSIBILITY:",                     // 3
            "PERSONALITY:",                        // 4
            "NEEDS",                               // 5
            "AVAILABLE GOALS",                     // 6
            "RULES:",                              // 7
            "OUTPUT SCHEMA",                       // 9（FEW-SHOT 是轮次，非段文本）
        ]
        var searchRange = system.startIndex..<system.endIndex
        for marker in markers {
            guard let found = system.range(of: marker, range: searchRange) else {
                XCTFail("前缀缺段或段序错乱：\(marker)")
                return
            }
            searchRange = found.upperBound..<system.endIndex
        }
        // 段序：OUTPUT SCHEMA 必须在 AVAILABLE GOALS 之后（§4.1 布局）。
    }

    func testPrefixEmbedsPersonalityAndLockedGoalVocabulary() {
        let system = BrainPrefixBuilder.prefixMessages(
            personality: .linDaiyu, profile: .fallback)[0]["content"]!
        XCTAssertTrue(system.contains("social=35"), "人格数值必须进前缀")
        XCTAssertTrue(system.contains("curiosity=75"))
        for goal in BrainPrefixBuilder.goals {
            XCTAssertTrue(system.contains(goal), "固定词表缺 \(goal)")
        }
        XCTAssertEqual(BrainPrefixBuilder.goals, [
            "join_activity", "observe", "self_activity", "seek_attention", "tease_user", "rest",
        ])
    }

    func testChatPrefixAndMessageUseSeparateShortReplySchema() {
        let messages = BrainPrefixBuilder.chatPrefixMessages(
            personality: .linDaiyu, profile: .fallback,
            dialogue: nil, intent: .tease)
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"],
                       "没有角色同类示例时使用 0-shot 前缀")
        XCTAssertFalse(messages[0]["content"]?.contains("chat JSON") ?? false,
                       "前缀不依赖实现术语")
        XCTAssertTrue(messages[0]["content"]?.contains("OUTPUT SCHEMA") == true)
        XCTAssertTrue(messages[0]["content"]?.contains("emotion") == true)
        XCTAssertEqual(messages.last?["content"], "")

        let text = BrainPrefixBuilder.chatMessage(
            intent: .tease, world: makeWorld(), brain: BrainState(), personality: .linDaiyu)
        XCTAssertTrue(text.contains("INTENT tease"))
        XCTAssertTrue(text.contains("PET_STYLE"))
        XCTAssertTrue(text.contains("active_app=Codex"))

        let chat = BrainPrefixBuilder.chatMessage(
            intent: .chatter, world: makeWorld(), brain: BrainState(),
            personality: .linDaiyu, userText: "今天辛苦了")
        XCTAssertTrue(chat.contains("USER_MESSAGE_BEGIN"))
        XCTAssertTrue(chat.contains("今天辛苦了"))
    }

    func testChatPrefixUsesOnlyTheMatchingCharacterFewShot() {
        let label: (String) -> LocalizedLabel = { LocalizedLabel(zhHans: $0, en: $0) }
        let dialogue = DialogueProfile(
            dialogueStyle: label("傲气短句"), selfReference: label("俺老孙"),
            preferredPhrases: .init(zhHans: ["俺老孙"], en: ["I"]),
            forbiddenStyles: .init(zhHans: ["客服腔"], en: ["customer-service tone"]),
            fewShots: [
                .init(speechActID: "greet", knownFacts: label("刚被唤来"), assistant: label("俺老孙来也！")),
                .init(speechActID: "tease", knownFacts: label("用户没发现我"), assistant: label("这也瞒得过俺老孙？")),
            ], fallbackLines: [:])
        let messages = BrainPrefixBuilder.chatPrefixMessages(
            personality: .default, profile: .fallback,
            dialogue: dialogue, intent: .tease)
        let combined = messages.compactMap { $0["content"] }.joined(separator: "\n")
        XCTAssertTrue(combined.contains("傲气短句"))
        XCTAssertTrue(combined.contains("这也瞒得过俺老孙？"))
        XCTAssertFalse(combined.contains("俺老孙来也！"), "不得混入其他言语行为的示例")
        XCTAssertEqual(messages.filter { $0["role"] == "assistant" }.count, 1)
    }

    func testFewshotTurnsAreWellFormedAndDeterministic() {
        let messages = BrainPrefixBuilder.prefixMessages(
            personality: .default, profile: .fallback)
        for (index, message) in messages.enumerated() {
            let expectedRole = index == 0 ? "system"
                : (index % 2 == 1 ? "user" : "assistant")
            XCTAssertEqual(message["role"], expectedRole, "第 \(index) 条角色错")
        }
        // few-shot assistant 轮全部是纯 JSON，goal 都在词表里；
        // window target 的例句用本测试世界的窗口（与校验器保持一致契约）。
        var windowsWorld = makeWorld()
        windowsWorld.nearbyWindows = [
            "window_7 (WeChat, chatting)",
            "window_3 (Figma, designing)",
        ]
        for message in messages.dropFirst() where message["role"] == "assistant" {
            let decision = BrainPrefixBuilder.parseDecision(
                message["content"] ?? "", world: windowsWorld)
            XCTAssertNotNil(decision, "内置 few-shot 输出必须自洽：\(message["content"] ?? "")")
        }
        // 确定性：两次构建逐字相同（前缀缓存的前提）
        XCTAssertEqual(
            BrainPrefixBuilder.prefixMessages(personality: .default, profile: .fallback),
            messages)
    }

    func testProfileOverridesReachThePrefix() {
        var profile = BrainProfile.fallback
        profile.prompt.worldModel = "WORLD MODEL: tiny desk world."
        profile.prompt.rulesExtra = ["Never choose rest before noon."]
        profile.prompt.fewshotExtra = [
            BrainProfile.FewshotExample(
                input: "SELF energy=.5 | DECIDE",
                output: #"{"goal":"observe","style":"calm","speech_intent":null}"#),
        ]
        profile.personality.description = "A shy poet."

        let system = BrainPrefixBuilder.prefixMessages(
            personality: .default, profile: profile)[0]["content"]!
        XCTAssertTrue(system.contains("tiny desk world"))
        XCTAssertTrue(system.contains("Never choose rest before noon."))
        XCTAssertTrue(system.contains("A shy poet."))
        XCTAssertTrue(system.contains("If energy is below 0.2"), "内置规则不被替换")

        let messages = BrainPrefixBuilder.prefixMessages(
            personality: .default, profile: profile)
        XCTAssertEqual(messages.count, 1 + (8 + 1) * 2 + 1, "用户 few-shot 追加在内置之后")
        XCTAssertTrue(messages[messages.count - 3]["content"]!.hasPrefix("SELF energy=.5"),
                      "用户案例必须在最后（靠后示例权重更强，§7.2）")
        XCTAssertEqual(messages.last?["role"], "user")
        XCTAssertEqual(messages.last?["content"], "")
    }

    // MARK: 动态输入（B 段）

    func testDynamicMessageFieldsAndDeterminism() {
        var brain = BrainState(energy: 0.74, curiosity: 0.5, socialNeed: 0.16,
                               boredom: 0.21, affection: 0.3, stress: 0.05)
        brain.currentGoal = "join_activity"
        let text = BrainPrefixBuilder.dynamicMessage(
            world: makeWorld(), brain: brain, personality: .linDaiyu,
            memoryLines: ["[habit] user codes at night", "[event] joined coding 12m ago"])

        XCTAssertTrue(text.hasPrefix("TIME session=31m"))
        XCTAssertTrue(text.contains("SELF energy=0.74 boredom=0.21 social_need=0.16"))
        XCTAssertTrue(text.contains("current_goal=join_activity"))
        XCTAssertTrue(text.contains("WORLD active_app=Codex app_activity=coding user_activity=editing_text user_idle=false"))
        XCTAssertTrue(text.contains("WINDOWS window_12 (Codex, coding) | window_34 (Chrome, browsing)"))
        XCTAssertTrue(text.contains("MEMORY [habit] user codes at night"))
        XCTAssertTrue(text.contains("EVENT 18s ago user switched to Codex"))
        XCTAssertTrue(text.hasSuffix("DECIDE"))
        XCTAssertFalse(text.contains("let x = 1"), "可见文本不进本地 prompt（v1 边界）")

        let again = BrainPrefixBuilder.dynamicMessage(
            world: makeWorld(), brain: brain, personality: .linDaiyu,
            memoryLines: ["[habit] user codes at night", "[event] joined coding 12m ago"])
        XCTAssertEqual(text, again)
    }

    func testDynamicMessageRetryHintAppended() {
        let plain = BrainPrefixBuilder.dynamicMessage(
            world: makeWorld(), brain: BrainState(), personality: .default, memoryLines: [])
        let retry = BrainPrefixBuilder.dynamicMessage(
            world: makeWorld(), brain: BrainState(), personality: .default,
            memoryLines: [], retryHint: BrainPrefixBuilder.retryHint)
        XCTAssertFalse(plain.contains("previous reply"))
        XCTAssertTrue(retry.contains("ONLY the JSON object"))
    }

    // MARK: 输出解析（三关校验）

    func testParseDecisionAcceptsAllSixGoalsAndIntents() {
        let world = makeWorld()
        for (goal, expected) in [("join_activity", GoalKind.joinUserActivity),
                                 ("observe", GoalKind.watchWithUser),
                                 ("self_activity", GoalKind.explore),
                                 ("seek_attention", GoalKind.seekAttention),
                                 ("tease_user", GoalKind.teaseUser),
                                 ("rest", GoalKind.rest)] {
            let output = #"{"goal":"\#(goal)","target":"user","style":"quiet","speech_intent":null}"#
            let decision = BrainPrefixBuilder.parseDecision(output, world: world)
            XCTAssertNotNil(decision, goal)
            XCTAssertEqual(decision?.goal, goal)
            XCTAssertEqual(LocalBrainGoal.mapping(decision!.goal), expected, goal)
        }
        for intent in SpeechIntent.allCases {
            let output = #"{"goal":"rest","speech_intent":"\#(intent.rawValue)"}"#
            XCTAssertEqual(BrainPrefixBuilder.parseDecision(output, world: world)?.speechIntent, intent)
        }
    }

    func testParseDecisionRejectsInvalid() {
        let world = makeWorld()
        XCTAssertNil(BrainPrefixBuilder.parseDecision("not json at all", world: world))
        XCTAssertNil(BrainPrefixBuilder.parseDecision(#"{"goal":"dance"}"#, world: world),
                     "goal 不在固定词表")
        XCTAssertNil(BrainPrefixBuilder.parseDecision(
            #"{"goal":"rest","target":"window_99"}"#, world: world),
            "window target 不在场")
        XCTAssertNil(BrainPrefixBuilder.parseDecision(
            #"{"goal":"rest","target":"desk"}"#, world: world),
            "target 只允许 user / window_<id>")
        XCTAssertNil(BrainPrefixBuilder.parseDecision(
            #"{"goal":"rest","speech_intent":"sing"}"#, world: world),
            "speech_intent 越枚举")
        // 带前后噪声的输出能提取（小模型常见）
        let decision = BrainPrefixBuilder.parseDecision(
            "Sure! {\"goal\":\"rest\"} hope that helps", world: world)
        XCTAssertEqual(decision?.goal, "rest")
    }

    func testGoalMappingRejectsUnknown() {
        XCTAssertNil(LocalBrainGoal.mapping("dance"))
        XCTAssertNil(LocalBrainGoal.mapping(""))
    }
}
