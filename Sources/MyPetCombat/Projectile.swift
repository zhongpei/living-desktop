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
    /// Maximum world-space distance from the spawn point. `nil` preserves
    /// schema-v1 lifetime-only content; schema-v2 combat content should author
    /// this explicitly so one desktop projectile cannot cross every display.
    public var maxTravelDistance: Double?
    /// Optional AI range floor. Manual input may still perform the move at any
    /// legal state; autonomous zoning uses this to avoid point-blank spam.
    public var minimumRange: Double?
    /// Optional per-owner occupancy used by autonomous move selection.
    public var maxConcurrentOwned: Int?
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
        maxTravelDistance: Double? = nil,
        minimumRange: Double? = nil,
        maxConcurrentOwned: Int? = nil,
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
        self.maxTravelDistance = maxTravelDistance.map { max(0, $0) }
        self.minimumRange = minimumRange.map { max(0, $0) }
        self.maxConcurrentOwned = maxConcurrentOwned.map { max(1, $0) }
        self.collisionMask = collisionMask
        self.hit = hit
        self.visualResourceID = visualResourceID
        self.destroyOnHit = destroyOnHit
    }

    public var effectiveTravelDistance: Double {
        maxTravelDistance ?? hypot(velocity.x, velocity.y) * Double(lifetimeFrames)
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
    public var travelledDistance: Double
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
        self.travelledDistance = 0
        self.hitLedger = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case entityID, ownerID, moveID, moveInstanceID, definition
        case spawnedAtFrame, previousPosition, travelledDistance, hitLedger
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try values.decode(EntityID.self, forKey: .entityID)
        ownerID = try values.decode(EntityID.self, forKey: .ownerID)
        moveID = try values.decode(String.self, forKey: .moveID)
        moveInstanceID = try values.decode(Int64.self, forKey: .moveInstanceID)
        definition = try values.decode(ProjectileDefinition.self, forKey: .definition)
        spawnedAtFrame = try values.decode(Int64.self, forKey: .spawnedAtFrame)
        previousPosition = try values.decode(Vec2.self, forKey: .previousPosition)
        travelledDistance = try values.decodeIfPresent(Double.self, forKey: .travelledDistance) ?? 0
        hitLedger = try values.decodeIfPresent([String: Int64].self, forKey: .hitLedger) ?? [:]
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
