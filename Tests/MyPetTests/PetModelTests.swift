import CoreGraphics
import XCTest
import MyPet2D
import MyPetCore
import MyPetCombat

@testable import MyPetApp

/// 状态机测试：用脚本化的假世界驱动 PetModel。
final class PetModelTests: XCTestCase {

    /// 脚本化假世界。floors 是多段地板（模拟多显示器：等高合并 / 高低差台阶）。
    final class FakeWorld: WorldReading {
        var live: [CGWindowID: CGRect] = [:]
        var floors: [(left: CGFloat, right: CGFloat, y: CGFloat)] = [(0, 1440, 800)]
        let floorY: CGFloat = 800

        func liveBounds(_ id: CGWindowID) -> CGRect? {
            live[id]
        }

        func surfaces(near x: CGFloat, footY: CGFloat) -> [(surface: MyPetApp.Surface, y: CGFloat, left: CGFloat, right: CGFloat)] {
            var result: [(surface: MyPetApp.Surface, y: CGFloat, left: CGFloat, right: CGFloat)] =
                floors.map { (.floor, $0.y, $0.left, $0.right) }
            for (id, b) in live.sorted(by: { $0.key < $1.key }) {
                result.append((.windowTop(id), b.minY, b.minX, b.maxX))
                result.append((.windowBottom(id), b.maxY, b.minX, b.maxX))
            }
            return result
        }

        func floorBeyond(edgeX: CGFloat, direction: CGFloat) -> (surface: MyPetApp.Surface, y: CGFloat, left: CGFloat, right: CGFloat)? {
            let within: CGFloat = 160
            for seg in floors {
                let isBeyond = direction > 0 ? seg.left > edgeX - 2 : seg.right < edgeX + 2
                let isNear = direction > 0 ? seg.left <= edgeX + within : seg.right >= edgeX - within
                if isBeyond && isNear {
                    return (.floor, seg.y, seg.left, seg.right)
                }
            }
            return nil
        }

        func workBox(at point: CGPoint) -> Screens.Box {
            let y = point.y
            let seg = floors.first { $0.left <= point.x && point.x <= $0.right }
                ?? floors.first { y >= $0.y - 400 && y <= $0.y + 100 }
                ?? floors[0]
            let top = seg.y - 775
            return Screens.Box(left: seg.left, top: top, right: seg.right, bottom: seg.y)
        }

        func virtualBox() -> Screens.Box {
            Screens.Box(
                left: floors.map { $0.left }.min() ?? 0,
                top: 25,
                right: floors.map { $0.right }.max() ?? 1440,
                bottom: floors.map { $0.y }.max() ?? 800
            )
        }

        func idleSeconds() -> Double { 0 }
    }

    private var world: FakeWorld!
    private var model: PetModel!

    override func setUp() {
        super.setUp()
        world = FakeWorld()
        world.live[7] = CGRect(x: 300, y: 400, width: 800, height: 400) // 一扇窗口
        model = PetModel(world: world, displayHeight: 110, startAt: CGPoint(x: 700, y: 800))
        model.spawn(onFloorAt: CGPoint(x: 700, y: 800))
    }

    private func run(seconds: Double, dt: Double = 1.0 / 60.0) {
        var t = 0.0
        while t < seconds {
            model.update(dtIn: dt)
            t += dt
        }
    }

    // ---- 站立与行走 ----

    func testWalkMovesAndClampsToFloorEdge() {
        model.startWalk(1)
        run(seconds: 30)
        XCTAssertLessThanOrEqual(model.x, 1440)
        XCTAssertGreaterThan(model.x, 700 + 100) // 确实往右走了
        XCTAssertEqual(model.yFeet, 800)
    }

    func testFaceTowardChangesOrientationWithoutStartingMovement() {
        model.faceToward(300)
        XCTAssertFalse(model.facingRight)
        XCTAssertFalse(model.walking)

        model.faceToward(1_000)
        XCTAssertTrue(model.facingRight)
        XCTAssertFalse(model.walking)
    }

