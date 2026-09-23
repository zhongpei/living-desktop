import XCTest
import MyPet2D
import MyPetCombat
import MyPetCore
@testable import MyPetCombatCPU

final class ClassicGameplayCPUTests: XCTestCase {
    private let floor = BodyEnvironment(
        bounds: Rect2D(x: 0, y: 0, width: 1000, height: 800),
        surfaces: [Surface(id: "floor", kind: .floor, left: 0, right: 1000, y: 700)])

    func testFormalRoundAlwaysDelegatesToCombatCPU() {
        var cpu = ClassicGameplayCPU(actorID: EntityID("me"), seed: 9)
        let output = cpu.advance(observation(formalRound: true, withOpponent: true))
        XCTAssertEqual(output.activity, .fight)
        XCTAssertNotNil(output.combatOutput)
        XCTAssertNil(output.platformIntent)
    }

    func testFreePlayChoosesSemanticWindowIntentWithoutMutatingPlatform() {
        var cpu = ClassicGameplayCPU(actorID: EntityID("me"), seed: 9)
        var input = observation(formalRound: false, withOpponent: false)
        input.windowIDs = ["window-b", "window-a"]
        input.style = CharacterGameplayStyle(
            combat: 0, explore: 0, destruction: 1, risk: 0,
            energyReserve: 0, spectacle: 1)
        input.combat.selfBody.gameplayEnergy = GameplayEnergyState(current: 300)
        let output = cpu.advance(input)
        XCTAssertEqual(output.activity, .interactWindow)
        XCTAssertEqual(output.platformIntent, .damageWindowOverlay("window-a"))
        XCTAssertEqual(output.fighterInput, .neutral)
    }

    func testGameplayCPUCheckpointProducesIdenticalContinuation() {
        var original = ClassicGameplayCPU(actorID: EntityID("me"), seed: 17)
        _ = original.advance(observation(formalRound: true, withOpponent: true))
        var restored = ClassicGameplayCPU(checkpoint: original.checkpoint())
        var lhs: [GameplayCPUOutput] = []
        var rhs: [GameplayCPUOutput] = []
        for frame in 1...20 {
            var next = observation(formalRound: true, withOpponent: true)
            next.combat.frame = Int64(frame)
            lhs.append(original.advance(next))
            rhs.append(restored.advance(next))
        }
        XCTAssertEqual(lhs, rhs)
    }

    func testCommitmentIsNotCancelledMerelyBecauseAnOpponentExists() {
        var cpu = ClassicGameplayCPU(actorID: EntityID("me"), seed: 29)
        var initial = observation(formalRound: false, withOpponent: false)
        initial.windowIDs = ["window-a"]
        initial.style = CharacterGameplayStyle(
            combat: 0, explore: 0, destruction: 1, risk: 0,
            energyReserve: 0, spectacle: 1)
        initial.combat.selfBody.gameplayEnergy = GameplayEnergyState(current: 300)
        XCTAssertEqual(cpu.advance(initial).activity, .interactWindow)

        var opponentAppeared = observation(formalRound: false, withOpponent: true)
        opponentAppeared.combat.frame = 1
        opponentAppeared.windowIDs = ["window-a"]
        opponentAppeared.style = initial.style
        opponentAppeared.combat.selfBody.gameplayEnergy = GameplayEnergyState(current: 300)

        XCTAssertEqual(cpu.advance(opponentAppeared).activity, .interactWindow)
    }

    func testWindowMinimumViabilityProtectsForegroundAndEnergyReserve() {
        var cpu = ClassicGameplayCPU(actorID: EntityID("me"), seed: 31)
        var input = observation(formalRound: false, withOpponent: false)
        input.style = CharacterGameplayStyle(
            combat: 0, explore: 0, destruction: 1, risk: 0,
            energyReserve: 1, spectacle: 1)
        input.windows = [GameplayWindowState(
            id: "front", areaRatio: 0.8, isForeground: true,
            isMoving: false, isPullable: true, allowsDamageOverlay: true)]

        let output = cpu.advance(input)

        XCTAssertNotEqual(output.activity, .interactWindow)
        if case .some(.damageWindowOverlay) = output.platformIntent {
            XCTFail("foreground window must not reach a destructive platform intent")
        }
    }

    private func observation(
        formalRound: Bool, withOpponent: Bool
    ) -> GameplayCPUObservation {
        let profile = CombatProfile()
        let me = CombatBodyState(actorID: EntityID("me"), x: 300, yFeet: 700)
        let opponent = CombatBodyState(
            actorID: EntityID("enemy"), x: 360, yFeet: 700, facing: .left)
        return GameplayCPUObservation(
            combat: CPUCombatObservation(
                frame: 0, selfBody: me,
                opponents: withOpponent ? [opponent] : [],
                selfProfile: profile,
                opponentProfiles: withOpponent ? ["enemy": profile] : [:],
                environment: floor),
            formalRound: formalRound)
    }
}
