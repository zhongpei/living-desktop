import XCTest
@testable import MyPetApp

/// 前缀缓存的纯数据边界：key、文件布局和聊天消息桥接均可离线验证。
final class BrainCacheTests: XCTestCase {

    func testCacheKeyCompositionAndSensitivity() {
        let dir = URL(fileURLWithPath: "/tmp/model-qwen")
        let key = BrainCacheManager.makeKey(
            petID: "lin_daiyu", personality: .linDaiyu,
            profile: .fallback, modelDir: dir)
        XCTAssertTrue(key.composite.contains("model-qwen"))
        XCTAssertTrue(key.composite.contains("brain-v\(BrainPrefixBuilder.brainPromptVersion)"))
        XCTAssertTrue(key.composite.contains("fewshot-v1"))
        XCTAssertTrue(key.composite.contains("lora-none"))
        XCTAssertTrue(key.composite.contains("profile-\(key.profileHash)"))
        XCTAssertTrue(key.composite.contains("prompt-goal"))
        XCTAssertTrue(key.composite.hasPrefix("model-qwen/"))
        XCTAssertEqual(key.hash8.count, 8)

        let chatKey = BrainCacheManager.makeKey(
            petID: "lin_daiyu", personality: .linDaiyu,
            profile: .fallback, modelDir: dir,
            promptKind: "chat", promptVersion: BrainPrefixBuilder.chatPromptVersion)
        XCTAssertNotEqual(key.hash8, chatKey.hash8, "聊天与目标前缀必须隔离")
        let changedDialogue = BrainCacheManager.makeKey(
            petID: "lin_daiyu", personality: .linDaiyu,
            profile: .fallback, modelDir: dir,
            promptKind: "chat", promptVersion: BrainPrefixBuilder.chatPromptVersion,
            contentHash: "dialogue-v2")
        XCTAssertNotEqual(chatKey.hash8, changedDialogue.hash8, "角色对话卡变化必须使缓存失效")

        var otherPersonality = Personality.linDaiyu
        otherPersonality.social = 0.9
        let changedPersonality = BrainCacheManager.makeKey(
            petID: "lin_daiyu", personality: otherPersonality,
            profile: .fallback, modelDir: dir)
        XCTAssertNotEqual(key.hash8, changedPersonality.hash8)

        let changedPet = BrainCacheManager.makeKey(
            petID: "mochi_cat", personality: .linDaiyu,
            profile: .fallback, modelDir: dir)
        XCTAssertNotEqual(key.hash8, changedPet.hash8)

        let url = BrainCacheManager.fileURL(petID: "lin_daiyu", key: key)
        XCTAssertEqual(url.lastPathComponent,
                       "lin_daiyu_v\(BrainPrefixBuilder.brainPromptVersion)_\(key.hash8).safetensors")
        XCTAssertEqual(url.deletingLastPathComponent(), BrainCacheManager.cacheDirectory)
    }

    func testSendableMessagesPreservesChatTemplateShape() {
        let messages = [
            ["role": "system", "content": "rules"],
            ["role": "user", "content": "hello"],
            ["role": "assistant", "content": "{}"],
        ]
        let bridged = BrainCacheManager.sendableMessages(messages)
        XCTAssertEqual(bridged.count, messages.count)
        XCTAssertEqual(bridged.map { $0["role"] as? String }, ["system", "user", "assistant"])
        XCTAssertEqual(bridged.last?["content"] as? String, "{}")
    }
}
