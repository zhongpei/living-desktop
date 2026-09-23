import XCTest
@testable import MyPetCombat
import MyPet2D

final class CombatInputTests: XCTestCase {
    func testHoldReleaseChargeAndSimultaneousButtonsUseCommandMatcher() {
        var holdBuffer = CombatInputBuffer()
        holdBuffer.push(.neutral)
        for _ in 0..<3 { holdBuffer.push(FighterInputFrame(buttons: [.x])) }
        XCTAssertTrue(CommandMatcher.matches(
            CombatCommand([CombatCommandStep(
                button: .x, trigger: .hold, minimumHoldFrames: 3)]),
            buffer: holdBuffer,
            facing: .right))

        var releaseBuffer = holdBuffer
        releaseBuffer.push(.neutral)
        XCTAssertTrue(CommandMatcher.matches(
            CombatCommand([CombatCommandStep(
                button: .x, trigger: .release, minimumHoldFrames: 3)]),
            buffer: releaseBuffer,
            facing: .right))

        var comboBuffer = CombatInputBuffer()
        comboBuffer.push(.neutral)
        comboBuffer.push(FighterInputFrame(buttons: [.x, .y]))
        XCTAssertTrue(CommandMatcher.matches(
            CombatCommand([CombatCommandStep(buttons: [.x, .y])]),
            buffer: comboBuffer,
            facing: .right))

        let charge = CombatCommand([
            CombatCommandStep(direction: .back, minimumHoldFrames: 3),
            CombatCommandStep(button: .z, maxGapFrames: 2),
        ])
        var chargeBuffer = CombatInputBuffer()
        for input in CombatCommandSynthesizer.frames(for: charge, facing: .right) {
            chargeBuffer.push(input)
        }
        XCTAssertTrue(CommandMatcher.matches(charge, buffer: chargeBuffer, facing: .right))
    }

    func testLegacyCommandStepPayloadDefaultsToPressTrigger() throws {
        let step = try JSONDecoder().decode(
            CombatCommandStep.self,
            from: Data(#"{"button":"x","maxGapFrames":3}"#.utf8))

        XCTAssertEqual(step.trigger, .press)
        XCTAssertEqual(step.minimumHoldFrames, 0)
        XCTAssertTrue(step.simultaneousButtons.isEmpty)
    }
}
