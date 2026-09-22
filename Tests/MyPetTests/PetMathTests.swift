import CoreGraphics
import XCTest

@testable import MyPetApp

final class PetMathTests: XCTestCase {

    let bounds = CGRect(x: 300, y: 200, width: 800, height: 600)

    // ---- 栖息 ----

    func testPerchXMapsFracIntoUsableWidth() {
        // margin = 100，可用宽 600：frac 0 → 400（left+margin），frac 1 → 1000。
        XCTAssertEqual(PetMath.perchX(bounds: bounds, frac: 0, margin: 100), 400)
        XCTAssertEqual(PetMath.perchX(bounds: bounds, frac: 1, margin: 100), 1000)
        XCTAssertEqual(PetMath.perchX(bounds: bounds, frac: 0.5, margin: 100), 700)
    }

    func testPerchFracRoundTrips() {
        let x = PetMath.perchX(bounds: bounds, frac: 0.31, margin: 40)
        let frac = PetMath.perchFrac(x: x, bounds: bounds, margin: 40)
        XCTAssertEqual(frac, 0.31, accuracy: 0.0001)
    }

    func testPerchFeetYStandsOnTopNormally() {
        let y = PetMath.perchFeetY(topY: 400, petHeight: 110, workTop: 25)
        XCTAssertEqual(y, 400)
    }

    func testPerchFeetYAvoidsMenuBar() {
        // 窗口顶沿贴着菜单栏：头顶放不下 → 退到标题栏上（+24）。
        let y = PetMath.perchFeetY(topY: 100, petHeight: 110, workTop: 25)
        XCTAssertEqual(y, 124)
    }

    func testPerchFeetYUsesBaselineSoMaximizedWindowKeepsPanelVisible() {
        // 最大化窗口的顶沿可能紧贴工作区；脚位必须按真实基线推导，
        // 不能只把一个仍在屏幕外的 raw panel 交给 AppKit 再硬钳。
        let y = PetMath.perchFeetY(topY: 25, petHeight: 110, workTop: 25,
                                   baselineRatio: 0.88)
        XCTAssertEqual(y, 25 + 110 * 0.88, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(y - 110 * 0.88, 25)
    }

    // ---- 跳跃 ----

    func testLeapVelocityReachesRise() {
        let v = PetMath.leapVelocity(rise: 300, gravity: 1600)
        let apex = PetMath.apexHeight(velocity: v, gravity: 1600)
        // 初速按 rise + clearance 计算，apex 必须盖过 rise。
        XCTAssertGreaterThanOrEqual(apex, 300)
        XCTAssertLessThan(apex, 340)
    }

    // ---- 拉窗 ----

    func testPullDeltaLinearThenClamped() {
        // 弹性段：走 20 拖 8。
        XCTAssertEqual(PetMath.pullDelta(stretch: 20), 8, accuracy: 0.001)
        // 500 × 0.4 = 200 → 钳到 120。
        XCTAssertEqual(PetMath.pullDelta(stretch: 500), 120)
        XCTAssertEqual(PetMath.pullDelta(stretch: -500), -120)
    }

    // ---- 抛掷 ----

    func testTossBouncesOffFloor() {
        let box = PetMath.Box(left: 0, top: 0, right: 1000, bottom: 800)
        let (p, v, event) = PetMath.stepToss(
            position: CGPoint(x: 500, y: 790),
            velocity: CGPoint(x: 0, y: 400),
            dt: 0.05, gravity: 1600, airDrag: 0.32,
            bounds: box, radius: 46
        )
        XCTAssertEqual(event, .floor)
        XCTAssertLessThanOrEqual(p.y, 754 + 0.001)
        XCTAssertLessThan(v.y, 0) // 反弹向上
    }

    func testTossNoEventWhenAirborne() {
        let box = PetMath.Box(left: 0, top: 0, right: 1000, bottom: 800)
        let (_, _, event) = PetMath.stepToss(
            position: CGPoint(x: 500, y: 400),
            velocity: CGPoint(x: 0, y: 0),
            dt: 0.025, gravity: 1600, airDrag: 0.32,
            bounds: box, radius: 46
        )
        XCTAssertEqual(event, .none)
    }

    // ---- 多显示器地板合并 ----

    func testMergeFloorSegmentsJoinsEqualHeightScreens() {
        // 两台等高屏幕无缝拼接 → 合并成一段连续地板。
        let boxes = [
            Screens.Box(left: 0, top: 25, right: 1920, bottom: 1010),
            Screens.Box(left: 1920, top: 25, right: 3840, bottom: 1010)
        ]
        let merged = Screens.mergeFloorSegments(boxes)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].left, 0)
        XCTAssertEqual(merged[0].right, 3840)
        XCTAssertEqual(merged[0].y, 1010)
    }

    func testMergeKeepsDifferentHeightsSeparate() {
        // 三屏三档高度（模拟主屏 + 左竖屏 + 右屏）→ 三段独立台阶。
        let boxes = [
            Screens.Box(left: 0, top: 0, right: 1920, bottom: 1010),
            Screens.Box(left: -1080, top: -493, right: 0, bottom: 1427),
            Screens.Box(left: 1920, top: 0, right: 3840, bottom: 1080)
        ]
        let merged = Screens.mergeFloorSegments(boxes)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.map { $0.y }, [1427, 1010, 1080]) // 按 left 排序
    }

    func testMergeBridgesSmallGapsAtEqualHeight() {
        // 等高但中间有 60pt 间隙的屏幕 → 仍合并（宠物从隐形条带走过）。
        let boxes = [
            Screens.Box(left: 0, top: 0, right: 1000, bottom: 800),
            Screens.Box(left: 1060, top: 0, right: 2000, bottom: 800)
        ]
        XCTAssertEqual(Screens.mergeFloorSegments(boxes).count, 1)
    }
}
