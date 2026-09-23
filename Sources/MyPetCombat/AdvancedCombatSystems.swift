import Foundation
import MyPetCore

// MARK: - Shared gameplay resource

public struct GameplayEnergyState: Codable, Equatable, Sendable {
    public var current: Int
    public var maximum: Int
    public var regenPerFrame: Double
    public var regenDelayFrames: Int
    public private(set) var lastSpendFrame: Int64?
    private var fractionalRegen: Double

    public init(
        current: Int = 0, maximum: Int = 300,
        regenPerFrame: Double = 0.05, regenDelayFrames: Int = 120,
        lastSpendFrame: Int64? = nil
    ) {
        self.maximum = max(1, maximum)
        self.current = min(max(0, current), self.maximum)
        self.regenPerFrame = max(0, regenPerFrame)
        self.regenDelayFrames = max(0, regenDelayFrames)
        self.lastSpendFrame = lastSpendFrame
        self.fractionalRegen = 0
    }

    @discardableResult
    public mutating func spend(_ amount: Int, frame: Int64) -> Bool {
        let cost = max(0, amount)
        guard current >= cost else { return false }
        current -= cost
        if cost > 0 { lastSpendFrame = frame; fractionalRegen = 0 }
        return true
    }

    public mutating func gain(_ amount: Int) {
        current = min(maximum, current + max(0, amount))
    }

    public mutating func advance(frame: Int64, regenerationAllowed: Bool = true) {
        guard regenerationAllowed, current < maximum,
              lastSpendFrame.map({ frame - $0 >= Int64(regenDelayFrames) }) ?? true else { return }
        fractionalRegen += regenPerFrame
        let whole = Int(fractionalRegen)
        guard whole > 0 else { return }
        current = min(maximum, current + whole)
        fractionalRegen -= Double(whole)
    }
}

public enum CombatActionFamily: String, Codable, CaseIterable, Sendable {
    case fastMelee, heavyMelee, `throw`, projectile, movement, guardAction
    case special, superMove, powerUp, burst, tag, assist, windowInteraction
}

public struct MoveResourceRules: Codable, Equatable, Sendable {
    public var family: CombatActionFamily
    public var startCost: Int
    public var onHitGain: Int
    public var onGuardGain: Int
    public var defenderGain: Int
    public var juggleCost: Int

    public init(
        family: CombatActionFamily = .fastMelee,
        startCost: Int = 0, onHitGain: Int = 12,
        onGuardGain: Int = 4, defenderGain: Int = 8,
        juggleCost: Int = 0
    ) {
        self.family = family
        self.startCost = max(0, startCost)
        self.onHitGain = max(0, onHitGain)
        self.onGuardGain = max(0, onGuardGain)
        self.defenderGain = max(0, defenderGain)
        self.juggleCost = max(0, juggleCost)
    }
}

// MARK: - Combo and recovery

public struct ComboRules: Codable, Equatable, Sendable {
    public var minimumDamageScale: Double
    public var damageScalePerHit: Double
    public var hitStunScalePerHit: Double
    public var repeatedMovePenalty: Double
    public var juggleBudget: Int
    public var comboGapFrames: Int

    public static let standard = ComboRules()

    public init(
        minimumDamageScale: Double = 0.25,
        damageScalePerHit: Double = 0.10,
        hitStunScalePerHit: Double = 0.06,
        repeatedMovePenalty: Double = 0.10,
        juggleBudget: Int = 10,
        comboGapFrames: Int = 45
    ) {
        self.minimumDamageScale = min(1, max(0.01, minimumDamageScale))
        self.damageScalePerHit = max(0, damageScalePerHit)
        self.hitStunScalePerHit = max(0, hitStunScalePerHit)
        self.repeatedMovePenalty = max(0, repeatedMovePenalty)
        self.juggleBudget = max(0, juggleBudget)
        self.comboGapFrames = max(1, comboGapFrames)
    }
}

public enum ComboEndReason: String, Codable, Sendable {
    case recovered, gapExpired, sessionEnded
}

public struct ScaledHit: Codable, Equatable, Sendable {
    public var damage: Int
    public var hitStunFrames: Int
    public var scale: Double
}

public struct ComboState: Codable, Equatable, Sendable {
    public private(set) var comboID: Int64?
    public private(set) var attackerID: EntityID?
    public private(set) var defenderID: EntityID?
    public private(set) var hitCount = 0
    public private(set) var juggleRemaining: Int
    public private(set) var lastHitFrame: Int64?
    public private(set) var moveCounts: [String: Int] = [:]
    public var rules: ComboRules

    public init(rules: ComboRules = .standard) {
        self.rules = rules
        self.juggleRemaining = rules.juggleBudget
    }

