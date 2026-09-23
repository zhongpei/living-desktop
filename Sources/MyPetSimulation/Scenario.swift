import Foundation
import MyPetCore
import MyPetEngine

public struct ScenarioExpectations: Codable, Sendable, Equatable {
    /// Stage names such as `goal`, `scene`, `needle`, `action` that must occur.
    public var requiredPipelineStages: [String]
    /// Each group is an ordered partial-order assertion over stage names.
    public var partialOrders: [[String]]
    /// Kernel trace details that must eventually be present.
    public var requiredTraceDetails: [String]

    public init(
        requiredPipelineStages: [String] = [],
        partialOrders: [[String]] = [],
        requiredTraceDetails: [String] = []
    ) {
        self.requiredPipelineStages = requiredPipelineStages
        self.partialOrders = partialOrders
        self.requiredTraceDetails = requiredTraceDetails
    }

    public func check(kernel: GameKernel, pipelineTrace: [PipelineTraceEntry]) -> [String] {
        let stages = pipelineTrace.map(\.stage)
        var failures: [String] = []
        for stage in requiredPipelineStages where !stages.contains(stage) {
            failures.append("missing_pipeline_stage:\(stage)")
        }
        for order in partialOrders where !isOrdered(order, in: stages) {
            failures.append("partial_order:\(order.joined(separator: ">"))")
        }
        let details = kernel.trace.map(\.detail)
        for detail in requiredTraceDetails where !details.contains(where: { $0.contains(detail) }) {
            failures.append("missing_trace_detail:\(detail)")
        }
        return failures
    }

    private func isOrdered(_ order: [String], in values: [String]) -> Bool {
        guard !order.isEmpty else { return true }
        var cursor = 0
        for expected in order {
            guard let offset = values[cursor...].firstIndex(of: expected) else { return false }
            cursor = offset + 1
        }
        return true
    }
}

public struct HarnessScenario: Codable, Sendable, Equatable {
    public var id: String
    public var seed: UInt64
    public var stepMilliseconds: Int64
    public var durationTicks: Int64
    public var entities: [EntityState]
    public var slots: [InteractionSlot]
    public var events: [ScheduledEvent]
    public var requireAllClaimsReleased: Bool
    public var desktop: VirtualDesktop
    /// Optional data-only route graph used only by the fast execution layer.
    public var playSpace: VirtualPlaySpace?
    /// Director-level relationship/objective input; contains no spatial facts.
    public var playBrief: QwenPlayBrief?
    public var pipeline: SemanticPipelineConfiguration?
    /// Optional combat track. Empty keeps legacy story-only scenarios byte-compatible.
    public var combatActors: [VirtualCombatActor]
    public var combatInputs: [CombatInputEvent]
    public var expectations: ScenarioExpectations

    public init(
        id: String,
        seed: UInt64 = 0,
        stepMilliseconds: Int64 = 50,
        durationTicks: Int64 = 100,
        entities: [EntityState] = [],
        slots: [InteractionSlot] = [],
        events: [ScheduledEvent] = [],
        requireAllClaimsReleased: Bool = true,
        desktop: VirtualDesktop = VirtualDesktop(),
        playSpace: VirtualPlaySpace? = nil,
        playBrief: QwenPlayBrief? = nil,
        pipeline: SemanticPipelineConfiguration? = nil,
        combatActors: [VirtualCombatActor] = [],
        combatInputs: [CombatInputEvent] = [],
        expectations: ScenarioExpectations = ScenarioExpectations()
    ) {
        self.id = id
        self.seed = seed
        self.stepMilliseconds = stepMilliseconds
        self.durationTicks = durationTicks
        self.entities = entities
        self.slots = slots
        self.events = events
        self.requireAllClaimsReleased = requireAllClaimsReleased
        self.desktop = desktop
        self.playSpace = playSpace
        self.playBrief = playBrief
        self.pipeline = pipeline
        self.combatActors = combatActors
        self.combatInputs = combatInputs
        self.expectations = expectations
    }