    func testPetModelReadsPositionFromInjectedBodyWorld() {
        let bodyWorld = BodyWorld()
        let actorID = EntityID("shared-pet")
        model = PetModel(
            world: world,
            displayHeight: 110,
            startAt: CGPoint(x: 700, y: 800),
            entityID: actorID,
            bodyWorld: bodyWorld)

        bodyWorld.update(actorID) { body in
            body.position = Vec2(x: 321, y: 654)
            body.facing = .left
        }

        XCTAssertEqual(model.x, 321)
        XCTAssertEqual(model.yFeet, 654)
        XCTAssertFalse(model.facingRight)
    }

    func testStandalonePetAdvancesInjectedBodyWorldInsteadOfPrivatePhysics() throws {
        let bodyWorld = BodyWorld()
        let actorID = EntityID("shared-pet")
        model = PetModel(
            world: world,
            displayHeight: 110,
            startAt: CGPoint(x: 700, y: 800),
            entityID: actorID,
            bodyWorld: bodyWorld)
        model.spawn(onFloorAt: CGPoint(x: 700, y: 800))
        model.startWalk(1)

        model.update(dtIn: 1.0 / 60.0)

        XCTAssertEqual(bodyWorld.frame, 1)
        XCTAssertGreaterThan(model.x, 700)
        XCTAssertEqual(
            try XCTUnwrap(bodyWorld.state(for: actorID)).position.x,
            Double(model.x), accuracy: 0.0001)
    }

    @MainActor
    func testSharedCoordinatorAdvancesTwoPetFacadesExactlyOncePerFrame() {
        let coordinator = DesktopCombatCoordinator()
        let firstID = EntityID("a")
        let secondID = EntityID("b")
        let first = PetModel(
            world: world, displayHeight: 110, startAt: CGPoint(x: 500, y: 800),
            entityID: firstID, bodyWorld: coordinator.bodyWorld)
        let second = PetModel(
            world: world, displayHeight: 110, startAt: CGPoint(x: 900, y: 800),
            entityID: secondID, bodyWorld: coordinator.bodyWorld)
        coordinator.bodyWorld.update(firstID) {
            $0.position = Vec2(x: 500, y: 800)
            $0.locomotion = .grounded
            $0.currentSurfaceID = "floor:0:800"
        }
        coordinator.bodyWorld.update(secondID) {
            $0.position = Vec2(x: 900, y: 800)
            $0.locomotion = .grounded
            $0.currentSurfaceID = "floor:0:800"
        }
        coordinator.register(
            actorID: firstID, profile: CombatProfile(), x: first.x, yFeet: first.yFeet,
            facingRight: true, displayHeight: 110)
        coordinator.register(
            actorID: secondID, profile: CombatProfile(), x: second.x, yFeet: second.yFeet,
            facingRight: true, displayHeight: 110)
        first.startWalk(1)
        second.startWalk(-1)

        _ = coordinator.advance(
            elapsedSeconds: 1.0 / 60.0,
            environment: first.bodyEnvironmentSnapshot()) {
                first.prepareBodySimulationFrame()
                second.prepareBodySimulationFrame()
            }

        XCTAssertEqual(coordinator.bodyWorld.frame, 1)
        XCTAssertEqual(first.x, 501.5, accuracy: 0.001)
        XCTAssertEqual(second.x, 898.5, accuracy: 0.001)
    }

    @MainActor
    func testDesktopCombatRequiresAnExplicitControlSession() {
        let coordinator = DesktopCombatCoordinator()
        coordinator.register(
            actorID: EntityID("a"), profile: CombatProfile(),
            x: 500, yFeet: 800, facingRight: true, displayHeight: 110)
        coordinator.register(
            actorID: EntityID("b"), profile: CombatProfile(),
            x: 550, yFeet: 800, facingRight: false, displayHeight: 110)
        XCTAssertNil(coordinator.world.session)

        coordinator.beginAutonomousCombat(actorID: EntityID("a"))
        XCTAssertEqual(coordinator.world.session?.state, .active)
        XCTAssertEqual(coordinator.world.session?.participantIDs, [EntityID("a"), EntityID("b")])

        coordinator.endAutonomousCombat(actorID: EntityID("a"))
        XCTAssertEqual(coordinator.world.session?.state, .completed)
    }

