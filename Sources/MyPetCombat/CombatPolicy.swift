import Foundation
import MyPetCore

public struct CombatObservation: Sendable {
    public var frame: Int64
    public var selfBody: CombatBodyState
    public var opponents: [CombatBodyState]
    public var profile: CombatProfile

    public init(
        frame: Int64 = 0,
        selfBody: CombatBodyState,
        opponents: [CombatBodyState],
        profile: CombatProfile = CombatProfile()
    ) {
        self.frame = frame
        self.selfBody = selfBody
        self.opponents = opponents
        self.profile = profile
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
        guard me.canAcceptAction,
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
        let directMoves = observation.profile.moves.filter {
            $0.command.steps.count == 1 &&
            $0.command.steps[0].direction == nil &&
            $0.command.steps[0].trigger == .press &&
            $0.command.steps[0].requiredButtons.count == 1
        }
        if distance >= 110, distance <= 320, observation.frame % 180 < 30,
           let projectile = directMoves.first(where: { !$0.authoredProjectiles.isEmpty }),
           let button = projectile.command.steps[0].requiredButtons.first {
            return FighterInputFrame(buttons: [button])
        }
        if distance > 95 {
            return dx >= 0
                ? FighterInputFrame(right: true)
                : FighterInputFrame(left: true)
        }
        let closeMoves = directMoves.filter { $0.authoredProjectiles.isEmpty }
        guard !closeMoves.isEmpty else { return .neutral }
        let index = Int((observation.frame / 30) % Int64(closeMoves.count))
        guard let button = closeMoves[index].command.steps[0].requiredButtons.first else {
            return .neutral
        }
        return FighterInputFrame(buttons: [button])
    }
}
