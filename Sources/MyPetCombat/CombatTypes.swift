import Foundation
import MyPetCore
import MyPet2D

public enum CombatPhase: String, Codable, Sendable {
    case neutral, startup, active, recovery, guarding, hitStun, blockStun
}

public enum CombatHealthState: String, Codable, Sendable {
    case active, knockedOut, downed, gettingUp
}

public enum CombatControlAuthority: String, Codable, Sendable {
    case autonomous, authored, manual, pointer, scripted
}

public enum CombatRosterRole: String, Codable, Sendable {
    case active, bench, assist, incidental
}

public enum CombatAttackHeight: String, Codable, Sendable {
    case high, mid, low, air, throwAttack
}

public struct CollisionBox: Codable, Equatable, Sendable {
    public var rect: CombatRect
    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        rect = CombatRect(x: min(x1, x2), y: min(y1, y2),
                          width: abs(x2 - x1), height: abs(y2 - y1))
    }

    public func placed(at axis: CombatPoint, facing: CombatFacing, scale: Double = 1) -> CombatRect {
        let x1 = rect.minX * scale * facing.sign + axis.x
        let x2 = rect.maxX * scale * facing.sign + axis.x
        return CombatRect(
            x: min(x1, x2),
            y: axis.y + rect.minY * scale,
            width: abs(x2 - x1),
            height: rect.height * scale)
    }
}

public struct CombatHitDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var damage: Int
    public var chipDamage: Int
    public var hitStopFrames: Int
    public var hitStunFrames: Int
    public var blockStunFrames: Int
    public var knockbackX: Double
    public var knockbackY: Double
    public var attackBoxes: [CollisionBox]
    public var attackHeight: CombatAttackHeight
    public var hitGroup: String
    public var rehitFrames: Int?
    public var clashLevel: Int

    public init(id: String = "primary", damage: Int = 40, chipDamage: Int = 0,
                hitStopFrames: Int = 5,
                hitStunFrames: Int = 14, blockStunFrames: Int = 9,
                knockbackX: Double = 3.2, knockbackY: Double = 0,
                attackBoxes: [CollisionBox] = [CollisionBox(x1: 18, y1: -78, x2: 78, y2: -25)],
                attackHeight: CombatAttackHeight = .mid,
                hitGroup: String = "primary", rehitFrames: Int? = nil,
                clashLevel: Int = 0) {
        self.id = id.isEmpty ? "primary" : id
        self.damage = max(0, damage)
        self.chipDamage = max(0, chipDamage)
        self.hitStopFrames = max(0, hitStopFrames)
        self.hitStunFrames = max(0, hitStunFrames)
        self.blockStunFrames = max(0, blockStunFrames)
        self.knockbackX = knockbackX
        self.knockbackY = knockbackY
        self.attackBoxes = attackBoxes
        self.attackHeight = attackHeight
        self.hitGroup = hitGroup.isEmpty ? self.id : hitGroup
        self.rehitFrames = rehitFrames.map { max(1, $0) }
        self.clashLevel = max(0, clashLevel)
    }

    private enum CodingKeys: String, CodingKey {
        case id, damage, chipDamage, hitStopFrames, hitStunFrames, blockStunFrames
        case knockbackX, knockbackY, attackBoxes, attackHeight, hitGroup, rehitFrames, clashLevel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(String.self, forKey: .id) ?? "primary",
            damage: try values.decodeIfPresent(Int.self, forKey: .damage) ?? 40,
            chipDamage: try values.decodeIfPresent(Int.self, forKey: .chipDamage) ?? 0,
            hitStopFrames: try values.decodeIfPresent(Int.self, forKey: .hitStopFrames) ?? 5,
            hitStunFrames: try values.decodeIfPresent(Int.self, forKey: .hitStunFrames) ?? 14,
            blockStunFrames: try values.decodeIfPresent(Int.self, forKey: .blockStunFrames) ?? 9,
            knockbackX: try values.decodeIfPresent(Double.self, forKey: .knockbackX) ?? 3.2,
            knockbackY: try values.decodeIfPresent(Double.self, forKey: .knockbackY) ?? 0,
            attackBoxes: try values.decodeIfPresent([CollisionBox].self, forKey: .attackBoxes)
                ?? [CollisionBox(x1: 18, y1: -78, x2: 78, y2: -25)],
            attackHeight: try values.decodeIfPresent(CombatAttackHeight.self, forKey: .attackHeight) ?? .mid,
            hitGroup: try values.decodeIfPresent(String.self, forKey: .hitGroup) ?? "primary",
            rehitFrames: try values.decodeIfPresent(Int.self, forKey: .rehitFrames),
            clashLevel: try values.decodeIfPresent(Int.self, forKey: .clashLevel) ?? 0)
    }
}

