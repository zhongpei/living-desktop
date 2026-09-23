import CoreGraphics
import XCTest
import MyPetContent

@testable import MyPetApp

/// PetBodyDriver 测试：verbs 注入 + 表演取消规则。
final class ActionRuntimeTests: XCTestCase {

    /// 极简假世界：一块平地板。
    final class StubWorld: WorldReading {
        func liveBounds(_ id: CGWindowID) -> CGRect? { nil }
        func surfaces(near x: CGFloat, footY: CGFloat) -> [(surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)] {
            [(surface: .floor, y: 800, left: 0, right: 1440)]
        }
        func floorBeyond(edgeX: CGFloat, direction: CGFloat) -> (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)? { nil }
        func workBox(at point: CGPoint) -> Screens.Box {
            Screens.Box(left: 0, top: 25, right: 1440, bottom: 800)
        }
        func virtualBox() -> Screens.Box {
            Screens.Box(left: 0, top: 25, right: 1440, bottom: 800)
        }
        func idleSeconds() -> Double { 0 }
    }

    private var world: StubWorld!
    private var model: PetModel!
    private var runtime: PetBodyDriver!

    override func setUp() {
        super.setUp()
        world = StubWorld()
        model = PetModel(world: world, displayHeight: 110, startAt: CGPoint(x: 700, y: 800))
        model.spawn(onFloorAt: CGPoint(x: 700, y: 800))
        runtime = PetBodyDriver(model: model, library: makeLibrary())
    }

    /// 内存里的最小 v2 库：base/idle + base/walk + 两个 actions（once / loop）。
    private func makeLibrary() -> ClipLibrary {
        let library = ClipLibrary(characterID: "test", cellSize: CGSize(width: 192, height: 208))
        // 直接借 ClipLibrary 的 clips 注入不可行（private），
        // 测试用磁盘 fixture：身体 driver 只读 meta/playback，帧不参与断言。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-lib-\(UUID().uuidString)", isDirectory: true)
        for rel in ["base/idle", "base/walk", "actions/wave", "actions/bathe"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(rel, isDirectory: true), withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            let png = rep.representation(using: .png, properties: [:])!
            try? png.write(to: dir.appendingPathComponent(rel + "/frame_00.png"))
        }
        let manifest: [String: Any] = [
            "id": "test", "format": "petpack-v2", "generator": "unit-test",
            "sprite": ["cell_width": 192, "cell_height": 208],
            "clips": [
                "base/idle": ["frames": 1, "fps": 5.0, "playback": "loop"],
                "base/walk": ["frames": 1, "fps": 5.0, "playback": "loop"],
                "actions/wave": ["frames": 4, "fps": 2.0, "playback": "once"],
                "actions/bathe": ["frames": 4, "fps": 2.0, "playback": "loop"],
            ],
        ]
        try? JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        // swift lint: 拿到真实的元信息结构
        return (try? ClipLibrary.load(from: dir)) ?? library
    }

    // ---- verbs ----

    func testMoveToSetsStrollTargetAndArrives() {
        runtime.inject(.moveTo(1000))
        XCTAssertEqual(runtime.strollTarget, 1000)
        XCTAssertTrue(model.walking)

        run(seconds: 5) { runtime.tick(now: $0) } // walkSpeed 90pt/s，700→1000 需 ~3.3s
        XCTAssertNil(runtime.strollTarget, "到点应自动停")
        XCTAssertFalse(model.walking)
    }

    func testPerformOnceAndLoop() {
        runtime.inject(.perform("actions/wave"))
        XCTAssertEqual(runtime.performance?.clipKey, "actions/wave")
        XCTAssertNil(runtime.performance?.endsAt, "once 型无 deadline，由播完收尾")
        XCTAssertEqual(runtime.actionTimeline?.definition.actionID, "actions/wave")
        XCTAssertEqual(runtime.actionTimeline?.definition.locomotionPolicy, .stationary)

        runtime.inject(.perform("actions/bathe"))
        XCTAssertEqual(runtime.performance?.clipKey, "actions/bathe")
        XCTAssertNotNil(runtime.performance?.endsAt, "loop 型 2 个循环后收尾")

        // 到 deadline 表演自动清掉。
        run(until: { $0 > 4.5 }) { runtime.tick(now: $0) }
        XCTAssertNil(runtime.performance)
    }

