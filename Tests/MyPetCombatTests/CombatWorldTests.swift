import XCTest
@testable import MyPetCombat
import MyPetCore
import MyPet2D

final class CombatWorldTests: XCTestCase {
    private let floor = CombatEnvironment(
        bounds: CombatRect(x: 0, y: 0, width: 1200, height: 800),
        surfaces: [CombatSurface(id: "floor:0", kind: .floor, left: 0, right: 1200, y: 700)])

    @discardableResult
    private func beginSession(_ world: CombatWorld, _ ids: [String] = ["a", "b"]) -> Bool {
        world.beginSession(
            id: "test-session",
            participants: ids.map(EntityID.init))
    }

    func testDamageRequiresExplicitCombatSession() {
        let move = CombatMoveDefinition(
            id: "hit", command: .button(.x), startupFrames: 0, activeFrames: 1,
            recoveryFrames: 1, hit: CombatHitDefinition(damage: 25, hitStopFrames: 0),
            visualAction: "attack")
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
                       x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 445, yFeet: 700, facing: .left)
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))

        _ = world.step(environment: floor)

        XCTAssertEqual(world.body(for: EntityID("b"))?.hp, 1000)
        XCTAssertNil(world.session)
    }

    func testExplicitCombatSessionAllowsDamageAndCheckpointsLifecycle() throws {
        let move = CombatMoveDefinition(
            id: "hit", command: .button(.x), startupFrames: 0, activeFrames: 1,
            recoveryFrames: 1, hit: CombatHitDefinition(damage: 25, hitStopFrames: 0),
            visualAction: "attack")
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
                       x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 445, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))

        _ = world.step(environment: floor)
        let restored = CombatWorld(checkpoint: world.checkpoint())

        XCTAssertEqual(world.body(for: EntityID("b"))?.hp, 975)
        XCTAssertEqual(restored.session, world.session)
        XCTAssertEqual(restored.session?.state, .active)
    }

    func testLegacyHitAndCheckpointPayloadsDecodeWithRuleDefaults() throws {
        let hit = try JSONDecoder().decode(
            CombatHitDefinition.self,
            from: Data(#"{"damage":25}"#.utf8))
        XCTAssertEqual(hit.id, "primary")
        XCTAssertEqual(hit.attackHeight, .mid)
        XCTAssertEqual(hit.hitGroup, "primary")
        XCTAssertNil(hit.rehitFrames)
        XCTAssertEqual(hit.clashLevel, 0)

        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 400, yFeet: 700)
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(world.checkpoint()))
                as? [String: Any])
        payload.removeValue(forKey: "session")
        var rules = try XCTUnwrap(payload["rules"] as? [String: Any])
        var actor = try XCTUnwrap(rules["a"] as? [String: Any])
        actor.removeValue(forKey: "hitLedger")
        rules["a"] = actor
        payload["rules"] = rules

        let restored = CombatWorld(checkpoint: try JSONDecoder().decode(
            CombatWorldCheckpoint.self,
            from: JSONSerialization.data(withJSONObject: payload)))

        XCTAssertNil(restored.session)
        XCTAssertEqual(restored.body(for: EntityID("a"))?.hitLedger, [:])

        var snapshotPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(world.snapshot()))
                as? [String: Any])
        snapshotPayload.removeValue(forKey: "projectiles")
        let oldSnapshot = try JSONDecoder().decode(
            CombatWorldSnapshot.self,
            from: JSONSerialization.data(withJSONObject: snapshotPayload))
        XCTAssertTrue(oldSnapshot.projectiles.isEmpty)
    }

    func testCombatSessionRejectsInvalidRosterAndCancelsWhenParticipantLeaves() {
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 445, yFeet: 700)

        XCTAssertFalse(world.beginSession(id: "single", participants: [EntityID("a")]))
        XCTAssertFalse(world.beginSession(
            id: "unknown", participants: [EntityID("a"), EntityID("missing")]))
        XCTAssertTrue(beginSession(world))

        world.unregister(actorID: EntityID("b"))

        XCTAssertEqual(world.session?.state, .cancelled)
        XCTAssertEqual(world.session?.endedAtFrame, 0)
    }

    func testAuthoredRootMotionAdvancesFighterBeforeFirstActiveFrame() {
        let move = CombatMoveDefinition(
            id: "step-in",
            command: .button(.x),
            startupFrames: 2,
            activeFrames: 1,
            recoveryFrames: 1,
            hit: CombatHitDefinition(damage: 20, hitStopFrames: 0),
            visualAction: "attack",
            rootMotion: [ActionRootMotion(
                active: ActionFrameWindow(start: 0, end: 1),
                deltaPerFrame: Vec2(x: 2, y: 0))])
        let world = CombatWorld()
        world.register(
            actorID: EntityID("a"),
            profile: CombatProfile(moves: [move]),
            x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 700, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))

        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        _ = world.step(environment: floor)
        world.setInput(.neutral, for: EntityID("a"))
        _ = world.step(environment: floor)

        XCTAssertEqual(
            world.body(for: EntityID("a"))?.position.x ?? .nan,
            404,
            accuracy: 1e-9)
        XCTAssertEqual(world.body(for: EntityID("a"))?.phase, .startup)
    }

    func testHighAndLowGuardRequireMatchingStance() {
        func remainingHP(height: CombatAttackHeight, crouching: Bool) -> Int? {
            let move = CombatMoveDefinition(
                id: "height", command: .button(.x), startupFrames: 0, activeFrames: 1,
                recoveryFrames: 1,
                hit: CombatHitDefinition(
                    damage: 40, chipDamage: 3, hitStopFrames: 0,
                    attackHeight: height),
                visualAction: "attack")
            let world = CombatWorld()
            world.register(actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
                           x: 400, yFeet: 700)
            world.register(actorID: EntityID("b"), x: 445, yFeet: 700, facing: .left)
            XCTAssertTrue(beginSession(world))
            world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
            world.setInput(FighterInputFrame(right: true, down: crouching), for: EntityID("b"))
            _ = world.step(environment: floor)
            return world.body(for: EntityID("b"))?.hp
        }

        XCTAssertEqual(remainingHP(height: .high, crouching: false), 997)
        XCTAssertEqual(remainingHP(height: .high, crouching: true), 960)
        XCTAssertEqual(remainingHP(height: .low, crouching: true), 997)
        XCTAssertEqual(remainingHP(height: .low, crouching: false), 960)
    }

    func testMultiHitUsesStableHitGroupAndRehitWindow() {
        let move = CombatMoveDefinition(
            id: "multi", command: .button(.x), startupFrames: 0, activeFrames: 5,
            recoveryFrames: 1,
            hit: CombatHitDefinition(
                id: "pulse", damage: 10, hitStopFrames: 0,
                hitGroup: "petals", rehitFrames: 2),
            visualAction: "attack")
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
                       x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 445, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))

        for frame in 0..<6 {
            world.setInput(frame == 0 ? FighterInputFrame(buttons: [.x]) : .neutral,
                           for: EntityID("a"))
            _ = world.step(environment: floor)
        }

        // Three contacts remain legal at frames 0/2/4; combo and repeated-move
        // scaling apply 10 + 8 + 6 damage.
        XCTAssertEqual(world.body(for: EntityID("b"))?.hp, 976)
    }

    func testEqualClashLevelsSuppressSameFrameDamageDeterministically() {
        let move = CombatMoveDefinition(
            id: "clash", command: .button(.x), startupFrames: 0, activeFrames: 1,
            recoveryFrames: 1,
            hit: CombatHitDefinition(damage: 40, hitStopFrames: 0, clashLevel: 1),
            visualAction: "attack")
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
                       x: 425, yFeet: 700)
        world.register(actorID: EntityID("b"), profile: CombatProfile(moves: [move]),
                       x: 475, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("b"))

        let events = world.step(environment: floor)

        XCTAssertEqual(world.body(for: EntityID("a"))?.hp, 1000)
        XCTAssertEqual(world.body(for: EntityID("b"))?.hp, 1000)
        XCTAssertEqual(events.filter { $0.kind == .clash }.count, 1)
    }

    func testInjectedBodyWorldRemainsSinglePositionAuthorityForScriptedActor() {
        let bodies = BodyWorld()
        let actor = EntityID("scripted")
        bodies.register(
            BodyDefinition(entityID: actor),
            state: BodyState(
                entityID: actor,
                position: Vec2(x: 100, y: 500),
                velocity: Vec2(x: 2, y: 0),
                locomotion: .grounded,
                currentSurfaceID: "floor"))
        let combat = CombatWorld(bodyWorld: bodies)
        combat.register(actorID: actor, profile: CombatProfile(), x: 999, yFeet: 999)
        combat.setAuthority(.scripted, for: actor)
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 800, height: 600),
            surfaces: [MyPet2D.Surface(
                id: "floor", kind: .floor, left: 0, right: 800, y: 500)])

        combat.step(environment: environment)

        XCTAssertEqual(bodies.state(for: actor)?.position.x, 102)
        XCTAssertEqual(combat.body(for: actor)?.position.x, 102)
    }

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

    func testUtilityAIAndManualInputUseTheSameCommandMatcher() throws {
        func startedMove(input: FighterInputFrame) -> String? {
            let world = CombatWorld()
            world.register(actorID: EntityID("a"), x: 400, yFeet: 700)
            world.register(actorID: EntityID("b"), x: 450, yFeet: 700, facing: .left)
            XCTAssertTrue(beginSession(world))
            world.setInput(input, for: EntityID("a"))
            return world.step(environment: floor).first(where: {
                $0.kind == .moveStarted && $0.actorID == EntityID("a")
            })?.moveID
        }
        let observationWorld = CombatWorld()
        observationWorld.register(actorID: EntityID("a"), x: 400, yFeet: 700)
        observationWorld.register(actorID: EntityID("b"), x: 450, yFeet: 700, facing: .left)
        let bodies = observationWorld.snapshot().bodies
        let me = try XCTUnwrap(bodies.first { $0.actorID == EntityID("a") })
        let target = try XCTUnwrap(bodies.first { $0.actorID == EntityID("b") })
        let aiInput = UtilityCombatPolicy().decide(
            CombatObservation(selfBody: me, opponents: [target]))

        XCTAssertEqual(startedMove(input: FighterInputFrame(buttons: [.x])), "light")
        XCTAssertEqual(startedMove(input: aiInput), "light")
    }

    func testCharacterMoveCommandsAreIndependentFromPhysicalKeyboardMapping() {
        var manual = ManualControlSession(mapping: ManualControlMapping(
            id: "custom",
            bindings: [.keyD: .buttonX]))
        _ = manual.begin()
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 450, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))

        world.setInput(manual.press(.keyD), for: EntityID("a"), authority: .manual)
        let events = world.step(environment: floor)

        XCTAssertEqual(events.first(where: { $0.kind == .moveStarted })?.moveID, "light")
    }

    func testSpecificMotionCommandWinsOverSingleButtonWithSameFinalButton() {
        let profile = CombatProfile(moves: [
            CombatMoveDefinition(
                id: "normal_z", command: .button(.z), startupFrames: 1,
                activeFrames: 1, recoveryFrames: 1,
                hit: CombatHitDefinition(), visualAction: "normal_z"),
            CombatMoveDefinition(
                id: "special_z",
                command: CombatCommand([
                    CombatCommandStep(direction: .down),
                    CombatCommandStep(direction: .downForward),
                    CombatCommandStep(direction: .forward),
                    CombatCommandStep(button: .z, maxGapFrames: 3),
                ]),
                startupFrames: 1, activeFrames: 1, recoveryFrames: 1,
                hit: CombatHitDefinition(damage: 100), visualAction: "special_z"),
        ])
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: profile, x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 450, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))

        var started: String?
        for input in CombatCommandSynthesizer.frames(
            for: profile.moves[1].command, facing: .right) {
            world.setInput(input, for: EntityID("a"), authority: .manual)
            started = world.step(environment: floor).first(where: {
                $0.kind == .moveStarted
            })?.moveID ?? started
        }

        XCTAssertEqual(started, "special_z")
    }

    func testDownPlusUpDropsThroughWindowSurfaceButNotFloor() throws {
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 1000, height: 800),
            surfaces: [
                Surface(id: "floor", kind: .floor, left: 0, right: 1000, y: 700),
                Surface(id: "window", kind: .windowTop, left: 250, right: 550, y: 400),
            ])
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 400, yFeet: 400)
        world.register(actorID: EntityID("b"), x: 800, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))
        _ = world.step(environment: environment)
        XCTAssertEqual(world.body(for: EntityID("a"))?.currentSurfaceID, "window")

        world.setInput(
            FighterInputFrame(up: true, down: true),
            for: EntityID("a"), authority: .manual)
        _ = world.step(environment: environment)

        let body = try XCTUnwrap(world.body(for: EntityID("a")))
        XCTAssertEqual(body.locomotion, .airborne)
        XCTAssertNil(body.currentSurfaceID)
        XCTAssertGreaterThan(body.position.y, 400)
    }

    func testHitUsesActualBoxesAndAppliesHitstun() {
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 450, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))
        for _ in 0..<8 {
            world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"), authority: .manual)
            _ = world.step(environment: floor)
        }
        XCTAssertLessThan(world.body(for: EntityID("b"))!.hp, 1000)
        XCTAssertTrue([CombatPhase.hitStun, .neutral].contains(world.body(for: EntityID("b"))!.phase))
    }

    func testCombatMoveUsesSharedActionTimelineAsItsFrameAuthority() {
        let move = CombatMoveDefinition(
            id: "timed", command: .button(.x),
            startupFrames: 2, activeFrames: 2, recoveryFrames: 2,
            hit: CombatHitDefinition(damage: 0), visualAction: "attack")
        let world = CombatWorld()
        world.register(
            actorID: EntityID("a"),
            profile: CombatProfile(moves: [move]),
            x: 300, yFeet: 700)

        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        _ = world.step(environment: floor)
        let timeline = world.body(for: EntityID("a"))?.actionTimeline

        XCTAssertEqual(timeline?.definition.actionID, "timed")
        XCTAssertEqual(timeline?.definition.animationBinding, "attack")
        XCTAssertEqual(timeline?.frame, 1)
        XCTAssertEqual(timeline?.phase, .startup)
    }

    func testSingleActiveFrameIsResolvedBeforeTimelineIsCleared() {
        let move = CombatMoveDefinition(
            id: "one-frame", command: .button(.x),
            startupFrames: 0, activeFrames: 1, recoveryFrames: 0,
            hit: CombatHitDefinition(damage: 25, hitStopFrames: 0),
            visualAction: "attack")
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
                       x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 445, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))

        _ = world.step(environment: floor)

        XCTAssertEqual(world.body(for: EntityID("b"))?.hp, 975)
        XCTAssertEqual(world.body(for: EntityID("a"))?.actionTimeline?.phase, .finished)
    }

    func testCombatHitStopFreezesSharedActionTimelineFrame() {
        let move = CombatMoveDefinition(
            id: "freeze", command: .button(.x),
            startupFrames: 0, activeFrames: 2, recoveryFrames: 2,
            hit: CombatHitDefinition(damage: 10, hitStopFrames: 2),
            visualAction: "attack")
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
                       x: 400, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 445, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        _ = world.step(environment: floor)
        let contactFrame = world.body(for: EntityID("a"))?.actionTimeline?.frame
        XCTAssertEqual(world.body(for: EntityID("a"))?.hitStopFrames, 2)

        world.setInput(.neutral, for: EntityID("a"))
        _ = world.step(environment: floor)

        XCTAssertEqual(world.body(for: EntityID("a"))?.actionTimeline?.frame, contactFrame)
        XCTAssertEqual(world.body(for: EntityID("a"))?.hitStopFrames, 1)
    }

    func testLegacyPresentationAttackNeverBecomesDamagingCombat() {
        let bodies = BodyWorld()
        let actor = EntityID("story-actor")
        bodies.register(
            BodyDefinition(entityID: actor),
            state: BodyState(
                entityID: actor,
                position: Vec2(x: 400, y: 700),
                locomotion: .grounded,
                currentSurfaceID: "floor:0",
                actionTimeline: ActionTimeline(
                    instanceID: 4,
                    definition: ActionDefinition(
                        actionID: "attack",
                        durationFrames: 30,
                        animationBinding: "attack",
                        domain: .presentation))))
        let world = CombatWorld(bodyWorld: bodies)
        world.register(actorID: actor, x: 400, yFeet: 700)
        world.register(actorID: EntityID("target"), x: 445, yFeet: 700, facing: .left)
        world.setAuthority(.scripted, for: actor)

        for _ in 0..<12 { _ = world.step(environment: floor) }

        XCTAssertEqual(world.body(for: EntityID("target"))?.hp, 1000)
        XCTAssertEqual(world.body(for: actor)?.actionTimeline?.definition.domain, .presentation)
        XCTAssertEqual(world.body(for: actor)?.currentMoveID, nil)
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
        XCTAssertTrue(beginSession(world))
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        _ = world.step(environment: floor)
        var sawKnockedOut = false
        var sawDowned = false
        for _ in 0..<60 {
            world.setInput(.neutral, for: EntityID("a"))
            _ = world.step(environment: floor)
            if let state = world.body(for: EntityID("b"))?.healthState {
                sawKnockedOut = sawKnockedOut || state == .knockedOut
                sawDowned = sawDowned || state == .downed
                if state == .active && sawDowned { break }
            }
        }
        let body = world.body(for: EntityID("b"))
        XCTAssertNotNil(body)
        XCTAssertTrue(sawKnockedOut)
        XCTAssertTrue(sawDowned)
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
        XCTAssertTrue(beginSession(world))
        for _ in 0..<90 {
            world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
            _ = world.step(environment: floor)
        }
        XCTAssertEqual(world.body(for: EntityID("b"))?.hp, 965)
    }

    func testHitstunCannotBeBypassedByBufferedControlInput() {
        let strike = CombatMoveDefinition(
            id: "strike", command: .button(.x), startupFrames: 0,
            activeFrames: 1, recoveryFrames: 1,
            hit: CombatHitDefinition(
                damage: 1, hitStopFrames: 0, hitStunFrames: 5,
                knockbackX: 0),
            visualAction: "attack")
        let reply = CombatMoveDefinition(
            id: "reply", command: .button(.y), startupFrames: 0,
            activeFrames: 1, recoveryFrames: 1,
            hit: CombatHitDefinition(damage: 1, hitStopFrames: 0),
            visualAction: "attack")
        let world = CombatWorld()
        world.register(
            actorID: EntityID("a"), profile: CombatProfile(moves: [strike]),
            x: 400, yFeet: 700)
        world.register(
            actorID: EntityID("b"), profile: CombatProfile(moves: [reply]),
            x: 445, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))
        world.setInput(
            FighterInputFrame(buttons: [.x]), for: EntityID("a"), authority: .manual)
        _ = world.step(environment: floor)

        world.setInput(.neutral, for: EntityID("a"), authority: .manual)
        world.setInput(
            FighterInputFrame(buttons: [.y]), for: EntityID("b"), authority: .manual)
        let events = world.step(environment: floor)

        XCTAssertFalse(events.contains {
            $0.kind == .moveStarted && $0.actorID == EntityID("b")
        })
        XCTAssertGreaterThan(world.body(for: EntityID("b"))?.stunFrames ?? 0, 0)
    }

    func testSameFrameTradeIsIndependentOfActorOrder() {
        let world = CombatWorld()
        world.register(actorID: EntityID("a"), x: 425, yFeet: 700)
        world.register(actorID: EntityID("b"), x: 475, yFeet: 700, facing: .left)
        XCTAssertTrue(beginSession(world))
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
        XCTAssertTrue(beginSession(world))
        world.setInput(FighterInputFrame(buttons: [.x]), for: EntityID("a"))
        _ = world.step(environment: floor)
        XCTAssertEqual(world.body(for: EntityID("b"))?.healthState, .knockedOut)

        world.beginDrag(actorID: EntityID("b"), x: 500, y: 300)
        for _ in 0..<20 { _ = world.step(environment: floor) }
        XCTAssertEqual(world.body(for: EntityID("b"))?.healthState, .knockedOut)

        world.endDrag(actorID: EntityID("b"), wasClick: false)
        var sawDowned = false
        for _ in 0..<180 {
            _ = world.step(environment: floor)
            if let state = world.body(for: EntityID("b"))?.healthState {
                sawDowned = sawDowned || state == .downed
                if state == .active { break }
            }
        }
        XCTAssertTrue(sawDowned)
        XCTAssertEqual(world.body(for: EntityID("b"))?.healthState, .active)
    }

    func testSameInputsProduceSameSnapshot() {
        func run() -> CombatWorldSnapshot {
            let world = CombatWorld()
            world.register(actorID: EntityID("a"), x: 300, yFeet: 700)
            world.register(actorID: EntityID("b"), x: 500, yFeet: 700, facing: .left)
            XCTAssertTrue(beginSession(world))
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
