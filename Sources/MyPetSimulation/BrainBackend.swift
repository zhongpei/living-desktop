import Foundation
import MyPetCore
import MyPetEngine

/// The three supported headless execution modes. `existing` keeps the current
/// deterministic data-only behaviour as the control line; the other two swap
/// only the decision providers while keeping the same semantic pipeline.
public enum SimulationMode: String, Codable, CaseIterable, Sendable {
    case existing
    case needleOnly = "needle-only"
    case qwenNeedle = "qwen+needle"
}

/// Backend execution verdict kept separate from the ordinary Kernel logic
/// verdict. A deterministic run may pass logic without proving a real model
/// was called; the two real modes require successful provider invocations.
public struct SimulationModeVerdict: Codable, Equatable, Sendable {
    public let mode: SimulationMode
    public let passed: Bool
    public let failures: [String]
    public let goalCalls: Int
    public let goalSuccesses: Int
    public let needleCalls: Int
    public let needleSuccesses: Int

    public init(
        mode: SimulationMode,
        passed: Bool,
        failures: [String] = [],
        goalCalls: Int = 0,
        goalSuccesses: Int = 0,
        needleCalls: Int = 0,
        needleSuccesses: Int = 0
    ) {
        self.mode = mode
        self.passed = passed
        self.failures = failures
        self.goalCalls = goalCalls
        self.goalSuccesses = goalSuccesses
        self.needleCalls = needleCalls
        self.needleSuccesses = needleSuccesses
    }
}

public enum BrainMode: String, Codable, CaseIterable, Sendable {
    case stub
    case replay
    case local
    case teacher
    case localMLX = "local-mlx"
    case semantic
}

/// Harness 中脑只提交可回放的 Goal→Behavior 请求，不直接碰 WorldState。
public struct BrainCommand: Codable, Equatable, Sendable {
    public var atTick: Int64
    public var request: BehaviorRequest

    public init(atTick: Int64, request: BehaviorRequest) {
        self.atTick = atTick
        self.request = request
    }
}

public struct BrainCassette: Codable, Equatable, Sendable {
    public var mode: BrainMode
    public var commands: [BrainCommand]
    /// Optional semantic cassette. When a HarnessScenario enables the pure
    /// pipeline, these commands feed GoalBrain/NeedleBrain instead of being
    /// installed as direct behavior requests.
    public var goalCommands: [SimulationGoalCommand]
    public var needleCommands: [SimulationNeedleCommand]

    public init(
        mode: BrainMode = .stub,
        commands: [BrainCommand] = [],
        goalCommands: [SimulationGoalCommand] = [],
        needleCommands: [SimulationNeedleCommand] = []
    ) {
        self.mode = mode
        self.commands = commands
        self.goalCommands = goalCommands
        self.needleCommands = needleCommands
    }

    private enum CodingKeys: String, CodingKey {
        case mode, commands, goalCommands, needleCommands
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try values.decodeIfPresent(BrainMode.self, forKey: .mode) ?? .stub,
            commands: try values.decodeIfPresent([BrainCommand].self, forKey: .commands) ?? [],
            goalCommands: try values.decodeIfPresent([SimulationGoalCommand].self, forKey: .goalCommands) ?? [],
            needleCommands: try values.decodeIfPresent([SimulationNeedleCommand].self, forKey: .needleCommands) ?? [])
    }

    public static func loadJSON(at url: URL) throws -> BrainCassette {
        try JSONDecoder().decode(BrainCassette.self, from: Data(contentsOf: url))
    }

    public func writeJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct BrainBackendStatus: Codable, Equatable, Sendable {
    public let mode: BrainMode
    public let available: Bool
    public let reason: String

    public init(mode: BrainMode, available: Bool, reason: String) {
        self.mode = mode
        self.available = available
        self.reason = reason
    }
}

public enum BrainBackend {
    /// 为 replay/故障测试安装 cassette。正常模型结果必须作为 Goal/Needle
    /// provider 进入 SemanticPipeline，不能在这里直接生成行为请求。
    @discardableResult
    public static func install(
        mode: BrainMode,
        cassette: BrainCassette?,
        in kernel: GameKernel
    ) -> BrainBackendStatus {
        switch mode {
        case .stub, .replay:
            guard let cassette else {
                return BrainBackendStatus(mode: mode, available: false, reason: "cassette_missing")
            }
            for command in cassette.commands.sorted(by: { $0.atTick == $1.atTick ? $0.request.id < $1.request.id : $0.atTick < $1.atTick }) {
                kernel.enqueue(GameEvent(kind: .behaviorRequest, request: command.request), atTick: command.atTick)
            }
            return BrainBackendStatus(mode: mode, available: true, reason: "cassette_installed")
        case .local:
            return BrainBackendStatus(mode: mode, available: false, reason: "live_adapter_required")
        case .teacher:
            return BrainBackendStatus(mode: mode, available: false, reason: "live_adapter_required")
        case .localMLX:
            return BrainBackendStatus(mode: mode, available: false, reason: "mlx_adapter_required")
        case .semantic:
            return BrainBackendStatus(mode: mode, available: true, reason: "pure_data_pipeline_required")
        }
    }
}
