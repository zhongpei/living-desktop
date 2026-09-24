import Foundation

public struct RuntimeCadenceConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var fixedHzWhenDisabled: Int
    public var quiescentHz: Int
    public var lifeHz: Int
    public var physicalHz: Int
    public var combatHz: Int
    public var downshiftDelaySeconds: Double

    public init(
        enabled: Bool = true, fixedHzWhenDisabled: Int = 60,
        quiescentHz: Int = 5, lifeHz: Int = 20,
        physicalHz: Int = 60, combatHz: Int = 60,
        downshiftDelaySeconds: Double = 2
    ) {
        self.enabled = enabled
        self.fixedHzWhenDisabled = Self.clamp(fixedHzWhenDisabled)
        self.quiescentHz = Self.clamp(quiescentHz)
        self.lifeHz = max(self.quiescentHz, Self.clamp(lifeHz))
        self.physicalHz = max(self.lifeHz, Self.clamp(physicalHz))
        self.combatHz = max(self.physicalHz, Self.clamp(combatHz))
        self.downshiftDelaySeconds = max(0, downshiftDelaySeconds)
    }

    private static func clamp(_ value: Int) -> Int { min(120, max(1, value)) }

    private enum CodingKeys: String, CodingKey {
        case enabled, fixedHzWhenDisabled, quiescentHz, lifeHz, physicalHz, combatHz
        case downshiftDelaySeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            fixedHzWhenDisabled: try c.decodeIfPresent(Int.self, forKey: .fixedHzWhenDisabled) ?? 60,
            quiescentHz: try c.decodeIfPresent(Int.self, forKey: .quiescentHz) ?? 5,
            lifeHz: try c.decodeIfPresent(Int.self, forKey: .lifeHz) ?? 20,
            physicalHz: try c.decodeIfPresent(Int.self, forKey: .physicalHz) ?? 60,
            combatHz: try c.decodeIfPresent(Int.self, forKey: .combatHz) ?? 60,
            downshiftDelaySeconds: try c.decodeIfPresent(
                Double.self, forKey: .downshiftDelaySeconds) ?? 2)
    }
}

public enum RuntimeCadenceDemand: Int, Codable, CaseIterable, Comparable, Sendable {
    case quiescent, life, physical, combat
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct RuntimeCadenceState: Codable, Equatable, Sendable {
    public private(set) var demand: RuntimeCadenceDemand
    public private(set) var downshiftEligibleAt: Double?

    public init(demand: RuntimeCadenceDemand = .life) {
        self.demand = demand
    }

    public mutating func select(
        demands: some Sequence<RuntimeCadenceDemand>,
        configuration: RuntimeCadenceConfiguration,
        now: Double
    ) -> Int {
        guard configuration.enabled else {
            demand = .combat
            downshiftEligibleAt = nil
            return configuration.fixedHzWhenDisabled
        }
        let requested = demands.max() ?? .quiescent
        if requested >= demand {
            demand = requested
            downshiftEligibleAt = nil
        } else if configuration.downshiftDelaySeconds == 0 {
            demand = requested
            downshiftEligibleAt = nil
        } else if let deadline = downshiftEligibleAt {
            if now >= deadline {
                demand = requested
                downshiftEligibleAt = nil
            }
        } else {
            downshiftEligibleAt = now + configuration.downshiftDelaySeconds
        }
        switch demand {
        case .quiescent: return configuration.quiescentHz
        case .life: return configuration.lifeHz
        case .physical: return configuration.physicalHz
        case .combat: return configuration.combatHz
        }
    }
}
