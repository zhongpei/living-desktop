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

/// Read-only desktop metadata used by the gameplay planner. It deliberately
/// contains no AppKit or accessibility object, so the CPU can be replayed in
/// the simulator and the platform adapter remains the only effectful layer.
public struct GameplayWindowState: Codable, Equatable, Sendable {
    public var id: String
    public var areaRatio: Double
    public var isForeground: Bool
    public var isMoving: Bool
    public var isPullable: Bool
    public var allowsDamageOverlay: Bool

    public init(
        id: String, areaRatio: Double = 0.25,
        isForeground: Bool = false, isMoving: Bool = false,
        isPullable: Bool = false, allowsDamageOverlay: Bool = true
    ) {
        self.id = id
        self.areaRatio = min(1, max(0, areaRatio))
        self.isForeground = isForeground
        self.isMoving = isMoving
        self.isPullable = isPullable
        self.allowsDamageOverlay = allowsDamageOverlay
    }
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
    public var windows: [GameplayWindowState]
    public var style: CharacterGameplayStyle

    public init(
        combat: CPUCombatObservation, formalRound: Bool = true,
        wasAttacked: Bool = false, userActive: Bool = false,
        windowIDs: [String] = [], windows: [GameplayWindowState] = [],
        style: CharacterGameplayStyle = .balanced
    ) {
        self.combat = combat; self.formalRound = formalRound
        self.wasAttacked = wasAttacked; self.userActive = userActive
        self.windows = windows.sorted { $0.id < $1.id }
        self.windowIDs = Array(Set(windowIDs + windows.map(\.id))).sorted()
        self.style = style
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
        let commitmentInvalid = activityIsInvalid(state.activity, observation: observation)
        let mayReconsider = frame >= state.commitmentUntilFrame ||
            observation.wasAttacked || commitmentInvalid
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
            let window = viableWindows(observation).sorted { lhs, rhs in
                let left = windowInterest(lhs, frame: frame)
                let right = windowInterest(rhs, frame: frame)
                return left == right ? lhs.id < rhs.id : left > right
            }.first
            let intent = window.map { window -> GameplayPlatformIntent in
                if observation.style.destruction > 0.65,
                   window.allowsDamageOverlay {
                    return .damageWindowOverlay(window.id)
                }
                if observation.style.explore > 0.7, window.isPullable {
                    return .pullWindow(window.id)
                }
                return .inspectWindow(window.id)
            }
            if let intent {
                state.history.record(id: "\(intent)", family: .windowInteraction)
                state.boredom = max(0, state.boredom - 0.12)
            }
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
        let windows = viableWindows(observation)
        let bestWindowInterest = windows.map {
            windowInterest($0, frame: observation.combat.frame)
        }.max() ?? -1_000
        let historyPenalty = state.history.repetitionPenalty(
            id: "window", family: .windowInteraction)
        return [
            .fight: hasOpponent * (120 + style.combat * 50) + (observation.wasAttacked ? 200 : 0),
            .explore: style.explore * 70 + state.boredom * 80,
            .interactWindow: windows.isEmpty
                ? -1_000
                : bestWindowInterest + style.spectacle * 45 +
                    style.destruction * 35 + state.boredom * 40 - historyPenalty,
            .interactProp: 10,
            .perform: style.spectacle * 20,
            .rest: (1 - energyRatio) * (30 + style.energyReserve * 60),
            .observe: 15,
        ]
    }

    private func activityIsInvalid(
        _ activity: GameplayActivity,
        observation: GameplayCPUObservation
    ) -> Bool {
        switch activity {
        case .fight:
            return observation.combat.opponents.isEmpty
        case .interactWindow:
            return viableWindows(observation).isEmpty
        default:
            return false
        }
    }

    /// Minimum viability is a hard safety/resource gate. Spectacle and
    /// personality only rank candidates that survive this filter.
    private func viableWindows(
        _ observation: GameplayCPUObservation
    ) -> [GameplayWindowState] {
        guard !observation.userActive else { return [] }
        let metadata = observation.windows.isEmpty
            ? observation.windowIDs.map { GameplayWindowState(id: $0) }
            : observation.windows
        let energy = observation.combat.selfBody.gameplayEnergy.current
        return metadata.filter { window in
            guard !window.isForeground else { return false }
            let requestedCost: Int
            if observation.style.destruction > 0.65, window.allowsDamageOverlay {
                requestedCost = 120
            } else if observation.style.explore > 0.7, window.isPullable {
                requestedCost = 180
            } else {
                requestedCost = 0
            }
            return energy - requestedCost >= 60
        }
    }

    private func windowInterest(
        _ window: GameplayWindowState,
        frame: Int64
    ) -> Double {
        let visit = state.visits[window.id]
        let novelty = visit == nil ? 35.0 : max(
            0, min(25, Double(frame - (visit?.lastVisitedFrame ?? frame)) / 120))
        let movement = window.isMoving ? 20.0 : 0
        let size = min(20, window.areaRatio * 25)
        let capability = (window.isPullable ? 8.0 : 0) +
            (window.allowsDamageOverlay ? 8.0 : 0)
        let repetition = Double(visit?.visitCount ?? 0) * 12
        return novelty + movement + size + capability - repetition
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
