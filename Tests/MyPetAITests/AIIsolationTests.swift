import XCTest
@testable import MyPetAI

final class AIIsolationTests: XCTestCase {
    func testNeedleRuntimeIsProcessSingleton() {
        XCTAssertTrue(CNeedleRuntime.shared === CNeedleRuntime.shared)
    }

    func testPromptCacheIdentityIsStableAndOwnsItsFileLayout() {
        let key = "model/tokenizer/prompt-v1/personality-a"
        let hash = MLXPromptCacheIdentity.hash8(key)
        XCTAssertEqual(hash, MLXPromptCacheIdentity.hash8(key))
        XCTAssertEqual(hash.count, 8)
        XCTAssertEqual(
            MLXPromptCacheIdentity.fileURL(
                petID: "pet", cacheKey: key, promptVersion: 3).lastPathComponent,
            "pet_v3_\(hash).safetensors")
    }
}
