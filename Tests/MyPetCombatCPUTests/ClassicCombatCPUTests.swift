import XCTest
import MyPet2D
import MyPetCombat
import MyPetCore
@testable import MyPetCombatCPU

final class ClassicCombatCPUTests: XCTestCase {
    func testSurfaceGraphBuildsDeterministicWalkJumpAndDropPath() throws {
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 1000, height: 800),
            surfaces: [
                Surface(id: "floor", kind: .floor, left: 0, right: 1000, y: 700),
                Surface(id: "window-a", kind: .windowTop, left: 200, right: 450, y: 520),
                Surface(id: "window-b", kind: .windowTop, left: 480, right: 720, y: 470),
            ])
        let graph = DynamicSurfaceGraph.build(
            environment: environment,
            mobility: SurfaceMobility(walkSpeed: 2, jumpVelocity: -9))

        let path = try XCTUnwrap(graph.path(from: "window-a", to: "window-b"))
        XCTAssertEqual(path.surfaceIDs, ["window-a", "window-b"])
        XCTAssertEqual(path.edges.first?.action, .jump)
        XCTAssertGreaterThan(path.totalCost, 0)
        XCTAssertEqual(
            graph.path(from: "window-a", to: "window-b"),
            DynamicSurfaceGraph.build(
                environment: environment,
                mobility: SurfaceMobility(walkSpeed: 2, jumpVelocity: -9))
                .path(from: "window-a", to: "window-b"))
    }

    func testClassicCPUSelectsVulnerableReachableTargetAndReservesSlot() throws {
        let profile = testProfile()
        let me = CombatBodyState(actorID: EntityID("me"), x: 280, yFeet: 700)
        var near = CombatBodyState(actorID: EntityID("near"), x: 370, yFeet: 700, facing: .left)
        near.phase = .recovery
        let far = CombatBodyState(actorID: EntityID("far"), x: 850, yFeet: 700, facing: .left)
        let observation = CPUCombatObservation(
            frame: 20, selfBody: me, opponents: [far, near],
            selfProfile: profile, opponentProfiles: ["near": profile, "far": profile],
            environment: floor)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .normal, seed: 7)

        let output = cpu.advance(observation)

        XCTAssertEqual(output.targetID, EntityID("near"))
        XCTAssertNotNil(output.slot)
        XCTAssertEqual(output.intent, .attack)
        XCTAssertEqual(output.moveID, "light")
    }

    func testEngagementReservationIsClearedWhenPerceivedTargetChanges() throws {
        let profile = testProfile()
        let me = CombatBodyState(actorID: EntityID("me"), x: 100, yFeet: 700)
        let firstTarget = CombatBodyState(
            actorID: EntityID("first"), x: 400, yFeet: 700, facing: .left)
        let secondTarget = CombatBodyState(
            actorID: EntityID("second"), x: 500, yFeet: 700, facing: .left)
        var cpu = ClassicCombatCPU(
            actorID: me.actorID, difficulty: .veryHard, seed: 13)

        let first = CPUCombatObservation(
            frame: 0, selfBody: me, opponents: [firstTarget],
            selfProfile: profile,
            opponentProfiles: ["first": profile, "second": profile],
            environment: floor)
        _ = cpu.advance(first)
        XCTAssertEqual(cpu.reservedSlot?.targetID, firstTarget.actorID)

        // Very-hard CPU perception is delayed by four frames. The new target
        // becomes visible before a replacement reservation is issued; the
        // old implementation leaked the first target's reservation through
        // this interval.
        for frame in 1...5 {
            var next = first
            next.frame = Int64(frame)
            next.opponents = [secondTarget]
            _ = cpu.advance(next)
        }

        XCTAssertEqual(cpu.checkpoint().targetID, secondTarget.actorID)
        XCTAssertNil(cpu.checkpoint().slot)
        XCTAssertNil(cpu.reservedSlot)
    }

    func testCPUExecutesSpecialThroughSynthesizedInputFramesAndCheckpointsQueue() throws {
        let special = CombatMoveDefinition(
            id: "special", command: CombatCommand([
                CombatCommandStep(direction: .down),
                CombatCommandStep(direction: .downForward),
                CombatCommandStep(direction: .forward),
                CombatCommandStep(button: .z, maxGapFrames: 3),
            ]), startupFrames: 2, activeFrames: 1, recoveryFrames: 2,
            hit: CombatHitDefinition(damage: 100, hitStopFrames: 0),
            visualAction: "special")
        let profile = CombatProfile(moves: [special])
        let me = CombatBodyState(actorID: EntityID("me"), x: 300, yFeet: 700)
        let enemy = CombatBodyState(actorID: EntityID("enemy"), x: 350, yFeet: 700, facing: .left)
        let observation = CPUCombatObservation(
            frame: 240, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .hard, seed: 11)

        let first = cpu.advance(observation)
        let checkpoint = cpu.checkpoint()
        var restored = ClassicCombatCPU(checkpoint: checkpoint)

        var originalFrames: [FighterInputFrame] = []
        var restoredFrames: [FighterInputFrame] = []
        for frame in 241..<252 {
            var next = observation
            next.frame = Int64(frame)
            originalFrames.append(cpu.advance(next).input)
            restoredFrames.append(restored.advance(next).input)
        }
        XCTAssertEqual(originalFrames, restoredFrames)
        var buffer = CombatInputBuffer()
        for input in [first.input] + originalFrames {
            buffer.push(input)
        }
        XCTAssertTrue(CommandMatcher.matches(special.command, buffer: buffer, facing: .right))
    }

    func testReferenceUCTParametersAndUnvisitedPriorityMatchFixedMctsAi23i() {
        XCTAssertEqual(MctsAi23iCompatibility.iterationLimit, 23)
        XCTAssertEqual(MctsAi23iCompatibility.explorationConstant, 3)
        XCTAssertEqual(MctsAi23iCompatibility.treeDepth, 2)
        XCTAssertEqual(MctsAi23iCompatibility.expansionVisitThreshold, 10)
        XCTAssertEqual(MctsAi23iCompatibility.simulationFrames, 60)
        XCTAssertEqual(MctsAi23iCompatibility.aheadFrames, 14)
        XCTAssertEqual(
            MctsAi23iCompatibility.ucb1(
                meanReward: 4, parentVisits: 20, visits: 5),
            4 + 3 * sqrt(2 * log(20) / 5), accuracy: 1e-12)
        XCTAssertEqual(
            MctsAi23iCompatibility.ucb1(
                meanReward: 0, parentVisits: 1, visits: 0), .infinity)
    }

    func testReferenceControllerKeypressSequenceAndFetchMatchFLFBoundary() {
        var controller = FLFControllerCompatibility<String>()
        controller.keyseq(["down", "right", "attack"])
        XCTAssertEqual(controller.fetch(), [
            .init(key: "down", isDown: true), .init(key: "down", isDown: false),
            .init(key: "right", isDown: true), .init(key: "right", isDown: false),
            .init(key: "attack", isDown: true), .init(key: "attack", isDown: false),
        ])
        XCTAssertEqual(controller.state["down"], false)
        XCTAssertEqual(controller.state["right"], false)
        XCTAssertEqual(controller.state["attack"], false)
    }

    func testFightingICECommandCenterDrainsBeforeAcceptingAnotherCommand() {
        var center = FightingICECommandCenterCompatibility()
        center.commandCall(.button(.x), facing: .right)
        let firstCommand = center.skillKeys
        center.commandCall(.button(.y), facing: .right)
        XCTAssertEqual(center.skillKeys, firstCommand)
        while center.skillFlag { _ = center.getSkillKey() }
        center.commandCall(.button(.y), facing: .right)
        XCTAssertTrue(center.skillKeys.contains { $0.buttons.contains(.y) })
        XCTAssertFalse(center.skillKeys.contains { $0.buttons.contains(.x) })
    }

    func testEngagementReservationChoosesAnotherSlotAroundSameTarget() throws {
        let profile = testProfile()
        let me = CombatBodyState(actorID: EntityID("me"), x: 100, yFeet: 700)
        let target = CombatBodyState(actorID: EntityID("target"), x: 400, yFeet: 700)
        var first = ClassicCombatCPU(actorID: me.actorID, difficulty: .normal, seed: 1)
        let firstOutput = first.advance(CPUCombatObservation(
            frame: 0, selfBody: me, opponents: [target], selfProfile: profile,
            opponentProfiles: ["target": profile], environment: floor))
        let reserved = try XCTUnwrap(firstOutput.slot)
        var second = ClassicCombatCPU(
            actorID: EntityID("other"), difficulty: .normal, seed: 2)
        let secondOutput = second.advance(CPUCombatObservation(
            frame: 0,
            selfBody: CombatBodyState(
                actorID: EntityID("other"), x: 120, yFeet: 700),
            opponents: [target], selfProfile: profile,
            opponentProfiles: ["target": profile], environment: floor,
            engagementReservations: [reserved]))

        XCTAssertNotEqual(secondOutput.slot?.side, reserved.side)
    }

    func testDifficultyUsesDelayedPerceptionInsteadOfSameFrameGuardCheat() {
        let profile = testProfile()
        let me = CombatBodyState(actorID: EntityID("me"), x: 300, yFeet: 700)
        var enemy = CombatBodyState(actorID: EntityID("enemy"), x: 350, yFeet: 700, facing: .left)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .easy, seed: 3)
        var firstGuardFrame: Int64?
        for frame: Int64 in 0..<30 {
            enemy.phase = frame >= 1 ? .active : .neutral
            let output = cpu.advance(CPUCombatObservation(
                frame: frame, selfBody: me, opponents: [enemy],
                selfProfile: profile, opponentProfiles: ["enemy": profile],
                environment: floor))
            if output.intent == .guard { firstGuardFrame = firstGuardFrame ?? frame }
        }
        XCTAssertGreaterThanOrEqual(firstGuardFrame ?? 0, 15)
    }

    func testCPUUsesDefensiveBurstOnlyWhileInStun() {
        let light = CombatMoveDefinition(
            id: "light", command: .button(.x), startupFrames: 3,
            activeFrames: 2, recoveryFrames: 6,
            hit: CombatHitDefinition(damage: 30, hitStopFrames: 0),
            visualAction: "attack")
        let superMove = CombatMoveDefinition(
            id: "super", command: .button(.z), startupFrames: 3,
            activeFrames: 2, recoveryFrames: 6,
            hit: CombatHitDefinition(damage: 300, hitStopFrames: 0),
            visualAction: "super",
            resourceRules: MoveResourceRules(
                family: .superMove, startCost: 300))
        let burst = CombatMoveDefinition(
            id: "burst", command: .button(.s), startupFrames: 0,
            activeFrames: 2, recoveryFrames: 6,
            hit: CombatHitDefinition(damage: 20, hitStopFrames: 0),
            visualAction: "burst",
            resourceRules: MoveResourceRules(family: .burst, startCost: 300),
            systemControl: .defensiveBurst)
        let profile = CombatProfile(moves: [light, superMove, burst])
        var me = CombatBodyState(actorID: EntityID("me"), x: 300, yFeet: 700)
        me.gameplayEnergy = GameplayEnergyState(current: 300)
        let enemy = CombatBodyState(
            actorID: EntityID("enemy"), x: 350, yFeet: 700, facing: .left)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .normal, seed: 19)

        let neutral = cpu.advance(CPUCombatObservation(
            frame: 0, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))
        XCTAssertNotEqual(neutral.moveID, "burst")

        me.phase = .hitStun
        me.stunFrames = 10
        let firstHit = cpu.advance(CPUCombatObservation(
            frame: 1, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))
        XCTAssertNotEqual(firstHit.moveID, "burst")

        me.hp = 250
        let defensive = cpu.advance(CPUCombatObservation(
            frame: 3, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))
        XCTAssertEqual(defensive.moveID, "burst")
        XCTAssertEqual(defensive.input.systemControls, [.defensiveBurst])
        let heldStun = cpu.advance(CPUCombatObservation(
            frame: 2, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))
        XCTAssertEqual(heldStun.input, .neutral)
    }

    func testCPUReservesFullGaugeForBurstWhenHealthIsCritical() {
        let superMove = CombatMoveDefinition(
            id: "super", command: .button(.z), startupFrames: 3,
            activeFrames: 2, recoveryFrames: 6,
            hit: CombatHitDefinition(damage: 300, hitStopFrames: 0),
            visualAction: "super",
            resourceRules: MoveResourceRules(
                family: .superMove, startCost: 300))
        let burst = CombatMoveDefinition(
            id: "burst", command: .button(.s), startupFrames: 0,
            activeFrames: 2, recoveryFrames: 6,
            hit: CombatHitDefinition(damage: 20, hitStopFrames: 0),
            visualAction: "burst",
            resourceRules: MoveResourceRules(family: .burst, startCost: 300),
            systemControl: .defensiveBurst)
        let resourceSpecial = CombatMoveDefinition(
            id: "resource-special", command: .button(.x), startupFrames: 2,
            activeFrames: 2, recoveryFrames: 4,
            hit: CombatHitDefinition(damage: 50, hitStopFrames: 0),
            visualAction: "special",
            resourceRules: MoveResourceRules(family: .special, startCost: 45))
        let profile = CombatProfile(moves: [superMove, burst, resourceSpecial])
        var me = CombatBodyState(actorID: EntityID("me"), x: 300, yFeet: 700)
        me.hp = 300
        me.gameplayEnergy = GameplayEnergyState(current: 300)
        let enemy = CombatBodyState(
            actorID: EntityID("enemy"), x: 350, yFeet: 700, facing: .left)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .normal, seed: 29)

        let neutral = cpu.advance(CPUCombatObservation(
            frame: 0, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))
        XCTAssertNotEqual(neutral.moveID, "super")
        XCTAssertNotEqual(neutral.moveID, "resource-special")

        me.phase = .hitStun
        me.stunFrames = 10
        let defensive = cpu.advance(CPUCombatObservation(
            frame: 1, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))
        XCTAssertEqual(defensive.moveID, "burst")
    }

    func testDecisionIntervalKeepsApproachInputHeld() {
        let profile = testProfile()
        let me = CombatBodyState(actorID: EntityID("me"), x: 200, yFeet: 700)
        let enemy = CombatBodyState(
            actorID: EntityID("enemy"), x: 700, yFeet: 700, facing: .left)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .normal, seed: 31)

        let first = cpu.advance(CPUCombatObservation(
            frame: 0, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))
        XCTAssertEqual(first.intent, .approach)
        XCTAssertTrue(first.input.right)

        let betweenDecisions = cpu.advance(CPUCombatObservation(
            frame: 1, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))
        XCTAssertTrue(betweenDecisions.input.right)
        XCTAssertFalse(betweenDecisions.input.left)
    }

    func testFullGaugeDoesNotForceFirstUseSuper() {
        let light = CombatMoveDefinition(
            id: "light", command: .button(.x), startupFrames: 3,
            activeFrames: 2, recoveryFrames: 6,
            hit: CombatHitDefinition(damage: 180, hitStopFrames: 0),
            visualAction: "light")
        let superMove = CombatMoveDefinition(
            id: "super", command: .button(.z), startupFrames: 24,
            activeFrames: 3, recoveryFrames: 48,
            hit: CombatHitDefinition(damage: 40, hitStopFrames: 0),
            visualAction: "super",
            resourceRules: MoveResourceRules(family: .superMove, startCost: 300))
        let profile = CombatProfile(moves: [light, superMove])
        var me = CombatBodyState(actorID: EntityID("me"), x: 300, yFeet: 700)
        me.gameplayEnergy = GameplayEnergyState(current: 300)
        let enemy = CombatBodyState(
            actorID: EntityID("enemy"), x: 350, yFeet: 700, facing: .left)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .normal, seed: 37)

        let output = cpu.advance(CPUCombatObservation(
            frame: 0, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))

        XCTAssertEqual(output.moveID, "light")
    }

    func testCPUApproachesWhenAttackBoxCannotYetReachHurtBox() {
        let profile = testProfile()
        let me = CombatBodyState(actorID: EntityID("me"), x: 300, yFeet: 700)
        let enemy = CombatBodyState(
            actorID: EntityID("enemy"), x: 402, yFeet: 700, facing: .left)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .normal, seed: 23)

        let output = cpu.advance(CPUCombatObservation(
            frame: 0, selfBody: me, opponents: [enemy],
            selfProfile: profile, opponentProfiles: ["enemy": profile],
            environment: floor))

        XCTAssertEqual(output.intent, .approach)
        XCTAssertNil(output.moveID)
        XCTAssertTrue(output.input.right)
    }

    func testCPUExploresEveryReachableMoveBeforeRepeatingOne() {
        let profile = CombatProfile(moves: [
            CombatMoveDefinition(
                id: "high-damage", command: .button(.z), startupFrames: 1,
                activeFrames: 1, recoveryFrames: 1,
                hit: CombatHitDefinition(damage: 500, hitStopFrames: 0),
                visualAction: "high-damage"),
            CombatMoveDefinition(
                id: "medium-damage", command: .button(.y), startupFrames: 1,
                activeFrames: 1, recoveryFrames: 1,
                hit: CombatHitDefinition(damage: 100, hitStopFrames: 0),
                visualAction: "medium-damage"),
            CombatMoveDefinition(
                id: "low-damage", command: .button(.x), startupFrames: 1,
                activeFrames: 1, recoveryFrames: 1,
                hit: CombatHitDefinition(damage: 1, hitStopFrames: 0),
                visualAction: "low-damage"),
        ])
        let me = CombatBodyState(actorID: EntityID("me"), x: 300, yFeet: 700)
        let enemy = CombatBodyState(
            actorID: EntityID("enemy"), x: 350, yFeet: 700, facing: .left)
        var cpu = ClassicCombatCPU(actorID: me.actorID, difficulty: .normal, seed: 41)
        var selected: [String] = []

        for frame: Int64 in 0..<120 where selected.count < 3 {
            let output = cpu.advance(CPUCombatObservation(
                frame: frame, selfBody: me, opponents: [enemy],
                selfProfile: profile, opponentProfiles: ["enemy": profile],
                environment: floor))
            if let moveID = output.moveID,
               output.input != .neutral,
               selected.last != moveID {
                selected.append(moveID)
            }
        }

        XCTAssertEqual(Set(selected), Set(["high-damage", "medium-damage", "low-damage"]))
    }

    private var floor: BodyEnvironment {
        BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 1000, height: 800),
            surfaces: [Surface(id: "floor", kind: .floor, left: 0, right: 1000, y: 700)])
    }

    private func testProfile() -> CombatProfile {
        CombatProfile(moves: [CombatMoveDefinition(
            id: "light", command: .button(.x), startupFrames: 3,
            activeFrames: 2, recoveryFrames: 6,
            hit: CombatHitDefinition(damage: 30, hitStopFrames: 0),
            visualAction: "attack")])
    }
}
