import Foundation
import MyPetCore

public struct CombatObservation: Sendable {
    public var selfBody: CombatBodyState
    public var opponents: [CombatBodyState]
    public init(selfBody: CombatBodyState, opponents: [CombatBodyState]) {
        self.selfBody = selfBody
        self.opponents = opponents
    }
}

public protocol CombatPolicy: Sendable {
    func decide(_ observation: CombatObservation) -> FighterInputFrame
}

/// Deterministic baseline policy. It uses the same FighterInputFrame interface as keyboard control,
/// so trained policies can replace it without changing the engine.
public struct UtilityCombatPolicy: CombatPolicy {
    public init() {}

    public func decide(_ observation: CombatObservation) -> FighterInputFrame {
        let me = observation.selfBody
        guard me.healthState == .active,
              let target = observation.opponents
                .filter({ $0.healthState == .active })
                .min(by: { abs($0.position.x - me.position.x) < abs($1.position.x - me.position.x) })
        else { return .neutral }

        let dx = target.position.x - me.position.x
        let distance = abs(dx)
        if target.phase == .active && distance < 105 {
            return dx >= 0
                ? FighterInputFrame(left: true)
                : FighterInputFrame(right: true)
        }
        if distance > 95 {
            return dx >= 0
                ? FighterInputFrame(right: true)
                : FighterInputFrame(left: true)
        }
        return FighterInputFrame(buttons: [.x])
    }
}
