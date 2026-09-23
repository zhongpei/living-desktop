import XCTest
@testable import MyPetCombat
import MyPetCore
import MyPet2D

final class ProjectileTests: XCTestCase {
    private let floor = CombatEnvironment(
        bounds: CombatRect(x: 0, y: 0, width: 1200, height: 800),
        surfaces: [CombatSurface(id: "floor", kind: .floor, left: 0, right: 1200, y: 700)])

    private func makeWorld(
        projectile: ProjectileDefinition,
        targetX: Double = 600
    ) -> CombatWorld {
        let move = CombatMoveDefinition(
            id: "cast", command: .button(.d), startupFrames: 0, activeFrames: 1,
            recoveryFrames: 2,
            hit: CombatHitDefinition(damage: 0, attackBoxes: []),
            visualAction: "cast", projectile: projectile)
        let world = CombatWorld()
        world.register(
            actorID: EntityID("caster"), profile: CombatProfile(moves: [move]),
            x: 200, yFeet: 700)
        world.register(actorID: EntityID("target"), x: targetX, yFeet: 700, facing: .left)
        XCTAssertTrue(world.beginSession(
            id: "projectile-test", participants: [EntityID("caster"), EntityID("target")]))
        return world
    }

    func testOneMoveCanThrowThreeIndependentBowls() {
        let bowls = [0, 2, 4].enumerated().map { index, frame in
            ProjectileDefinition(
                id: "bowl_\(index)", spawnFrame: frame,
                spawnOffset: Vec2(x: 20, y: -50),
                velocity: Vec2(x: 10, y: 0), lifetimeFrames: 20,
                hit: CombatHitDefinition(damage: 5, hitStopFrames: 0),
                visualResourceID: "effects/wu_song/wu_bowl_projectile_loop")
        }
        let move = CombatMoveDefinition(
            id: "three_bowls", command: .button(.d), startupFrames: 0,
            activeFrames: 5, recoveryFrames: 1,
            hit: CombatHitDefinition(damage: 0, attackBoxes: []),
            visualAction: "super", projectiles: bowls)
        let world = CombatWorld()
        world.register(actorID: EntityID("caster"), profile: CombatProfile(moves: [move]), x: 200, yFeet: 700)
        world.register(actorID: EntityID("target"), x: 900, yFeet: 700, facing: .left)
        XCTAssertTrue(world.beginSession(id: "bowls", participants: [EntityID("caster"), EntityID("target")]))
        world.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("caster"))
        var spawns: [CombatEvent] = []
        for _ in 0..<5 {
            spawns += world.step(environment: floor).filter { $0.kind == .projectileSpawned }
            world.setInput(.neutral, for: EntityID("caster"))
        }
        XCTAssertEqual(spawns.count, 3)
        XCTAssertEqual(Set(world.snapshot().projectiles.map(\.entityID.raw)).count, 3)
        XCTAssertEqual(Set(world.snapshot().projectiles.map(\.definitionID)), ["bowl_0", "bowl_1", "bowl_2"])
    }

    func testProjectileSpawnsOnAuthoredFrameAndMovesThroughBodyWorld() {
        let definition = ProjectileDefinition(
            id: "petal", spawnFrame: 0, spawnOffset: Vec2(x: 20, y: -50),
            velocity: Vec2(x: 12, y: 0), lifetimeFrames: 30,
            hit: CombatHitDefinition(damage: 15, hitStopFrames: 0),
            visualResourceID: "effects/petal")
        let world = makeWorld(projectile: definition)
        world.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("caster"))

        let events = world.step(environment: floor)
        let projectile = world.snapshot().projectiles.first

        XCTAssertEqual(events.filter { $0.kind == .projectileSpawned }.count, 1)
        XCTAssertEqual(projectile?.position, Vec2(x: 232, y: 650))
        XCTAssertEqual(projectile?.velocity, Vec2(x: 12, y: 0))
        XCTAssertEqual(projectile?.visualResourceID, "effects/petal")
    }

    func testProjectileHitsEachTargetOnceWithoutRehitAndExpiresOnContact() {
        let definition = ProjectileDefinition(
            id: "petal", spawnFrame: 0, spawnOffset: Vec2(x: 20, y: -50),
            velocity: Vec2(x: 120, y: 0), lifetimeFrames: 30,
            hit: CombatHitDefinition(
                id: "petal-hit", damage: 25, hitStopFrames: 0,
                attackBoxes: [CollisionBox(x1: -6, y1: -6, x2: 6, y2: 6)],
                hitGroup: "petal"),
            visualResourceID: "effects/petal", destroyOnHit: true)
        let world = makeWorld(projectile: definition, targetX: 300)
        world.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("caster"))

        var events: [CombatEvent] = []
        for _ in 0..<8 {
            events.append(contentsOf: world.step(environment: floor))
            world.setInput(.neutral, for: EntityID("caster"))
        }

        XCTAssertEqual(world.body(for: EntityID("target"))?.hp, 975)
        XCTAssertEqual(events.filter { $0.kind == .hit }.count, 1)
        XCTAssertTrue(world.snapshot().projectiles.isEmpty)
    }

    func testPersistentProjectileDeduplicatesTargetAcrossFrames() {
        let definition = ProjectileDefinition(
            id: "field", spawnFrame: 0, spawnOffset: Vec2(x: 100, y: -50),
            velocity: Vec2(), lifetimeFrames: 4,
            hit: CombatHitDefinition(
                id: "field-hit", damage: 25, hitStopFrames: 0,
                attackBoxes: [CollisionBox(x1: -6, y1: -6, x2: 6, y2: 6)],
                hitGroup: "field"),
            visualResourceID: "effects/field", destroyOnHit: false)
        let world = makeWorld(projectile: definition, targetX: 300)
        world.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("caster"))

        var events: [CombatEvent] = []
        for _ in 0..<4 {
            events.append(contentsOf: world.step(environment: floor))
            world.setInput(.neutral, for: EntityID("caster"))
        }

        XCTAssertEqual(world.body(for: EntityID("target"))?.hp, 975)
        XCTAssertEqual(events.filter { $0.kind == .hit }.count, 1)
        XCTAssertTrue(world.snapshot().projectiles.isEmpty)
    }

    func testDestroyOnHitProjectileChoosesNearestSweptTarget() {
        let projectile = ProjectileDefinition(
            id: "line", spawnFrame: 0, spawnOffset: Vec2(x: 20, y: -50),
            velocity: Vec2(x: 220, y: 0), lifetimeFrames: 10,
            hit: CombatHitDefinition(
                damage: 25, hitStopFrames: 0,
                attackBoxes: [CollisionBox(x1: -4, y1: -4, x2: 4, y2: 4)]),
            visualResourceID: "effects/line", destroyOnHit: true)
        let move = CombatMoveDefinition(
            id: "cast", command: .button(.d), startupFrames: 0, activeFrames: 1,
            recoveryFrames: 1,
            hit: CombatHitDefinition(damage: 0, attackBoxes: []),
            visualAction: "cast", projectile: projectile)
        let world = CombatWorld()
        world.register(
            actorID: EntityID("caster"), profile: CombatProfile(moves: [move]),
            x: 200, yFeet: 700)
        world.register(actorID: EntityID("near"), x: 300, yFeet: 700, facing: .left)
        world.register(actorID: EntityID("far"), x: 360, yFeet: 700, facing: .left)
        XCTAssertTrue(world.beginSession(
            id: "ordered-impact",
            participants: [EntityID("caster"), EntityID("near"), EntityID("far")]))
        world.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("caster"))

        let events = world.step(environment: floor)

        XCTAssertEqual(world.body(for: EntityID("near"))?.hp, 975)
        XCTAssertEqual(world.body(for: EntityID("far"))?.hp, 1000)
        XCTAssertEqual(events.filter { $0.kind == .hit }.count, 1)
    }

    func testProjectileLifetimeAndBoundsExpiryAreDeterministic() {
        let lifetimeWorld = makeWorld(projectile: ProjectileDefinition(
            id: "short", spawnFrame: 0, velocity: Vec2(x: 1, y: 0),
            lifetimeFrames: 2, hit: CombatHitDefinition(damage: 1),
            visualResourceID: "effects/short"))
        lifetimeWorld.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("caster"))
        _ = lifetimeWorld.step(environment: floor)
        XCTAssertEqual(lifetimeWorld.snapshot().projectiles.count, 1)
        let lifetimeEvents = lifetimeWorld.step(environment: floor)
        XCTAssertTrue(lifetimeWorld.snapshot().projectiles.isEmpty)
        XCTAssertEqual(lifetimeEvents.filter { $0.kind == .projectileExpired }.count, 1)

        let boundsWorld = makeWorld(projectile: ProjectileDefinition(
            id: "fast", spawnFrame: 0, velocity: Vec2(x: -500, y: 0),
            lifetimeFrames: 30, hit: CombatHitDefinition(damage: 1),
            visualResourceID: "effects/fast"))
        boundsWorld.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("caster"))
        let boundsEvents = boundsWorld.step(environment: floor)
        XCTAssertTrue(boundsWorld.snapshot().projectiles.isEmpty)
        XCTAssertEqual(boundsEvents.filter { $0.kind == .projectileExpired }.count, 1)
    }

    func testProjectileCheckpointReplayProducesIdenticalSnapshotsAndEvents() {
        let world = makeWorld(projectile: ProjectileDefinition(
            id: "replay", spawnFrame: 0, velocity: Vec2(x: 9, y: 0),
            lifetimeFrames: 20, hit: CombatHitDefinition(damage: 10, hitStopFrames: 0),
            visualResourceID: "effects/replay"))
        world.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("caster"))
        _ = world.step(environment: floor)
        world.setInput(.neutral, for: EntityID("caster"))
        let restored = CombatWorld(checkpoint: world.checkpoint())

        var originalEvents: [CombatEvent] = []
        var replayEvents: [CombatEvent] = []
        for _ in 0..<10 {
            originalEvents.append(contentsOf: world.step(environment: floor))
            replayEvents.append(contentsOf: restored.step(environment: floor))
        }

        XCTAssertEqual(restored.snapshot(), world.snapshot())
        XCTAssertEqual(replayEvents, originalEvents)
    }

    func testEqualLevelOpposingProjectilesClashAndBothExpire() {
        let projectile = ProjectileDefinition(
            id: "orb", spawnFrame: 0, spawnOffset: Vec2(x: 20, y: -50),
            velocity: Vec2(x: 10, y: 0), lifetimeFrames: 30,
            hit: CombatHitDefinition(
                damage: 20, hitStopFrames: 0,
                attackBoxes: [CollisionBox(x1: -8, y1: -8, x2: 8, y2: 8)],
                clashLevel: 1),
            visualResourceID: "effects/orb")
        let move = CombatMoveDefinition(
            id: "cast", command: .button(.d), startupFrames: 0,
            activeFrames: 1, recoveryFrames: 2,
            hit: CombatHitDefinition(damage: 0, attackBoxes: []),
            visualAction: "cast", projectile: projectile)
        let world = CombatWorld()
        world.register(
            actorID: EntityID("left"), profile: CombatProfile(moves: [move]),
            x: 300, yFeet: 700)
        world.register(
            actorID: EntityID("right"), profile: CombatProfile(moves: [move]),
            x: 400, yFeet: 700, facing: .left)
        XCTAssertTrue(world.beginSession(
            id: "projectile-clash",
            participants: [EntityID("left"), EntityID("right")]))
        world.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("left"))
        world.setInput(FighterInputFrame(buttons: [.d]), for: EntityID("right"))

        var events: [CombatEvent] = []
        for _ in 0..<4 {
            events += world.step(environment: floor)
            world.setInput(.neutral, for: EntityID("left"))
            world.setInput(.neutral, for: EntityID("right"))
        }

        XCTAssertEqual(events.filter { $0.kind == .clash }.count, 1)
        XCTAssertTrue(world.snapshot().projectiles.isEmpty)
        XCTAssertEqual(world.body(for: EntityID("left"))?.hp, 1000)
        XCTAssertEqual(world.body(for: EntityID("right"))?.hp, 1000)
    }
}
