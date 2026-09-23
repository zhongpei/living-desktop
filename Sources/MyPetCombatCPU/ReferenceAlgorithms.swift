import Foundation
import MyPetCombat

/// Fixed compatibility parameters reproduced from MctsAi23i commit
/// b05afc13f6b0815ff154d19ca7e76c99c172799b. That repository has no
/// discoverable license, so this is an independent implementation of the
/// published UCB1 equation and observable limits, not copied source code.
enum MctsAi23iCompatibility {
    static let iterationLimit = 23
    static let explorationConstant = 3.0
    static let treeDepth = 2
    static let expansionVisitThreshold = 10
    static let simulationFrames = 60
    static let aheadFrames = 14

    static func ucb1(meanReward: Double, parentVisits: Int, visits: Int) -> Double {
        guard visits > 0 else { return .infinity }
        return meanReward + explorationConstant *
            sqrt(2 * log(Double(max(1, parentVisits))) / Double(visits))
    }
}

/// Swift port of the keypress/keyseq/fetch controller boundary from F.LF
/// commit 21341737e4154d06d9784e9a629c9dd4db9148d6 (GNU GPL v3). The original
/// JavaScript arrays are represented as typed state and event values.
struct FLFControllerCompatibility<Key: Hashable & Sendable>: Sendable {
    struct Event: Equatable, Sendable {
        var key: Key
        var isDown: Bool
    }

    private(set) var state: [Key: Bool] = [:]
    private(set) var bufferedEvents: [Event] = []

    mutating func keypress(_ key: Key, hold: Bool? = nil) {
        switch hold {
        case nil:
            if state[key] == true { bufferedEvents.append(Event(key: key, isDown: false)) }
            bufferedEvents.append(Event(key: key, isDown: true))
            bufferedEvents.append(Event(key: key, isDown: false))
        case true:
            if state[key] != true { bufferedEvents.append(Event(key: key, isDown: true)) }
        case false:
            if state[key] == true { bufferedEvents.append(Event(key: key, isDown: false)) }
        }
    }

    mutating func keyseq(_ keys: [Key]) {
        for key in keys { keypress(key) }
    }

    mutating func fetch() -> [Event] {
        let result = bufferedEvents
        for event in result { state[event.key] = event.isDown }
        bufferedEvents.removeAll(keepingCapacity: true)
        return result
    }
}

/// Direct Swift adaptation of FightingICE CommandCenter's public queue
/// semantics: a command is accepted only when the previous command's physical
/// key frames have drained, and consumers poll one frame at a time.
struct FightingICECommandCenterCompatibility: Codable, Equatable, Sendable {
    private(set) var skillKeys: [FighterInputFrame] = []

    var skillFlag: Bool { !skillKeys.isEmpty }

    mutating func commandCall(_ command: CombatCommand, facing: CombatFacing) {
        guard skillKeys.isEmpty else { return }
        skillKeys = CombatCommandSynthesizer.frames(for: command, facing: facing)
    }

    mutating func getSkillKey() -> FighterInputFrame {
        skillKeys.isEmpty ? .neutral : skillKeys.removeFirst()
    }

    mutating func skillCancel() {
        skillKeys.removeAll(keepingCapacity: true)
    }
}

/// Deterministic shortest-path primitive used by the surface adaptation. The
/// surface/trajectory split follows Surfacer commit 04058c5 (MIT); this compact
/// implementation is native Swift and keeps only the behavior MyPet needs.
enum SurfacerPathCompatibility {
    struct Edge<Node: Hashable & Comparable & Sendable>: Sendable {
        var from: Node
        var to: Node
        var cost: Double
    }

    static func shortestPath<Node: Hashable & Comparable & Sendable>(
        from start: Node,
        to goal: Node,
        edges: [Edge<Node>]
    ) -> [Edge<Node>]? {
        if start == goal { return [] }
        var frontier: [(node: Node, cost: Double)] = [(start, 0)]
        var best: [Node: Double] = [start: 0]
        var previous: [Node: Edge<Node>] = [:]
        while !frontier.isEmpty {
            frontier.sort {
                $0.cost == $1.cost ? $0.node < $1.node : $0.cost < $1.cost
            }
            let current = frontier.removeFirst()
            guard current.cost <= best[current.node, default: .infinity] else { continue }
            if current.node == goal { break }
            for edge in edges where edge.from == current.node {
                let next = current.cost + edge.cost
                let old = best[edge.to, default: .infinity]
                if next < old - 1e-9 ||
                    (abs(next - old) <= 1e-9 &&
                     edge.from < (previous[edge.to]?.from ?? edge.from)) {
                    best[edge.to] = next
                    previous[edge.to] = edge
                    frontier.append((edge.to, next))
                }
            }
        }
        guard best[goal] != nil else { return nil }
        var cursor = goal
        var result: [Edge<Node>] = []
        while cursor != start {
            guard let edge = previous[cursor] else { return nil }
            result.append(edge)
            cursor = edge.from
        }
        return result.reversed()
    }
}
