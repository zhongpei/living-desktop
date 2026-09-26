import XCTest
@testable import MyPetEngine
import MyPetCombat
import MyPetCore

final class ControlRouterTests: XCTestCase {
    func testPointerManualAuthoredAndAutonomousPriorityResumesLowerSource() {
        let actor = EntityID("fighter")
        var router = ControlRouter()
        router.activate(.autonomous, for: actor, input: FighterInputFrame(buttons: [.x]))
        router.activate(.authored, for: actor, input: FighterInputFrame(buttons: [.y]))
        router.activate(.manual, for: actor, input: FighterInputFrame(buttons: [.z]))
        router.activate(.pointer, for: actor, input: .neutral)

        XCTAssertEqual(router.resolve(for: actor)?.authority, .pointer)
        XCTAssertEqual(router.resolve(for: actor)?.input, .neutral)

        router.deactivate(.pointer, for: actor)
        XCTAssertEqual(router.resolve(for: actor)?.authority, .manual)
        XCTAssertEqual(router.resolve(for: actor)?.input.buttons, [.z])

        router.releaseAllManualInput(for: actor)
        XCTAssertEqual(router.resolve(for: actor)?.authority, .manual)
        XCTAssertEqual(router.resolve(for: actor)?.input, .neutral)

        router.deactivate(.manual, for: actor)
        XCTAssertEqual(router.resolve(for: actor)?.authority, .authored)
        router.deactivate(.authored, for: actor)
        XCTAssertEqual(router.resolve(for: actor)?.authority, .autonomous)
    }

    func testResolvedSourceMatchesWinningAuthority() {
        let actor = EntityID("fighter")
        var router = ControlRouter()
        router.activate(.autonomous, for: actor, input: FighterInputFrame(right: true))
        XCTAssertEqual(router.resolvedSource(for: actor), .autonomous)
        router.activate(.pointer, for: actor, input: .neutral)
        XCTAssertEqual(router.resolvedSource(for: actor), .pointer)
        router.deactivate(.pointer, for: actor)
        XCTAssertEqual(router.resolvedSource(for: actor), .autonomous)
    }

    func testRouterCheckpointRoundTripsWithoutChangingResolution() throws {
        let actor = EntityID("fighter")
        var router = ControlRouter()
        router.activate(.manual, for: actor, input: FighterInputFrame(right: true))

        let restored = try JSONDecoder().decode(
            ControlRouter.self,
            from: JSONEncoder().encode(router))

        XCTAssertEqual(restored, router)
        XCTAssertEqual(restored.resolve(for: actor), router.resolve(for: actor))
    }

    func testInputUpdateCannotActivateAControlSource() {
        let actor = EntityID("fighter")
        var router = ControlRouter()

        router.setInput(FighterInputFrame(buttons: [.x]), source: .manual, for: actor)

        XCTAssertNil(router.resolve(for: actor))
        XCTAssertFalse(router.isActive(.manual, for: actor))
    }
}
