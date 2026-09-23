import Foundation
import MyPet2D
import MyPetCombat
import MyPetCore

public enum GameplayActivity: String, Codable, CaseIterable, Hashable, Sendable {
    case fight, explore, interactWindow, interactProp, perform, rest, observe
}

public enum GameplayPlatformIntent: Codable, Equatable, Sendable {
    case inspectWindow(String)
    case perchWindow(String)
    case pullWindow(String)
    case damageWindowOverlay(String)
    case rest
    case observe
}

public struct CharacterGameplayStyle: Codable, Equatable, Sendable {
    public var combat: Double
    public var explore: Double
    public var destruction: Double
    public var risk: Double
    public var energyReserve: Double
    public var spectacle: Double

    public static let balanced = CharacterGameplayStyle()
    public init(
        combat: Double = 0.7, explore: Double = 0.5,
        destruction: Double = 0.2, risk: Double = 0.5,
        energyReserve: Double = 0.5, spectacle: Double = 0.5
    ) {
        self.combat = combat; self.explore = explore
        self.destruction = destruction; self.risk = risk
        self.energyReserve = energyReserve; self.spectacle = spectacle
    }
}

public struct SurfaceVisit: Codable, Equatable, Sendable {
    public var lastVisitedFrame: Int64
    public var visitCount: Int
    public var timeSpent: Int
    public var interestingEvents: Int
}

public struct GameplayCPUObservation: Sendable {
    public var combat: CPUCombatObservation
    public var formalRound: Bool
    public var wasAttacked: Bool
    public var userActive: Bool
    public var windowIDs: [String]
    public var style: CharacterGameplayStyle

    public init(
        combat: CPUCombatObservation, formalRound: Bool = true,
        wasAttacked: Bool = false, userActive: Bool = false,
        windowIDs: [String] = [], style: CharacterGameplayStyle = .balanced
    ) {
        self.combat = combat; self.formalRound = formalRound
        self.wasAttacked = wasAttacked; self.userActive = userActive
        self.windowIDs = windowIDs.sorted(); self.style = style
    }
}

public struct GameplayCPUOutput: Equatable, Sendable {
    public var activity: GameplayActivity
    public var fighterInput: FighterInputFrame
    public var combatOutput: CombatCPUOutput?
    public var platformIntent: GameplayPlatformIntent?
    public var utilities: [GameplayActivity: Double]
}

public struct ClassicGameplayCPUCheckpoint: Codable, Equatable, Sendable {
    public var actorID: EntityID
    public var combat: ClassicCombatCPUCheckpoint
    public var activity: GameplayActivity
    public var commitmentUntilFrame: Int64
    public var boredom: Double
    public var visits: [String: SurfaceVisit]
    public var history: ActionHistory
}

/// Top-level fast brain. It chooses an activity and emits only logical fighter
/// input or a semantic platform intent; platform adapters still authorize all
/// external effects.
public struct ClassicGameplayCPU: Sendable {
    private var state: ClassicGameplayCPUCheckpoint
    private var combatCPU: ClassicCombatCPU

    public init(
        actorID: EntityID, difficulty: CombatCPUDifficulty = .normal,
        seed: UInt64
    ) {
        let combat = ClassicCombatCPU(actorID: actorID, difficulty: difficulty, seed: seed)
        combatCPU = combat
        state = ClassicGameplayCPUCheckpoint(
            actorID: actorID, combat: combat.checkpoint(), activity: .observe,
            commitmentUntilFrame: 0, boredom: 0, visits: [:], history: ActionHistory())
    }

    public init(checkpoint: ClassicGameplayCPUCheckpoint) {
        state = checkpoint
        combatCPU = ClassicCombatCPU(checkpoint: checkpoint.combat)
    }

    public func checkpoint() -> ClassicGameplayCPUCheckpoint {
        var copy = state
        copy.combat = combatCPU.checkpoint()
        return copy
    }

    public var reservedSlot: EngagementSlot? { combatCPU.reservedSlot }

