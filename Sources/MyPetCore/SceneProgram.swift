import Foundation

public enum SceneAction: Codable, Equatable, Sendable {
    case named(String)
}

public indirect enum SceneNode: Codable, Equatable, Sendable {
    case action(SceneAction)
    case sequence([SceneNode])
    case parallel([SceneNode])
    case race([SceneNode])
    case wait(Int64)
    case waitUntilFact(String)
    case timeout(Int64, SceneNode)

    private enum CodingKeys: String, CodingKey {
        case kind
        case action
        case children
        case ticks
        case fact
        case child
    }

    private enum Kind: String, Codable {
        case action
        case sequence
        case parallel
        case race
        case wait
        case waitUntilFact
        case timeout
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .action(action):
            try container.encode(Kind.action, forKey: .kind)
            try container.encode(action, forKey: .action)
        case let .sequence(children):
            try container.encode(Kind.sequence, forKey: .kind)
            try container.encode(children, forKey: .children)
        case let .parallel(children):
            try container.encode(Kind.parallel, forKey: .kind)
            try container.encode(children, forKey: .children)
        case let .race(children):
            try container.encode(Kind.race, forKey: .kind)
            try container.encode(children, forKey: .children)
        case let .wait(ticks):
            try container.encode(Kind.wait, forKey: .kind)
            try container.encode(ticks, forKey: .ticks)
        case let .waitUntilFact(fact):
            try container.encode(Kind.waitUntilFact, forKey: .kind)
            try container.encode(fact, forKey: .fact)
        case let .timeout(ticks, child):
            try container.encode(Kind.timeout, forKey: .kind)
            try container.encode(ticks, forKey: .ticks)
            try container.encode(child, forKey: .child)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .action:
            self = .action(try container.decode(SceneAction.self, forKey: .action))
        case .sequence:
            self = .sequence(try container.decode([SceneNode].self, forKey: .children))
        case .parallel:
            self = .parallel(try container.decode([SceneNode].self, forKey: .children))
        case .race:
            self = .race(try container.decode([SceneNode].self, forKey: .children))
        case .wait:
            self = .wait(try container.decode(Int64.self, forKey: .ticks))
        case .waitUntilFact:
            self = .waitUntilFact(try container.decode(String.self, forKey: .fact))
        case .timeout:
            self = .timeout(
                try container.decode(Int64.self, forKey: .ticks),
                try container.decode(SceneNode.self, forKey: .child)
            )
        }
    }
}

public struct SceneProgram: Codable, Equatable, Sendable {
    public let id: String
    public let root: SceneNode

    public init(id: String, root: SceneNode) {
        self.id = id
        self.root = root
    }
}

public enum SceneExecutionStatus: String, Codable, Sendable {
    case running
    case completed
    case timedOut
}

public struct SceneTickResult: Codable, Equatable, Sendable {
    public let status: SceneExecutionStatus
    public let tick: Int64
    public let winner: Int?

    public init(status: SceneExecutionStatus, tick: Int64, winner: Int? = nil) {
        self.status = status
        self.tick = tick
        self.winner = winner
    }
}

/// A deterministic interpreter with a real cursor per node. Game time advances only when tick() is called.
public final class SceneRuntime {
    public let program: SceneProgram
    private var elapsedTicks: Int64 = 0
    private let root: NodeState

    public init(program: SceneProgram) {
        self.program = program
        self.root = NodeState(node: program.root)
    }

    public func tick(validFacts: Set<String> = []) -> SceneTickResult {
        if root.completed {
            return SceneTickResult(
                status: root.timedOut ? .timedOut : .completed,
                tick: elapsedTicks,
                winner: root.winner)
        }

        elapsedTicks += 1
        let result = advance(root, facts: validFacts)
        return SceneTickResult(
            status: result == .timedOut ? .timedOut : (result == .completed ? .completed : .running),
            tick: elapsedTicks,
            winner: root.winner)
    }

    private enum Result: Equatable {
        case running
        case completed
        case timedOut
    }

    private final class NodeState {
        let node: SceneNode
        var elapsedTicks: Int64 = 0
        var nextChild = 0
        var completed = false
        var timedOut = false
        var winner: Int?
        var lastConsumed = false
        var children: [NodeState]

        init(node: SceneNode) {
            self.node = node
            switch node {
            case let .sequence(nodes), let .parallel(nodes), let .race(nodes):
                children = nodes.map(NodeState.init)
            case let .timeout(_, child):
                children = [NodeState(node: child)]
            default:
                children = []
            }
        }
    }

    private func advance(_ state: NodeState, facts: Set<String>) -> Result {
        state.lastConsumed = false
        if state.completed { return state.timedOut ? .timedOut : .completed }

        switch state.node {
        case .action:
            state.lastConsumed = true
            state.elapsedTicks += 1
            if state.elapsedTicks >= 1 { complete(state) }
        case let .wait(ticks):
            state.elapsedTicks += 1
            state.lastConsumed = ticks > 0
            if state.elapsedTicks >= max(0, ticks) { complete(state) }
        case let .waitUntilFact(fact):
            if facts.contains(fact) { complete(state) }
        case .sequence:
            while state.nextChild < state.children.count {
                let result = advance(state.children[state.nextChild], facts: facts)
                switch result {
                case .running:
                    state.lastConsumed = state.children[state.nextChild].lastConsumed
                    return .running
                case .timedOut:
                    state.timedOut = true
                    state.completed = true
                    return .timedOut
                case .completed:
                    let consumed = state.children[state.nextChild].lastConsumed
                    state.nextChild += 1
                    if consumed {
                        state.lastConsumed = true
                        if state.nextChild < state.children.count { return .running }
                        complete(state)
                        return .completed
                    }
                }
            }
            complete(state)
        case .parallel:
            var allCompleted = true
            var consumed = false
            for child in state.children {
                let result = advance(child, facts: facts)
                consumed = consumed || child.lastConsumed
                if result == .timedOut {
                    state.timedOut = true
                    state.completed = true
                    return .timedOut
                }
                if result == .running { allCompleted = false }
            }
            state.lastConsumed = consumed
            if allCompleted { complete(state) }
        case .race:
            var completedIndex: Int?
            var timedOutIndex: Int?
            var consumed = false
            for (index, child) in state.children.enumerated() where !child.completed {
                switch advance(child, facts: facts) {
                case .completed:
                    consumed = consumed || child.lastConsumed
                    completedIndex = completedIndex ?? index
                case .timedOut:
                    consumed = consumed || child.lastConsumed
                    timedOutIndex = timedOutIndex ?? index
                case .running:
                    consumed = consumed || child.lastConsumed
                    break
                }
            }
            state.lastConsumed = consumed
            if let winner = completedIndex {
                state.winner = winner
                complete(state)
            } else if let winner = timedOutIndex {
                state.winner = winner
                state.timedOut = true
                state.completed = true
                return .timedOut
            }
        case let .timeout(limit, _):
            state.lastConsumed = true
            state.elapsedTicks += 1
            let childResult = advance(state.children[0], facts: facts)
            switch childResult {
            case .completed:
                complete(state)
            case .timedOut:
                state.timedOut = true
                state.completed = true
                return .timedOut
            case .running:
                if state.elapsedTicks >= max(0, limit) {
                    state.timedOut = true
                    state.completed = true
                    return .timedOut
                }
            }
        }
        return state.completed ? (state.timedOut ? .timedOut : .completed) : .running
    }

    private func complete(_ state: NodeState) {
        state.completed = true
    }
}
