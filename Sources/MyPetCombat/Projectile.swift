import Foundation
import MyPetCore
import MyPet2D

/// Authored combat rules for a body-backed projectile. Animation callbacks do
/// not create or resolve hits; the fixed-step combat runtime owns its lifetime.
public struct ProjectileDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var spawnFrame: Int
    public var spawnOffset: Vec2
    public var velocity: Vec2
    public var lifetimeFrames: Int
    public var collisionMask: CollisionMask
    public var hit: CombatHitDefinition
    public var visualResourceID: String
    public var destroyOnHit: Bool

    public init(
        id: String,
        spawnFrame: Int = 0,
        spawnOffset: Vec2 = Vec2(),
        velocity: Vec2,
        lifetimeFrames: Int,
        collisionMask: CollisionMask = [.hit, .hurt],
        hit: CombatHitDefinition,
        visualResourceID: String,
        destroyOnHit: Bool = true
    ) {
        self.id = id
        self.spawnFrame = max(0, spawnFrame)
        self.spawnOffset = spawnOffset
        self.velocity = velocity
        self.lifetimeFrames = max(1, lifetimeFrames)
        self.collisionMask = collisionMask
        self.hit = hit
        self.visualResourceID = visualResourceID
        self.destroyOnHit = destroyOnHit
    }
}

public struct CombatProjectileState: Codable, Equatable, Sendable {
    public var entityID: EntityID
    public var ownerID: EntityID
    public var moveID: String
    public var moveInstanceID: Int64
    public var definition: ProjectileDefinition
    public var spawnedAtFrame: Int64
    public var previousPosition: Vec2
    public var hitLedger: [String: Int64]

    public init(
        entityID: EntityID,
        ownerID: EntityID,
        moveID: String,
        moveInstanceID: Int64,
        definition: ProjectileDefinition,
        spawnedAtFrame: Int64,
        previousPosition: Vec2
    ) {
        self.entityID = entityID
        self.ownerID = ownerID
        self.moveID = moveID
        self.moveInstanceID = moveInstanceID
        self.definition = definition
        self.spawnedAtFrame = spawnedAtFrame
        self.previousPosition = previousPosition
        self.hitLedger = [:]
    }
}

public struct CombatProjectileSnapshot: Codable, Equatable, Sendable {
    public var entityID: EntityID
    public var ownerID: EntityID
    public var definitionID: String
    public var position: Vec2
    public var velocity: Vec2
    public var spawnedAtFrame: Int64
    public var visualResourceID: String
}
