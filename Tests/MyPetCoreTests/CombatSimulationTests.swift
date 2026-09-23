import XCTest
import MyPetCombat
import MyPetCombatCPU
import MyPetCore
import MyPetEngine
@testable import MyPetSimulation

final class CombatSimulationTests: XCTestCase {
    func testCombatSnapshotRestoresBitExactWorldState() {
        let desktop = VirtualDesktop(
            screens: [VirtualScreen(id: "main", frame: LayoutRect(x: 0, y: 0, width: 1000, height: 700), main: true)])
        let scenario = VirtualCombatScenario(
            id: "replay",
            desktop: desktop,
            actors: [
                VirtualCombatActor(actorID: EntityID("a"), x: 400, yFeet: 700),
                VirtualCombatActor(actorID: EntityID("b"), x: 455, yFeet: 700, facing: .left),
            ],
            inputs: [
                CombatInputEvent(frame: 0, actorID: EntityID("a"), input: FighterInputFrame(buttons: [.x])),
                CombatInputEvent(frame: 1, actorID: EntityID("a"), input: .neutral),
            ],
            durationFrames: 30)
        let first = CombatDataSimulation(scenario: scenario)
        _ = first.run(frames: 8)
        let restored = CombatDataSimulation(snapshot: first.snapshot())
        _ = first.run(frames: 22)
        _ = restored.run(frames: 22)
        XCTAssertEqual(first.combat.snapshot(), restored.combat.snapshot())
    }

    func testMovingVirtualWindowIsRealCombatSurface() {
        var desktop = VirtualDesktop(
            screens: [VirtualScreen(id: "main", frame: LayoutRect(x: 0, y: 0, width: 1000, height: 800), main: true)],
            windows: [VirtualWindow(
                id: EntityID("w"), app: "Test", title: "Platform",
                frame: LayoutRect(x: 300, y: 400, width: 400, height: 200))])
        desktop.schedule(VirtualDesktopEvent(
            atTick: 2,
            action: .moveWindow(EntityID("w"), LayoutRect(x: 500, y: 500, width: 400, height: 200))))
        let scenario = VirtualCombatScenario(
            id: "moving-window", desktop: desktop,
            actors: [VirtualCombatActor(actorID: EntityID("a"), x: 500, yFeet: 390)],
            durationFrames: 30)
        let sim = CombatDataSimulation(scenario: scenario)
        _ = sim.run(frames: 30)
        XCTAssertNotNil(sim.combat.body(for: EntityID("a")))
    }

    func testCombatSimulationCheckpointUsesGameRuntimeAsTheOnlyClockOwner() throws {
        let scenario = makeScenario()
        let simulation = CombatDataSimulation(scenario: scenario)
        _ = simulation.run(frames: 7)

        let snapshot = simulation.snapshot()
        XCTAssertEqual(snapshot.runtime.bodyClock.frame, 7)
        XCTAssertEqual(snapshot.runtime.combat?.world.frame, 7)

        let data = try JSONEncoder().encode(snapshot)
        let restored = CombatDataSimulation(
            snapshot: try JSONDecoder().decode(CombatSimulationSnapshot.self, from: data))
        let originalEvents = simulation.run(frames: 13)
        let replayedEvents = restored.run(frames: 13)
        XCTAssertEqual(originalEvents, replayedEvents)
        XCTAssertEqual(simulation.digest, restored.digest)
    }

