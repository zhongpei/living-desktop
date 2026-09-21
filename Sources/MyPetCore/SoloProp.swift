import Foundation

/// One prop per solo actor. This is gameplay state, not an AppKit animation.
public struct SoloProp: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case held, placed, despawning
    }

    public var propID: String
    public var phase: Phase
    public var x: Double
    public var y: Double
    public var expiresAtTick: Int64?
    public var fadeEndsAtTick: Int64?

    public init(propID: String, phase: Phase, x: Double = 0, y: Double = 0,
                expiresAtTick: Int64? = nil, fadeEndsAtTick: Int64? = nil) {
        self.propID = propID
        self.phase = phase
        self.x = x
        self.y = y
        self.expiresAtTick = expiresAtTick
        self.fadeEndsAtTick = fadeEndsAtTick
    }

    public func isPlacedNear(x: Double, y: Double, within: Double) -> Bool {
        phase == .placed && within >= 0 &&
            hypot(self.x - x, self.y - y) <= within
    }
}

/// Commands are applied by GameKernel at a tick boundary and can be replayed.
public struct PropCommand: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case spawnHeld, spawnPlaced, putDown, pickUp, despawn, clear
    }

    public var operation: Operation
    public var propID: String?
    public var x: Double?
    public var y: Double?
    public var ttlTicks: Int64?
    public var within: Double?

    public init(_ operation: Operation, propID: String? = nil, x: Double? = nil,
                y: Double? = nil, ttlTicks: Int64? = nil, within: Double? = nil) {
        self.operation = operation
        self.propID = propID
        self.x = x
        self.y = y
        self.ttlTicks = ttlTicks
        self.within = within
    }
}
