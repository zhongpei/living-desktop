import Foundation
import MyPetCombat
import MyPetCore
import MyPetEngine
import MyPet2D

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
    public var runtime: GameRuntimeCheckpoint

    public init(
        scenario: VirtualCombatScenario,
        desktop: VirtualDesktop,
        runtime: GameRuntimeCheckpoint
    ) {
        self.scenario = scenario
        self.desktop = desktop
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case scenario, desktop, runtime, combat, activeInputs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scenario = try values.decode(VirtualCombatScenario.self, forKey: .scenario)
        desktop = try values.decode(VirtualDesktop.self, forKey: .desktop)
        if let runtime = try values.decodeIfPresent(
            GameRuntimeCheckpoint.self, forKey: .runtime) {
            self.runtime = runtime
            return
        }

        // Transitional combat-runner recordings stored the rules world and
        // active input separately. Upgrade them into the unified checkpoint.
        let legacyWorld = try values.decode(CombatWorldCheckpoint.self, forKey: .combat)
        let legacyInputs = try values.decodeIfPresent(
            [String: FighterInputFrame].self, forKey: .activeInputs) ?? [:]
        var controls = ControlRouter()
        for id in legacyWorld.rules.keys.sorted() {
            controls.activate(
                .authored,
                for: EntityID(id),
                input: legacyInputs[id] ?? legacyWorld.inputs[id] ?? .neutral)
        }
        let combat = CombatRuntime(checkpoint: CombatRuntimeCheckpoint(
            world: legacyWorld, controls: controls))
        var upgraded = GameRuntime(combatRuntime: combat).checkpoint()
        upgraded.bodyClock = BodyFrameAccumulator(frame: legacyWorld.frame)
        runtime = upgraded
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scenario, forKey: .scenario)
        try values.encode(desktop, forKey: .desktop)
        try values.encode(runtime, forKey: .runtime)
    }
}

/// VirtualDesktop is an environment adapter around the same `GameRuntime` and
/// `CombatRuntime` used by production. It owns no parallel combat clock.
public final class CombatDataSimulation {
    public let scenario: VirtualCombatScenario
    public private(set) var desktop: VirtualDesktop
    public let runtime: GameRuntime
    public var combatRuntime: CombatRuntime { runtime.combatRuntime! }
    public var combat: CombatWorld { combatRuntime.world }
    public var digest: CombatRuntimeDigest { combatRuntime.digest }
    private let eventsByFrame: [Int64: [CombatInputEvent]]

    public init(scenario: VirtualCombatScenario) {
        let combat = Self.makeCombatRuntime(scenario: scenario)
        self.scenario = scenario
        self.desktop = scenario.desktop
        self.runtime = GameRuntime(combatRuntime: combat)
        self.eventsByFrame = Dictionary(grouping: scenario.inputs, by: \.frame)
    }

    init(scenario: VirtualCombatScenario, runtime: GameRuntime, desktop: VirtualDesktop) {
        precondition(runtime.combatRuntime != nil)
        self.scenario = scenario
        self.desktop = desktop
        self.runtime = runtime
        self.eventsByFrame = Dictionary(grouping: scenario.inputs, by: \.frame)
    }

    init(snapshot: CombatSimulationSnapshot, runtime: GameRuntime) {
        precondition(runtime.combatRuntime != nil)
        self.scenario = snapshot.scenario
        self.desktop = snapshot.desktop
        self.runtime = runtime
        self.eventsByFrame = Dictionary(grouping: snapshot.scenario.inputs, by: \.frame)
    }

    public init(snapshot: CombatSimulationSnapshot) {
        self.scenario = snapshot.scenario
        self.desktop = snapshot.desktop
        self.runtime = GameRuntime(checkpoint: snapshot.runtime)
        precondition(runtime.combatRuntime != nil)
        self.eventsByFrame = Dictionary(grouping: snapshot.scenario.inputs, by: \.frame)
    }

    static func makeCombatRuntime(scenario: VirtualCombatScenario) -> CombatRuntime {
        let runtime = CombatRuntime()
        for actor in scenario.actors {
            runtime.register(actorID: actor.actorID, profile: actor.profile,
                             x: actor.x, yFeet: actor.yFeet, facing: actor.facing)
            runtime.activate(.authored, for: actor.actorID)
        }
        _ = runtime.beginSession(id: "simulation:\(scenario.id)")
        return runtime
    }

    @discardableResult
    public func step() -> [CombatEvent] {
        step(semanticStep: nil)
    }

    @discardableResult
    func step(semanticStep: (() -> TickReport?)?) -> [CombatEvent] {
        let frame = runtime.bodyFrame
        if frame.isMultiple(of: 3) {
            _ = desktop.advance(to: frame / 3)
        }
        for event in eventsByFrame[frame] ?? [] {
            combatRuntime.setInput(event.input, source: .authored, for: event.actorID)
        }
        return runtime.advance(
            elapsedSeconds: 1.0 / Double(BodyFrameAccumulator.framesPerSecond),
            combatEnvironment: desktop.combatEnvironment(),
            semanticStep: semanticStep).combatEvents
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
            scenario: scenario,
            desktop: desktop,
            runtime: runtime.checkpoint())
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
