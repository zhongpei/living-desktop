import Foundation
import MyPetCore

public enum CombatSessionState: String, Codable, Sendable {
    case active, completed, cancelled
}

public enum CombatSessionEndReason: String, Codable, Sendable {
    case knockout, timeout, doubleKnockout, completed, cancelled
}

public struct CombatRoundRules: Codable, Equatable, Sendable {
    public var durationFrames: Int
    public var endOnKnockout: Bool

    public static let desktop = CombatRoundRules(durationFrames: 0, endOnKnockout: false)
    public static let formal = CombatRoundRules(durationFrames: 99 * 60, endOnKnockout: true)

    public init(durationFrames: Int = 0, endOnKnockout: Bool = false) {
        self.durationFrames = max(0, durationFrames)
        self.endOnKnockout = endOnKnockout
    }
}

/// Explicit authorization boundary for HP-changing combat. Merely playing an
/// attack-shaped presentation action never creates a session.
public struct CombatSession: Codable, Equatable, Sendable {
    public var id: String
    public var participantIDs: [EntityID]
    public var startedAtFrame: Int64
    public var endedAtFrame: Int64?
    public var state: CombatSessionState
    public var roundRules: CombatRoundRules
    public var winnerIDs: [EntityID]
    public var endReason: CombatSessionEndReason?

    private enum CodingKeys: String, CodingKey {
        case id, participantIDs, startedAtFrame, endedAtFrame, state
        case roundRules, winnerIDs, endReason
    }

    public init(
        id: String, participants: [EntityID], startedAtFrame: Int64,
        roundRules: CombatRoundRules = .desktop
    ) {
        self.id = id
        self.participantIDs = Array(Set(participants)).sorted { $0.raw < $1.raw }
        self.startedAtFrame = startedAtFrame
        self.endedAtFrame = nil
        self.state = .active
        self.roundRules = roundRules
        self.winnerIDs = []
        self.endReason = nil
    }

    public func permits(_ actorID: EntityID, _ targetID: EntityID) -> Bool {
        guard state == .active else { return false }
        let participants = Set(participantIDs)
        return actorID != targetID && participants.contains(actorID) && participants.contains(targetID)
    }

    public func elapsedFrames(at currentFrame: Int64) -> Int64 {
        max(0, (endedAtFrame ?? currentFrame) - startedAtFrame)
    }

    public func remainingFrames(at currentFrame: Int64) -> Int? {
        guard roundRules.durationFrames > 0 else { return nil }
        return max(0, roundRules.durationFrames - Int(elapsedFrames(at: currentFrame)))
    }

    public mutating func complete(
        at frame: Int64, winners: [EntityID], reason: CombatSessionEndReason
    ) {
        guard state == .active else { return }
        state = reason == .cancelled ? .cancelled : .completed
        endedAtFrame = frame
        winnerIDs = Array(Set(winners)).sorted { $0.raw < $1.raw }
        endReason = reason
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        participantIDs = try values.decode([EntityID].self, forKey: .participantIDs)
        startedAtFrame = try values.decode(Int64.self, forKey: .startedAtFrame)
        endedAtFrame = try values.decodeIfPresent(Int64.self, forKey: .endedAtFrame)
        state = try values.decode(CombatSessionState.self, forKey: .state)
        roundRules = try values.decodeIfPresent(
            CombatRoundRules.self, forKey: .roundRules) ?? .desktop
        winnerIDs = try values.decodeIfPresent([EntityID].self, forKey: .winnerIDs) ?? []
        endReason = try values.decodeIfPresent(
            CombatSessionEndReason.self, forKey: .endReason)
    }
}