    func testVirtualDesktopAdapterMatchesDirectRuntimeDigest() {
        let scenario = makeScenario()
        let simulation = CombatDataSimulation(scenario: scenario)
        let runtime = CombatRuntime()
        for actor in scenario.actors {
            runtime.register(
                actorID: actor.actorID, profile: actor.profile,
                x: actor.x, yFeet: actor.yFeet, facing: actor.facing)
            runtime.activate(.authored, for: actor.actorID)
        }
        _ = runtime.beginSession(id: "simulation:\(scenario.id)")
        let game = GameRuntime(combatRuntime: runtime)
        let events = Dictionary(grouping: scenario.inputs, by: \.frame)
        var active: [String: FighterInputFrame] = [:]
        var desktop = scenario.desktop
        for frame: Int64 in 0..<20 {
            if frame % 3 == 0 { _ = desktop.advance(to: frame / 3) }
            for event in events[frame] ?? [] { active[event.actorID.raw] = event.input }
            for actor in scenario.actors {
                runtime.setInput(active[actor.actorID.raw] ?? .neutral,
                                 source: .authored, for: actor.actorID)
            }
            _ = game.advance(
                elapsedSeconds: 1.0 / 60.0,
                combatEnvironment: desktop.combatEnvironment())
        }
        _ = simulation.run(frames: 20)
        XCTAssertEqual(simulation.digest, runtime.digest)
    }

    func testLegacyCombatRunnerRecordingUpgradesToUnifiedRuntimeCheckpoint() throws {
        let scenario = makeScenario()
        let simulation = CombatDataSimulation(scenario: scenario)
        _ = simulation.run(frames: 5)
        let legacy = LegacyCombatSimulationSnapshot(
            scenario: scenario,
            desktop: simulation.desktop,
            combat: simulation.combat.checkpoint(),
            activeInputs: ["a": .neutral, "b": .neutral])

        let upgraded = try JSONDecoder().decode(
            CombatSimulationSnapshot.self,
            from: JSONEncoder().encode(legacy))

        XCTAssertEqual(upgraded.runtime.bodyClock.frame, 5)
        XCTAssertEqual(upgraded.runtime.combat?.world.frame, 5)
        XCTAssertNotNil(CombatDataSimulation(snapshot: upgraded).combat.body(for: EntityID("a")))
    }

    func testDataSimulationAdvancesSemanticAndCombatOnOneRuntimeTimeline() {
        let combat = makeScenario()
        let scenario = HarnessScenario(
            id: "combined-runtime",
            durationTicks: 2,
            entities: combat.actors.map {
                EntityState(id: $0.actorID, kind: .actor)
            },
            desktop: combat.desktop,
            combatActors: combat.actors,
            combatInputs: combat.inputs)
        let simulation = DataSimulation(scenario: scenario)

        _ = simulation.step()

        XCTAssertEqual(simulation.runtime.clock.tick, 1)
        XCTAssertEqual(simulation.runtime.bodyFrame, 3)
        XCTAssertEqual(simulation.runtime.combatRuntime?.world.frame, 3)
        XCTAssertTrue(simulation.combatSimulation?.runtime === simulation.runtime)

        let restored = DataSimulation(snapshot: simulation.snapshot())
        _ = simulation.step()
        _ = restored.step()
        XCTAssertEqual(simulation.runtime.checkpoint(), restored.runtime.checkpoint())
    }

    func testCombatDigestIsIndependentOfRenderSamplingRate() {
        let digests = [20, 40, 60, 120].map(combatDigest(renderHz:))
        XCTAssertTrue(digests.dropFirst().allSatisfy { $0 == digests[0] })
    }

    func testAutonomousCombatProducesRepeatedButtonPresses() {
        let move = CombatMoveDefinition(
            id: "light", command: .button(.x), startupFrames: 0,
            activeFrames: 1, recoveryFrames: 2,
            hit: CombatHitDefinition(
                damage: 10, hitStopFrames: 0, hitStunFrames: 0,
                knockbackX: 0),
            visualAction: "attack")
        let runtime = CombatRuntime()
        runtime.register(
            actorID: EntityID("a"), profile: CombatProfile(moves: [move]),
            x: 400, yFeet: 700)
        runtime.register(
            actorID: EntityID("b"), profile: CombatProfile(moves: []),
            x: 445, yFeet: 700, facing: .left)
        runtime.activate(.autonomous, for: EntityID("a"))
        runtime.activate(.autonomous, for: EntityID("b"))

        for _ in 0..<20 {
            _ = runtime.advance(environment: makeScenario().desktop.combatEnvironment())
        }

        XCTAssertLessThanOrEqual(runtime.world.body(for: EntityID("b"))?.hp ?? 1000, 980)
    }