public struct CombatMoveDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var command: CombatCommand
    public var startupFrames: Int
    public var activeFrames: Int
    public var recoveryFrames: Int
    public var hit: CombatHitDefinition
    /// Petpack action name without the actions/ prefix.
    public var visualAction: String
    public var projectile: ProjectileDefinition?
    /// Several independently timed projectiles may belong to one move (for example, thrown bowls).
    public var projectiles: [ProjectileDefinition]?
    /// FightingICE-style start/hit/guard resource deltas translated into the
    /// shared MyPet gameplay resource. Optional preserves schema-v1 profiles.
    public var resourceRules: MoveResourceRules?
    /// Optional mapped gameplay control. Character profiles bind a logical
    /// control to a move; physical keys remain entirely outside content data.
    public var systemControl: CombatSystemControl?

    public init(id: String, command: CombatCommand, startupFrames: Int, activeFrames: Int,
                recoveryFrames: Int, hit: CombatHitDefinition, visualAction: String,
                projectile: ProjectileDefinition? = nil,
                projectiles: [ProjectileDefinition]? = nil,
                resourceRules: MoveResourceRules? = nil,
                systemControl: CombatSystemControl? = nil) {
        self.id = id
        self.command = command
        self.startupFrames = max(0, startupFrames)
        self.activeFrames = max(1, activeFrames)
        self.recoveryFrames = max(0, recoveryFrames)
        self.hit = hit
        self.visualAction = visualAction
        self.projectile = projectile
        self.projectiles = projectiles
        self.resourceRules = resourceRules
        self.systemControl = systemControl
    }

    public var totalFrames: Int { startupFrames + activeFrames + recoveryFrames }
    public var authoredProjectiles: [ProjectileDefinition] {
        (projectile.map { [$0] } ?? []) + (projectiles ?? [])
    }
    public var effectiveResourceRules: MoveResourceRules {
        resourceRules ?? MoveResourceRules(
            family: authoredProjectiles.isEmpty ? .fastMelee : .projectile,
            startCost: authoredProjectiles.isEmpty ? 0 : 45)
    }

    public var actionDefinition: ActionDefinition {
        ActionDefinition(
            actionID: id,
            durationFrames: totalFrames,
            animationBinding: visualAction,
            domain: .combat,
            startupFrames: startupFrames,
            activeFrames: activeFrames,
            locomotionPolicy: .stationary)
    }
}

public struct CombatProfile: Codable, Equatable, Sendable {
    public var maxHP: Int
    public var walkSpeed: Double
    public var jumpVelocity: Double
    public var pushRadius: Double
    public var hurtBoxes: [CollisionBox]
    public var moves: [CombatMoveDefinition]
    public var downedRecoveryFrames: Int
    public var getUpFrames: Int
    public var revivedHPFraction: Double
    public var reviveInvulnerabilityFrames: Int

