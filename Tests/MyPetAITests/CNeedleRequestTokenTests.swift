import XCTest

@testable import MyPetAI

final class CNeedleRequestTokenTests: XCTestCase {
    func testTokenCanDiscardQueuedOrCompletedStaleInference() {
        let token = CNeedleRequestToken()
        XCTAssertFalse(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.isCancelled)

        var modelCalls = 0
        let output = CNeedleRuntime.runUnlessCancelled(token) {
            modelCalls += 1
            return "model answer"
        }
        XCTAssertNil(output)
        XCTAssertEqual(modelCalls, 0)
    }
}
