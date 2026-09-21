import CoreGraphics
import XCTest

@testable import MyPet

/// 检查 SceneGraph 已经接入当前道具运行时，而不只是一个孤立的测试模型。
final class SceneGraphRuntimeTests: XCTestCase {

    private func makePropController() -> PropController {
        let props = PropController(
            library: ClipLibrary(characterID: "test", cellSize: CGSize(width: 192, height: 208)))
        props.panelsEnabled = false
        return props
    }

    func testPropControllerUsesTheInjectedSceneGraphAndActorSocket() throws {
        let graph = SceneGraph(rootID: "shared-scene")
        let actor = SceneNode(id: "alice")
        let hand = try actor.addSocket("hand")
        try graph.add(actor)
        let props = PropController(
            library: ClipLibrary(characterID: "test", cellSize: CGSize(width: 192, height: 208)),
            sceneGraph: graph, actorNode: actor, handSocket: hand)
        props.panelsEnabled = false

        let prop = try XCTUnwrap(props.spawnHeld("apple", petX: 100, petYFeet: 200,
                                                 facingRight: true, now: 0))
        props.tick(petX: 100, petYFeet: 200, facingRight: true,
                   displayHeight: 100, now: 0)

        XCTAssertTrue(prop.spatialNode.parent === hand)
        XCTAssertTrue(graph.root.children.contains { $0 === actor })
        XCTAssertEqual(prop.spatialNode.worldPosition, CGPoint(x: 130, y: 155))
    }

    func testHeldPropUsesHandSocketAsItsWorldPosition() throws {
        let props = makePropController()
        let prop = try XCTUnwrap(props.spawnHeld("apple", petX: 500, petYFeet: 800,
                                                 facingRight: true, now: 0))

        props.tick(petX: 500, petYFeet: 800, facingRight: true,
                   displayHeight: 100, now: 0)
        XCTAssertEqual(prop.spatialNode.parent?.id, "hand")
        XCTAssertEqual(prop.spatialNode.worldPosition,
                       PropEntity.holdPoint(petX: 500, petYFeet: 800,
                                             facingRight: true, displayHeight: 100))

        props.tick(petX: 700, petYFeet: 800, facingRight: false,
                   displayHeight: 100, now: 1)
        XCTAssertEqual(prop.spatialNode.worldPosition,
                       PropEntity.holdPoint(petX: 700, petYFeet: 800,
                                             facingRight: false, displayHeight: 100),
                       "角色移动/转身时，持有物通过 hand socket 跟随")
    }

    func testPutDownReparentsToSceneRootAndKeepsWorldContinuity() throws {
        let props = makePropController()
        let prop = try XCTUnwrap(props.spawnHeld("apple", petX: 500, petYFeet: 800,
                                                 facingRight: true, now: 0))
        props.tick(petX: 500, petYFeet: 800, facingRight: true,
                   displayHeight: 100, now: 0)
        let handPosition = prop.spatialNode.worldPosition

        XCTAssertTrue(props.putDown(at: 560, footY: 800, now: 0, ttl: 30))
        XCTAssertEqual(prop.spatialNode.parent?.id, "scene")
        XCTAssertEqual(prop.spatialNode.worldPosition, handPosition,
                       "从手部脱离时不能瞬移")

        props.tick(petX: 900, petYFeet: 800, facingRight: false,
                   displayHeight: 100, now: 0.35)
        XCTAssertEqual(prop.spatialNode.worldPosition, CGPoint(x: 560, y: 800))
        XCTAssertEqual(prop.x, 560)
        XCTAssertEqual(prop.footY, 800)
    }

    func testPlacedPropRemainsAtWorldRootWhenActorMoves() throws {
        let props = makePropController()
        let prop = try XCTUnwrap(props.spawnPlaced("chair", at: 560, footY: 800, now: 0))

        props.tick(petX: 1200, petYFeet: 800, facingRight: true,
                   displayHeight: 100, now: 1)

        XCTAssertEqual(prop.spatialNode.parent?.id, "scene")
        XCTAssertEqual(prop.spatialNode.worldPosition, CGPoint(x: 560, y: 800))
    }

    func testReplacingPropDetachesTheOldSpatialNode() throws {
        let props = makePropController()
        let old = try XCTUnwrap(props.spawnPlaced("chair", at: 560, footY: 800, now: 0))
        _ = props.spawnHeld("apple", petX: 100, petYFeet: 200,
                            facingRight: true, now: 1)

        XCTAssertNil(old.spatialNode.parent,
                     "替换单活动道具时，旧节点不能继续被场景根保留")
    }
}
