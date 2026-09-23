import Foundation
import MyPetCombat
import MyPetCore
import MyPetEngine

// MARK: - Deterministic execution / fuzz seams

public struct SeededRNG: RandomNumberGenerator, Codable, Equatable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    public mutating func index(count: Int) -> Int? {
        guard count > 0 else { return nil }
        return Int(next() % UInt64(count))
    }
}

public enum ChaosFault: String, Codable, CaseIterable, Sendable {
    case moveFocusedWindow
    case closeFocusedWindow
    case expireObservation
    case userDrag
}

public struct ChaosProfile: Codable, Equatable, Sendable {
    public var faults: [ChaosFault]
    public var atTicks: [Int64]

    public init(faults: [ChaosFault] = [], atTicks: [Int64] = []) {
        self.faults = faults
        self.atTicks = atTicks
    }
}

public enum ChaosSimulator {
    public static func apply(
        to scenario: HarnessScenario,
        seed: UInt64,
        profile: ChaosProfile
    ) -> HarnessScenario {
        guard !scenario.desktop.windows.isEmpty, !profile.faults.isEmpty else { return scenario }
        var result = scenario
        var rng = SeededRNG(seed: seed)
        let windowIDs = result.desktop.windows.values.filter(\.alive).map(\.id).sorted { $0.raw < $1.raw }
        for tick in profile.atTicks.sorted() {
            guard !windowIDs.isEmpty else { continue }
            let windowID = windowIDs[rng.index(count: windowIDs.count) ?? 0]
            for fault in profile.faults {
                switch fault {
                case .moveFocusedWindow:
                    result.desktop.schedule(VirtualDesktopEvent(
                        atTick: tick,
                        action: .moveWindow(windowID, LayoutRect(x: Double(tick), y: 10, width: 600, height: 400))))
                case .closeFocusedWindow:
                    result.desktop.schedule(VirtualDesktopEvent(atTick: tick, action: .closeWindow(windowID)))
                case .expireObservation:
                    let observation = InputObservation(
                        id: "chaos-\(tick)", pluginID: "browser-content", channel: .browser,
                        appName: "Browser", text: "chaos", capturedAtTick: tick, expiresAtTick: tick)
                    result.desktop.schedule(VirtualDesktopEvent(atTick: tick, action: .emitObservation(
                        VirtualSensorObservation(observation: observation))))
                case .userDrag:
                    result.desktop.schedule(VirtualDesktopEvent(atTick: tick, action: .user(
                        VirtualUserAction(kind: .dragActor, actorID: result.pipeline?.actorID))))
                }
            }
        }
        return result
    }
}

public struct ScenarioGenerator {
    public init() {}

    public func variants(of scenario: HarnessScenario, count: Int, seed: UInt64) -> [HarnessScenario] {
        guard count > 0 else { return [] }
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { index in
            var variant = scenario
            variant.id = "\(scenario.id)-variant-\(index)"
            let offset = Int64(rng.next() % 4)
            variant.events = scenario.events.map { event in
                var shifted = event
                shifted.atTick += offset
                return shifted
            }
            if let window = variant.desktop.windows.values.sorted(by: { $0.id.raw < $1.id.raw }).first {
                variant.desktop.schedule(VirtualDesktopEvent(
                    atTick: offset,
                    action: .moveWindow(window.id, LayoutRect(
                        x: Double(rng.next() % 80), y: 20,
                        width: window.frame.width, height: window.frame.height))))
            }
            return variant
        }
    }
}

public struct DataSimulationSnapshot: Codable, Equatable, Sendable {
    public var scenario: HarnessScenario
    public let runtimeCheckpoint: GameRuntimeCheckpoint?
    public var desktop: VirtualDesktop
    public var pipeline: SemanticPipelineSnapshot?
    public var combat: CombatSimulationSnapshot?
    private var legacyKernel: KernelSnapshot?

    public var kernel: KernelSnapshot { runtimeCheckpoint?.kernel ?? legacyKernel! }

    public init(
        scenario: HarnessScenario,
        runtimeCheckpoint: GameRuntimeCheckpoint,
        desktop: VirtualDesktop,
        pipeline: SemanticPipelineSnapshot?,
        combat: CombatSimulationSnapshot? = nil
    ) {
        self.scenario = scenario
        self.runtimeCheckpoint = runtimeCheckpoint
        self.desktop = desktop
        self.pipeline = pipeline
        self.combat = combat
        self.legacyKernel = nil
    }