    func testAutonomousAuthoritySurvivesKnockoutAndRecovery() {
        let finisher = CombatMoveDefinition(
            id: "finisher", command: .button(.x), startupFrames: 0,
            activeFrames: 1, recoveryFrames: 1,
            hit: CombatHitDefinition(
                damage: 1000, hitStopFrames: 0, hitStunFrames: 0,
                knockbackX: 0),
            visualAction: "attack")
        let runtime = CombatRuntime()
        runtime.register(
            actorID: EntityID("a"),
            profile: CombatProfile(moves: [finisher]),
            x: 400, yFeet: 700)
        runtime.register(
            actorID: EntityID("b"),
            profile: CombatProfile(
                moves: [], downedRecoveryFrames: 2, getUpFrames: 2,
                revivedHPFraction: 0.3, reviveInvulnerabilityFrames: 0),
            x: 445, yFeet: 700, facing: .left)
        runtime.activate(.autonomous, for: EntityID("a"))
        runtime.activate(.autonomous, for: EntityID("b"))

        var events: [CombatEvent] = []
        for _ in 0..<12 {
            events.append(contentsOf: runtime.advance(
                environment: makeScenario().desktop.combatEnvironment()))
        }

        XCTAssertTrue(runtime.isActive(.autonomous, for: EntityID("b")))
        XCTAssertTrue(events.contains {
            $0.kind == .recovered && $0.actorID == EntityID("b")
        })
    }

    func testOneControlledTeamStartsSessionWithAnOpposingTeam() {
        let runtime = CombatRuntime()
        for (id, x) in [("red-a", 300.0), ("red-b", 250.0),
                        ("blue-a", 500.0), ("blue-b", 550.0)] {
            runtime.register(
                actorID: EntityID(id), profile: CombatProfile(),
                x: x, yFeet: 700)
        }
        runtime.configureTeam(
            teamID: "red", activeID: EntityID("red-a"),
            benchID: EntityID("red-b"))
        runtime.configureTeam(
            teamID: "blue", activeID: EntityID("blue-a"),
            benchID: EntityID("blue-b"))

        runtime.activate(.autonomous, for: EntityID("red-a"))

        XCTAssertEqual(runtime.world.session?.participantIDs, [
            EntityID("blue-a"), EntityID("blue-b"),
            EntityID("red-a"), EntityID("red-b"),
        ])
    }

    func testNonCombatReadyBystanderIsNotSelectedAsAutomaticOpponent() {
        let runtime = CombatRuntime()
        runtime.register(
            actorID: EntityID("fighter"), profile: CombatProfile(),
            x: 300, yFeet: 700)
        runtime.register(
            actorID: EntityID("pet"), profile: CombatProfile(moves: []),
            x: 350, yFeet: 700, realCombatReady: false)

        runtime.activate(.autonomous, for: EntityID("fighter"))

        XCTAssertNil(runtime.world.session)
        XCTAssertEqual(
            runtime.world.body(for: EntityID("pet"))?.participation,
            .uninvolved)
    }

    func testRuntimeCPUSeedChangesDecisionStreamButRemainsReplayable() {
        func run(seed: UInt64) -> CombatRuntimeDigest {
            let runtime = CombatRuntime(cpuSeed: seed)
            let moves = CombatButton.allCases.map { button in
                CombatMoveDefinition(
                    id: "move-\(button.rawValue)", command: .button(button),
                    startupFrames: 0, activeFrames: 1, recoveryFrames: 1,
                    hit: CombatHitDefinition(
                        damage: 10, hitStopFrames: 0, hitStunFrames: 0,
                        knockbackX: 0),
                    visualAction: "attack")
            }
            let profile = CombatProfile(moves: moves)
            runtime.register(actorID: EntityID("a"), profile: profile, x: 400, yFeet: 700)
            runtime.register(
                actorID: EntityID("b"), profile: profile,
                x: 445, yFeet: 700, facing: .left)
            runtime.activate(.autonomous, for: EntityID("a"))
            runtime.activate(.autonomous, for: EntityID("b"))
            for _ in 0..<120 {
                _ = runtime.advance(environment: makeScenario().desktop.combatEnvironment())
            }
            return runtime.digest
        }

        XCTAssertEqual(run(seed: 101), run(seed: 101))
        XCTAssertNotEqual(run(seed: 101), run(seed: 202))
    }

