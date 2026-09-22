import CoreGraphics
import XCTest
import MyPetContent
import MyPetCore
@testable import MyPetEngine
import MyPetSimulation

@testable import MyPetApp

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

        props.tick(petX: 100, petYFeet: 200, facingRight: true,
                   displayHeight: 100, now: 0,
                   worldProp: SoloProp(propID: "apple", phase: .held))
        let prop = try XCTUnwrap(props.entity)

        XCTAssertTrue(prop.spatialNode.parent === hand)
        XCTAssertTrue(graph.root.children.contains { $0 === actor })
        XCTAssertEqual(prop.spatialNode.worldPosition, CGPoint(x: 130, y: 155))
    }

    func testHeldPropUsesHandSocketAsItsWorldPosition() throws {
        let props = makePropController()
        props.tick(petX: 500, petYFeet: 800, facingRight: true,
                   displayHeight: 100, now: 0,
                   worldProp: SoloProp(propID: "apple", phase: .held))
        let prop = try XCTUnwrap(props.entity)
        XCTAssertEqual(prop.spatialNode.parent?.id, "hand")
        XCTAssertEqual(prop.spatialNode.worldPosition,
                       PropEntity.holdPoint(petX: 500, petYFeet: 800,
                                             facingRight: true, displayHeight: 100))

        props.tick(petX: 700, petYFeet: 800, facingRight: false,
                   displayHeight: 100, now: 1,
                   worldProp: SoloProp(propID: "apple", phase: .held))
        XCTAssertEqual(prop.spatialNode.worldPosition,
                       PropEntity.holdPoint(petX: 700, petYFeet: 800,
                                             facingRight: false, displayHeight: 100),
                       "角色移动/转身时，持有物通过 hand socket 跟随")
    }

    func testPutDownReparentsToSceneRootAndKeepsWorldContinuity() throws {
        let props = makePropController()
        props.tick(petX: 500, petYFeet: 800, facingRight: true,
                   displayHeight: 100, now: 0,
                   worldProp: SoloProp(propID: "apple", phase: .held))
        let prop = try XCTUnwrap(props.entity)
        let handPosition = prop.spatialNode.worldPosition

        props.tick(petX: 500, petYFeet: 800, facingRight: true,
                   displayHeight: 100, now: 0,
                   worldProp: SoloProp(propID: "apple", phase: .placed, x: 560, y: 800))
        XCTAssertEqual(prop.spatialNode.parent?.id, "scene")
        XCTAssertEqual(prop.spatialNode.worldPosition, handPosition,
                       "从手部脱离时不能瞬移")

        props.tick(petX: 900, petYFeet: 800, facingRight: false,
                   displayHeight: 100, now: 0.35,
                   worldProp: SoloProp(propID: "apple", phase: .placed, x: 560, y: 800))
        XCTAssertEqual(prop.spatialNode.worldPosition, CGPoint(x: 560, y: 800))
        XCTAssertEqual(prop.x, 560)
        XCTAssertEqual(prop.footY, 800)
    }

    func testPlacedPropRemainsAtWorldRootWhenActorMoves() throws {
        let props = makePropController()
        props.tick(petX: 1200, petYFeet: 800, facingRight: true,
                   displayHeight: 100, now: 1,
                   worldProp: SoloProp(propID: "chair", phase: .placed, x: 560, y: 800))
        let prop = try XCTUnwrap(props.entity)

        XCTAssertEqual(prop.spatialNode.parent?.id, "scene")
        XCTAssertEqual(prop.spatialNode.worldPosition, CGPoint(x: 560, y: 800))
    }

    func testReplacingPropDetachesTheOldSpatialNode() throws {
        let props = makePropController()
        props.tick(petX: 100, petYFeet: 200, facingRight: true,
                   displayHeight: 100, now: 0,
                   worldProp: SoloProp(propID: "chair", phase: .placed, x: 560, y: 800))
        let old = try XCTUnwrap(props.entity)
        props.tick(petX: 100, petYFeet: 200, facingRight: true,
                   displayHeight: 100, now: 1,
                   worldProp: SoloProp(propID: "apple", phase: .held))

        XCTAssertNil(old.spatialNode.parent,
                     "替换单活动道具时，旧节点不能继续被场景根保留")
    }
}
