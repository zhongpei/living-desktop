import XCTest
@testable import MyPet2D

final class BodyFrameAccumulatorTests: XCTestCase {
    func testConsumeReturnsStableFrameIdentifiers() {
        var clock = BodyFrameAccumulator()

        XCTAssertEqual(Array(clock.consume(elapsedSeconds: 0.025)), [0])
        XCTAssertEqual(Array(clock.consume(elapsedSeconds: 0.025)), [1, 2])
        XCTAssertEqual(clock.frame, 3)
    }

    func testInvalidDeltasDoNotAdvanceAndLargeDeltaIsCapped() {
        var clock = BodyFrameAccumulator()

        XCTAssertTrue(clock.consume(elapsedSeconds: -.infinity).isEmpty)
        XCTAssertTrue(clock.consume(elapsedSeconds: .nan).isEmpty)
        XCTAssertTrue(clock.consume(elapsedSeconds: 0).isEmpty)
        XCTAssertEqual(clock.consume(elapsedSeconds: 2).count, 15)
        XCTAssertEqual(clock.frame, 15)
    }
}