    func testWindowPlatformIntentIsAuthorizedBeforePublicationAndSpendsEnergy() {
        let runtime = CombatRuntime(cpuSeed: 7)
        runtime.register(
            actorID: EntityID("a"), profile: CombatProfile(moves: []),
            x: 400, yFeet: 500)
        runtime.setGameplayEnergy(300, for: EntityID("a"))
        runtime.setGameplayStyle(
            CharacterGameplayStyle(
                combat: 0, explore: 0, destruction: 1, risk: 0,
                energyReserve: 0, spectacle: 1),
            for: EntityID("a"))
        runtime.activate(.autonomous, for: EntityID("a"))
        var policy = WindowInteractionPolicy()
        policy.damageCooldownFrames = 0
        runtime.setWindowInteractionPolicy(policy)
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 1000, height: 700),
            surfaces: [
                Surface(id: "floor", kind: .floor, left: 0, right: 1000, y: 700),
                Surface(id: "window-a", kind: .windowTop, left: 250, right: 750, y: 520),
            ])

        for _ in 0..<240 {
            _ = runtime.advance(
                environment: environment,
                platformContext: GameplayPlatformContext(userActive: false))
            if runtime.platformIntents["a"] != nil { break }
        }

        XCTAssertEqual(
            runtime.platformIntents["a"],
            .damageWindowOverlay("window-a"))
        XCTAssertEqual(runtime.world.body(for: EntityID("a"))?.gameplayEnergy.current, 180)
        XCTAssertEqual(runtime.platformAuthorizations["a"], .allowed)
    }

    private func combatDigest(renderHz: Int) -> CombatRuntimeDigest {
        let combat = CombatRuntime()
        combat.register(actorID: EntityID("a"), profile: CombatProfile(),
                        x: 400, yFeet: 700)
        combat.register(actorID: EntityID("b"), profile: CombatProfile(),
                        x: 600, yFeet: 700, facing: .left)
        combat.activate(.autonomous, for: EntityID("a"))
        combat.activate(.autonomous, for: EntityID("b"))
        let runtime = GameRuntime(combatRuntime: combat)
        let environment = makeScenario().desktop.combatEnvironment()
        for _ in 0..<renderHz {
            _ = runtime.advance(
                elapsedSeconds: 1.0 / Double(renderHz),
                combatEnvironment: environment)
        }
        return combat.digest
    }

    private func makeScenario() -> VirtualCombatScenario {
        VirtualCombatScenario(
            id: "unified-runtime",
            desktop: VirtualDesktop(screens: [
                VirtualScreen(id: "main", frame: LayoutRect(
                    x: 0, y: 0, width: 1000, height: 700), main: true),
            ]),
            actors: [
                VirtualCombatActor(actorID: EntityID("a"), x: 400, yFeet: 700),
                VirtualCombatActor(actorID: EntityID("b"), x: 455, yFeet: 700, facing: .left),
            ],
            inputs: [
                CombatInputEvent(frame: 0, actorID: EntityID("a"),
                                 input: FighterInputFrame(buttons: [.x])),
                CombatInputEvent(frame: 1, actorID: EntityID("a"), input: .neutral),
            ])
    }
}

private struct LegacyCombatSimulationSnapshot: Codable {
    var scenario: VirtualCombatScenario
    var desktop: VirtualDesktop
    var combat: CombatWorldCheckpoint
    var activeInputs: [String: FighterInputFrame]
}