    public init(maxHP: Int = 1000, walkSpeed: Double = 1.5, jumpVelocity: Double = -8.6,
                pushRadius: Double = 24,
                hurtBoxes: [CollisionBox] = [CollisionBox(x1: -24, y1: -92, x2: 24, y2: 0)],
                moves: [CombatMoveDefinition] = CombatProfile.defaultMoves,
                downedRecoveryFrames: Int = 480, getUpFrames: Int = 36,
                revivedHPFraction: Double = 0.30, reviveInvulnerabilityFrames: Int = 120) {
        self.maxHP = max(1, maxHP)
        self.walkSpeed = max(0, walkSpeed)
        self.jumpVelocity = jumpVelocity
        self.pushRadius = max(1, pushRadius)
        self.hurtBoxes = hurtBoxes
        self.moves = moves
        self.downedRecoveryFrames = max(1, downedRecoveryFrames)
        self.getUpFrames = max(1, getUpFrames)
        self.revivedHPFraction = min(1, max(0.01, revivedHPFraction))
        self.reviveInvulnerabilityFrames = max(0, reviveInvulnerabilityFrames)
    }

    public static let defaultMoves: [CombatMoveDefinition] = [
        CombatMoveDefinition(
            id: "light", command: .button(.x), startupFrames: 4, activeFrames: 3, recoveryFrames: 9,
            hit: CombatHitDefinition(damage: 35, hitStopFrames: 4, hitStunFrames: 12,
                                     blockStunFrames: 8, knockbackX: 2.6),
            visualAction: "attack"),
        CombatMoveDefinition(
            id: "heavy", command: .button(.y), startupFrames: 8, activeFrames: 4, recoveryFrames: 15,
            hit: CombatHitDefinition(damage: 80, hitStopFrames: 7, hitStunFrames: 20,
                                     blockStunFrames: 12, knockbackX: 5.0, knockbackY: -2.0,
                                     attackBoxes: [CollisionBox(x1: 16, y1: -92, x2: 92, y2: -18)]),
            visualAction: "attack"),
        CombatMoveDefinition(
            id: "special", command: CombatCommand([
                CombatCommandStep(direction: .down),
                CombatCommandStep(direction: .downForward),
                CombatCommandStep(direction: .forward),
                CombatCommandStep(button: .z, maxGapFrames: 3)
            ]), startupFrames: 10, activeFrames: 5, recoveryFrames: 20,
            hit: CombatHitDefinition(damage: 125, hitStopFrames: 9, hitStunFrames: 28,
                                     blockStunFrames: 15, knockbackX: 7.2, knockbackY: -3.2,
                                     attackBoxes: [CollisionBox(x1: 10, y1: -105, x2: 110, y2: -10)]),
            visualAction: "attack")
    ]

    public func move(id: String?) -> CombatMoveDefinition? {
        guard let id else { return nil }
        return moves.first { $0.id == id }
    }
}

public struct CombatRuleState: Codable, Equatable, Sendable {
    public var actorID: EntityID
    public var phase: CombatPhase
    public var healthState: CombatHealthState
    public var hp: Int
    /// Optional so checkpoints written before ActionTimeline continue to decode.
    public var actionSequence: Int64?
    public var hitStopFrames: Int
    public var stunFrames: Int
    public var recoveryFramesRemaining: Int
    public var invulnerabilityFrames: Int
    public var authority: CombatControlAuthority
    public var hitTargets: Set<String>
    /// Per move-instance and hit-group contact frames. Optional preserves old checkpoints.
    public var hitLedger: [String: Int64]?
    public var visualScale: Double
    public var gameplayEnergy: GameplayEnergyState?
    public var participation: CombatParticipation?
    public var combo: ComboState?
    public var lastRecoveryChoice: RecoveryChoice?
    public var rosterRole: CombatRosterRole?
    public var powerUpFrames: Int?

