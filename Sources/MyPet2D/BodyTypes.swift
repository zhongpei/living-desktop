import Foundation
import MyPetCore

public enum LocomotionState: String, Codable, Sendable {
    case grounded, airborne, dragged, tossed, sleeping
}

public struct BodyDefinition: Codable, Equatable, Sendable {
    public var entityID: EntityID
    public var pushRadius: Double
    public var visualScale: Double
    public var pushEnabled: Bool
    public var simulationEnabled: Bool
    public var collisionMask: CollisionMask

    public init(
        entityID: EntityID,
        pushRadius: Double = 24,
        visualScale: Double = 1,
        pushEnabled: Bool = true,
        simulationEnabled: Bool = true,
        collisionMask: CollisionMask = [.environment, .body]
    ) {
        self.entityID = entityID
        self.pushRadius = max(1, pushRadius)
        self.visualScale = max(0.05, visualScale)
        self.pushEnabled = pushEnabled
        self.simulationEnabled = simulationEnabled
        self.collisionMask = collisionMask
    }
}

public struct BodyState: Codable, Equatable, Sendable {
    public var entityID: EntityID
    public var position: Vec2
    public var velocity: Vec2
    public var facing: Facing2D
    public var locomotion: LocomotionState
    public var currentSurfaceID: String?
    public var surfaceFraction: Double?
    public var landingHorizontalVelocityRetention: Double

    public init(
        entityID: EntityID,
        position: Vec2,
        velocity: Vec2 = Vec2(),
        facing: Facing2D = .right,
        locomotion: LocomotionState = .grounded,
        currentSurfaceID: String? = nil,
        surfaceFraction: Double? = nil,
        landingHorizontalVelocityRetention: Double = 0
    ) {
        self.entityID = entityID
        self.position = position
        self.velocity = velocity
        self.facing = facing
        self.locomotion = locomotion
        self.currentSurfaceID = currentSurfaceID
        self.surfaceFraction = surfaceFraction
        self.landingHorizontalVelocityRetention = min(1, max(0, landingHorizontalVelocityRetention))
    }
}

public struct Contact: Codable, Equatable, Sendable {
    public var entityID: EntityID
    public var surfaceID: String

    public init(entityID: EntityID, surfaceID: String) {
        self.entityID = entityID
        self.surfaceID = surfaceID
    }
}

public struct BodyFrameResult: Codable, Equatable, Sendable {
    public var frame: Int64
    public var contacts: [Contact]

    public init(frame: Int64, contacts: [Contact] = []) {
        self.frame = frame
        self.contacts = contacts
    }
}

public struct BodyWorldSnapshot: Codable, Equatable, Sendable {
    public var frame: Int64
    public var bodies: [BodyState]

    public init(frame: Int64, bodies: [BodyState]) {
        self.frame = frame
        self.bodies = bodies.sorted { $0.entityID.raw < $1.entityID.raw }
    }
}

public struct BodyWorldCheckpoint: Codable, Equatable, Sendable {
    public var frame: Int64
    public var definitions: [String: BodyDefinition]
    public var bodies: [String: BodyState]
    public var dragLast: [String: Vec2]

    public init(
        frame: Int64,
        definitions: [String: BodyDefinition],
        bodies: [String: BodyState],
        dragLast: [String: Vec2] = [:]
    ) {
        self.frame = frame
        self.definitions = definitions
        self.bodies = bodies
        self.dragLast = dragLast
    }
}