    public init(
        scenario: HarnessScenario,
        kernel: KernelSnapshot,
        desktop: VirtualDesktop,
        pipeline: SemanticPipelineSnapshot?
    ) {
        self.scenario = scenario
        self.runtimeCheckpoint = nil
        self.desktop = desktop
        self.pipeline = pipeline
        self.combat = nil
        self.legacyKernel = kernel
    }

    private enum CodingKeys: String, CodingKey {
        case scenario, runtimeCheckpoint, kernel, desktop, pipeline, combat
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scenario = try values.decode(HarnessScenario.self, forKey: .scenario)
        runtimeCheckpoint = try values.decodeIfPresent(GameRuntimeCheckpoint.self, forKey: .runtimeCheckpoint)
        legacyKernel = try values.decodeIfPresent(KernelSnapshot.self, forKey: .kernel)
        guard runtimeCheckpoint != nil || legacyKernel != nil else {
            throw DecodingError.keyNotFound(CodingKeys.runtimeCheckpoint,
                .init(codingPath: values.codingPath, debugDescription: "Missing runtime checkpoint"))
        }
        desktop = try values.decode(VirtualDesktop.self, forKey: .desktop)
        pipeline = try values.decodeIfPresent(SemanticPipelineSnapshot.self, forKey: .pipeline)
        combat = try values.decodeIfPresent(CombatSimulationSnapshot.self, forKey: .combat)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scenario, forKey: .scenario)
        if let runtimeCheckpoint {
            try values.encode(runtimeCheckpoint, forKey: .runtimeCheckpoint)
        } else if let legacyKernel {
            try values.encode(legacyKernel, forKey: .kernel)
        }
        try values.encode(desktop, forKey: .desktop)
        try values.encodeIfPresent(pipeline, forKey: .pipeline)
        try values.encodeIfPresent(combat, forKey: .combat)
    }
}

/// One deterministic, rewindable execution of VirtualDesktop → GameKernel →
/// GoalBrain → SceneRunner → NeedleBrain → ActionRuntime.
public final class DataSimulation {
    public let scenario: HarnessScenario
    public private(set) var runtime: GameRuntime
    public var kernel: KernelSnapshot { runtime.snapshot() }
    public private(set) var desktop: VirtualDesktop
    public let pipeline: SemanticPipeline?
    public private(set) var combatSimulation: CombatDataSimulation?

    public init(scenario: HarnessScenario) {
        self.scenario = scenario
        self.runtime = GameRuntime(kernel: GameKernel(scenario: scenario))
        self.desktop = scenario.desktop
        self.pipeline = scenario.pipeline.map { SemanticPipeline(configuration: $0) }
        if !scenario.combatActors.isEmpty {
            self.combatSimulation = CombatDataSimulation(scenario: VirtualCombatScenario(
                id: scenario.id + "-combat",
                desktop: scenario.desktop,
                actors: scenario.combatActors,
                inputs: scenario.combatInputs,
                durationFrames: scenario.durationTicks * 3))
        } else {
            self.combatSimulation = nil
        }
    }

    public init(snapshot: DataSimulationSnapshot) {
        self.scenario = snapshot.scenario
        self.runtime = snapshot.runtimeCheckpoint.map(GameRuntime.init(checkpoint:))
            ?? GameRuntime(snapshot: snapshot.kernel)
        self.desktop = snapshot.desktop
        self.combatSimulation = snapshot.combat.map(CombatDataSimulation.init(snapshot:))
        if let configuration = snapshot.scenario.pipeline {
            let pipeline = SemanticPipeline(configuration: configuration)
            if let snapshot = snapshot.pipeline { pipeline.restore(snapshot) }
            self.pipeline = pipeline
        } else {
            self.pipeline = nil
        }
    }

    @discardableResult
    public func step() -> TickReport {
        let tick = runtime.clock.tick
        let events = desktop.advance(to: tick)
        let report: TickReport
        if let pipeline {
            report = runtime.step(
                events: events,
                pipeline: pipeline,
                context: desktop.runtimeContext)!
        } else {
            report = runtime.step(events: events)!
        }
        // 50 ms narrative ticks contain exactly three 60 Hz body/combat frames.
        // Legacy scenarios without a combat track pay no cost.
        if let combatSimulation { _ = combatSimulation.run(frames: 3) }
        return report
    }

    @discardableResult
    public func run(ticks: Int64) -> [TickReport] {
        guard ticks > 0 else { return [] }
        return (0..<ticks).map { _ in step() }
    }

    public func snapshot() -> DataSimulationSnapshot {
        DataSimulationSnapshot(
            scenario: scenario,
            runtimeCheckpoint: runtime.checkpoint(),
            desktop: desktop,
            pipeline: pipeline?.snapshot(),
            combat: combatSimulation?.snapshot())
    }
}
