import CoreGraphics
import XCTest

@testable import MyPet

final class SceneGraphTests: XCTestCase {

    func testWorldPositionIncludesParentPositionAndScale() throws {
        let scene = SceneGraph()
        let actor = SceneNode(id: "alice",
                              localPosition: CGPoint(x: 100, y: 200),
                              localScale: CGSize(width: 2, height: 3))
        try scene.add(actor)

        let hand = try actor.addSocket("hand", at: CGPoint(x: 10, y: 20))
        let apple = SceneNode(id: "apple", localPosition: CGPoint(x: 4, y: 5))
        try hand.addChild(apple)

        XCTAssertEqual(apple.worldPosition.x, 128, accuracy: 0.001)
        XCTAssertEqual(apple.worldPosition.y, 275, accuracy: 0.001)
        XCTAssertEqual(apple.worldScale.width, 2, accuracy: 0.001)
        XCTAssertEqual(apple.worldScale.height, 3, accuracy: 0.001)

        actor.localPosition = CGPoint(x: 300, y: 400)
        XCTAssertEqual(apple.worldPosition.x, 328, accuracy: 0.001)
        XCTAssertEqual(apple.worldPosition.y, 475, accuracy: 0.001)
    }

    func testSocketAttachmentFollowsTheActorButNotAnUnrelatedActor() throws {
        let scene = SceneGraph()
        let alice = SceneNode(id: "alice", localPosition: CGPoint(x: 100, y: 100))
        let bob = SceneNode(id: "bob", localPosition: CGPoint(x: 500, y: 100))
        try scene.add(alice)
        try scene.add(bob)

        _ = try alice.addSocket("hand", at: CGPoint(x: 20, y: 30))
        let apple = SceneNode(id: "apple")
        try alice.attach(apple, toSocket: "hand")

        XCTAssertEqual(apple.worldPosition, CGPoint(x: 120, y: 130))
        bob.localPosition = CGPoint(x: 700, y: 100)
        XCTAssertEqual(apple.worldPosition, CGPoint(x: 120, y: 130),
                       "不相关角色移动不能改变 Alice 手里的苹果")

        alice.localPosition = CGPoint(x: 150, y: 180)
        XCTAssertEqual(apple.worldPosition, CGPoint(x: 170, y: 210))
    }

    func testReparentPreservesWorldPositionByDefault() throws {
        let scene = SceneGraph()
        let left = SceneNode(id: "left", localPosition: CGPoint(x: 100, y: 100))
        let right = SceneNode(id: "right", localPosition: CGPoint(x: 400, y: 300),
                              localScale: CGSize(width: 2, height: 2))
        try scene.add(left)
        try scene.add(right)

        let apple = SceneNode(id: "apple", localPosition: CGPoint(x: 25, y: 35))
        try left.addChild(apple)
        let before = apple.worldPosition

        try apple.reparent(to: right)

        XCTAssertEqual(apple.parent, right)
        XCTAssertEqual(apple.worldPosition, before,
                       "换父节点不应因为坐标系变化而瞬移")
        XCTAssertEqual(apple.localPosition.x, -137.5, accuracy: 0.001)
        XCTAssertEqual(apple.localPosition.y, -82.5, accuracy: 0.001)
    }

    func testDetachKeepsWorldPosition() throws {
        let scene = SceneGraph()
        let actor = SceneNode(id: "alice", localPosition: CGPoint(x: 80, y: 90),
                              localScale: CGSize(width: 1.5, height: 2))
        try scene.add(actor)
        let prop = SceneNode(id: "prop", localPosition: CGPoint(x: 10, y: 12))
        try actor.addChild(prop)
        let before = prop.worldPosition

        try prop.reparent(to: nil)

        XCTAssertNil(prop.parent)
        XCTAssertEqual(prop.worldPosition, before)
        XCTAssertTrue(scene.root.children.contains { $0 === actor })
    }