    public init(actorID: EntityID, hp: Int = 1000, visualScale: Double = 1) {
        self.actorID = actorID
        self.phase = .neutral
        self.healthState = .active
        self.hp = hp
        self.actionSequence = nil
        self.hitStopFrames = 0
        self.stunFrames = 0
        self.recoveryFramesRemaining = 0
        self.invulnerabilityFrames = 0
        self.authority = .autonomous
        self.hitTargets = []
        self.hitLedger = [:]
        self.visualScale = max(0.05, visualScale)
        self.gameplayEnergy = GameplayEnergyState(current: 150)
        self.participation = .uninvolved
        self.combo = ComboState()
        self.lastRecoveryChoice = nil
        self.rosterRole = .active
        self.powerUpFrames = 0
    }

    public var canAcceptAction: Bool {
        healthState == .active && rosterRole != .bench && hitStopFrames == 0 && stunFrames == 0 &&
        (phase == .neutral || phase == .guarding)
    }
}

/// Read/write compatibility view combining MyPet2D physical state with combat-only rules.
public struct CombatBodyState: Codable, Equatable, Sendable {
    public var body: BodyState
    public var rules: CombatRuleState

    public init(body: BodyState, rules: CombatRuleState) {
        precondition(body.entityID == rules.actorID)
        self.body = body
        self.rules = rules
    }

    public init(actorID: EntityID, x: Double, yFeet: Double, hp: Int = 1000,
                facing: CombatFacing = .right, visualScale: Double = 1) {
        body = BodyState(entityID: actorID, position: Vec2(x: x, y: yFeet), facing: facing)
        rules = CombatRuleState(actorID: actorID, hp: hp, visualScale: visualScale)
    }

    public var actorID: EntityID { body.entityID }
    public var position: Vec2 { get { body.position } set { body.position = newValue } }
    public var velocity: Vec2 { get { body.velocity } set { body.velocity = newValue } }
    public var facing: Facing2D { get { body.facing } set { body.facing = newValue } }
    public var locomotion: LocomotionState { get { body.locomotion } set { body.locomotion = newValue } }
    public var currentSurfaceID: String? {
        get { body.currentSurfaceID }
        set { body.currentSurfaceID = newValue }
    }
    public var surfaceFraction: Double? {
        get { body.surfaceFraction }
        set { body.surfaceFraction = newValue }
    }
    public var phase: CombatPhase { get { rules.phase } set { rules.phase = newValue } }
    public var healthState: CombatHealthState {
        get { rules.healthState }
        set { rules.healthState = newValue }
    }
    public var hp: Int { get { rules.hp } set { rules.hp = newValue } }
    public var actionTimeline: ActionTimeline? {
        get { body.actionTimeline }
        set { body.actionTimeline = newValue }
    }
    public var currentMoveID: String? {
        body.actionTimeline?.definition.domain == .combat
            ? body.actionTimeline?.definition.actionID : nil
    }
    public var hitStopFrames: Int {
        get { rules.hitStopFrames }
        set { rules.hitStopFrames = newValue }
    }
    public var stunFrames: Int { get { rules.stunFrames } set { rules.stunFrames = newValue } }
    public var recoveryFramesRemaining: Int {
        get { rules.recoveryFramesRemaining }
        set { rules.recoveryFramesRemaining = newValue }
    }
    public var invulnerabilityFrames: Int {
        get { rules.invulnerabilityFrames }
        set { rules.invulnerabilityFrames = newValue }
    }
    public var authority: CombatControlAuthority {
        get { rules.authority }
        set { rules.authority = newValue }
    }
    public var hitTargets: Set<String> {
        get { rules.hitTargets }
        set { rules.hitTargets = newValue }
    }
    public var hitLedger: [String: Int64] {
        get { rules.hitLedger ?? [:] }
        set { rules.hitLedger = newValue }
    }
    public var visualScale: Double {
        get { rules.visualScale }
        set { rules.visualScale = max(0.05, newValue) }
    }
    public var gameplayEnergy: GameplayEnergyState {
        get { rules.gameplayEnergy ?? GameplayEnergyState(current: 0) }
        set { rules.gameplayEnergy = newValue }
    }
    public var participation: CombatParticipation {
        get { rules.participation ?? .uninvolved }
        set { rules.participation = newValue }
    }
    public var combo: ComboState {
        get { rules.combo ?? ComboState() }
        set { rules.combo = newValue }
    }
    public var lastRecoveryChoice: RecoveryChoice? {
        get { rules.lastRecoveryChoice }
        set { rules.lastRecoveryChoice = newValue }
    }
    public var rosterRole: CombatRosterRole {
        get { rules.rosterRole ?? .active }
        set { rules.rosterRole = newValue }
    }
    public var powerUpFrames: Int {
        get { rules.powerUpFrames ?? 0 }
        set { rules.powerUpFrames = max(0, newValue) }
    }

