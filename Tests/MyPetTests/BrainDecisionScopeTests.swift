import XCTest

@testable import MyPetApp

final class BrainDecisionScopeTests: XCTestCase {
    private func world(title: String = "Code", content: [String] = ["draft"]) -> BrainContextSnapshot {
        BrainContextSnapshot(
            capturedAt: 1, activeApp: "Editor", windowTitle: title,
            appActivity: "coding", userActivity: "editing_text", focusRole: "text_area",
            visibleContext: content, salientUI: ["button:Run"],
            nearbyWindows: ["window_1 (Editor, coding)"], recentEvents: ["old event"])
    }

    func testScopeIgnoresClockAndEventAgeButRejectsChangedInput() {
        let original = BrainDecisionScope(world: world(), planEpoch: 2,
                                          goalTraceID: "goal-1", sceneID: "scene-1")
        var same = world()
        same.capturedAt = 30
        same.recentEvents = ["new event"]
        XCTAssertTrue(original.matches(world: same, planEpoch: 2,
                                       goalTraceID: "goal-1", sceneID: "scene-1"))
        XCTAssertFalse(original.matches(world: world(content: ["different"]), planEpoch: 2,
                                        goalTraceID: "goal-1", sceneID: "scene-1"))
        XCTAssertFalse(original.matches(world: world(title: "Chat"), planEpoch: 2,
                                        goalTraceID: "goal-1", sceneID: "scene-1"))
    }

    func testScopeRejectsPreemptionGoalAndSceneChanges() {
        let original = BrainDecisionScope(world: world(), planEpoch: 2,
                                          goalTraceID: "goal-1", sceneID: "scene-1")
        XCTAssertFalse(original.matches(world: world(), planEpoch: 3,
                                        goalTraceID: "goal-1", sceneID: "scene-1"))
        XCTAssertFalse(original.matches(world: world(), planEpoch: 2,
                                        goalTraceID: "goal-2", sceneID: "scene-1"))
        XCTAssertFalse(original.matches(world: world(), planEpoch: 2,
                                        goalTraceID: "goal-1", sceneID: "scene-2"))
    }
}