    public mutating func advance(_ observation: GameplayCPUObservation) -> GameplayCPUOutput {
        let frame = observation.combat.frame
        updateVisit(observation.combat.selfBody.currentSurfaceID, frame: frame)
        let threatened = observation.wasAttacked || !observation.combat.opponents.isEmpty
        let mayReconsider = frame >= state.commitmentUntilFrame || threatened
        let utilities = scoreActivities(observation)
        if observation.formalRound {
            state.activity = .fight
        } else if mayReconsider {
            state.activity = utilities.max {
                $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value
            }?.key ?? .observe
            state.commitmentUntilFrame = frame + Int64(60 + stableOffset(frame: frame, range: 121))
        }

        switch state.activity {
        case .fight:
            let output = combatCPU.advance(observation.combat)
            if let moveID = output.moveID,
               let move = observation.combat.selfProfile.move(id: moveID) {
                state.history.record(id: moveID, family: move.effectiveResourceRules.family)
                state.boredom = max(0, state.boredom - 0.08)
            } else {
                state.boredom = min(1, state.boredom + 0.001)
            }
            var fighterInput = output.input
            if frame > 0, frame % 1_800 == 0 {
                fighterInput.systemControls.insert(.tag)
            } else if frame > 0, frame % 600 == 0 {
                fighterInput.systemControls.insert(.assist)
            }
            return GameplayCPUOutput(
                activity: .fight, fighterInput: fighterInput,
                combatOutput: output, platformIntent: nil, utilities: utilities)
        case .explore:
            let input = explorationInput(observation.combat)
            state.boredom = max(0, state.boredom - 0.002)
            return GameplayCPUOutput(
                activity: .explore, fighterInput: input,
                combatOutput: nil, platformIntent: nil, utilities: utilities)
        case .interactWindow:
            let id = observation.windowIDs.min { lhs, rhs in
                let left = state.visits[lhs]?.visitCount ?? 0
                let right = state.visits[rhs]?.visitCount ?? 0
                return left == right ? lhs < rhs : left < right
            }
            let intent = id.map { observation.style.destruction > 0.65
                ? GameplayPlatformIntent.damageWindowOverlay($0)
                : GameplayPlatformIntent.inspectWindow($0) }
            return GameplayCPUOutput(
                activity: .interactWindow, fighterInput: .neutral,
                combatOutput: nil, platformIntent: intent, utilities: utilities)
        case .rest:
            return GameplayCPUOutput(activity: .rest, fighterInput: .neutral,
                                     combatOutput: nil, platformIntent: .rest, utilities: utilities)
        case .observe, .perform, .interactProp:
            return GameplayCPUOutput(activity: state.activity, fighterInput: .neutral,
                                     combatOutput: nil, platformIntent: .observe, utilities: utilities)
        }
    }

    private func scoreActivities(_ observation: GameplayCPUObservation) -> [GameplayActivity: Double] {
        let style = observation.style
        let hasOpponent = observation.combat.opponents.isEmpty ? 0.0 : 1.0
        let energyRatio = Double(observation.combat.selfBody.gameplayEnergy.current) /
            Double(max(1, observation.combat.selfBody.gameplayEnergy.maximum))
        return [
            .fight: hasOpponent * (120 + style.combat * 50) + (observation.wasAttacked ? 200 : 0),
            .explore: style.explore * 70 + state.boredom * 80,
            .interactWindow: observation.windowIDs.isEmpty || observation.userActive
                ? -1_000 : style.spectacle * 45 + style.destruction * 35 + state.boredom * 40,
            .interactProp: 10,
            .perform: style.spectacle * 20,
            .rest: (1 - energyRatio) * (30 + style.energyReserve * 60),
            .observe: 15,
        ]
    }

    private mutating func updateVisit(_ surfaceID: String?, frame: Int64) {
        guard let surfaceID else { state.boredom = min(1, state.boredom + 0.002); return }
        if var visit = state.visits[surfaceID] {
            visit.timeSpent += 1
            visit.lastVisitedFrame = frame
            state.visits[surfaceID] = visit
            state.boredom = min(1, state.boredom + 0.001)
        } else {
            state.visits[surfaceID] = SurfaceVisit(
                lastVisitedFrame: frame, visitCount: 1, timeSpent: 1, interestingEvents: 0)
            state.boredom = max(0, state.boredom - 0.2)
        }
    }

    private func explorationInput(_ observation: CPUCombatObservation) -> FighterInputFrame {
        let surfaces = observation.environment.surfaces.sorted {
            (state.visits[$0.id]?.visitCount ?? 0) < (state.visits[$1.id]?.visitCount ?? 0)
        }
        guard let target = surfaces.first else { return .neutral }
        if observation.selfBody.currentSurfaceID == target.id {
            return FighterInputFrame(up: true)
        }
        let center = (target.left + target.right) / 2
        return center >= observation.selfBody.position.x
            ? FighterInputFrame(right: true) : FighterInputFrame(left: true)
    }

    private func stableOffset(frame: Int64, range: Int) -> Int {
        let hash = state.actorID.raw.utf8.reduce(UInt64(bitPattern: frame)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
        return Int(hash % UInt64(max(1, range)))
    }
}