    func testWalkOffWindowEdgeFalls() {
        // 宠物从上方落到窗口顶沿（y=300），再往左走出窗沿 → 掉到地板。
        world.live[7] = CGRect(x: 300, y: 300, width: 800, height: 400)
        model = PetModel(world: world, displayHeight: 110, startAt: CGPoint(x: 700, y: 100))
        model.edgeDropChance = 1.0
        run(seconds: 3)
        XCTAssertEqual(model.state, .perched)

        model.startWalk(-1)
        run(seconds: 10)
        XCTAssertEqual(model.state, .grounded)
        XCTAssertEqual(model.yFeet, 800)
    }

    // ---- 跳上窗口与栖息 ----

    func testLeapLandsOnWindowTopAndAttaches() {
        model.leapTo(window: WindowEntity(id: 7, pid: 42, owner: "Safari", bounds: world.live[7]!))
        run(seconds: 3)
        XCTAssertEqual(model.state, .perched)
        XCTAssertNotNil(model.perch)
        XCTAssertEqual(model.perch?.id, 7)
        XCTAssertEqual(model.yFeet, 400)
    }

    func testPerchedPetFollowsWindowMove() {
        model.leapTo(window: WindowEntity(id: 7, pid: 42, owner: "Safari", bounds: world.live[7]!))
        run(seconds: 3)
        XCTAssertEqual(model.state, .perched)
        let xBefore = model.x

        // 窗口右移 120、上移 60 → 宠物原样跟随（Surface Attachment 的核心断言）。
        world.live[7] = CGRect(x: 420, y: 340, width: 800, height: 400)
        run(seconds: 0.2)
        XCTAssertEqual(model.x, xBefore + 120, accuracy: 0.5)
        XCTAssertEqual(model.yFeet, 340)
    }

    func testWindowCloseDropsPet() {
        model.leapTo(window: WindowEntity(id: 7, pid: 42, owner: "Safari", bounds: world.live[7]!))
        run(seconds: 3)
        XCTAssertEqual(model.state, .perched)

        world.live.removeValue(forKey: 7) // 关窗
        run(seconds: 2)
        XCTAssertEqual(model.state, .grounded)
        XCTAssertEqual(model.yFeet, 800)
    }

    func testLandingPicksTopmostCrossedSurface() {
        // 两扇堆叠窗口：宠物从上方坠落，必须落在更高的顶沿上（y 更小）。
        world.live[9] = CGRect(x: 200, y: 300, width: 1000, height: 100)
        world.live[7] = CGRect(x: 300, y: 400, width: 800, height: 400)
        model = PetModel(world: world, displayHeight: 110, startAt: CGPoint(x: 700, y: 100))
        run(seconds: 3)
        XCTAssertEqual(model.state, .perched)
        XCTAssertEqual(model.perch?.id, 9)
        XCTAssertEqual(model.yFeet, 300)
    }

    // ---- 拖拽与抛掷 ----

    func testDragAndTossSettleOnFloor() {
        model.beginDrag(at: CGPoint(x: 700, y: 754))
        XCTAssertEqual(model.state, .dragged)

        // 拖到窗口（x ≤ 1100）右侧再向下甩，避免半路被窗口顶沿截住。
        for i in 1...6 {
            model.drag(to: CGPoint(x: 700 + CGFloat(i) * 90, y: 700), dt: 1 / 40)
        }
        model.endDrag(wasClick: false)
        XCTAssertEqual(model.state, .tossed)

        run(seconds: 8)
        XCTAssertEqual(model.state, .grounded)
        XCTAssertEqual(model.yFeet, 800)
        XCTAssertNil(model.perch) // 落在地板，不是窗台上
    }

    func testClickPetHops() {
        model.beginDrag(at: CGPoint(x: 700, y: 754))
        model.endDrag(wasClick: true)
        XCTAssertEqual(model.state, .airborne) // 开心小跳
        run(seconds: 1)
        XCTAssertEqual(model.state, .grounded)
    }

