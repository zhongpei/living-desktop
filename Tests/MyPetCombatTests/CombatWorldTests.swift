import XCTest
@testable import MyPetCombat
import MyPetCore

final class CombatWorldTests: XCTestCase {
    private let floor = CombatEnvironment(
        bounds: CombatRect(x: 0, y: 0, width: 1200, height: 800),
        surfaces: [CombatSurface(id: "floor:0", kind: .floor, left: 0, right: 1200, y: 700)])

    func testSixButtonContractUsesXYZASD() {
        XCTAssertEqual(Set(CombatButton.allCases.map(\.rawValue)), Set(["x", "y", "z", "a", "s", "d"]))
    }

    func testCommandSynthesizerRoundTripsThroughRecognizer() {
        let command = CombatCommand([
            CombatCommandStep(direction: .down),
            CombatCommandStep(direction: .downForward),
            CombatCommandStep(direction: .forward),
            CombatCommandStep(button: .z, maxGapFrames: 3)
        ])
        var buffer = CombatInputBuffer()
        for frame in CombatCommandSynthesizer.frames(for: command, facing: .right) {
            buffer.push(frame)
        }
        XCTAssertTrue(CombatCommandRecognizer.matches(command, buffer: buffer, facing: .right))
    }

    func testHitUsesActualBoxesAndAppliesHitstun() {
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 450, yFeet: 700, facing: .left)
        for _ in 0..<8 {
            world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"), authority: .manual)
            _ = world.step(environment: floor)
        }
        XCTAssertLessThan(world.body(for: EntityID("b"))!.hp, 1000)
        XCTAssertTrue([CombatPhase.hitStun, .neutral].contains(world.body(for: EntityID("b"))!.phase))
    }

    func testZeroHPLandsThenRecoversInsteadOfDeletingActor() {
        let finisher = CombatMoveDefinition(
            id: "ko", command: .button(.x), startupFrames: 0, activeFrames: 1, recoveryFrames: 1,
            hit: CombatHitDefinition(damage: 2000, hitStopFrames: 0, hitStunFrames: 2,
                                     knockbackX: 0, knockbackY: 0),
            visualAction: "attack")
        let profile = CombatProfile(
            moves: [finisher], downedRecoveryFrames: 3, getUpFrames: 2,
            revivedHPFraction: 0.30, reviveInvulnerabilityFrames: 2)
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: profile, x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), profile: profile, x: 450, yFeet: 700, facing: .left)
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        _ = world.step(environment: floor)
        for _ in 0..<10 {
            world.setInput(.neutral, for: EntityID("a"))
            _ = world.step(environment: floor)
            if world.body(for: EntityID("b"))?.healthState == .active { break }
        }
        let body = world.body(for: EntityID("b"))
        XCTAssertNotNil(body)
        XCTAssertEqual(body?.healthState, .active)
        XCTAssertEqual(body?.hp, 300)
        XCTAssertGreaterThan(body?.invulnerabilityFrames ?? 0, 0)
    }

    func testAttachedPlatformMovesBodyWithoutRenderSideEffects() {
        var environment = CombatEnvironment(
            bounds: CombatRect(x: 0, y: 0, width: 1200, height: 800),
            surfaces: [CombatSurface(id: "window:7:top", kind: .windowTop,
                                     left: 300, right: 700, y: 400, hostID: EntityID("window:7"))])
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 500, yFeet: 390)
        for _ in 0..<30 { _ = world.step(environment: environment) }
        guard let landed = world.body(for: EntityID("a")) else { return XCTFail() }
        XCTAssertEqual(landed.currentSurfaceID, "window:7:top")

        environment = CombatEnvironment(
            bounds: environment.bounds,
            surfaces: [CombatSurface(id: "window:7:top", kind: .windowTop,
                                     left: 500, right: 900, y: 520, hostID: EntityID("window:7"))])
        _ = world.step(environment: environment)
        XCTAssertEqual(world.body(for: EntityID("a"))?.position.y, 520)
    }

    func testHeldAttackButtonDoesNotAutoRepeatAfterRecovery() {
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 450, yFeet: 700, facing: .left)
        for _ in 0..<90 {
            world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
            _ = world.step(environment: floor)
        }
        XCTAssertEqual(world.body(for: EntityID("b"))?.hp, 965)
    }

    func testSameFrameTradeIsIndependentOfActorOrder() {
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 425, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 475, yFeet: 700, facing: .left)
        for _ in 0..<5 {
            world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
            world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("b"))
            _ = world.step(environment: floor)
        }
        XCTAssertLessThan(world.body(for: EntityID("a"))!.hp, 1000)
        XCTAssertLessThan(world.body(for: EntityID("b"))!.hp, 1000)
    }

    func testDownedRecoveryWaitsUntilDraggedActorReturnsToGround() {
        let finisher = CombatMoveDefinition(
            id: "ko", command: .button(.x), startupFrames: 0, activeFrames: 1, recoveryFrames: 1,
            hit: CombatHitDefinition(damage: 2000, hitStopFrames: 0, hitStunFrames: 1),
            visualAction: "attack")
        let profile = CombatProfile(
            moves: [finisher], downedRecoveryFrames: 1, getUpFrames: 1,
            revivedHPFraction: 0.30, reviveInvulnerabilityFrames: 2)
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: profile, x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), profile: profile, x: 450, yFeet: 700, facing: .left)
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        _ = world.step(environment: floor)
        XCTAssertEqual(world.body(for: EntityID("b"))?.healthState, .downed)

        world.beginDrag(actorID: EntityID("b"), x: 500, y: 300)
        for _ in 0..<20 { _ = world.step(environment: floor) }
        XCTAssertEqual(world.body(for: EntityID("b"))?.healthState, .downed)

        world.endDrag(actorID: EntityID("b"), wasClick: false)
        for _ in 0..<180 {
            _ = world.step(environment: floor)
            if world.body(for: EntityID("b"))?.healthState == .active { break }
        }
        XCTAssertEqual(world.body(for: EntityID("b"))?.healthState, .active)
    }

    func testSameInputsProduceSameSnapshot() {
        func run() -> CombatWorldSnapshot {
            let world = CombatWorld()
            world.register(actorID: EntityID("a"), x: 300, yFeet: 700)
            world.register(actorID: EntityID("b"), x: 500, yFeet: 700, facing: .left)
            for frame in 0..<120 {
                world.setInput(frame < 40 ? FighterInputFrame(right: true) :
                    FighterInputFrame(buttons: [.x]), for: EntityID("a"))
                world.setInput(frame < 40 ? FighterInputFrame(left: true) :
                    FighterInputFrame(buttons: [.x]), for: EntityID("b"))
                _ = world.step(environment: floor)
            }
            return world.snapshot()
        }
        XCTAssertEqual(run(), run())
    }
}
