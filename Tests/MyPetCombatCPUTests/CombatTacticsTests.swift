import XCTest
import MyPet2D
import MyPetCombat
import MyPetCombatCPU
import MyPetCore

final class CombatTacticsTests: XCTestCase {
    func testProjectilePremiumRequiresExplicitZonerBias() {
        let melee = CombatMoveDefinition(
            id: "melee", command: .button(.x), startupFrames: 4,
            activeFrames: 2, recoveryFrames: 8,
            hit: CombatHitDefinition(damage: 80), visualAction: "normal_x")
        let projectile = CombatMoveDefinition(
            id: "shot", command: .button(.d), startupFrames: 7,
            activeFrames: 1, recoveryFrames: 10,
            hit: CombatHitDefinition(damage: 0, attackBoxes: []), visualAction: "normal_d",
            projectile: ProjectileDefinition(
                id: "shot", spawnFrame: 7, spawnOffset: Vec2(x: 20, y: -30),
                velocity: Vec2(x: 6, y: 0), lifetimeFrames: 60,
                collisionMask: [.hit, .hurt],
                hit: CombatHitDefinition(damage: 45), visualResourceID: "synthetic"),
            resourceRules: MoveResourceRules(family: .projectile))
        let profile = CombatProfile(moves: [melee, projectile])
        var selfBody = CombatBodyState(actorID: EntityID("a"), x: 100, yFeet: 200)
        selfBody.currentSurfaceID = "floor"
        selfBody.locomotion = .grounded
        var target = CombatBodyState(actorID: EntityID("b"), x: 180, yFeet: 200, facing: .left)
        target.currentSurfaceID = "floor"
        target.locomotion = .grounded
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 500, height: 200),
            surfaces: [Surface(id: "floor", kind: .floor, left: 0, right: 500, y: 200)])
        func decision(_ tactics: CombatTactics) -> String? {
            var cpu = ClassicCombatCPU(actorID: selfBody.actorID, seed: 4)
            return cpu.advance(CPUCombatObservation(
                frame: 0, selfBody: selfBody, opponents: [target],
                selfProfile: profile, opponentProfiles: [target.actorID.raw: profile],
                environment: environment, tactics: tactics)).moveID
        }
        XCTAssertEqual(decision(.balanced), "melee")
        XCTAssertEqual(decision(CombatTactics(projectile: 3)), "shot")

        selfBody.position.x = 20
        target.position.x = 240
        var balanced = ClassicCombatCPU(actorID: selfBody.actorID, seed: 4)
        func observation(frame: Int64) -> CPUCombatObservation {
            CPUCombatObservation(
                frame: frame, selfBody: selfBody, opponents: [target],
                selfProfile: profile, opponentProfiles: [target.actorID.raw: profile],
                environment: environment, tactics: .balanced)
        }
        XCTAssertEqual(balanced.advance(observation(frame: 0)).moveID, "shot")
        let rotation = (1...40).lazy.map { balanced.advance(observation(frame: Int64($0))) }
            .first { $0.intent == .approach }
        XCTAssertNotNil(rotation)
        XCTAssertNil(rotation?.moveID)
    }
}
