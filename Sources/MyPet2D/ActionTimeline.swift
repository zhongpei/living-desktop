import Foundation

public enum ActionTimelinePhase: String, Codable, Sendable {
    case startup, active, recovery, finished, cancelled
}

public enum ActionTimelineAdvance: String, Codable, Sendable {
    case advanced, paused, finished, cancelled
}

public enum ActionDomain: String, Codable, Sendable {
    case idle, locomotion, presentation, combat
}

public enum ActionLocomotionPolicy: String, Codable, Sendable {
    case preserve, stationary, authored
}

public enum ActionEndState: String, Codable, Sendable {
    case neutral, locomotion, hold
}

public enum ActionCollisionKind: String, Codable, Sendable {
    case push, hurt, hit, sensor
}

public struct ActionFrameWindow: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = max(0, min(start, end))
        self.end = max(0, max(start, end))
    }

    public func contains(_ frame: Int) -> Bool {
        frame >= start && frame <= end
    }
}

public struct ActionCollisionFrame: Codable, Equatable, Sendable {
    public var kind: ActionCollisionKind
    public var rectLocal: Rect2D
    public var active: ActionFrameWindow
    public var hitGroup: String?
    public var tags: [String]

    public init(
        kind: ActionCollisionKind,
        rectLocal: Rect2D,
        active: ActionFrameWindow,
        hitGroup: String? = nil,
        tags: [String] = []
    ) {
        self.kind = kind
        self.rectLocal = rectLocal
        self.active = active
        self.hitGroup = hitGroup
        self.tags = tags
    }
}

public struct ActionRootMotion: Codable, Equatable, Sendable {
    public var active: ActionFrameWindow
    public var deltaPerFrame: Vec2

    public init(active: ActionFrameWindow, deltaPerFrame: Vec2) {
        self.active = active
        self.deltaPerFrame = deltaPerFrame
    }
}

public struct ActionDefinition: Codable, Equatable, Sendable {
    public var actionID: String
    public var domain: ActionDomain
    /// Nil means the action is held until its owner explicitly completes it.
    public var durationFrames: Int?
    public var animationBinding: String
    public var locomotionPolicy: ActionLocomotionPolicy
    public var startupFrames: Int
    public var activeFrames: Int?
    public var interruptWindows: [ActionFrameWindow]
    public var cancelWindows: [ActionFrameWindow]
    public var collisionFrames: [ActionCollisionFrame]
    public var rootMotion: [ActionRootMotion]
    public var endState: ActionEndState

    public init(
        actionID: String,
        durationFrames: Int?,
        animationBinding: String,
        domain: ActionDomain = .presentation,
        startupFrames: Int = 0,
        activeFrames: Int? = nil,
        locomotionPolicy: ActionLocomotionPolicy = .preserve,
        interruptWindows: [ActionFrameWindow] = [],
        cancelWindows: [ActionFrameWindow] = [],
        collisionFrames: [ActionCollisionFrame] = [],
        rootMotion: [ActionRootMotion] = [],
        endState: ActionEndState = .neutral
    ) {
        let duration = durationFrames.map { max(1, $0) }
        let startup = max(0, min(startupFrames, duration ?? startupFrames))
        self.actionID = actionID
        self.domain = domain
        self.durationFrames = duration
        self.animationBinding = animationBinding
        self.locomotionPolicy = locomotionPolicy
        self.startupFrames = startup
        self.activeFrames = activeFrames.map {
            max(0, min($0, max(0, (duration ?? (startup + $0)) - startup)))
        }
        self.interruptWindows = interruptWindows
        self.cancelWindows = cancelWindows
        self.collisionFrames = collisionFrames
        self.rootMotion = rootMotion
        self.endState = endState
    }
}

/// The only frame cursor for an action instance. Rules and renderers inspect
/// this value; neither keeps an independent action clock.
public struct ActionTimeline: Codable, Equatable, Sendable {
    public var instanceID: Int64
    public var definition: ActionDefinition
    public private(set) var frame: Int
    public private(set) var terminalPhase: ActionTimelinePhase?

    public init(instanceID: Int64, definition: ActionDefinition, frame: Int = 0) {
        self.instanceID = instanceID
        self.definition = definition
        self.frame = max(0, frame)
        if let duration = definition.durationFrames, self.frame >= duration {
            self.frame = duration
            self.terminalPhase = .finished
        } else {
            self.terminalPhase = nil
        }
    }

    public var phase: ActionTimelinePhase {
        if let terminalPhase { return terminalPhase }
        if frame < definition.startupFrames { return .startup }
        if let activeFrames = definition.activeFrames,
           frame >= definition.startupFrames + activeFrames {
            return .recovery
        }
        return .active
    }

    public var canInterrupt: Bool {
        definition.interruptWindows.contains { $0.contains(frame) }
    }

    public var canCancel: Bool {
        definition.cancelWindows.contains { $0.contains(frame) }
    }

    public var activeCollisions: [ActionCollisionFrame] {
        guard terminalPhase == nil else { return [] }
        return definition.collisionFrames.filter { $0.active.contains(frame) }
    }

    public var rootMotionDelta: Vec2 {
        guard terminalPhase == nil else { return Vec2() }
        return definition.rootMotion.reduce(into: Vec2()) { delta, motion in
            guard motion.active.contains(frame) else { return }
            delta.x += motion.deltaPerFrame.x
            delta.y += motion.deltaPerFrame.y
        }
    }

    @discardableResult
    public mutating func advance(frames: Int = 1, paused: Bool = false) -> ActionTimelineAdvance {
        if terminalPhase == .cancelled { return .cancelled }
        if terminalPhase == .finished { return .finished }
        if paused || frames <= 0 { return .paused }
        frame += frames
        if let duration = definition.durationFrames, frame >= duration {
            frame = duration
            terminalPhase = .finished
            return .finished
        }
        return .advanced
    }

    @discardableResult
    public mutating func cancel() -> ActionTimelineAdvance {
        guard terminalPhase == nil else {
            return terminalPhase == .cancelled ? .cancelled : .finished
        }
        terminalPhase = .cancelled
        return .cancelled
    }
}
