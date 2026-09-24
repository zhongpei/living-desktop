import XCTest
import MyPet2D
import MyPetCombat
import MyPetCore

final class CombatCompletionTests: XCTestCase {
    private let arena = BodyEnvironment(
        bounds: Rect2D(x: 0, y: 0, width: 240, height: 200),
        surfaces: [Surface(id: "floor", kind: .floor, left: 0, right: 240, y: 160)])

    func testFormalRoundTimesOutAndSelectsHighestHPWinner() {
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 70, yFeet: 160)
        world.register(actorID: EntityID("b"), x: 170, yFeet: 160)
        XCTAssertTrue(world.beginSession(
            id: "round", participants: [EntityID("a"), EntityID("b")],
            roundRules: CombatRoundRules(durationFrames: 2, endOnKnockout: true)))
        _ = world.step(environment: arena)
        let events = world.step(environment: arena)
        XCTAssertEqual(world.session?.state, .completed)
        XCTAssertEqual(world.session?.endReason, .timeout)
        XCTAssertTrue(events.contains { $0.kind == .roundEnded })
    }

    func testFormalTeamTimeoutUsesCombinedTeamHealth() {
        let world = CombatWorld()
        let ids = ["red-a", "red-b", "blue-a", "blue-b"].map(EntityID.init)
        for (index, id) in ids.enumerated() {
            world.register(actorID: id, x: 40 + Double(index) * 45, yFeet: 160)
        }
        world.configureTeam(teamID: "red", activeID: ids[0], benchID: ids[1])
        world.configureTeam(teamID: "blue", activeID: ids[2], benchID: ids[3])
        XCTAssertTrue(world.beginSession(
            id: "teams", participants: ids,
            roundRules: CombatRoundRules(durationFrames: 1, endOnKnockout: true)))
        var checkpoint = world.checkpoint()
        checkpoint.rules[ids[0].raw]?.hp = 600
        checkpoint.rules[ids[1].raw]?.hp = 600
        checkpoint.rules[ids[2].raw]?.hp = 1_000
        checkpoint.rules[ids[3].raw]?.hp = 100
        let restored = CombatWorld(checkpoint: checkpoint)

        _ = restored.step(environment: arena)

        XCTAssertEqual(Set(restored.session?.winnerIDs ?? []), Set([ids[0], ids[1]]))
    }

    func testAirTechRequiresLateStunButtonEdgeAndOnlyOccursOnce() {
        let launcher = CombatMoveDefinition(
            id: "launcher", command: .button(.x), startupFrames: 0,
            activeFrames: 1, recoveryFrames: 2,
            hit: CombatHitDefinition(
                damage: 10, hitStopFrames: 0, hitStunFrames: 20,
                knockbackX: 0, knockbackY: -4),
            visualAction: "launcher")
        let world = CombatWorld()
        world.register(
            actorID: EntityID("a"), profile: CombatProfile(moves: [launcher]),
            x: 70, yFeet: 160)
        world.register(actorID: EntityID("b"), x: 110, yFeet: 160, facing: .left)
        _ = world.beginSession(id: "air-tech", participants: [EntityID("a"), EntityID("b")])
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"), authority: .manual)
        _ = world.step(environment: arena)
        world.setInput(.neutral, for: EntityID("a"), authority: .manual)
        for _ in 0..<8 { _ = world.step(environment: arena) }

        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("b"), authority: .manual)
        let events = world.step(environment: arena)
        let heldEvents = world.step(environment: arena)

        XCTAssertEqual(events.filter { $0.kind == .airTech }.count, 1)
        XCTAssertTrue(heldEvents.allSatisfy { $0.kind != .airTech })
    }

    func testComboAllowsOnlyOneWallAndGroundBounce() {
        var combo = ComboState()
        XCTAssertTrue(combo.consumeWallBounce())
        XCTAssertFalse(combo.consumeWallBounce())
        XCTAssertTrue(combo.consumeGroundBounce())
        XCTAssertFalse(combo.consumeGroundBounce())
        combo.end(reason: .recovered)
        XCTAssertTrue(combo.consumeWallBounce())
    }

    func testNeutralCascadeAndTeamLiabilityUseRecordedAggro() {
        var state = CombatEscalationState(policy: .desktopBrawl)
        let npc = EntityID("npc")
        let offender = EntityID("offender")
        state.recordCollateralHit(
            victimID: npc, offenderID: offender, offenderTeamID: "red",
            damage: 10, frame: 0, cascadeDepth: 0)
        _ = state.advance(frame: 1, combatReady: [npc])
        XCTAssertTrue(state.isHostile(
            actorID: npc, toward: EntityID("red-partner"), candidateTeamID: "red"))
        XCTAssertEqual(state.cascadeDepth(for: npc), 0)

        var noCascade = CombatEscalationState(policy: NeutralEscalationPolicy(
            enabled: true, joinOnFirstDamagingHit: true, teamLiability: false,
            cascadeEnabled: false, maxIncidentalCombatants: 4, maxCascadeDepth: 2,
            hostilityDecayFrames: 10, reactionDelayFrames: 1))
        noCascade.recordCollateralHit(
            victimID: npc, offenderID: offender, offenderTeamID: nil,
            damage: 10, frame: 0, cascadeDepth: 1)
        XCTAssertTrue(noCascade.aggro.isEmpty)
    }

    func testCancelGraphStartsOnlyAuthoredDestinationInsideWindow() {
        let first = CombatMoveDefinition(
            id: "normal", command: .button(.x), startupFrames: 0,
            activeFrames: 3, recoveryFrames: 6,
            hit: CombatHitDefinition(damage: 0, attackBoxes: []),
            visualAction: "normal_x",
            cancelWindows: [ActionFrameWindow(start: 1, end: 2)],
            cancelInto: ["special"])
        let special = CombatMoveDefinition(
            id: "special", command: .button(.z), startupFrames: 0,
            activeFrames: 1, recoveryFrames: 1,
            hit: CombatHitDefinition(damage: 0, attackBoxes: []),
            visualAction: "special")
        let world = CombatWorld()
        world.register(
            actorID: EntityID("a"), profile: CombatProfile(moves: [first, special]),
            x: 70, yFeet: 160)
        world.register(actorID: EntityID("b"), x: 150, yFeet: 160)
        _ = world.beginSession(id: "cancel", participants: [EntityID("a"), EntityID("b")])
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"), authority: .manual)
        _ = world.step(environment: arena)
        world.setInput(.neutral, for: EntityID("a"), authority: .manual)
        _ = world.step(environment: arena)
        world.setInput(FighterInputFrame(buttons: [.z]), for: EntityID("a"), authority: .manual)
        let events = world.step(environment: arena)
        XCTAssertEqual(world.body(for: EntityID("a"))?.currentMoveID, "special")
        XCTAssertTrue(events.contains { $0.kind == .moveCancelled })
    }

    func testAuthoredWallBounceEmitsOncePerCombo() {
        let move = CombatMoveDefinition(
            id: "bounce", command: .button(.x), startupFrames: 0,
            activeFrames: 1, recoveryFrames: 1,
            hit: CombatHitDefinition(
                damage: 10, hitStopFrames: 0, knockbackX: 30,
                wallBounce: true),
            visualAction: "normal_x")
        let world = CombatWorld()
        world.register(
            actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
            x: 175, yFeet: 160)
        world.register(actorID: EntityID("b"), x: 220, yFeet: 160, facing: .left)
        _ = world.beginSession(id: "bounce", participants: [EntityID("a"), EntityID("b")])
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"), authority: .manual)
        let events = world.step(environment: arena)
        XCTAssertTrue(events.contains { $0.kind == .wallBounce })
        XCTAssertLessThan(world.body(for: EntityID("b"))?.velocity.x ?? 0, 0)
    }
}
