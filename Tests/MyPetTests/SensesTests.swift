import XCTest
@testable import MyPetApp
import MyPetPlatform

/// 感知契约与存储的纯函数部分（离线可测，不需要 AX 权限）。
final class SensesTests: XCTestCase {

    private func observation(
        siblings: Int = 4, salient: Int = 12, longText: Bool = false
    ) -> SensorObservation {
        let filler = longText ? String(repeating: "甲", count: 200) : "下午三点开会"
        var o = SensorObservation(
            requestID: 17, timestamp: 100, app: "Google Chrome", pid: 9013,
            windowTitle: "ChatGPT", focused: nil, selectedText: "")
        o.focused = AXElementDTO(id: "ax:9013:f", role: "textarea", value: filler, focused: true)
        o.ancestors = ["group", "group", "webarea"]
        o.siblings = (0..<siblings).map {
            AXElementDTO(id: "ax:9013:s\($0)", role: "button", title: "按钮\($0)\(longText ? filler : "")")
        }
        o.salient = (0..<salient).map {
            AXElementDTO(id: "ax:9013:w.\($0)", role: "link", title: "链接\($0)\(longText ? filler : "")")
        }
        return o
    }

    // MARK: 契约

    func testSensesJSONContainsKeyFieldsAndBounded() {
        let json = SensorContract.sensesJSON(observation())!
        XCTAssertLessThanOrEqual(json.count, SensorContract.budgetChars)
        XCTAssertTrue(json.contains("Chrome"))
        XCTAssertTrue(json.contains("textarea"))
        XCTAssertTrue(json.contains("下午三点开会"))
    }

    func testSensesJSONDropsSectionsBeforeExceedingBudget() {
        // 200 字符 × 26 个字段远超 1200 预算：应逐段丢弃并打 truncated 标记。
        let json = SensorContract.sensesJSON(observation(siblings: 4, salient: 12, longText: true))!
        XCTAssertLessThanOrEqual(json.count, SensorContract.budgetChars)
        XCTAssertTrue(json.contains("truncated"))
        // focus 是最后被保留的核心段。
        XCTAssertTrue(json.contains("textarea"))
    }

    func testSensesJSONNilWhenEvenFocusCannotFit() {
        var o = observation(longText: true)
        o.siblings = []
        o.salient = []
        // 预算压到 10：连 focus 都放不下 → nil。
        XCTAssertNil(SensorContract.sensesJSON(o, budget: 10))
    }

    func testObservationCodableRoundtrip() throws {
        let o = observation()
        let data = try JSONEncoder().encode(o)
        let back = try JSONDecoder().decode(SensorObservation.self, from: data)
        XCTAssertEqual(o, back)
    }

    /// opaque id：宿主与大脑不解释结构，只需原样往返。
    func testElementIDOpaque() throws {
        let o = observation()
        let data = try JSONEncoder().encode(o.siblings[0])
        let back = try JSONDecoder().decode(AXElementDTO.self, from: data)
        XCTAssertEqual(back.id, "ax:9013:s0")
    }

    // MARK: 存储（TTL / 脏标记 / 防抖）

    func testTTLExpiry() {
        let store = SensesStore()
        XCTAssertNil(store.current(now: 100))
        store.update(observation())  // timestamp = 100
        XCTAssertNotNil(store.current(now: 105))
        XCTAssertNil(store.current(now: 107))  // ttl=6
    }

    func testDirtyRequiresCooldownThenClearsOnUpdate() {
        let store = SensesStore()
        store.update(observation())
        store.markDirty(now: 100)
        XCTAssertFalse(store.shouldResense(now: 101))  // 冷却 2s 内
        XCTAssertTrue(store.shouldResense(now: 102.5))
        store.update(observation())
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(store.shouldResense(now: 103))
    }

    func testMarkDirtyIdempotent() {
        let store = SensesStore()
        store.markDirty(now: 0)
        store.markDirty(now: 5)  // 已脏：不刷新 dirtyAt
        XCTAssertEqual(store.shouldResense(now: 1.5), false)
        XCTAssertTrue(store.shouldResense(now: 2.5))  // 仍以第一次脏时刻起算
    }

    func testSensesSectionRespectsEnabledPathAndTTL() {
        let store = SensesStore()
        store.update(observation())
        XCTAssertNotNil(store.sensesSection(now: 101))
        XCTAssertNil(store.sensesSection(now: 200))  // 过期
    }
}