    func testMovementAndPerformanceShareOneActionCursor() {
        runtime.inject(.moveTo(1000))
        XCTAssertEqual(runtime.actionTimeline?.definition.actionID, "move_to")
        XCTAssertEqual(runtime.actionTimeline?.definition.locomotionPolicy, .authored)

        runtime.inject(.perform("actions/wave"))
        XCTAssertEqual(runtime.actionTimeline?.definition.actionID, "actions/wave")
        XCTAssertFalse(model.walking)
    }

    func testWaitCancelsEverything() {
        runtime.inject(.moveTo(1000))
        runtime.inject(.perform("actions/wave"))
        runtime.inject(.wait)
        XCTAssertNil(runtime.performance)
        XCTAssertNil(runtime.strollTarget)
        XCTAssertFalse(model.walking)
    }

    // ---- 取消规则 ----

    func testBodyLeavingGroundCancelsPerformance() {
        runtime.inject(.perform("actions/bathe"))
        model.hop() // 身体进空中
        run(seconds: 0.5) { runtime.tick(now: $0) }
        XCTAssertNil(runtime.performance, "身体离开地面 → 取消")
    }

    func testWalkingCancelsPerformance() {
        runtime.inject(.perform("actions/bathe"))
        model.startWalk(1)
        run(seconds: 0.2) { runtime.tick(now: $0) }
        XCTAssertNil(runtime.performance, "开始走路 → 取消")
    }

    func testCancelledPerformanceDoesNotReplay() {
        // 回归：旧实现里被打断的手势会在落地后「从头补演」。
        runtime.inject(.perform("actions/bathe"))
        model.hop()
        run(seconds: 2.0) { runtime.tick(now: $0) } // 跳起又落地
        XCTAssertEqual(model.state, .grounded)
        XCTAssertNil(runtime.performance, "取消不补演")
    }

    func testInjectIgnoredWhileAirborne() {
        model.hop()
        run(seconds: 0.3) // 确保在空中
        runtime.inject(.perform("actions/wave"))
        XCTAssertNil(runtime.performance, "空中不能开始表演")
        runtime.inject(.moveTo(500))
        XCTAssertNil(runtime.strollTarget, "空中不能开始散步")
    }

    func testUserSummonQueuedWhileAirborneExecutesOnLanding() {
        // 回归：空中/抛掷中点「过来」曾被静默忽略 → 现在排队，落地即执行。
        model.hop()
        run(seconds: 0.3)
        runtime.inject(.moveTo(1200), userInitiated: true)
        XCTAssertNotNil(runtime.pendingSummon, "空中应排队而非丢弃")

        // 落地（hop 全程约 0.65s）后执行召唤：700→1200 @260pt/s 约 1.9s，中途断言。
        run(seconds: 1.2) { runtime.tick(now: $0) }
        XCTAssertNil(runtime.pendingSummon)
        XCTAssertTrue(model.walking, "落地后应朝目标快走")
        XCTAssertEqual(model.currentWalkSpeed, PetModel.hurrySpeed, "用户召唤用快速")
    }

    func testGrabCancelsPendingSummon() {
        model.hop()
        runtime.inject(.moveTo(1200), userInitiated: true)
        runtime.clearPendingUserActions()
        XCTAssertNil(runtime.pendingSummon, "抓起 = 接管，排队作废")
    }

    // ---- 工具 ----

    private func run(seconds: Double, dt: Double = 1.0 / 60.0, _ body: (Double) -> Void = { _ in }) {
        var t = 0.0
        while t < seconds {
            model.update(dtIn: dt)
            body(t)
            t += dt
        }
    }

    private func run(until condition: (Double) -> Bool, dt: Double = 1.0 / 60.0, _ body: (Double) -> Void = { _ in }) {
        var t = 0.0
        while t < 30 && !condition(t) {
            model.update(dtIn: dt)
            body(t)
            t += dt
        }
    }
}