    public mutating func recordHit(
        attackerID: EntityID, defenderID: EntityID, moveID: String,
        baseDamage: Int, baseHitStun: Int, juggleCost: Int, frame: Int64
    ) -> ScaledHit {
        if self.defenderID != defenderID ||
            lastHitFrame.map({ frame - $0 > Int64(rules.comboGapFrames) }) == true {
            end(reason: .gapExpired)
        }
        if hitCount == 0 {
            comboID = frame
            self.attackerID = attackerID
            self.defenderID = defenderID
            juggleRemaining = rules.juggleBudget
        }
        let repeats = moveCounts[moveID, default: 0]
        let scale = max(
            rules.minimumDamageScale,
            1 - Double(hitCount) * rules.damageScalePerHit -
                Double(repeats) * rules.repeatedMovePenalty)
        let stunScale = max(0.35, 1 - Double(hitCount) * rules.hitStunScalePerHit)
        hitCount += 1
        moveCounts[moveID, default: 0] += 1
        juggleRemaining = max(0, juggleRemaining - max(0, juggleCost))
        lastHitFrame = frame
        return ScaledHit(
            damage: max(1, Int((Double(max(0, baseDamage)) * scale).rounded(.down))),
            hitStunFrames: max(1, Int((Double(max(0, baseHitStun)) * stunScale).rounded(.down))),
            scale: scale)
    }

    public mutating func end(reason: ComboEndReason) {
        comboID = nil
        attackerID = nil
        defenderID = nil
        hitCount = 0
        juggleRemaining = rules.juggleBudget
        lastHitFrame = nil
        moveCounts.removeAll()
    }

    @discardableResult
    public mutating func expireIfNeeded(frame: Int64) -> Bool {
        guard hitCount > 0, let lastHitFrame,
              frame - lastHitFrame > Int64(rules.comboGapFrames) else { return false }
        end(reason: .gapExpired)
        return true
    }
}

public enum RecoveryChoice: String, Codable, CaseIterable, Sendable {
    case neutral, forward, backward, delayed, air
}

// MARK: - Team combat

public enum BenchPhase: String, Codable, Sendable {
    case standby, assisting, taggingOut, taggingIn
}

public struct TeamCombatRules: Codable, Equatable, Sendable {
    public var assistActiveFrames: Int
    public var assistExitFrames: Int
    public var tagHandoffFrame: Int
    public var tagTotalFrames: Int
    public var sharedCooldownFrames: Int

    public static let standard = TeamCombatRules()
    public var assistTotalFrames: Int { assistActiveFrames + assistExitFrames }

    public init(
        assistActiveFrames: Int = 30, assistExitFrames: Int = 18,
        tagHandoffFrame: Int = 12, tagTotalFrames: Int = 30,
        sharedCooldownFrames: Int = 240
    ) {
        self.assistActiveFrames = max(1, assistActiveFrames)
        self.assistExitFrames = max(1, assistExitFrames)
        self.tagHandoffFrame = max(1, tagHandoffFrame)
        self.tagTotalFrames = max(self.tagHandoffFrame, tagTotalFrames)
        self.sharedCooldownFrames = max(0, sharedCooldownFrames)
    }
}

public enum TeamCombatEventKind: String, Codable, Sendable {
    case assistEntered, assistExited, tagStarted, tagHandoff, tagCompleted
}

public struct TeamCombatEvent: Codable, Equatable, Sendable {
    public var frame: Int64
    public var kind: TeamCombatEventKind
    public var teamID: String
    public var actorID: EntityID
}

public struct TeamCombatState: Codable, Equatable, Sendable {
    public var teamID: String
    public private(set) var activeID: EntityID
    public private(set) var benchID: EntityID
    public private(set) var benchPhase: BenchPhase = .standby
    public private(set) var cooldownFrames = 0
    public var rules: TeamCombatRules
    private var phaseFrame = 0
    private var handoffDone = false

    public init(
        teamID: String, activeID: EntityID, benchID: EntityID,
        rules: TeamCombatRules = .standard
    ) {
        self.teamID = teamID
        self.activeID = activeID
        self.benchID = benchID
        self.rules = rules
    }

    public mutating func requestAssist(frame: Int64) -> Bool {
        guard benchPhase == .standby, cooldownFrames == 0 else { return false }
        benchPhase = .assisting
        phaseFrame = 0
        return true
    }

    public mutating func requestTag(frame: Int64) -> Bool {
        guard benchPhase == .standby, cooldownFrames == 0 else { return false }
        benchPhase = .taggingOut
        phaseFrame = 0
        handoffDone = false
        return true
    }

