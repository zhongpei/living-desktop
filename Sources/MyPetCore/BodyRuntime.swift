import Foundation

public enum BodyExecutionMode: String, Codable, Sendable {
    case headless
    case external
}

public struct BodyCommand: Codable, Equatable, Sendable {
    public var behaviorID: String
    public var executionToken: Int64
    public var actorID: EntityID
    public var intent: String
    public var target: EntityRef?
    public var slot: SlotRef?
    public var durationTicks: Int64
    public var planEpoch: Int64

    public init(behaviorID: String, executionToken: Int64, actorID: EntityID,
                intent: String, target: EntityRef?, slot: SlotRef?,
                durationTicks: Int64, planEpoch: Int64) {
        self.behaviorID = behaviorID
        self.executionToken = executionToken
        self.actorID = actorID
        self.intent = intent
        self.target = target
        self.slot = slot
        self.durationTicks = durationTicks
        self.planEpoch = planEpoch
    }
}

public enum BodyResultOutcome: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

public struct BodyResult: Codable, Equatable, Sendable {
    public var behaviorID: String
    public var executionToken: Int64
    public var outcome: BodyResultOutcome

    public init(behaviorID: String, executionToken: Int64, outcome: BodyResultOutcome) {
        self.behaviorID = behaviorID
        self.executionToken = executionToken
        self.outcome = outcome
    }
}

public struct BodyPose: Codable, Equatable, Sendable {
    public var actorID: EntityID
    public var x: Double
    public var yFeet: Double
    public var facingRight: Bool
    public var motion: String
    public var action: String?
    public var horizontalSpeed: Double
    /// Only needed for translating a successful put-down to a world position.
    public var displayHeight: Double?

    public init(
        actorID: EntityID,
        x: Double,
        yFeet: Double,
        facingRight: Bool,
        motion: String,
        action: String? = nil,
        horizontalSpeed: Double = 0,
        displayHeight: Double? = nil
    ) {
        self.actorID = actorID
        self.x = x
        self.yFeet = yFeet
        self.facingRight = facingRight
        self.motion = motion
        self.action = action
        self.horizontalSpeed = horizontalSpeed
        self.displayHeight = displayHeight
    }

    private enum CodingKeys: String, CodingKey {
        case actorID, x, yFeet, facingRight, motion, action, horizontalSpeed, displayHeight
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            actorID: try values.decode(EntityID.self, forKey: .actorID),
            x: try values.decode(Double.self, forKey: .x),
            yFeet: try values.decode(Double.self, forKey: .yFeet),
            facingRight: try values.decode(Bool.self, forKey: .facingRight),
            motion: try values.decode(String.self, forKey: .motion),
            action: try values.decodeIfPresent(String.self, forKey: .action),
            horizontalSpeed: try values.decodeIfPresent(Double.self, forKey: .horizontalSpeed) ?? 0,
            displayHeight: try values.decodeIfPresent(Double.self, forKey: .displayHeight))
    }
}

public struct PresentationEntitySnapshot: Codable, Equatable, Sendable {
    public var id: EntityID
    public var kind: EntityKind
    public var alive: Bool
    public var pose: BodyPose?
    public var behaviorID: String?
    public var intent: String?
    public var behaviorStatus: BehaviorStatus?
    public var attachedToID: EntityID?

    public init(id: EntityID, kind: EntityKind, alive: Bool, pose: BodyPose?,
                behaviorID: String?, intent: String?, behaviorStatus: BehaviorStatus?,
                attachedToID: EntityID?) {
        self.id = id
        self.kind = kind
        self.alive = alive
        self.pose = pose
        self.behaviorID = behaviorID
        self.intent = intent
        self.behaviorStatus = behaviorStatus
        self.attachedToID = attachedToID
    }
}

public struct PresentationSnapshot: Codable, Equatable, Sendable {
    public var tick: Int64
    public var entities: [PresentationEntitySnapshot]
    public var attachments: [SpatialAttachment]

    public init(
        tick: Int64,
        entities: [PresentationEntitySnapshot],
        attachments: [SpatialAttachment] = []
    ) {
        self.tick = tick
        self.entities = entities
        self.attachments = attachments
    }
}

public enum PresentationEffectKind: String, Codable, Sendable {
    case behaviorStarted
    case behaviorCompleted
    case behaviorCancelled
}

public struct PresentationEffect: Codable, Equatable, Sendable {
    public var kind: PresentationEffectKind
    public var behaviorID: String
    public var actorID: EntityID
    public var intent: String

    public init(kind: PresentationEffectKind, behaviorID: String,
                actorID: EntityID, intent: String) {
        self.kind = kind
        self.behaviorID = behaviorID
        self.actorID = actorID
        self.intent = intent
    }
}

public struct BodyRuntimeSnapshot: Codable, Equatable, Sendable {
    public struct ActiveCommand: Codable, Equatable, Sendable {
        public var command: BodyCommand
        public var completesAtTick: Int64

        public init(command: BodyCommand, completesAtTick: Int64) {
            self.command = command
            self.completesAtTick = completesAtTick
        }
    }

    public var mode: BodyExecutionMode
    public var nextExecutionToken: Int64
    public var active: [String: ActiveCommand]
    public var commands: [BodyCommand]
    public var effects: [PresentationEffect]
    public var poses: [String: BodyPose]

    public init(
        mode: BodyExecutionMode,
        nextExecutionToken: Int64 = 0,
        active: [String: ActiveCommand] = [:],
        commands: [BodyCommand] = [],
        effects: [PresentationEffect] = [],
        poses: [String: BodyPose] = [:]
    ) {
        self.mode = mode
        self.nextExecutionToken = max(0, nextExecutionToken)
        self.active = active
        self.commands = commands
        self.effects = effects
        self.poses = poses
    }
}