    // ---- 跨显示器 ----

    func testWalksAcrossScreensOverStep() {
        // 两台「高低差台阶」显示器：地板1 y=800 [0,1440]，地板2 y=900 [1500,2800]。
        world.floors = [(0, 1440, 800), (1500, 2800, 900)]
        model = PetModel(world: world, displayHeight: 110, startAt: CGPoint(x: 700, y: 800))
        model.spawn(onFloorAt: CGPoint(x: 700, y: 800))
        model.edgeDropChance = 0

        // 一路向右：走过 1440 屏边 → 掉下 100pt 台阶 → 落到屏幕2 地板 → 接着走。
        model.startWalk(1)
        run(seconds: 20)
        XCTAssertGreaterThan(model.x, 1500, "应该已经走到第二台显示器上")
        XCTAssertEqual(model.yFeet, 900)
        XCTAssertEqual(model.state, .grounded)
        XCTAssertTrue(model.walking, "落地后应保持行走（跨屏散步不中断）")
    }

    func testStanceFollowsCorrectFloorSegment() {
        // 站在第二段地板上时，refreshStance 必须匹配包含脚下 x 的那一段，
        // 而不是列表里第一段（多显示器下 y 会被错误吸回第一屏高度）。
        world.floors = [(0, 1440, 800), (1500, 2800, 900)]
        model = PetModel(world: world, displayHeight: 110, startAt: CGPoint(x: 2000, y: 900))
        model.spawn(onFloorAt: CGPoint(x: 2000, y: 900))
        run(seconds: 2)
        XCTAssertEqual(model.yFeet, 900)
        XCTAssertEqual(model.state, .grounded)
    }

    func testTurnsAroundAtWorldEdgeWhenNoOtherScreen() {
        // 只有一块屏：到世界边缘必须掉头，不许走出去。
        model.startWalk(1)
        run(seconds: 40)
        XCTAssertLessThanOrEqual(model.x, 1440)
    }

    // ---- 睡眠 ----

    func testSleepAndWake() {
        model.sleep()
        XCTAssertEqual(model.state, .asleep)
        run(seconds: 0.5)
        XCTAssertEqual(model.state, .asleep) // 睡着不会自己动
        model.wake()
        XCTAssertEqual(model.state, .grounded)
    }

    // ---- 用户召唤（summonTo）----

    func testSummonWalksAtHurrySpeedSameSpan() {
        // 同段地板：召唤速度 260pt/s，0.5s 走 130pt（旧闲逛速度 90 只走 45pt）。
        model.summonTo(targetX: 1000)
        XCTAssertTrue(model.walking)
        run(seconds: 0.5)
        XCTAssertGreaterThan(abs(model.x - 700), 110, "召唤必须明显快于闲逛")
    }

    func testSummonAirdropsAcrossFloorGap() {
        // 回归：地板断档 200pt（> 120pt 融合窗口），走路永远过不去 → 必须空降。
        world.floors = [(0, 700, 800), (900, 1600, 800)]
        model = PetModel(world: world, displayHeight: 110, startAt: CGPoint(x: 400, y: 800))
        model.spawn(onFloorAt: CGPoint(x: 400, y: 800))

        model.summonTo(targetX: 1200)
        XCTAssertEqual(model.state, .airborne, "跨断档召唤应空降")
        run(seconds: 2)
        XCTAssertEqual(model.state, .grounded)
        XCTAssertEqual(model.x, 1200, accuracy: 1)
        XCTAssertEqual(model.yFeet, 800)
    }

    func testSummonFromPerchComesDownToFloor() {
        // 栖息在窗口（y=400）时点「过来」到远处地板：下地并到达。
        model.leapTo(window: WindowEntity(id: 7, pid: 42, owner: "Safari", bounds: world.live[7]!))
        run(seconds: 3)
        XCTAssertEqual(model.state, .perched)

        model.summonTo(targetX: 200)
        XCTAssertEqual(model.state, .airborne)
        run(seconds: 2)
        XCTAssertEqual(model.state, .grounded)
        XCTAssertEqual(model.x, 200, accuracy: 1)
    }
}
