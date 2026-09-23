import XCTest
import MyPetCore
@testable import MyPetCombat

final class AdvancedCombatSystemsTests: XCTestCase {
    private let floor = CombatEnvironment(
        bounds: CombatRect(x: 0, y: 0, width: 1200, height: 800),
        surfaces: [CombatSurface(
            id: "floor", kind: .floor, left: 0, right: 1200, y: 700)])
    func testEnergySpendIsAtomicAndClamped() {
        var energy = GameplayEnergyState(current: 90, maximum: 300)
        XCTAssertFalse(energy.spend(100, frame: 4))
        XCTAssertEqual(energy.current, 90)
        XCTAssertTrue(energy.spend(45, frame: 5))
        XCTAssertEqual(energy.current, 45)
        energy.gain(400)
        XCTAssertEqual(energy.current, 300)
    }

    func testScenarioEnergySetupClampsThroughWorldAuthority() {
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 100, yFeet: 700)
        world.setGameplayEnergy(999, for: EntityID("a"))
        XCTAssertEqual(world.body(for: EntityID("a"))?.gameplayEnergy.current, 300)
    }

    func testComboScalingJuggleAndRecoveryAreDeterministic() {
        var combo = ComboState()
        let first = combo.recordHit(
            attackerID: EntityID("a"), defenderID: EntityID("b"),
            moveID: "light", baseDamage: 100, baseHitStun: 20,
            juggleCost: 2, frame: 10)
        let second = combo.recordHit(
            attackerID: EntityID("a"), defenderID: EntityID("b"),
            moveID: "light", baseDamage: 100, baseHitStun: 20,
            juggleCost: 2, frame: 15)
        XCTAssertEqual(first.damage, 100)
        XCTAssertLessThan(second.damage, first.damage)
        XCTAssertLessThan(second.hitStunFrames, first.hitStunFrames)
        XCTAssertEqual(combo.hitCount, 2)
        XCTAssertEqual(combo.juggleRemaining, ComboRules.standard.juggleBudget - 4)
        combo.end(reason: .recovered)
        XCTAssertEqual(combo.hitCount, 0)
    }

    func testComboExpiresAfterGap() {
        var combo = ComboState()
        _ = combo.recordHit(
            attackerID: EntityID("a"), defenderID: EntityID("b"),
            moveID: "light", baseDamage: 20, baseHitStun: 10,
            juggleCost: 0, frame: 5)
        XCTAssertFalse(combo.expireIfNeeded(frame: 50))
        XCTAssertTrue(combo.expireIfNeeded(frame: 51))
        XCTAssertEqual(combo.hitCount, 0)
    }

    func testTagAndAssistShareBenchOccupancyAndCooldown() {
        var team = TeamCombatState(
            teamID: "red", activeID: EntityID("a"), benchID: EntityID("b"))
        XCTAssertTrue(team.requestAssist(frame: 0))
        XCTAssertFalse(team.requestTag(frame: 1))
        for frame in 1...TeamCombatRules.standard.assistTotalFrames {
            _ = team.advance(frame: Int64(frame))
        }
        XCTAssertEqual(team.benchPhase, .standby)
        XCTAssertGreaterThan(team.cooldownFrames, 0)
        while team.cooldownFrames > 0 { _ = team.advance(frame: 100) }
        XCTAssertTrue(team.requestTag(frame: 200))
        var handoff: TeamCombatEvent?
        for frame in 201...240 {
            let events = team.advance(frame: Int64(frame))
            handoff = handoff ?? events.first { $0.kind == .tagHandoff }
        }
        XCTAssertNotNil(handoff)
        XCTAssertEqual(team.activeID, EntityID("b"))
        XCTAssertEqual(team.benchID, EntityID("a"))
    }

    func testCollateralHitEscalatesOnNextFrameAndRetainsOffender() {
        var escalation = CombatEscalationState(policy: .desktopBrawl)
        let victim = EntityID("npc")
        let offender = EntityID("fighter")
        escalation.recordCollateralHit(
            victimID: victim, offenderID: offender, offenderTeamID: "red",
            damage: 12, frame: 30, cascadeDepth: 0)
        XCTAssertEqual(escalation.participation[victim], .alerted(offenderID: offender))
        XCTAssertTrue(escalation.advance(frame: 30, combatReady: [victim]).isEmpty)
        let events = escalation.advance(frame: 31, combatReady: [victim])
        XCTAssertEqual(events.first?.kind, .joined)
        XCTAssertEqual(escalation.participation[victim],
                       .incidentalCombatant(primaryOffenderID: offender))
    }

    func testIncidentalCombatantWithdrawsAfterHostilityDecay() {
        var policy = NeutralEscalationPolicy.desktopBrawl
        policy.hostilityDecayFrames = 3
        var escalation = CombatEscalationState(policy: policy)
        let victim = EntityID("npc")
        let offender = EntityID("fighter")
        escalation.recordCollateralHit(
            victimID: victim, offenderID: offender, offenderTeamID: nil,
            damage: 10, frame: 1, cascadeDepth: 0)
        _ = escalation.advance(frame: 2, combatReady: [victim])
        let events = escalation.advance(frame: 4, combatReady: [victim])
        XCTAssertEqual(events.first?.kind, .withdrew)
        XCTAssertEqual(escalation.participation[victim], .withdrawing)
    }

    func testWindowPolicyRequiresSafetyEnergyAndGlobalPermission() {
        var policy = WindowInteractionPolicy()
        var energy = GameplayEnergyState(current: 300, maximum: 300)
        XCTAssertEqual(policy.authorize(
            .pull, energy: &energy, frame: 10, userActive: false,
            targetIsForeground: false), .disabled)
        policy.pullEnabled = true
        XCTAssertEqual(policy.authorize(
            .pull, energy: &energy, frame: 10, userActive: true,
            targetIsForeground: false), .userActive)
        XCTAssertEqual(energy.current, 300)
        XCTAssertEqual(policy.authorize(
            .pull, energy: &energy, frame: 10, userActive: false,
            targetIsForeground: false), .allowed)
        XCTAssertEqual(energy.current, 120)
    }

    func testActionHistoryPenalizesFamiliesAndRepeatedSequences() {
        var history = ActionHistory(capacity: 12)
        history.record(id: "jab-a", family: .fastMelee)
        history.record(id: "jab-b", family: .fastMelee)
        let familyPenalty = history.repetitionPenalty(id: "jab-c", family: .fastMelee)
        history.record(id: "jab-c", family: .fastMelee)
        let directPenalty = history.repetitionPenalty(id: "jab-c", family: .fastMelee)
        XCTAssertGreaterThan(familyPenalty, 0)
        XCTAssertGreaterThan(directPenalty, familyPenalty)
    }

    func testMappedAssistControlEntersBenchAndStartsProfileMoveThroughMatcher() {
        let assist = CombatMoveDefinition(
            id: "assist-strike", command: .button(.x),
            startupFrames: 0, activeFrames: 1, recoveryFrames: 3,
            hit: CombatHitDefinition(damage: 20, hitStopFrames: 0),
            visualAction: "assist", resourceRules: MoveResourceRules(family: .assist),
            systemControl: .assist)
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), profile: CombatProfile(moves: [assist]),
                       x: 300, yFeet: 700)
        world.register(actorID: EntityID("c"), x: 470, yFeet: 700, facing: .left)
        world.register(actorID: EntityID("d"), x: 560, yFeet: 700, facing: .left)
        world.configureTeam(teamID: "red", activeID: EntityID("a"), benchID: EntityID("b"))
        world.configureTeam(teamID: "blue", activeID: EntityID("c"), benchID: EntityID("d"))
        XCTAssertTrue(world.beginSession(
            id: "team", participants: ["a", "b", "c", "d"].map(EntityID.init)))
        world.setInput(FighterInputFrame(systemControls: [.assist]), for: EntityID("a"))

        let events = world.step(environment: floor)

        XCTAssertTrue(events.contains { $0.kind == .assistEntered && $0.actorID == EntityID("b") })
        XCTAssertTrue(events.contains { $0.kind == .moveStarted && $0.moveID == "assist-strike" })
        XCTAssertEqual(world.body(for: EntityID("b"))?.rosterRole, .assist)
    }

    func testHeldSystemControlDoesNotRepeatWithoutReleaseEdge() {
        var buffer = CombatInputBuffer()
        buffer.push(FighterInputFrame(systemControls: [.powerUp]))
        XCTAssertTrue(buffer.isSystemControlPress(.powerUp))
        buffer.push(FighterInputFrame(systemControls: [.powerUp]))
        XCTAssertFalse(buffer.isSystemControlPress(.powerUp))
        buffer.push(.neutral)
        buffer.push(FighterInputFrame(systemControls: [.powerUp]))
        XCTAssertTrue(buffer.isSystemControlPress(.powerUp))
    }

    func testDefensiveBurstRequiresEnergyAndCancelsHitStunViaMappedControl() {
        let hit = CombatMoveDefinition(
            id: "hit", command: .button(.x), startupFrames: 0, activeFrames: 1,
            recoveryFrames: 2,
            hit: CombatHitDefinition(damage: 10, hitStopFrames: 0, hitStunFrames: 20),
            visualAction: "hit")
        let burst = CombatMoveDefinition(
            id: "burst", command: .button(.d), startupFrames: 0, activeFrames: 2,
            recoveryFrames: 8, hit: CombatHitDefinition(damage: 0, hitStopFrames: 0),
            visualAction: "burst",
            resourceRules: MoveResourceRules(family: .burst, startCost: 150),
            systemControl: .defensiveBurst)
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: CombatProfile(moves: [hit]),
                       x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), profile: CombatProfile(moves: [burst]),
                       x: 445, yFeet: 700, facing: .left)
        XCTAssertTrue(world.beginSession(id: "burst", participants: [EntityID("a"), EntityID("b")]))
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        _ = world.step(environment: floor)
        world.setInput(.neutral, for: EntityID("a"))
        world.setInput(FighterInputFrame(systemControls: [.defensiveBurst]), for: EntityID("b"))

        let events = world.step(environment: floor)

        XCTAssertTrue(events.contains { $0.kind == .moveStarted && $0.moveID == "burst" })
        XCTAssertEqual(world.body(for: EntityID("b"))?.stunFrames, 0)
        // 150 start + 8 defender gain - 150 burst + 12 burst-hit gain.
        XCTAssertEqual(world.body(for: EntityID("b"))?.gameplayEnergy.current, 20)
    }
}
