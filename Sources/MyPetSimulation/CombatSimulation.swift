import Foundation
import MyPetCombat
import MyPetCore

public struct CombatInputEvent: Codable, Equatable, Sendable {
    public var frame: Int64
    public var actorID: EntityID
    public var input: FighterInputFrame

    public init(frame: Int64, actorID: EntityID, input: FighterInputFrame) {
        self.frame = frame
        self.actorID = actorID
        self.input = input
    }
}

public struct VirtualCombatActor: Codable, Equatable, Sendable {
    public var actorID: EntityID
    public var profile: CombatProfile
    public var x: Double
    public var yFeet: Double
    public var facing: CombatFacing

    public init(actorID: EntityID, profile: CombatProfile = CombatProfile(),
                x: Double, yFeet: Double, facing: CombatFacing = .right) {
        self.actorID = actorID
        self.profile = profile
        self.x = x
        self.yFeet = yFeet
        self.facing = facing
    }
}

public struct VirtualCombatScenario: Codable, Equatable, Sendable {
    public var id: String
    public var desktop: VirtualDesktop
    public var actors: [VirtualCombatActor]
    public var inputs: [CombatInputEvent]
    public var durationFrames: Int64

    public init(id: String, desktop: VirtualDesktop, actors: [VirtualCombatActor],
                inputs: [CombatInputEvent] = [], durationFrames: Int64 = 600) {
        self.id = id
        self.desktop = desktop
        self.actors = actors
        self.inputs = inputs
        self.durationFrames = max(1, durationFrames)
    }
}

public struct CombatSimulationSnapshot: Codable, Equatable, Sendable {
    public var scenario: VirtualCombatScenario
    public var desktop: VirtualDesktop
    public var combat: CombatWorldCheckpoint
    public var activeInputs: [String: FighterInputFrame]

    public init(scenario: VirtualCombatScenario, desktop: VirtualDesktop,
                combat: CombatWorldCheckpoint, activeInputs: [String: FighterInputFrame]) {
        self.scenario = scenario
        self.desktop = desktop
        self.combat = combat
        self.activeInputs = activeInputs
    }
}

/// Headless combat uses the exact MyPetCombat world used by AppKit. Only the environment
/// adapter changes. This makes hitboxes, gravity, moving windows, KO/recovery and input
/// command matching replayable without a renderer.
public final class CombatDataSimulation {
    public let scenario: VirtualCombatScenario
    public private(set) var desktop: VirtualDesktop
    public private(set) var combat: CombatWorld
    private var activeInputs: [String: FighterInputFrame] = [:]
    private let eventsByFrame: [Int64: [CombatInputEvent]]

    public init(scenario: VirtualCombatScenario) {
        self.scenario = scenario
        self.desktop = scenario.desktop
        self.combat = CombatWorld()
        self.eventsByFrame = Dictionary(grouping: scenario.inputs, by: \.frame)
        for actor in scenario.actors {
            combat.register(actorID: actor.actorID, profile: actor.profile,
                            x: actor.x, yFeet: actor.yFeet, facing: actor.facing)
        }
    }

    public init(snapshot: CombatSimulationSnapshot) {
        self.scenario = snapshot.scenario
        self.desktop = snapshot.desktop
        self.combat = CombatWorld(checkpoint: snapshot.combat)
        self.activeInputs = snapshot.activeInputs
        self.eventsByFrame = Dictionary(grouping: snapshot.scenario.inputs, by: \.frame)
    }

    @discardableResult
    public func step() -> [CombatEvent] {
        let frame = combat.frame
        // Existing harness time is 50 ms (20 Hz). Apply desktop events at those
        // boundaries while combat continues at 60 Hz between them.
        if frame % 3 == 0 {
            _ = desktop.advance(to: frame / 3)
        }
        for event in eventsByFrame[frame] ?? [] {
            activeInputs[event.actorID.raw] = event.input
        }
        for actor in combat.snapshot().bodies {
            combat.setInput(activeInputs[actor.actorID.raw] ?? .neutral, for: actor.actorID)
        }
        return combat.step(environment: desktop.combatEnvironment())
    }

    @discardableResult
    public func run(frames: Int64? = nil) -> [CombatEvent] {
        let count = max(0, frames ?? scenario.durationFrames)
        var result: [CombatEvent] = []
        for _ in 0..<count { result.append(contentsOf: step()) }
        return result
    }

    public func snapshot() -> CombatSimulationSnapshot {
        CombatSimulationSnapshot(
            scenario: scenario, desktop: desktop,
            combat: combat.checkpoint(), activeInputs: activeInputs)
    }
}

public extension VirtualDesktop {
    func combatEnvironment() -> CombatEnvironment {
        let screenFrames: [LayoutRect] = screens.isEmpty
            ? [LayoutRect(x: 0, y: 0, width: 1440, height: 900)]
            : screens.map(\.frame)
        let minX = screenFrames.map(\.x).min() ?? 0
        let minY = screenFrames.map(\.y).min() ?? 0
        let maxX = screenFrames.map { $0.x + $0.width }.max() ?? 1440
        let maxY = screenFrames.map { $0.y + $0.height }.max() ?? 900

        var surfaces = screenFrames.enumerated().map { index, rect in
            CombatSurface(
                id: "screen:\(index):floor",
                kind: .floor,
                left: rect.x,
                right: rect.x + rect.width,
                y: rect.y + rect.height)
        }
        for window in windows.values.filter(\.alive).sorted(by: { $0.id.raw < $1.id.raw }) {
            let left = window.frame.x
            let right = window.frame.x + window.frame.width
            surfaces.append(CombatSurface(
                id: "window:\(window.id.raw):top",
                kind: .windowTop,
                left: left, right: right, y: window.frame.y, hostID: window.id))
            surfaces.append(CombatSurface(
                id: "window:\(window.id.raw):bottom",
                kind: .windowBottom,
                left: left, right: right,
                y: window.frame.y + window.frame.height, hostID: window.id))
        }
        return CombatEnvironment(
            bounds: CombatRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            surfaces: surfaces)
    }
}
