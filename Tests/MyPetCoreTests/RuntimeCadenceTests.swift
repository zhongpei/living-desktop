import XCTest
import MyPetEngine

final class RuntimeCadenceTests: XCTestCase {
    func testHighestDemandWinsAndDownshiftIsDelayed() {
        let config = RuntimeCadenceConfiguration(downshiftDelaySeconds: 2)
        var state = RuntimeCadenceState(demand: .life)
        XCTAssertEqual(state.select(demands: [.life, .combat], configuration: config, now: 0), 60)
        XCTAssertEqual(state.select(demands: [.quiescent], configuration: config, now: 1), 60)
        XCTAssertEqual(state.select(demands: [.quiescent], configuration: config, now: 2.9), 60)
        XCTAssertEqual(state.select(demands: [.quiescent], configuration: config, now: 3), 5)
    }

    func testDisabledUsesFixedRateAndConfigurationNormalizesOrdering() {
        let config = RuntimeCadenceConfiguration(
            enabled: false, fixedHzWhenDisabled: 40,
            quiescentHz: 30, lifeHz: 10, physicalHz: 40, combatHz: 20,
            downshiftDelaySeconds: -1)
        XCTAssertEqual(config.lifeHz, 30)
        XCTAssertEqual(config.combatHz, 40)
        XCTAssertEqual(config.downshiftDelaySeconds, 0)
        var state = RuntimeCadenceState()
        XCTAssertEqual(state.select(demands: [.quiescent], configuration: config, now: 0), 40)
    }
}