    func testOneSocketHasOneDirectOccupant() throws {
        let actor = SceneNode(id: "alice")
        _ = try actor.addSocket("hand")
        let apple = SceneNode(id: "apple")
        let book = SceneNode(id: "book")

        try actor.attach(apple, toSocket: "hand")
        XCTAssertThrowsError(try actor.attach(book, toSocket: "hand")) { error in
            guard case SceneNodeError.socketOccupied(name: "hand") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let spoon = SceneNode(id: "spoon")
        let hand = try XCTUnwrap(actor.socket(named: "hand"))
        XCTAssertThrowsError(try hand.addChild(spoon)) { error in
            guard case SceneNodeError.socketOccupied(name: "hand") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        try apple.reparent(to: nil)
        try actor.attach(book, toSocket: "hand")
        XCTAssertEqual(actor.socket(named: "hand")?.children.count, 1)
        XCTAssertEqual(book.parent, actor.socket(named: "hand"))
    }

    func testRejectsCyclesAndDuplicateSiblingIDs() throws {
        let scene = SceneGraph()
        let parent = SceneNode(id: "parent")
        let child = SceneNode(id: "child")
        try scene.add(parent)
        try parent.addChild(child)

        XCTAssertThrowsError(try child.addChild(parent)) { error in
            guard case SceneNodeError.cycle = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let duplicate = SceneNode(id: "child")
        XCTAssertThrowsError(try parent.addChild(duplicate)) { error in
            guard case SceneNodeError.duplicateChild(id: "child") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSceneGraphResolvesHierarchicalPathsForMultipleActors() throws {
        let scene = SceneGraph(rootID: "scene")
        let alice = SceneNode(id: "alice")
        let bob = SceneNode(id: "bob")
        try scene.add(alice)
        try scene.add(bob)
        let aliceHand = try alice.addSocket("hand")
        let bobHand = try bob.addSocket("hand")
        let apple = SceneNode(id: "apple")
        let book = SceneNode(id: "book")
        try aliceHand.addChild(apple)
        try bobHand.addChild(book)

        XCTAssertTrue(scene.node(atPath: ["alice", "hand", "apple"]) === apple)
        XCTAssertTrue(scene.node(atPath: ["bob", "hand", "book"]) === book)
        XCTAssertNil(scene.node(atPath: ["alice", "hand", "book"]))
        XCTAssertEqual(scene.nodes(withID: "hand").count, 2,
                       "不同角色可以拥有同名 socket，但路径仍然无歧义")
    }

    func testSharedGraphReparentsAPropBetweenActorSocketsWithoutTeleportingUnexpectedly() throws {
        let scene = SceneGraph(rootID: "cast")
        let alice = SceneNode(id: "alice", localPosition: CGPoint(x: 100, y: 100))
        let bob = SceneNode(id: "bob", localPosition: CGPoint(x: 420, y: 240))
        try scene.add(alice)
        try scene.add(bob)
        let aliceHand = try alice.addSocket("hand", at: CGPoint(x: 20, y: 25))
        let bobHand = try bob.addSocket("hand", at: CGPoint(x: -15, y: 10))
        let prop = SceneNode(id: "shared-prop")

        try alice.attach(prop, toSocket: "hand")
        XCTAssertEqual(prop.parent, aliceHand)
        XCTAssertEqual(prop.worldPosition, CGPoint(x: 120, y: 125))

        try prop.reparent(to: bobHand, keepWorldTransform: false)
        XCTAssertEqual(prop.parent, bobHand)
        XCTAssertEqual(prop.worldPosition, CGPoint(x: 405, y: 250))

        try prop.reparent(to: aliceHand, keepWorldTransform: true)
        XCTAssertEqual(prop.worldPosition, CGPoint(x: 405, y: 250))
    }

    func testSharedGraphRemoveAllDetachesCastRootsButKeepsGraphReusable() throws {
        let scene = SceneGraph(rootID: "cast")
        let alice = SceneNode(id: "alice")
        let bob = SceneNode(id: "bob")
        try scene.add(alice)
        try scene.add(bob)
        try alice.addSocket("hand")
        try bob.addSocket("hand")

        scene.removeAll()

        XCTAssertTrue(scene.root.children.isEmpty)
        XCTAssertNil(alice.parent)
        XCTAssertNil(bob.parent)
        XCTAssertTrue(scene.nodes(withID: "hand").isEmpty)

        let replacement = SceneNode(id: "replacement")
        try scene.add(replacement)
        XCTAssertTrue(scene.node(atPath: ["replacement"]) === replacement)
    }
}