    public var canAcceptAction: Bool { rules.canAcceptAction }
}

public enum CombatEventKind: String, Codable, Sendable {
    case moveStarted, hit, blocked, clash, projectileSpawned, projectileExpired
    case knockedOut, downed, recoveryStarted, recovered
    case energySpent, energyGained, comboAdvanced, recoverySelected
    case assistEntered, assistExited, tagStarted, tagHandoff, tagCompleted
    case neutralAlerted, neutralJoined, neutralWithdrew
    case powerUpStarted, powerUpEnded
}

public struct CombatEvent: Codable, Equatable, Sendable {
    public var frame: Int64
    public var kind: CombatEventKind
    public var actorID: EntityID
    public var targetID: EntityID?
    public var moveID: String?
    public var amount: Int?

    public init(frame: Int64, kind: CombatEventKind, actorID: EntityID,
                targetID: EntityID? = nil, moveID: String? = nil, amount: Int? = nil) {
        self.frame = frame; self.kind = kind; self.actorID = actorID
        self.targetID = targetID; self.moveID = moveID; self.amount = amount
    }
}

public struct CombatWorldSnapshot: Codable, Equatable, Sendable {
    public var frame: Int64
    public var bodies: [CombatBodyState]
    public var projectiles: [CombatProjectileSnapshot]
    public init(frame: Int64, bodies: [CombatBodyState],
                projectiles: [CombatProjectileSnapshot] = []) {
        self.frame = frame
        self.bodies = bodies.sorted { $0.actorID.raw < $1.actorID.raw }
        self.projectiles = projectiles.sorted { $0.entityID.raw < $1.entityID.raw }
    }

    private enum CodingKeys: String, CodingKey { case frame, bodies, projectiles }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            frame: try values.decode(Int64.self, forKey: .frame),
            bodies: try values.decode([CombatBodyState].self, forKey: .bodies),
            projectiles: try values.decodeIfPresent(
                [CombatProjectileSnapshot].self, forKey: .projectiles) ?? [])
    }
}


public struct CombatWorldCheckpoint: Codable, Equatable, Sendable {
    public var frame: Int64
    public var bodyWorld: BodyWorldCheckpoint
    public var rules: [String: CombatRuleState]
    public var profiles: [String: CombatProfile]
    public var inputs: [String: FighterInputFrame]
    public var buffers: [String: CombatInputBuffer]
    public var session: CombatSession?
    public var projectiles: [String: CombatProjectileState]?
    public var teams: [String: TeamCombatState]?
    public var escalation: CombatEscalationState?

    public init(frame: Int64, bodyWorld: BodyWorldCheckpoint, rules: [String: CombatRuleState],
                profiles: [String: CombatProfile], inputs: [String: FighterInputFrame],
                buffers: [String: CombatInputBuffer], session: CombatSession? = nil,
                projectiles: [String: CombatProjectileState]? = nil,
                teams: [String: TeamCombatState]? = nil,
                escalation: CombatEscalationState? = nil) {
        self.frame = frame
        self.bodyWorld = bodyWorld
        self.rules = rules
        self.profiles = profiles
        self.inputs = inputs
        self.buffers = buffers
        self.session = session
        self.projectiles = projectiles
        self.teams = teams
        self.escalation = escalation
    }
}
