import XCTest
@testable import MyPetApp

final class CombatPlatformEffectsTests: XCTestCase {
    @MainActor
    func testCombatSurfaceIDResolvesExactCGWindowID() {
        XCTAssertEqual(CombatPlatformEffects.windowID(from: "window:42:top"), 42)
        XCTAssertNil(CombatPlatformEffects.windowID(from: "floor:42"))
        XCTAssertNil(CombatPlatformEffects.windowID(from: "window:not-a-number:top"))
    }
}