    private enum CodingKeys: String, CodingKey {
        case id, seed, stepMilliseconds, durationTicks, entities, slots, events
        case requireAllClaimsReleased, desktop, playSpace, playBrief, pipeline
        case combatActors, combatInputs, expectations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            seed: try values.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0,
            stepMilliseconds: try values.decodeIfPresent(Int64.self, forKey: .stepMilliseconds) ?? 50,
            durationTicks: try values.decodeIfPresent(Int64.self, forKey: .durationTicks) ?? 100,
            entities: try values.decodeIfPresent([EntityState].self, forKey: .entities) ?? [],
            slots: try values.decodeIfPresent([InteractionSlot].self, forKey: .slots) ?? [],
            events: try values.decodeIfPresent([ScheduledEvent].self, forKey: .events) ?? [],
            requireAllClaimsReleased: try values.decodeIfPresent(Bool.self, forKey: .requireAllClaimsReleased) ?? true,
            desktop: try values.decodeIfPresent(VirtualDesktop.self, forKey: .desktop) ?? VirtualDesktop(),
            playSpace: try values.decodeIfPresent(VirtualPlaySpace.self, forKey: .playSpace),
            playBrief: try values.decodeIfPresent(QwenPlayBrief.self, forKey: .playBrief),
            pipeline: try values.decodeIfPresent(SemanticPipelineConfiguration.self, forKey: .pipeline),
            combatActors: try values.decodeIfPresent([VirtualCombatActor].self, forKey: .combatActors) ?? [],
            combatInputs: try values.decodeIfPresent([CombatInputEvent].self, forKey: .combatInputs) ?? [],
            expectations: try values.decodeIfPresent(ScenarioExpectations.self, forKey: .expectations) ?? ScenarioExpectations())
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(seed, forKey: .seed)
        try values.encode(stepMilliseconds, forKey: .stepMilliseconds)
        try values.encode(durationTicks, forKey: .durationTicks)
        try values.encode(entities, forKey: .entities)
        try values.encode(slots, forKey: .slots)
        try values.encode(events, forKey: .events)
        try values.encode(requireAllClaimsReleased, forKey: .requireAllClaimsReleased)
        try values.encode(desktop, forKey: .desktop)
        try values.encodeIfPresent(playSpace, forKey: .playSpace)
        try values.encodeIfPresent(playBrief, forKey: .playBrief)
        try values.encodeIfPresent(pipeline, forKey: .pipeline)
        if !combatActors.isEmpty { try values.encode(combatActors, forKey: .combatActors) }
        if !combatInputs.isEmpty { try values.encode(combatInputs, forKey: .combatInputs) }
        try values.encode(expectations, forKey: .expectations)
    }

}

public struct ScenarioReport: Codable, Sendable, Equatable {
    public let scenarioID: String
    public let ticks: Int64
    public let passed: Bool
    public let finalDigest: String
    public let violations: [InvariantViolation]
    public let traceCount: Int
    public let desktopDigest: String
    public let pipelineTrace: [PipelineTraceEntry]
    public let logicVerdict: LogicVerdict
    public let contentVerdict: ContentVerdict
    public let simulationMode: SimulationMode?
    public let simulationVerdict: SimulationModeVerdict?

    public init(
        scenarioID: String,
        ticks: Int64,
        passed: Bool,
        finalDigest: String,
        violations: [InvariantViolation],
        traceCount: Int,
        desktopDigest: String = "",
        pipelineTrace: [PipelineTraceEntry] = [],
        logicVerdict: LogicVerdict = LogicVerdict(),
        contentVerdict: ContentVerdict = ContentVerdict(),
        simulationMode: SimulationMode? = nil,
        simulationVerdict: SimulationModeVerdict? = nil
    ) {
        self.scenarioID = scenarioID
        self.ticks = ticks
        self.passed = passed
        self.finalDigest = finalDigest
        self.violations = violations
        self.traceCount = traceCount
        self.desktopDigest = desktopDigest
        self.pipelineTrace = pipelineTrace
        self.logicVerdict = logicVerdict
        self.contentVerdict = contentVerdict
        self.simulationMode = simulationMode
        self.simulationVerdict = simulationVerdict
    }

    public func withSimulationVerdict(
        mode: SimulationMode,
        verdict: SimulationModeVerdict
    ) -> ScenarioReport {
        ScenarioReport(
            scenarioID: scenarioID,
            ticks: ticks,
            passed: passed && verdict.passed,
            finalDigest: finalDigest,
            violations: violations,
            traceCount: traceCount,
            desktopDigest: desktopDigest,
            pipelineTrace: pipelineTrace,
            logicVerdict: logicVerdict,
            contentVerdict: contentVerdict,
            simulationMode: mode,
            simulationVerdict: verdict)
    }
}

