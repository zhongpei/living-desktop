import XCTest
@testable import MyPetCore
@testable import MyPetEngine
import MyPetSimulation

final class KernelTests: XCTestCase {
    func testScenarioWindowEntityGetsSameDefaultSlotsAsDynamicRegistration() {
        let window = EntityState(id: EntityID("42"), kind: .window)
        let scenario = HarnessScenario(id: "entity-window", entities: [window])
        let kernel = GameKernel(scenario: scenario)
        XCTAssertEqual(kernel.world.slots["42/top.left"]?.status, .free)
        XCTAssertEqual(kernel.world.slots["42/top.right"]?.status, .free)
    }

    func testRegisteredWindowGetsPerchSlotsAndLifecycleInvalidatesThem() {
        let window = EntityState(id: EntityID("42"), kind: .window)
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: window), atTick: 0)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.slots["42/top.left"]?.status, .free)
        XCTAssertEqual(kernel.world.slots["42/top.right"]?.status, .free)

        let request = BehaviorRequest(
            id: "visit-window", actorID: EntityID("pet"), intent: "move",
            priority: .ambient, slot: kernel.world.slots["42/top.left"]?.ref,
            durationTicks: 100)
        kernel.enqueue(GameEvent(kind: .registerEntity,
                                 entity: EntityState(id: request.actorID, kind: .actor)), atTick: 1)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: 1)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.behaviors[request.id]?.status, .running)

        kernel.enqueue(GameEvent(kind: .windowChanged, entity: EntityState(
            id: window.id, kind: .window, revision: 1)), atTick: 2)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.behaviors[request.id]?.status, .cancelled)

        kernel.enqueue(GameEvent(kind: .destroyEntity, entityID: window.id), atTick: 3)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.slots["42/top.left"]?.status, .disabled)

        kernel.enqueue(GameEvent(kind: .windowChanged, entity: EntityState(
            id: window.id, kind: .window, revision: 2)), atTick: 4)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.slots["42/top.left"]?.status, .free)
        XCTAssertEqual(kernel.world.slots["42/top.right"]?.status, .free)
        XCTAssertTrue(kernel.manualViolations.isEmpty)
    }

    func testDestroyWindowCancelsSlotOnlyBehavior() {
        let window = EntityState(id: EntityID("42"), kind: .window)
        let actor = EntityState(id: EntityID("pet"), kind: .actor)
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: window), atTick: 0)
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: actor), atTick: 0)
        _ = kernel.tick()
        let request = BehaviorRequest(
            id: "perch", actorID: actor.id, intent: "perch", priority: .ambient,
            slot: kernel.world.slots["42/top.left"]?.ref, durationTicks: 100)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: 1)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.behaviors[request.id]?.status, .running)
        kernel.enqueue(GameEvent(kind: .destroyEntity, entityID: window.id), atTick: 2)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.behaviors[request.id]?.status, .cancelled)
    }

    func testInvariantCheckerReportsSpatialAttachmentCycles() {
        let a = EntityState(id: EntityID("a"), kind: .actor)
        let b = EntityState(id: EntityID("b"), kind: .actor)
        let world = WorldState(
            entities: [a.id.raw: a, b.id.raw: b],
            spatialAttachments: [
                a.id.raw: SpatialAttachment(
                    childID: a.id, parentID: b.id, socketID: "contact",
                    slotRef: SlotRef(entityID: b.id, slotID: "contact", revision: 0)),
                b.id.raw: SpatialAttachment(
                    childID: b.id, parentID: a.id, socketID: "contact",
                    slotRef: SlotRef(entityID: a.id, slotID: "contact", revision: 0))
            ])

        let violations = InvariantChecker.check(world, tick: 7)

        XCTAssertEqual(
            violations.filter { $0.code == "spatial_attachment_cycle" }.count, 1)
        XCTAssertTrue(violations.contains {
            $0.code == "spatial_attachment_cycle" && $0.message == "a->b"
        })
    }

    func testOnlyOneActorCanClaimSingleCapacitySlot() {
        let scenario = ScenarioLoader.builtInSlotRace()
        let (_, kernel) = ScenarioRunner.run(scenario)

        XCTAssertEqual(kernel.world.slots["window42/top.right"]?.status, .free)
        XCTAssertEqual(kernel.world.behaviors["a-perch"]?.status, .completed)
        XCTAssertEqual(kernel.world.behaviors["b-perch"]?.status, .rejected)
        XCTAssertTrue(kernel.manualViolations.isEmpty)
    }

    func testMultiCapacitySlotKeepsIndependentOccupants() {
        let window = EntityState(id: EntityID("window"), kind: .window)
        let actors = (1...3).map { EntityState(id: EntityID("actor\($0)"), kind: .actor) }
        let slot = InteractionSlot(entityID: window.id, slotID: "bench", capacity: 2)
        let requests = actors.map { actor in
            BehaviorRequest(
                id: "perch-\(actor.id.raw)", actorID: actor.id, intent: "perch",
                priority: .story, slot: slot.ref, durationTicks: 1, occupySlotOnSuccess: true)
        }
        let kernel = GameKernel()
        for entity in [window] + actors {
            kernel.enqueue(GameEvent(kind: .registerEntity, entity: entity), atTick: 0)
        }
        kernel.enqueue(GameEvent(kind: .createSlot, slot: slot), atTick: 0)
        for request in requests {
            kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: 0)
        }
        _ = kernel.tick()

        let occupied = kernel.world.slots[slot.key]
        XCTAssertEqual(occupied?.occupants.count, 2)
        XCTAssertEqual(Set(occupied?.occupants.map(\.actorID.raw) ?? []), Set(["actor1", "actor2"]))
        XCTAssertEqual(kernel.world.behaviors[requests[2].id]?.status, .rejected)
        XCTAssertEqual(kernel.world.spatialAttachments["actor1"]?.parentID.raw, "window")
        XCTAssertEqual(kernel.world.spatialAttachments["actor2"]?.parentID.raw, "window")

        kernel.enqueue(GameEvent(kind: .destroyEntity, entityID: actors[0].id), atTick: 1)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.slots[slot.key]?.occupants.map(\.actorID.raw), ["actor2"])
        XCTAssertEqual(kernel.world.slots[slot.key]?.status, .occupied)
        XCTAssertNil(kernel.world.spatialAttachments["actor1"])
        XCTAssertEqual(kernel.world.spatialAttachments["actor2"]?.parentID.raw, "window")
        XCTAssertTrue(kernel.manualViolations.isEmpty)
    }

    func testReleaseSlotCanRemoveOnlyOneScopedOccupant() {
        let surface = EntityState(id: EntityID("surface"), kind: .surface)
        let actors = [
            EntityState(id: EntityID("giver"), kind: .actor),
            EntityState(id: EntityID("receiver"), kind: .actor)
        ]
        let slot = InteractionSlot(entityID: surface.id, slotID: "bench", capacity: 2)
        let requests = actors.map { actor in
            BehaviorRequest(
                id: "sit-\(actor.id.raw)", actorID: actor.id, intent: "sit",
                priority: .story, slot: slot.ref, durationTicks: 1, occupySlotOnSuccess: true)
        }
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: surface), atTick: 0)
        for actor in actors {
            kernel.enqueue(GameEvent(kind: .registerEntity, entity: actor), atTick: 0)
        }
        kernel.enqueue(GameEvent(kind: .createSlot, slot: slot), atTick: 0)
        for request in requests {
            kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: 0)
        }
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.slots[slot.key]?.occupants.count, 2)

        kernel.enqueue(GameEvent(
            kind: .releaseSlot, behaviorID: requests[0].id, slotRef: slot.ref), atTick: 1)
        _ = kernel.tick()

        XCTAssertEqual(kernel.world.slots[slot.key]?.occupants.map(\.actorID.raw), ["receiver"])
        XCTAssertEqual(kernel.world.slots[slot.key]?.status, .occupied)
        XCTAssertNil(kernel.world.spatialAttachments["giver"])
        XCTAssertEqual(kernel.world.spatialAttachments["receiver"]?.parentID.raw, "surface")
        XCTAssertTrue(kernel.trace.contains {
            $0.detail == "releaseSlot:surface/bench:scope=sit-giver"
        })
        XCTAssertTrue(kernel.manualViolations.isEmpty)
    }

    func testStalePlanIsRejectedAfterForegroundChange() {
        let actor = EntityState(id: EntityID("actor"), kind: .actor)
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: actor), atTick: 0)
        kernel.enqueue(GameEvent(kind: .foregroundChanged, actorID: actor.id), atTick: 0)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: BehaviorRequest(
            id: "stale", actorID: actor.id, intent: "old", priority: .brainReactive, planEpoch: 0
        )), atTick: 0)
        _ = kernel.tick()

        XCTAssertEqual(kernel.world.behaviors["stale"]?.status, .rejected)
        XCTAssertEqual(kernel.world.planEpochs["actor"], 1)
    }

    func testForegroundChangePreemptsAmbientAndStoryBehaviors() {
        let ambientActor = EntityState(id: EntityID("ambient-actor"), kind: .actor)
        let storyActor = EntityState(id: EntityID("story-actor"), kind: .actor)
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: ambientActor), atTick: 0)
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: storyActor), atTick: 0)
        _ = kernel.tick()

        let ambient = BehaviorRequest(
            id: "ambient", actorID: ambientActor.id, intent: "idle", priority: .ambient, durationTicks: 20)
        let story = BehaviorRequest(
            id: "story", actorID: storyActor.id, intent: "scene", priority: .story, durationTicks: 20)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: ambient), atTick: 1)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: story), atTick: 1)
        _ = kernel.tick()

        kernel.enqueue(GameEvent(kind: .foregroundChanged), atTick: 2)
        _ = kernel.tick()

        XCTAssertEqual(kernel.world.behaviors[ambient.id]?.status, .cancelled)
        XCTAssertEqual(kernel.world.behaviors[story.id]?.status, .cancelled)
        XCTAssertEqual(kernel.world.planEpochs[ambientActor.id.raw], 1)
        XCTAssertEqual(kernel.world.planEpochs[storyActor.id.raw], 1)
    }

    func testStoryInterruptionPolicyCanKeepStoryRunningThroughExternalSignals() {
        let actor = EntityState(id: EntityID("story-actor"), kind: .actor)
        let kernel = GameKernel(
            storyInterruptionPolicy: StoryInterruptionPolicy(foreground: false, content: false))
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: actor), atTick: 0)
        _ = kernel.tick()

        let story = BehaviorRequest(
            id: "story", actorID: actor.id, intent: "scene", priority: .story,
            durationTicks: 20)
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: story), atTick: 1)
        _ = kernel.tick()
        XCTAssertEqual(kernel.world.behaviors[story.id]?.status, .running)

        let observation = InputObservation(
            id: "chat-1", pluginID: "chat-content", channel: .chat,
            appName: "WeChat", text: "hello", capturedAtTick: 2)
        kernel.enqueue(GameEvent(kind: .foregroundChanged), atTick: 2)
        kernel.enqueue(GameEvent(
            kind: .contentObservation,
            inputObservation: observation,
            inputPreemptive: true,
            inputPriority: .urgentReactive), atTick: 2)
        _ = kernel.tick()

        XCTAssertEqual(kernel.world.behaviors[story.id]?.status, .running)
        XCTAssertEqual(kernel.world.planEpochs[actor.id.raw], 2)
        XCTAssertNotNil(kernel.world.inputObservations[observation.id])
    }

    func testEffectsCommitOnlyOnSuccess() {
        let actor = EntityState(id: EntityID("actor"), kind: .actor)
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: actor), atTick: 0)
        _ = kernel.tick()

        let request = BehaviorRequest(
            id: "argue", actorID: actor.id, intent: "argue", priority: .story,
            effectsOnSuccess: [.relationDelta("actor/other/tension", 0.2)]
        )
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: 1)
        kernel.enqueue(GameEvent(kind: .cancelBehavior, behaviorID: request.id), atTick: 1)
        _ = kernel.tick()

        XCTAssertEqual(kernel.world.relationValues["actor/other/tension"], nil)
    }

    func testHigherPriorityRequestPreemptsLowerPriorityRequest() {
        let actor = EntityState(id: EntityID("actor"), kind: .actor)
        let kernel = GameKernel()
        kernel.enqueue(GameEvent(kind: .registerEntity, entity: actor), atTick: 0)
        _ = kernel.tick()

        let ambient = BehaviorRequest(
            id: "ambient", actorID: actor.id, intent: "idle", priority: .ambient, durationTicks: 20
        )
        let urgent = BehaviorRequest(
            id: "urgent", actorID: actor.id, intent: "react", priority: .urgentReactive, durationTicks: 1
        )
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: ambient), atTick: 1)
        _ = kernel.tick()
        kernel.enqueue(GameEvent(kind: .behaviorRequest, request: urgent), atTick: 2)
        _ = kernel.tick()

        XCTAssertEqual(kernel.world.behaviors["ambient"]?.status, .cancelled)
        XCTAssertEqual(kernel.world.behaviors["urgent"]?.status, .completed)
    }

    func testSceneRuntimeUsesTickOnlyAndRaceHasOneWinner() {
        let program = SceneProgram(id: "race", root: .race([.wait(2), .wait(4)]))
        let runtime = SceneRuntime(program: program)
        XCTAssertEqual(runtime.tick().status, .running)
        let result = runtime.tick()
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.winner, 0)
    }

    func testSceneRuntimeTimeoutIsTerminal() {
        let program = SceneProgram(id: "timeout", root: .timeout(2, .wait(10)))
        let runtime = SceneRuntime(program: program)
        XCTAssertEqual(runtime.tick().status, .running)
        XCTAssertEqual(runtime.tick().status, .timedOut)
        XCTAssertEqual(runtime.tick().status, .timedOut)
    }

    func testSceneRuntimeKeepsNestedSequenceAndParallelCursors() {
        let sequence = SceneRuntime(program: SceneProgram(
            id: "nested-sequence",
            root: .sequence([.wait(1), .action(.named("wave")), .wait(1)])))
        XCTAssertEqual(sequence.tick().status, .running)
        XCTAssertEqual(sequence.tick().status, .running)
        XCTAssertEqual(sequence.tick().status, .completed)

        let parallel = SceneRuntime(program: SceneProgram(
            id: "nested-parallel",
            root: .parallel([
                .sequence([.wait(1), .action(.named("wave"))]),
                .wait(3)
            ])))
        XCTAssertEqual(parallel.tick().status, .running)
        XCTAssertEqual(parallel.tick().status, .running)
        XCTAssertEqual(parallel.tick().status, .completed)
    }

    func testSceneRuntimeConditionAndRaceAreTickDeterministic() {
        let runtime = SceneRuntime(program: SceneProgram(
            id: "condition",
            root: .sequence([.waitUntilFact("ready"), .action(.named("launch"))])))
        XCTAssertEqual(runtime.tick().status, .running)
        XCTAssertEqual(runtime.tick(validFacts: ["ready"]).status, .completed)

        let race = SceneRuntime(program: SceneProgram(
            id: "tie",
            root: .race([.sequence([.wait(1), .action(.named("a"))]), .wait(2)])))
        XCTAssertEqual(race.tick().status, .running)
        let result = race.tick()
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.winner, 0)
    }

    func testReplayProducesIdenticalTraceAndDigest() {
        let replay = ScenarioRunner.replay(ScenarioLoader.builtInSlotRace())
        XCTAssertTrue(replay.matched)
        XCTAssertNil(replay.firstDifference)
        XCTAssertEqual(replay.firstDigest, replay.secondDigest)
    }

    func testKernelSnapshotRestoresPendingEventsAndTrace() {
        let scenario = ScenarioLoader.builtInSlotRace()
        let first = GameKernel(scenario: scenario)
        _ = first.run(ticks: 2)
        let snapshot = first.snapshot()
        _ = first.run(ticks: 4)

        let restored = GameKernel(snapshot: snapshot)
        _ = restored.run(ticks: 4)
        XCTAssertEqual(restored.world.stableDigest(), first.world.stableDigest())
        XCTAssertEqual(restored.trace, first.trace)
        XCTAssertEqual(restored.inbox.pendingEvents, first.inbox.pendingEvents)
        XCTAssertEqual(restored.inbox.sequence, first.inbox.sequence)
    }

    func testPersistentInvariantIsReportedPerTickWithoutHistoryDuplication() {
        let deadWindow = EntityState(id: EntityID("dead-window"), kind: .window, alive: false)
        let scenario = HarnessScenario(
            id: "persistent-invariant",
            durationTicks: 2,
            entities: [deadWindow],
            slots: [InteractionSlot(entityID: deadWindow.id, slotID: "top")],
            requireAllClaimsReleased: false)
        let kernel = GameKernel(scenario: scenario)

        let first = kernel.tick()
        let second = kernel.tick()

        XCTAssertEqual(first.violations.map(\.code), ["destroyed_window_has_live_slot"])
        XCTAssertEqual(second.violations.map(\.code), ["destroyed_window_has_live_slot"])
        XCTAssertTrue(kernel.manualViolations.isEmpty)
    }

    func testSpatialSafetyFindsOffscreenOcclusionAndOverlap() {
        let snapshot = SpatialSnapshot(
            virtualBounds: LayoutRect(x: 0, y: 0, width: 1000, height: 800),
            actors: [
                LayoutActor(id: EntityID("a"), frame: LayoutRect(x: -10, y: 20, width: 120, height: 180), zIndex: 0),
                LayoutActor(id: EntityID("b"), frame: LayoutRect(x: 40, y: 50, width: 120, height: 180), zIndex: 0)
            ],
            occluders: [LayoutOccluder(id: EntityID("window"), frame: LayoutRect(x: 0, y: 0, width: 200, height: 200), zIndex: 10)]
        )
        let codes = Set(SpatialSafety.check(snapshot).map(\.code))
        XCTAssertTrue(codes.contains("actor_outside_virtual_bounds"))
        XCTAssertTrue(codes.contains("actor_occluded"))
        XCTAssertTrue(codes.contains("actor_overlap"))
    }

    func testSpatialSafetyFitAndSeparateProduceVisibleFrames() {
        let bounds = LayoutRect(x: 0, y: 0, width: 300, height: 200)
        let actors = SpatialSafety.separate([
            LayoutActor(id: EntityID("a"), frame: LayoutRect(x: -20, y: -10, width: 150, height: 100)),
            LayoutActor(id: EntityID("b"), frame: LayoutRect(x: 30, y: 0, width: 150, height: 100))
        ], in: bounds)
        XCTAssertEqual(actors.count, 2)
        XCTAssertTrue(actors.allSatisfy { bounds.contains($0.frame) })
        XCTAssertTrue(SpatialSafety.check(SpatialSnapshot(virtualBounds: bounds, actors: actors)).isEmpty)
    }

    func testSpatialSafetyCompactsRawAnchorsBeforeBoundaryClamping() {
        let bounds = LayoutRect(x: 0, y: 0, width: 160, height: 120)
        let actors = [
            LayoutActor(id: EntityID("a"), frame: LayoutRect(x: 0, y: 40, width: 20, height: 28)),
            LayoutActor(id: EntityID("b"), frame: LayoutRect(x: 34, y: 40, width: 20, height: 28)),
            LayoutActor(id: EntityID("c"), frame: LayoutRect(x: 96, y: 40, width: 20, height: 28)),
            LayoutActor(id: EntityID("d"), frame: LayoutRect(x: 124, y: 40, width: 20, height: 28)),
            LayoutActor(id: EntityID("e"), frame: LayoutRect(x: 140, y: 40, width: 20, height: 28)),
        ]

        let placed = SpatialSafety.separate(actors, in: bounds, gap: 4)
        XCTAssertTrue(bounds.contains(placed[0].frame) && bounds.contains(placed[4].frame))
        XCTAssertTrue(SpatialSafety.check(SpatialSnapshot(virtualBounds: bounds, actors: placed)).isEmpty)
        XCTAssertLessThanOrEqual(placed.map(\.frame.maxX).max() ?? .infinity, bounds.maxX)
    }

    func testPanelPlacementKeepsCharacterVisibleAboveMaximizedWindow() {
        let bounds = LayoutRect(x: 0, y: 0, width: 1000, height: 800)
        let actor = SpatialSafety.placeActor(
            id: EntityID("pet"), anchorX: 500, feetY: 20,
            width: 100, height: 160, baselineRatio: 0.88, in: bounds)
        XCTAssertTrue(bounds.contains(actor.frame))
        XCTAssertEqual(actor.frame.minY, bounds.minY)

        let window = LayoutOccluder(id: EntityID("maximized"), frame: LayoutRect(x: 300, y: 100, width: 400, height: 400), zIndex: 200)
        let moved = SpatialSafety.placeActor(
            id: EntityID("pet"), anchorX: 500, feetY: 310,
            width: 100, height: 160, baselineRatio: 0.88,
            in: bounds, zIndex: 100, occluders: [window])
        XCTAssertTrue(SpatialSafety.check(SpatialSnapshot(virtualBounds: bounds, actors: [moved], occluders: [window])).isEmpty)
    }

    func testPanelPlacementSearchesSideWhenOccludersBlockBothVerticalPaths() {
        let bounds = LayoutRect(x: 0, y: 0, width: 1000, height: 600)
        let occluders = [
            LayoutOccluder(id: EntityID("upper"), frame: LayoutRect(x: 350, y: 0, width: 300, height: 270), zIndex: 200),
            LayoutOccluder(id: EntityID("lower"), frame: LayoutRect(x: 350, y: 330, width: 300, height: 270), zIndex: 200),
        ]
        let actor = SpatialSafety.placeActor(
            id: EntityID("pet"), anchorX: 500, feetY: 300,
            width: 120, height: 120, baselineRatio: 0.88,
            in: bounds, zIndex: 100, occluders: occluders)

        XCTAssertTrue(SpatialSafety.check(SpatialSnapshot(
            virtualBounds: bounds, actors: [actor], occluders: occluders)).isEmpty)
        XCTAssertTrue(actor.frame.maxX <= occluders[0].frame.minX || actor.frame.minX >= occluders[0].frame.maxX)
    }

    func testSpatialSafetyHandlesManyActorsWithoutOverlapOrEscape() {
        let bounds = LayoutRect(x: 0, y: 0, width: 640, height: 360)
        let actors = (0..<24).map { index in
            LayoutActor(
                id: EntityID("actor-\(index)"),
                frame: LayoutRect(x: 280, y: 130, width: 120, height: 180))
        }
        let placed = SpatialSafety.separate(actors, in: bounds, gap: 2)
        XCTAssertEqual(placed.count, actors.count)
        XCTAssertTrue(SpatialSafety.check(SpatialSnapshot(virtualBounds: bounds, actors: placed)).isEmpty)
    }

    func testSpatialLayoutCoordinatorSeparatesAndReleasesActorsDeterministically() {
        let bounds = LayoutRect(x: 0, y: 0, width: 320, height: 200)
        let coordinator = SpatialLayoutCoordinator()
        let first = LayoutActor(
            id: EntityID("rei"), frame: LayoutRect(x: 100, y: 20, width: 120, height: 160))
        let second = LayoutActor(
            id: EntityID("eva"), frame: LayoutRect(x: 100, y: 20, width: 120, height: 160))

        _ = coordinator.update(first, in: bounds)
        let placedSecond = coordinator.update(second, in: bounds)
        XCTAssertEqual(placedSecond.id, EntityID("eva"))
        XCTAssertTrue(SpatialSafety.check(SpatialSnapshot(
            virtualBounds: bounds, actors: coordinator.snapshot)).isEmpty)

        coordinator.remove(EntityID("rei"))
        XCTAssertEqual(coordinator.snapshot.map(\.id), [EntityID("eva")])
        XCTAssertTrue(bounds.contains(coordinator.actor(EntityID("eva"))!.frame))
    }

    func testSpatialLayoutCoordinatorKeepsDisplaysIndependent() {
        let left = LayoutRect(x: 0, y: 0, width: 320, height: 200)
        let right = LayoutRect(x: 1920, y: 0, width: 320, height: 200)
        let coordinator = SpatialLayoutCoordinator()
        let leftActor = LayoutActor(id: EntityID("left"), frame: LayoutRect(x: 100, y: 20, width: 120, height: 160))
        let rightActor = LayoutActor(id: EntityID("right"), frame: LayoutRect(x: 2020, y: 20, width: 120, height: 160))

        _ = coordinator.update(leftActor, in: left, groupID: "display-left")
        _ = coordinator.update(rightActor, in: right, groupID: "display-right")

        XCTAssertTrue(left.contains(coordinator.actor(EntityID("left"))!.frame))
        XCTAssertTrue(right.contains(coordinator.actor(EntityID("right"))!.frame))
        XCTAssertTrue(SpatialSafety.check(SpatialSnapshot(
            virtualBounds: left, actors: [coordinator.actor(EntityID("left"))!])).isEmpty)
        XCTAssertTrue(SpatialSafety.check(SpatialSnapshot(
            virtualBounds: right, actors: [coordinator.actor(EntityID("right"))!])).isEmpty)
    }
}
