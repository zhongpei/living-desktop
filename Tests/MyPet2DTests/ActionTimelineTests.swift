import XCTest
@testable import MyPet2D

final class ActionTimelineTests: XCTestCase {
    func testTimelineOwnsStartupActiveRecoveryAndCompletion() {
        let definition = ActionDefinition(
            actionID: "petal_touch",
            durationFrames: 6,
            animationBinding: "actions/petal_touch",
            startupFrames: 2,
            activeFrames: 2,
            locomotionPolicy: .stationary)
        var timeline = ActionTimeline(instanceID: 7, definition: definition)

        XCTAssertEqual(timeline.phase, .startup)
        XCTAssertEqual(timeline.frame, 0)
        XCTAssertEqual(timeline.advance(), .advanced)
        XCTAssertEqual(timeline.phase, .startup)
        XCTAssertEqual(timeline.advance(), .advanced)
        XCTAssertEqual(timeline.phase, .active)
        XCTAssertEqual(timeline.advance(), .advanced)
        XCTAssertEqual(timeline.advance(), .advanced)
        XCTAssertEqual(timeline.phase, .recovery)
        XCTAssertEqual(timeline.advance(frames: 2), .finished)
        XCTAssertEqual(timeline.phase, .finished)
    }

    func testPauseAndCancelDoNotInventExtraFrames() {
        let definition = ActionDefinition(
            actionID: "wave", durationFrames: 20,
            animationBinding: "actions/wave",
            interruptWindows: [ActionFrameWindow(start: 5, end: 10)],
            cancelWindows: [ActionFrameWindow(start: 8, end: 12)])
        var timeline = ActionTimeline(instanceID: 2, definition: definition)

        XCTAssertEqual(timeline.advance(frames: 8), .advanced)
        XCTAssertTrue(timeline.canInterrupt)
        XCTAssertTrue(timeline.canCancel)
        XCTAssertEqual(timeline.advance(paused: true), .paused)
        XCTAssertEqual(timeline.frame, 8)
        XCTAssertEqual(timeline.cancel(), .cancelled)
        XCTAssertEqual(timeline.phase, .cancelled)
    }

    func testCollisionAndRootMotionUseTheSameFrameCursor() {
        let hit = ActionCollisionFrame(
            kind: .hit,
            rectLocal: Rect2D(x: 10, y: -20, width: 30, height: 20),
            active: ActionFrameWindow(start: 3, end: 4),
            hitGroup: "first")
        let definition = ActionDefinition(
            actionID: "strike", durationFrames: 8,
            animationBinding: "actions/strike",
            collisionFrames: [hit],
            rootMotion: [ActionRootMotion(
                active: ActionFrameWindow(start: 3, end: 4),
                deltaPerFrame: Vec2(x: 2, y: 0))])
        var timeline = ActionTimeline(instanceID: 3, definition: definition)

        _ = timeline.advance(frames: 3)
        XCTAssertEqual(timeline.activeCollisions.map(\.hitGroup), ["first"])
        XCTAssertEqual(timeline.rootMotionDelta, Vec2(x: 2, y: 0))
        _ = timeline.advance(frames: 2)
        XCTAssertTrue(timeline.activeCollisions.isEmpty)
        XCTAssertEqual(timeline.rootMotionDelta, Vec2())
    }
}