public struct ReplayReport: Codable, Sendable, Equatable {
    public let scenarioID: String
    public let matched: Bool
    public let firstDifference: Int?
    public let firstDigest: String
    public let secondDigest: String

    public init(
        scenarioID: String,
        matched: Bool,
        firstDifference: Int?,
        firstDigest: String,
        secondDigest: String
    ) {
        self.scenarioID = scenarioID
        self.matched = matched
        self.firstDifference = firstDifference
        self.firstDigest = firstDigest
        self.secondDigest = secondDigest
    }
}

public enum ScenarioLoader {
    public static func loadJSON(at url: URL) throws -> HarnessScenario {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(HarnessScenario.self, from: data)
    }

    public static func builtInSlotRace() -> HarnessScenario {
        let window = EntityState(id: EntityID("window42"), kind: .window)
        let a = EntityState(id: EntityID("pilot_a"), kind: .actor)
        let b = EntityState(id: EntityID("pilot_b"), kind: .actor)
        let slot = InteractionSlot(entityID: window.id, slotID: "top.right")
        let aRequest = BehaviorRequest(
            id: "a-perch",
            actorID: a.id,
            intent: "perch",
            priority: .story,
            slot: slot.ref,
            durationTicks: 4,
            occupySlotOnSuccess: true
        )
        let bRequest = BehaviorRequest(
            id: "b-perch",
            actorID: b.id,
            intent: "perch",
            priority: .story,
            slot: slot.ref,
            durationTicks: 4,
            occupySlotOnSuccess: true
        )
        return HarnessScenario(
            id: "slot-race",
            seed: 48123,
            durationTicks: 12,
            entities: [window, a, b],
            slots: [slot],
            events: [
                ScheduledEvent(atTick: 0, event: GameEvent(kind: .behaviorRequest, request: aRequest)),
                ScheduledEvent(atTick: 0, event: GameEvent(kind: .behaviorRequest, request: bRequest)),
                ScheduledEvent(atTick: 8, event: GameEvent(kind: .releaseSlot, slotRef: slot.ref))
            ]
        )
    }

    /// Small acceptance scenario for the complete pure-data semantic chain.
    public static func builtInSemanticChain() -> HarnessScenario {
        let actor = EntityState(id: EntityID("semantic-actor"), kind: .actor)
        let window = VirtualWindow(
            id: EntityID("codex"), app: "codex", title: "mypet — Agent",
            frame: LayoutRect(x: 200, y: 100, width: 1100, height: 800), focused: true,
            content: VirtualWindowContent(activity: "coding", text: ["SceneRuntime.swift"]))
        let slot = InteractionSlot(entityID: window.id, slotID: "top.right")
        return HarnessScenario(
            id: "semantic-chain",
            seed: 48123,
            durationTicks: 8,
            entities: [actor],
            slots: [slot],
            desktop: VirtualDesktop(windows: [window]),
            pipeline: SemanticPipelineConfiguration(
                actorID: actor.id,
                assetCatalog: AssetCatalog(exactActions: ["think"])),
            expectations: ScenarioExpectations(
                requiredPipelineStages: ["goal", "scene", "needle", "action"],
                partialOrders: [["goal", "scene", "needle", "action"]]))
    }

    /// Reproducible world for a local-Qwen complete-gameplay run. Two related
    /// actors begin on different windows and a third actor blocks the route.
    public static func builtInQwenPlay() -> HarnessScenario {
        let left = VirtualWindow(
            id: EntityID("window-left"), app: "Finder", title: "Left workspace",
            frame: LayoutRect(x: 40, y: 80, width: 720, height: 620), focused: true)
        let right = VirtualWindow(
            id: EntityID("window-right"), app: "Safari", title: "Right workspace",
            frame: LayoutRect(x: 820, y: 80, width: 720, height: 620), focused: false)
        let actors = ["actor-a", "actor-b", "blocker"].map {
            EntityState(id: EntityID($0), kind: .actor)
        }
        return HarnessScenario(
            id: "qwen-complete-gameplay",
            seed: 48123,
            durationTicks: 80,
            entities: actors,
            desktop: VirtualDesktop(windows: [left, right]),
            playSpace: VirtualPlaySpace(
                actorAnchors: [
                    "actor-a": "window-left",
                    "actor-b": "window-right",
                    "blocker": "bridge",
                ],
                edges: [
                    VirtualPlayEdge(
                        id: "left-to-bridge", from: "window-left", to: "bridge",
                        traversalIntent: "jump_to_bridge", blockedByActorIDs: ["blocker"]),
                    VirtualPlayEdge(
                        id: "bridge-to-right", from: "bridge", to: "window-right",
                        traversalIntent: "jump_to_right_window"),
                ]),
            playBrief: QwenPlayBrief(
                relationships: ["actor-a and actor-b are hostile enemies"],
                objective: "actor-a and actor-b must meet and fight",
                requiredOutcomeIntents: ["fight"]))
    }

