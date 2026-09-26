import Foundation
import MyPet2D
import MyPetCombat
import MyPetCore

public enum CombatCPUDifficulty: String, Codable, Sendable {
    case easy, normal, hard, veryHard

    public var configuration: CombatCPUConfiguration {
        switch self {
        case .easy:
            return CombatCPUConfiguration(
                perceptionDelayFrames: 14, decisionIntervalFrames: 8,
                searchIterations: 0, predictionFrames: 30, mistakePercent: 20)
        case .normal:
            return CombatCPUConfiguration(
                perceptionDelayFrames: 9, decisionIntervalFrames: 6,
                searchIterations: 0, predictionFrames: 45, mistakePercent: 8)
        case .hard:
            return CombatCPUConfiguration(
                perceptionDelayFrames: 6, decisionIntervalFrames: 4,
                searchIterations: MctsAi23iCompatibility.iterationLimit,
                predictionFrames: MctsAi23iCompatibility.simulationFrames,
                mistakePercent: 3)
        case .veryHard:
            return CombatCPUConfiguration(
                perceptionDelayFrames: 4, decisionIntervalFrames: 4,
                searchIterations: 40, predictionFrames: 90, mistakePercent: 1)
        }
    }
}

public struct CombatCPUConfiguration: Codable, Equatable, Sendable {
    public var perceptionDelayFrames: Int
    public var decisionIntervalFrames: Int
    public var searchIterations: Int
    public var predictionFrames: Int
    public var mistakePercent: Int
    public var topK: Int

    public init(
        perceptionDelayFrames: Int, decisionIntervalFrames: Int,
        searchIterations: Int, predictionFrames: Int,
        mistakePercent: Int, topK: Int = 5
    ) {
        self.perceptionDelayFrames = max(0, perceptionDelayFrames)
        self.decisionIntervalFrames = max(1, decisionIntervalFrames)
        self.searchIterations = max(0, searchIterations)
        self.predictionFrames = max(1, predictionFrames)
        self.mistakePercent = min(100, max(0, mistakePercent))
        self.topK = max(1, topK)
    }
}

public enum CombatCPUIntent: String, Codable, Sendable {
    case wait, approach, retreat, jump, `guard`, attack, navigate
}

public enum EngagementSide: String, Codable, Sendable {
    case leftNear, leftFar, rightNear, rightFar, upper
}

public enum CombatNavigationReason: String, Codable, Sendable {
    case chase, projectileEvade, pressureEscape, highGround
}

public struct CombatNavigationPlan: Codable, Equatable, Sendable {
    public var targetSurfaceID: String
    public var landingLeft: Double
    public var landingRight: Double
    public var jumpsRemaining: Int
    public var reason: CombatNavigationReason
    public var commitUntilFrame: Int64

    public init(
        targetSurfaceID: String,
        landingLeft: Double,
        landingRight: Double,
        jumpsRemaining: Int,
        reason: CombatNavigationReason,
        commitUntilFrame: Int64
    ) {
        self.targetSurfaceID = targetSurfaceID
        self.landingLeft = landingLeft
        self.landingRight = landingRight
        self.jumpsRemaining = max(0, jumpsRemaining)
        self.reason = reason
        self.commitUntilFrame = commitUntilFrame
    }

    public var landingCenter: Double {
        (landingLeft + landingRight) * 0.5
    }
}

public struct EngagementSlot: Codable, Equatable, Sendable {
    public var targetID: EntityID
    public var side: EngagementSide
    public var anchorX: Double

    public init(targetID: EntityID, side: EngagementSide, anchorX: Double) {
        self.targetID = targetID
        self.side = side
        self.anchorX = anchorX
    }
}

public struct CPUCombatObservation: Sendable {
    public var frame: Int64
    public var selfBody: CombatBodyState
    public var opponents: [CombatBodyState]
    public var selfProfile: CombatProfile
    public var opponentProfiles: [String: CombatProfile]
    public var environment: BodyEnvironment
    public var worldCheckpoint: CombatWorldCheckpoint?
    public var engagementReservations: [EngagementSlot]
    public var tactics: CombatTactics
    public var pacingRate: Double
    public var recentlyHit: Bool
    public var recentHitFrame: Int64?