    public mutating func advance(frame: Int64) -> [TeamCombatEvent] {
        if cooldownFrames > 0 { cooldownFrames -= 1 }
        guard benchPhase != .standby else { return [] }
        phaseFrame += 1
        switch benchPhase {
        case .assisting:
            if phaseFrame == 1 {
                return [TeamCombatEvent(frame: frame, kind: .assistEntered,
                                        teamID: teamID, actorID: benchID)]
            }
            if phaseFrame >= rules.assistTotalFrames {
                benchPhase = .standby
                cooldownFrames = rules.sharedCooldownFrames
                return [TeamCombatEvent(frame: frame, kind: .assistExited,
                                        teamID: teamID, actorID: benchID)]
            }
        case .taggingOut, .taggingIn:
            if phaseFrame == 1 {
                return [TeamCombatEvent(frame: frame, kind: .tagStarted,
                                        teamID: teamID, actorID: activeID)]
            }
            if !handoffDone, phaseFrame >= rules.tagHandoffFrame {
                swap(&activeID, &benchID)
                handoffDone = true
                benchPhase = .taggingIn
                return [TeamCombatEvent(frame: frame, kind: .tagHandoff,
                                        teamID: teamID, actorID: activeID)]
            }
            if phaseFrame >= rules.tagTotalFrames {
                benchPhase = .standby
                cooldownFrames = rules.sharedCooldownFrames
                return [TeamCombatEvent(frame: frame, kind: .tagCompleted,
                                        teamID: teamID, actorID: activeID)]
            }
        case .standby: break
        }
        return []
    }
}

// MARK: - Neutral escalation

public enum CombatParticipation: Codable, Equatable, Sendable {
    case uninvolved
    case alerted(offenderID: EntityID)
    case incidentalCombatant(primaryOffenderID: EntityID)
    case withdrawing
    case rosterParticipant(teamID: String)
}

public struct NeutralEscalationPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var joinOnFirstDamagingHit: Bool
    public var teamLiability: Bool
    public var cascadeEnabled: Bool
    public var maxIncidentalCombatants: Int
    public var maxCascadeDepth: Int
    public var hostilityDecayFrames: Int
    public var reactionDelayFrames: Int

    public static let desktopBrawl = NeutralEscalationPolicy(
        enabled: true, joinOnFirstDamagingHit: true, teamLiability: true,
        cascadeEnabled: true, maxIncidentalCombatants: 4, maxCascadeDepth: 2,
        hostilityDecayFrames: 1_800, reactionDelayFrames: 1)
    public static let flatArena = NeutralEscalationPolicy(
        enabled: false, joinOnFirstDamagingHit: false, teamLiability: false,
        cascadeEnabled: false, maxIncidentalCombatants: 0, maxCascadeDepth: 0,
        hostilityDecayFrames: 0, reactionDelayFrames: 1)
}

public struct AggroEntry: Codable, Equatable, Sendable {
    public var offenderID: EntityID
    public var offenderTeamID: String?
    public var damage: Int
    public var firstFrame: Int64
    public var lastFrame: Int64
    public var cascadeDepth: Int
}

public enum CombatEscalationEventKind: String, Codable, Sendable {
    case alerted, joined, withdrew, degraded
}

public struct CombatEscalationEvent: Codable, Equatable, Sendable {
    public var frame: Int64
    public var kind: CombatEscalationEventKind
    public var actorID: EntityID
    public var offenderID: EntityID?
}

public struct CombatEscalationState: Codable, Equatable, Sendable {
    public var policy: NeutralEscalationPolicy
    public private(set) var participation: [EntityID: CombatParticipation] = [:]
    public private(set) var aggro: [EntityID: [EntityID: AggroEntry]] = [:]

    public init(policy: NeutralEscalationPolicy) { self.policy = policy }

    public mutating func recordCollateralHit(
        victimID: EntityID, offenderID: EntityID, offenderTeamID: String?,
        damage: Int, frame: Int64, cascadeDepth: Int
    ) {
        guard policy.enabled, damage > 0,
              cascadeDepth <= policy.maxCascadeDepth else { return }
        let prior = aggro[victimID]?[offenderID]
        aggro[victimID, default: [:]][offenderID] = AggroEntry(
            offenderID: offenderID, offenderTeamID: offenderTeamID,
            damage: (prior?.damage ?? 0) + damage,
            firstFrame: prior?.firstFrame ?? frame, lastFrame: frame,
            cascadeDepth: max(prior?.cascadeDepth ?? 0, cascadeDepth))
        if participation[victimID] == nil || participation[victimID] == .uninvolved {
            participation[victimID] = .alerted(offenderID: offenderID)
        }
    }