    /// End-to-end headless matrix for the six external input plugins. The
    /// observations are routed through the same catalog used by AppKit before
    /// entering the kernel, so this catches channel mismatches, clipping,
    /// TTL/preemption and raw-text leakage in one replayable run.
    public static func builtInInputMatrix() -> HarnessScenario {
        var catalog = InputPluginCatalog.defaults()
        for pluginID in catalog.plugins.keys {
            guard var config = catalog.plugins[pluginID] else { continue }
            config.enabled = true
            config.ttlTicks = 6
            config.maxCharacters = 24
            config.preemptive = true
            config.priority = .urgentReactive
            catalog.plugins[pluginID] = config
        }

        let inputs: [(String, String, InputChannel, String, String, String)] = [
            ("title", "window-title", .windowTitle, "WeChat", "微信", "微信 - Alice"),
            ("ax", "accessibility", .accessibility, "WeChat", "Alice", "AX focused message"),
            ("ocr", "ocr", .ocr, "WeChat", "Alice", "OCR message content"),
            ("chat", "chat-content", .chat, "WeChat", "Alice", "你好，桌宠请过来"),
            ("code", "code-content", .code, "Xcode", "main.swift", "let answer = 42"),
            ("browser", "browser-content", .browser, "Safari", "Docs", "private browser content"),
        ]
        let sensorProfiles = inputs.map { _, pluginID, channel, _, _, _ in
            VirtualSensorProfile(pluginID: pluginID, channel: channel)
        }
        let sensorEvents = inputs.map { id, pluginID, channel, app, title, text in
            let observation = InputObservation(
                id: "matrix-\(id)", pluginID: pluginID, channel: channel,
                appName: app, windowTitle: title, text: text,
                capturedAtTick: 2)
            return VirtualDesktopEvent(
                atTick: 2,
                action: .emitObservation(VirtualSensorObservation(observation: observation)))
        }

        let actor = EntityState(id: EntityID("input-matrix-actor"), kind: .actor)
        let ambient = BehaviorRequest(
            id: "input-matrix-ambient", actorID: actor.id, intent: "idle",
            priority: .ambient, durationTicks: 20)
        return HarnessScenario(
            id: "input-matrix", seed: 48123, durationTicks: 12,
            entities: [actor],
            events: [
                ScheduledEvent(atTick: 1, event: GameEvent(kind: .behaviorRequest, request: ambient)),
                ScheduledEvent(atTick: 2, event: GameEvent(kind: .foregroundChanged)),
            ],
            desktop: VirtualDesktop(
                sensors: SensorSimulator(profiles: sensorProfiles),
                inputCatalog: catalog,
                events: sensorEvents))
    }

    /// 仅用于 Harness 的确定性压力场景：大量独立 actor、行为请求和有 TTL
    /// 的内容观察同时进入同一 GameKernel；不包含 AppKit 或模型依赖。
    public static func builtInStressGrid() -> HarnessScenario {
        let actorCount = 64
        let entities = (0..<actorCount).map {
            EntityState(id: EntityID("stress-actor-\($0)"), kind: .actor)
        }
        let requests = entities.map { actor in
            BehaviorRequest(
                id: "stress-behavior-\(actor.id.raw)", actorID: actor.id,
                intent: "wait", priority: .ambient, durationTicks: 40)
        }
        var events = requests.map {
            ScheduledEvent(atTick: 0, event: GameEvent(kind: .behaviorRequest, request: $0))
        }
        for index in 0..<256 {
            let observation = InputObservation(
                id: "stress-input-\(index)", pluginID: "browser-content", channel: .browser,
                appName: "Safari", windowTitle: "Stress \(index)", text: "bounded input \(index)",
                capturedAtTick: Int64(index % 80), expiresAtTick: Int64(index % 80 + 20))
            events.append(ScheduledEvent(
                atTick: observation.capturedAtTick,
                event: GameEvent(kind: .contentObservation, inputObservation: observation)))
        }
        return HarnessScenario(
            id: "stress-grid", seed: 48123, durationTicks: 160,
            entities: entities, events: events, requireAllClaimsReleased: false)
    }
}

