import Foundation
import MyPet2D
import MyPetCombat
import MyPetCore

public enum CombatReplayControl: Codable, Equatable, Sendable {
    case activate(actorID: EntityID, source: ControlSource)
    case deactivate(actorID: EntityID, source: ControlSource)
    case input(actorID: EntityID, source: ControlSource, frame: FighterInputFrame)
    case releaseManual(actorID: EntityID)
    case beginDrag(actorID: EntityID, position: Vec2)
    case drag(actorID: EntityID, position: Vec2, elapsedSeconds: Double)
    case endDrag(actorID: EntityID, wasClick: Bool)
}

public struct CombatReplayFrame: Codable, Equatable, Sendable {
    public var environment: BodyEnvironment
    public var platformContext: GameplayPlatformContext
    public var controls: [CombatReplayControl]

    public init(
        environment: BodyEnvironment,
        platformContext: GameplayPlatformContext = .idle,
        controls: [CombatReplayControl] = []
    ) {
        self.environment = environment
        self.platformContext = platformContext
        self.controls = controls
    }
}

public struct CombatReplayTape: Codable, Equatable, Sendable {
    public static let currentSchema = "mypet.combat-replay.v1"
    public var schema: String
    public var engineVersion: String
    public var contentFingerprint: String
    public var initialCheckpoint: CombatRuntimeCheckpoint
    public var frames: [CombatReplayFrame]

    public init(
        engineVersion: String,
        contentFingerprint: String,
        initialCheckpoint: CombatRuntimeCheckpoint,
        frames: [CombatReplayFrame]
    ) {
        self.schema = Self.currentSchema
        self.engineVersion = engineVersion
        self.contentFingerprint = contentFingerprint
        self.initialCheckpoint = initialCheckpoint
        self.frames = frames
    }
}

public struct CombatReplayResult: Equatable, Sendable {
    public var digest: CombatRuntimeDigest
    public var events: [CombatEvent]
}

public enum CombatReplayRunner {
    public enum ReplayError: Error, Equatable, Sendable {
        case unsupportedSchema(String)
        case engineVersionMismatch(expected: String, actual: String)
        case contentFingerprintMismatch(expected: String, actual: String)
    }

    public static func replay(
        _ tape: CombatReplayTape,
        expectedEngineVersion: String,
        expectedContentFingerprint: String
    ) throws -> CombatReplayResult {
        guard tape.schema == CombatReplayTape.currentSchema else {
            throw ReplayError.unsupportedSchema(tape.schema)
        }
        guard tape.engineVersion == expectedEngineVersion else {
            throw ReplayError.engineVersionMismatch(
                expected: expectedEngineVersion, actual: tape.engineVersion)
        }
        guard tape.contentFingerprint == expectedContentFingerprint else {
            throw ReplayError.contentFingerprintMismatch(
                expected: expectedContentFingerprint, actual: tape.contentFingerprint)
        }
        let runtime = CombatRuntime(checkpoint: tape.initialCheckpoint)
        var events: [CombatEvent] = []
        for frame in tape.frames {
            for control in frame.controls { apply(control, to: runtime) }
            events.append(contentsOf: runtime.advance(
                environment: frame.environment,
                platformContext: frame.platformContext))
        }
        return CombatReplayResult(digest: runtime.digest, events: events)
    }

    private static func apply(_ control: CombatReplayControl, to runtime: CombatRuntime) {
        switch control {
        case .activate(let actorID, let source):
            runtime.activate(source, for: actorID)
        case .deactivate(let actorID, let source):
            runtime.deactivate(source, for: actorID)
        case .input(let actorID, let source, let frame):
            runtime.setInput(frame, source: source, for: actorID)
        case .releaseManual(let actorID):
            runtime.releaseAllManualInput(for: actorID)
        case .beginDrag(let actorID, let position):
            runtime.beginDrag(actorID: actorID, x: position.x, y: position.y)
        case .drag(let actorID, let position, let elapsedSeconds):
            runtime.drag(
                actorID: actorID, x: position.x, y: position.y,
                elapsedSeconds: elapsedSeconds)
        case .endDrag(let actorID, let wasClick):
            runtime.endDrag(actorID: actorID, wasClick: wasClick)
        }
    }
}