    public mutating func advance(
        frame: Int64, combatReady: Set<EntityID>
    ) -> [CombatEscalationEvent] {
        var events: [CombatEscalationEvent] = []
        if policy.hostilityDecayFrames > 0 {
            for actorID in participation.keys.sorted(by: { $0.raw < $1.raw }) {
                guard case .incidentalCombatant(let offenderID) = participation[actorID],
                      let entry = aggro[actorID]?[offenderID],
                      frame - entry.lastFrame >= Int64(policy.hostilityDecayFrames)
                else { continue }
                participation[actorID] = .withdrawing
                events.append(CombatEscalationEvent(
                    frame: frame, kind: .withdrew,
                    actorID: actorID, offenderID: offenderID))
            }
        }
        let incidentalCount = participation.values.filter {
            if case .incidentalCombatant = $0 { return true }; return false
        }.count
        var available = max(0, policy.maxIncidentalCombatants - incidentalCount)
        for actorID in participation.keys.sorted(by: { $0.raw < $1.raw }) {
            guard case .alerted(let offenderID) = participation[actorID],
                  let entry = aggro[actorID]?[offenderID],
                  frame - entry.firstFrame >= Int64(policy.reactionDelayFrames) else { continue }
            if policy.joinOnFirstDamagingHit, combatReady.contains(actorID), available > 0 {
                participation[actorID] = .incidentalCombatant(primaryOffenderID: offenderID)
                available -= 1
                events.append(CombatEscalationEvent(
                    frame: frame, kind: .joined, actorID: actorID, offenderID: offenderID))
            } else if !combatReady.contains(actorID) {
                participation[actorID] = .withdrawing
                events.append(CombatEscalationEvent(
                    frame: frame, kind: .degraded, actorID: actorID, offenderID: offenderID))
            }
        }
        return events
    }
}

// MARK: - Desktop interaction policy

public enum WindowGameplayAction: String, Codable, Sendable { case pull, damageOverlay }
public enum WindowAuthorization: String, Codable, Sendable {
    case allowed, disabled, userActive, foregroundProtected, cooldown, rateLimited, insufficientEnergy
}

public struct WindowInteractionPolicy: Codable, Equatable, Sendable {
    public var enabled = true
    public var pullEnabled = false
    public var damageOverlayEnabled = true
    public var energyCostScale = 1.0
    public var minimumEnergyAfterAction = 60
    public var pullCooldownFrames = 1_800
    public var damageCooldownFrames = 900
    public var maxActionsPerMinute = 2
    public var suppressWhileUserActive = true
    public var protectForegroundWindow = true
    private var lastFrame: [WindowGameplayAction: Int64] = [:]
    private var recentFrames: [Int64] = []

    public init() {}

    public mutating func authorize(
        _ action: WindowGameplayAction, energy: inout GameplayEnergyState,
        frame: Int64, userActive: Bool, targetIsForeground: Bool
    ) -> WindowAuthorization {
        guard enabled,
              action != .pull || pullEnabled,
              action != .damageOverlay || damageOverlayEnabled else { return .disabled }
        if suppressWhileUserActive && userActive { return .userActive }
        if protectForegroundWindow && targetIsForeground { return .foregroundProtected }
        let cooldown = action == .pull ? pullCooldownFrames : damageCooldownFrames
        if let last = lastFrame[action], frame - last < Int64(cooldown) { return .cooldown }
        recentFrames.removeAll { frame - $0 >= 3_600 }
        guard recentFrames.count < maxActionsPerMinute else { return .rateLimited }
        let baseCost = action == .pull ? 180 : 120
        let cost = max(0, Int((Double(baseCost) * max(0, energyCostScale)).rounded()))
        guard energy.current - cost >= minimumEnergyAfterAction else { return .insufficientEnergy }
        guard energy.spend(cost, frame: frame) else { return .insufficientEnergy }
        lastFrame[action] = frame
        recentFrames.append(frame)
        return .allowed
    }
}

// MARK: - Variety memory

public struct ActionHistoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var family: CombatActionFamily
}

public struct ActionHistory: Codable, Equatable, Sendable {
    public var capacity: Int
    public private(set) var entries: [ActionHistoryEntry] = []

    public init(capacity: Int = 20) { self.capacity = max(3, capacity) }

    public mutating func record(id: String, family: CombatActionFamily) {
        entries.append(ActionHistoryEntry(id: id, family: family))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func repetitionPenalty(id: String, family: CombatActionFamily) -> Double {
        let direct = entries.suffix(4).filter { $0.id == id }.count
        let sameFamily = entries.suffix(4).filter { $0.family == family }.count
        var sequence = 0
        if entries.count >= 2, entries.suffix(2).allSatisfy({ $0.family == family }) {
            sequence = 1
        }
        return Double(direct * direct * 20 + sameFamily * 8 + sequence * 18)
    }
}