public enum ScenarioRunner {
    public static func report(_ scenario: HarnessScenario, kernel: KernelSnapshot) -> ScenarioReport {
        report(scenario, kernel: kernel, desktop: scenario.desktop, pipeline: nil)
    }

    public static func report(
        _ scenario: HarnessScenario,
        kernel: KernelSnapshot,
        desktop: VirtualDesktop,
        pipeline: SemanticPipeline?
    ) -> ScenarioReport {
        var violations = kernel.manualViolations
        violations.append(contentsOf: InvariantChecker.check(kernel.world, tick: kernel.clock.tick))
        if scenario.requireAllClaimsReleased {
            violations.append(contentsOf: InvariantChecker.checkTerminal(kernel.world, tick: kernel.clock.tick))
        }
        var logicVerdict: LogicVerdict
        var contentVerdict: ContentVerdict
        var pipelineTrace: [PipelineTraceEntry]
        if let pipeline {
            let inspectionKernel = GameKernel(snapshot: kernel)
            logicVerdict = pipeline.logicVerdict(
                kernel: inspectionKernel, expectations: scenario.expectations)
            contentVerdict = pipeline.contentVerdict()
            pipelineTrace = pipeline.trace
        } else {
            logicVerdict = LogicVerdict(failures: violations.map { "\($0.code):\($0.message)" })
            let inspectionKernel = GameKernel(snapshot: kernel)
            logicVerdict = LogicVerdict(failures: logicVerdict.failures +
                scenario.expectations.check(kernel: inspectionKernel, pipelineTrace: []))
            contentVerdict = ContentVerdict()
            pipelineTrace = []
        }
        let passed = violations.isEmpty && logicVerdict.passed && contentVerdict.complete
        return ScenarioReport(
            scenarioID: scenario.id,
            ticks: kernel.clock.tick,
            passed: passed,
            finalDigest: kernel.world.stableDigest(),
            violations: violations,
            traceCount: kernel.trace.count,
            desktopDigest: desktop.stableDigest(),
            pipelineTrace: pipelineTrace,
            logicVerdict: logicVerdict,
            contentVerdict: contentVerdict)
    }

    public static func run(_ scenario: HarnessScenario) -> (ScenarioReport, KernelSnapshot) {
        let simulation = DataSimulation(scenario: scenario)
        _ = simulation.run(ticks: scenario.durationTicks)
        return (
            report(
                scenario,
                kernel: simulation.kernel,
                desktop: simulation.desktop,
                pipeline: simulation.pipeline),
            simulation.kernel)
    }

    public static func replay(_ scenario: HarnessScenario) -> ReplayReport {
        let firstSimulation = DataSimulation(scenario: scenario)
        let secondSimulation = DataSimulation(scenario: scenario)
        _ = firstSimulation.run(ticks: scenario.durationTicks)
        _ = secondSimulation.run(ticks: scenario.durationTicks)
        let first = (
            report(scenario, kernel: firstSimulation.kernel, desktop: firstSimulation.desktop, pipeline: firstSimulation.pipeline),
            firstSimulation.kernel)
        let second = (
            report(scenario, kernel: secondSimulation.kernel, desktop: secondSimulation.desktop, pipeline: secondSimulation.pipeline),
            secondSimulation.kernel)
        let firstDifference = zip(first.1.trace, second.1.trace)
            .enumerated()
            .first(where: { $0.element.0 != $0.element.1 })?.offset
            ?? (first.1.trace.count == second.1.trace.count ? nil : min(first.1.trace.count, second.1.trace.count))
        return ReplayReport(
            scenarioID: scenario.id,
            matched: firstDifference == nil && first.1.trace.count == second.1.trace.count && first.0.finalDigest == second.0.finalDigest,
            firstDifference: firstDifference,
            firstDigest: first.0.finalDigest,
            secondDigest: second.0.finalDigest
        )
    }
}
