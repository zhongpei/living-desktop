import Foundation
import MyPetCore

public enum CombatSessionState: String, Codable, Sendable {
    case active, completed, cancelled
}

/// Explicit authorization boundary for HP-changing combat. Merely playing an
/// attack-shaped presentation action never creates a session.
public struct CombatSession: Codable, Equatable, Sendable {
    public var id: String
    public var participantIDs: [EntityID]
    public var startedAtFrame: Int64
    public var endedAtFrame: Int64?
    public var state: CombatSessionState

    public init(id: String, participants: [EntityID], startedAtFrame: Int64) {
        self.id = id
        self.participantIDs = Array(Set(participants)).sorted { $0.raw < $1.raw }
        self.startedAtFrame = startedAtFrame
        self.endedAtFrame = nil
        self.state = .active
    }

    public func permits(_ actorID: EntityID, _ targetID: EntityID) -> Bool {
        guard state == .active else { return false }
        let participants = Set(participantIDs)
        return actorID != targetID && participants.contains(actorID) && participants.contains(targetID)
    }
}