    public init(
        frame: Int64, selfBody: CombatBodyState,
        opponents: [CombatBodyState], selfProfile: CombatProfile,
        opponentProfiles: [String: CombatProfile], environment: BodyEnvironment,
        worldCheckpoint: CombatWorldCheckpoint? = nil,
        engagementReservations: [EngagementSlot] = [],
        tactics: CombatTactics = .balanced,
        pacingRate: Double = 1,
        recentlyHit: Bool = false,
        recentHitFrame: Int64? = nil
    ) {
        self.frame = frame
        self.selfBody = selfBody
        self.opponents = opponents
        self.selfProfile = selfProfile
        self.opponentProfiles = opponentProfiles
        self.environment = environment
        self.worldCheckpoint = worldCheckpoint
        self.engagementReservations = engagementReservations
        self.tactics = tactics
        self.pacingRate = min(2, max(0.25, pacingRate))
        self.recentlyHit = recentlyHit
        self.recentHitFrame = recentHitFrame
    }
}

public struct CombatTactics: Codable, Equatable, Sendable {
    public var aggression: Double
    public var defense: Double
    public var projectile: Double
    public var throwBias: Double
    public var antiAir: Double

    public static let balanced = CombatTactics()
    public init(
        aggression: Double = 1, defense: Double = 1,
        projectile: Double = 1, throwBias: Double = 1,
        antiAir: Double = 1
    ) {
        self.aggression = max(0, aggression)
        self.defense = max(0, defense)
        self.projectile = max(0, projectile)
        self.throwBias = max(0, throwBias)
        self.antiAir = max(0, antiAir)
    }
}

public struct CombatCPUOutput: Equatable, Sendable {
    public var input: FighterInputFrame
    public var intent: CombatCPUIntent
    public var targetID: EntityID?
    public var slot: EngagementSlot?
    public var moveID: String?
    public var utilityScore: Double
    public var usedSearch: Bool

    public init(
        input: FighterInputFrame = .neutral, intent: CombatCPUIntent = .wait,
        targetID: EntityID? = nil, slot: EngagementSlot? = nil,
        moveID: String? = nil, utilityScore: Double = 0,
        usedSearch: Bool = false
    ) {
        self.input = input
        self.intent = intent
        self.targetID = targetID
        self.slot = slot
        self.moveID = moveID
        self.utilityScore = utilityScore
        self.usedSearch = usedSearch
    }
}

struct DelayedOpponent: Codable, Equatable, Sendable {
    var frame: Int64
    var bodies: [CombatBodyState]
}

struct DeterministicCPURNG: Codable, Equatable, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
    mutating func index(_ count: Int) -> Int {
        count <= 1 ? 0 : Int(next() % UInt64(count))
    }
    mutating func chance(percent: Int) -> Bool {
        Int(next() % 100) < percent
    }
}

public struct ClassicCombatCPUCheckpoint: Codable, Equatable, Sendable {
    var actorID: EntityID
    var configuration: CombatCPUConfiguration
    var rng: DeterministicCPURNG
    var history: [DelayedOpponent]
    var pendingInputs: [FighterInputFrame]
    var targetID: EntityID?
    var slot: EngagementSlot?
    var lastDecisionFrame: Int64
    var lastOutput: CombatCPUOutputCheckpoint
    var recentMoves: [String]
    var lastIssuedInput: FighterInputFrame
    var surfaceGraph: DynamicSurfaceGraph?
    var actionHistory: ActionHistory?
    var moveUseCounts: [String: Int]?
    /// OpenBOR-style attack throttle: strategy/movement may continue before this frame,
    /// but a new offensive move may not be selected.
    var nextAttackFrame: Int64?
    var lastCounteredHitFrame: Int64?
    var navigationPlan: CombatNavigationPlan? = nil
    var tacticalNavigationCooldownUntil: Int64? = nil
}

struct CombatCPUOutputCheckpoint: Codable, Equatable, Sendable {
    var intent: CombatCPUIntent = .wait
    var targetID: EntityID?
    var slot: EngagementSlot?
    var moveID: String?
    var utilityScore: Double = 0
    var usedSearch = false
}
