import Foundation
import MyPetCore

public enum BodyLocomotionState: String, Codable, Sendable {
    case grounded, airborne, dragged, tossed, sleeping
}

public enum CombatPhase: String, Codable, Sendable {
    case neutral, startup, active, recovery, guarding, hitStun, blockStun
}

public enum CombatHealthState: String, Codable, Sendable {
    case active, knockedOut, downed, gettingUp
}

public enum CombatControlAuthority: String, Codable, Sendable {
    case autonomous, manual, pointer, scripted
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
    public var damage: Int
    public var chipDamage: Int
    public var hitStopFrames: Int
    public var hitStunFrames: Int
    public var blockStunFrames: Int
    public var knockbackX: Double
    public var knockbackY: Double
    public var attackBoxes: [CollisionBox]

    public init(damage: Int = 40, chipDamage: Int = 0, hitStopFrames: Int = 5,
                hitStunFrames: Int = 14, blockStunFrames: Int = 9,
                knockbackX: Double = 3.2, knockbackY: Double = 0,
                attackBoxes: [CollisionBox] = [CollisionBox(x1: 18, y1: -78, x2: 78, y2: -25)]) {
        self.damage = max(0, damage)
        self.chipDamage = max(0, chipDamage)
        self.hitStopFrames = max(0, hitStopFrames)
        self.hitStunFrames = max(0, hitStunFrames)
        self.blockStunFrames = max(0, blockStunFrames)
        self.knockbackX = knockbackX
        self.knockbackY = knockbackY
        self.attackBoxes = attackBoxes
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

    public init(id: String, command: CombatCommand, startupFrames: Int, activeFrames: Int,
                recoveryFrames: Int, hit: CombatHitDefinition, visualAction: String) {
        self.id = id
        self.command = command
        self.startupFrames = max(0, startupFrames)
        self.activeFrames = max(1, activeFrames)
        self.recoveryFrames = max(0, recoveryFrames)
        self.hit = hit
        self.visualAction = visualAction
    }

    public var totalFrames: Int { startupFrames + activeFrames + recoveryFrames }
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

public struct CombatBodyState: Codable, Equatable, Sendable {
    public var actorID: EntityID
    public var position: CombatPoint
    public var velocity: CombatPoint
    public var facing: CombatFacing
    public var locomotion: BodyLocomotionState
    public var phase: CombatPhase
    public var healthState: CombatHealthState
    public var hp: Int
    public var currentSurfaceID: String?
    public var surfaceFraction: Double?
    public var currentMoveID: String?
    public var moveFrame: Int
    public var hitStopFrames: Int
    public var stunFrames: Int
    public var recoveryFramesRemaining: Int
    public var invulnerabilityFrames: Int
    public var authority: CombatControlAuthority
    public var hitTargets: Set<String>
    public var visualScale: Double

    public init(actorID: EntityID, x: Double, yFeet: Double, hp: Int = 1000,
                facing: CombatFacing = .right, visualScale: Double = 1) {
        self.actorID = actorID
        self.position = CombatPoint(x: x, y: yFeet)
        self.velocity = CombatPoint()
        self.facing = facing
        self.locomotion = .grounded
        self.phase = .neutral
        self.healthState = .active
        self.hp = hp
        self.currentSurfaceID = nil
        self.surfaceFraction = nil
        self.currentMoveID = nil
        self.moveFrame = 0
        self.hitStopFrames = 0
        self.stunFrames = 0
        self.recoveryFramesRemaining = 0
        self.invulnerabilityFrames = 0
        self.authority = .autonomous
        self.hitTargets = []
        self.visualScale = max(0.05, visualScale)
    }

    public var canAcceptAction: Bool {
        healthState == .active && hitStopFrames == 0 && stunFrames == 0 &&
        (phase == .neutral || phase == .guarding)
    }
}

public enum CombatEventKind: String, Codable, Sendable {
    case moveStarted, hit, blocked, knockedOut, downed, recoveryStarted, recovered
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
    public init(frame: Int64, bodies: [CombatBodyState]) {
        self.frame = frame
        self.bodies = bodies.sorted { $0.actorID.raw < $1.actorID.raw }
    }
}


public struct CombatWorldCheckpoint: Codable, Equatable, Sendable {
    public var frame: Int64
    public var bodies: [String: CombatBodyState]
    public var profiles: [String: CombatProfile]
    public var inputs: [String: FighterInputFrame]
    public var buffers: [String: CombatInputBuffer]

    public init(frame: Int64, bodies: [String: CombatBodyState],
                profiles: [String: CombatProfile], inputs: [String: FighterInputFrame],
                buffers: [String: CombatInputBuffer]) {
        self.frame = frame
        self.bodies = bodies
        self.profiles = profiles
        self.inputs = inputs
        self.buffers = buffers
    }
}
