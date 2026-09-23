import XCTest
import MyPetCore
@testable import MyPet2D

final class GeometryAndBodyWorldTests: XCTestCase {
    func testRectOverlapIsStrictAtTouchingEdgeAndMirrorsAroundAxis() {
        let left = Rect2D(x: 0, y: 0, width: 10, height: 10)
        XCTAssertFalse(left.overlaps(Rect2D(x: 10, y: 0, width: 3, height: 3)))
        XCTAssertTrue(left.overlaps(Rect2D(x: 9.999, y: 0, width: 3, height: 3)))
        XCTAssertEqual(
            Rect2D(x: 2, y: -5, width: 6, height: 5).placed(
                at: Vec2(x: 100, y: 50), facing: .left),
            Rect2D(x: 92, y: 45, width: 6, height: 5))
    }

    func testSweepFindsEdgeContactAndHonorsParallelEpsilon() throws {
        let moving = Rect2D(x: 0, y: 0, width: 10, height: 10)
        let target = Rect2D(x: 20, y: 0, width: 10, height: 10)
        let hit = try XCTUnwrap(moving.sweep(
            displacement: Vec2(x: 10, y: 0), against: target))
        XCTAssertEqual(hit.time, 1, accuracy: 1e-9)
        XCTAssertEqual(hit.normal, Vec2(x: -1, y: 0))

        XCTAssertNil(moving.sweep(
            displacement: Vec2(x: 10, y: 0),
            against: Rect2D(x: 20, y: 10.001, width: 10, height: 10),
            epsilon: 0.0001))
        XCTAssertNotNil(moving.sweep(
            displacement: Vec2(x: 10, y: 0),
            against: Rect2D(x: 20, y: 10.001, width: 10, height: 10),
            epsilon: 0.01))
    }

    func testBodyWorldOwnsGravityLandingAndMovingSurfaceAttachment() {
        let actor = EntityID("actor")
        let world = BodyWorld()
        world.register(
            BodyDefinition(entityID: actor, pushRadius: 20),
            state: BodyState(entityID: actor, position: Vec2(x: 300, y: 399.9)))

        var environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 1200, height: 800),
            surfaces: [Surface(
                id: "window:7:top", kind: .windowTop,
                left: 200, right: 600, y: 400, hostID: EntityID("window:7"))])
        world.update(actor) { $0.locomotion = .airborne }
        world.advance(environment)
        XCTAssertEqual(world.state(for: actor)?.currentSurfaceID, "window:7:top")

        environment = BodyEnvironment(
            bounds: environment.bounds,
            surfaces: [Surface(
                id: "window:7:top", kind: .windowTop,
                left: 500, right: 900, y: 520, hostID: EntityID("window:7"))])
        world.advance(environment)
        XCTAssertEqual(world.state(for: actor)?.position.y, 520)
        XCTAssertGreaterThanOrEqual(world.state(for: actor)?.position.x ?? 0, 520)
    }

    func testPushResolutionUsesStableEntityOrder() {
        func run(registrationOrder: [String]) -> BodyWorldSnapshot {
            let world = BodyWorld()
            for id in registrationOrder {
                let x = id == "a" ? 100.0 : 120.0
                world.register(
                    BodyDefinition(entityID: EntityID(id), pushRadius: 20),
                    state: BodyState(entityID: EntityID(id), position: Vec2(x: x, y: 300)))
            }
            let environment = BodyEnvironment(
                bounds: Rect2D(x: 0, y: 0, width: 500, height: 400),
                surfaces: [Surface(id: "floor", kind: .floor, left: 0, right: 500, y: 300)])
            world.advance(environment)
            return world.snapshot()
        }

        XCTAssertEqual(run(registrationOrder: ["a", "b"]), run(registrationOrder: ["b", "a"]))
    }

    func testSimulationDisabledBodyIsNotMovedByPushResolution() {
        let frozen = EntityID("frozen")
        let active = EntityID("active")
        let world = BodyWorld()
        world.register(
            BodyDefinition(entityID: frozen, pushRadius: 20, simulationEnabled: false),
            state: BodyState(entityID: frozen, position: Vec2(x: 100, y: 300)))
        world.register(
            BodyDefinition(entityID: active, pushRadius: 20),
            state: BodyState(entityID: active, position: Vec2(x: 120, y: 300)))
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 500, height: 400),
            surfaces: [Surface(id: "floor", kind: .floor, left: 0, right: 500, y: 300)])

        world.advance(environment)

        XCTAssertEqual(world.state(for: frozen)?.position.x, 100)
        XCTAssertEqual(world.state(for: active)?.position.x, 120)
    }

    func testCheckpointRestoresTheAuthoritativeBodyState() throws {
        let actor = EntityID("actor")
        let world = BodyWorld()
        world.register(
            BodyDefinition(entityID: actor),
            state: BodyState(
                entityID: actor,
                position: Vec2(x: 120, y: 100),
                velocity: Vec2(x: 2, y: 1),
                locomotion: .airborne))
        let environment = BodyEnvironment(
            bounds: Rect2D(x: 0, y: 0, width: 500, height: 400),
            surfaces: [Surface(id: "floor", kind: .floor, left: 0, right: 500, y: 300)])
        world.advance(environment)

        let data = try JSONEncoder().encode(world.checkpoint())
        let restored = BodyWorld(checkpoint: try JSONDecoder().decode(
            BodyWorldCheckpoint.self, from: data))
        XCTAssertEqual(restored.snapshot(), world.snapshot())
        restored.advance(environment)
        world.advance(environment)
        XCTAssertEqual(restored.snapshot(), world.snapshot())
    }

    func testCheckpointPreservesDragVelocitySampling() throws {
        let actor = EntityID("actor")
        let world = BodyWorld()
        world.register(
            BodyDefinition(entityID: actor),
            state: BodyState(entityID: actor, position: Vec2(x: 20, y: 30)))
        world.beginDrag(entityID: actor, position: Vec2(x: 20, y: 30))
        let restored = BodyWorld(checkpoint: try JSONDecoder().decode(
            BodyWorldCheckpoint.self,
            from: JSONEncoder().encode(world.checkpoint())))

        world.drag(entityID: actor, position: Vec2(x: 80, y: 60), elapsedSeconds: 0.1)
        restored.drag(entityID: actor, position: Vec2(x: 80, y: 60), elapsedSeconds: 0.1)
        XCTAssertEqual(restored.snapshot(), world.snapshot())
    }
}
