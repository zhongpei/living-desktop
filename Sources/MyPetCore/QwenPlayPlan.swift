import Foundation

public struct VirtualPlayEdge: Codable, Equatable, Sendable {
    public var id: String
    public var from: String
    public var to: String
    public var traversalIntent: String
    public var blockedByActorIDs: [String]

    public init(
        id: String, from: String, to: String, traversalIntent: String,
        blockedByActorIDs: [String] = []
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.traversalIntent = traversalIntent
        self.blockedByActorIDs = blockedByActorIDs
    }
}

/// Spatial facts are fast-brain input. They never appear in Qwen's plan graph.
public struct VirtualPlaySpace: Codable, Equatable, Sendable {
    public var actorAnchors: [String: String]
    public var edges: [VirtualPlayEdge]

    public init(actorAnchors: [String: String] = [:], edges: [VirtualPlayEdge] = []) {
        self.actorAnchors = actorAnchors
        self.edges = edges
    }
}

public struct QwenPlayBrief: Codable, Equatable, Sendable {
    public var relationships: [String]
    public var objective: String
    public var requiredOutcomeIntents: [String]

    public init(
        relationships: [String], objective: String,
        requiredOutcomeIntents: [String] = []
    ) {
        self.relationships = relationships
        self.objective = objective
        self.requiredOutcomeIntents = requiredOutcomeIntents
    }
}

public enum QwenPlayNodeKind: String, Codable, Sendable {
    case interact
    case rendezvous
    case resolveObstacle = "resolve_obstacle"
}

public enum QwenPlayTargetRole: String, Codable, Sendable {
    case blockingActor = "blocking_actor"
}

/// One machine-readable director decision node. Nodes express interaction
/// logic and branches, never coordinates, windows, anchors, edges, or travel.
public struct QwenPlayNode: Codable, Equatable, Sendable {
    public var id: String
    public var kind: QwenPlayNodeKind
    public var actorIDs: [String]
    public var intent: String
    /// Fast-brain candidates for realizing this node. Qwen may bound the
    /// choices but does not select the concrete action.
    public var actionCandidates: [String]?
    public var targetID: String?
    public var targetRole: QwenPlayTargetRole?
    public var onSuccess: String?
    public var onBlocked: String?
    public var durationTicks: Int64

    public init(
        id: String,
        kind: QwenPlayNodeKind,
        actorIDs: [String],
        intent: String,
        actionCandidates: [String]? = nil,
        targetID: String? = nil,
        targetRole: QwenPlayTargetRole? = nil,
        onSuccess: String? = nil,
        onBlocked: String? = nil,
        durationTicks: Int64 = 1
    ) {
        self.id = id
        self.kind = kind
        self.actorIDs = actorIDs
        self.intent = intent
        self.actionCandidates = actionCandidates
        self.targetID = targetID
        self.targetRole = targetRole
        self.onSuccess = onSuccess
        self.onBlocked = onBlocked
        self.durationTicks = max(1, durationTicks)
    }
}

public enum QwenPlaySuccessKind: String, Codable, Sendable {
    case actorsCoLocated = "actors_co_located"
    case interactionCompleted = "interaction_completed"
}

public struct QwenPlaySuccessCriterion: Codable, Equatable, Sendable {
    public var kind: QwenPlaySuccessKind
    public var actorIDs: [String]
    public var intent: String?

    public init(kind: QwenPlaySuccessKind, actorIDs: [String], intent: String? = nil) {
        self.kind = kind
        self.actorIDs = actorIDs
        self.intent = intent
    }
}

/// Complete gameplay output from Qwen: a bounded node graph for the fast brain.
public struct QwenPlayPlan: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var participants: [String]
    public var entryNodeID: String
    public var nodes: [QwenPlayNode]
    public var successCriteria: [QwenPlaySuccessCriterion]?

    public init(
        id: String, title: String, participants: [String],
        entryNodeID: String, nodes: [QwenPlayNode],
        successCriteria: [QwenPlaySuccessCriterion]? = nil
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.entryNodeID = entryNodeID
        self.nodes = nodes
        self.successCriteria = successCriteria
    }
}

public struct QwenPlayPlanValidation: Codable, Equatable, Sendable {
    public var failures: [String]
    public init(failures: [String]) { self.failures = failures }
}

public struct ResolvedQwenPlayPlan: Codable, Equatable, Sendable {
    public var episode: StoryEpisode
    public var resolutionTrace: [String]
    public var nodeDecisions: [QwenNodeDecision]
    public var fastActionDecisions: [QwenFastActionDecision]
    public var finalActorAnchors: [String: String]
    public init(
        episode: StoryEpisode,
        resolutionTrace: [String],
        nodeDecisions: [QwenNodeDecision],
        fastActionDecisions: [QwenFastActionDecision],
        finalActorAnchors: [String: String]
    ) {
        self.episode = episode
        self.resolutionTrace = resolutionTrace
        self.nodeDecisions = nodeDecisions
        self.fastActionDecisions = fastActionDecisions
        self.finalActorAnchors = finalActorAnchors
    }
}

public struct QwenFastActionDecision: Codable, Equatable, Sendable {
    public var nodeID: String
    public var actorID: String
    public var observation: String
    public var candidates: [String]
    public var candidateFingerprint: String
    public var selected: String

    public init(nodeID: String, actorID: String, observation: String,
                candidates: [String], selected: String) {
        self.nodeID = nodeID
        self.actorID = actorID
        self.observation = observation
        self.candidates = candidates
        self.candidateFingerprint = ActionDecisionBoundary.fingerprint(candidates)
        self.selected = selected
    }
}

public protocol FastPlayDecisionProvider: Sendable {
    func selectAction(node: QwenPlayNode, actorID: String,
                      observation: String, candidates: [String]) -> String?
}

public struct DeterministicFastPlayDecisionProvider: FastPlayDecisionProvider {
    public init() {}
    public func selectAction(node: QwenPlayNode, actorID: String,
                             observation: String, candidates: [String]) -> String? {
        candidates.first
    }
}

public struct QwenPlayOutcomeVerdict: Codable, Equatable, Sendable {
    public var passed: Bool
    public var failures: [String]
    public init(passed: Bool, failures: [String]) {
        self.passed = passed
        self.failures = failures
    }
}

/// Training/evaluation boundary for Director-S1: current node plus a bounded
/// observation selects one of the graph's eligible next nodes.
public struct QwenNodeDecision: Codable, Equatable, Sendable {
    public var planID: String
    public var currentNodeID: String
    public var observation: String
    public var eligibleNodeIDs: [String]
    public var candidateFingerprint: String
    public var selectedNodeID: String?

    public init(
        planID: String,
        currentNodeID: String,
        observation: String,
        eligibleNodeIDs: [String],
        selectedNodeID: String?
    ) {
        self.planID = planID
        self.currentNodeID = currentNodeID
        self.observation = observation
        self.eligibleNodeIDs = eligibleNodeIDs
        self.candidateFingerprint = ActionDecisionBoundary.fingerprint(eligibleNodeIDs)
        self.selectedNodeID = selectedNodeID
    }
}

public enum QwenPlayPlanError: Error, Equatable {
    case invalid([String])
}

public enum QwenPlayPlanValidator {
    public static func validate(
        _ plan: QwenPlayPlan,
        availableActorIDs: Set<String>,
        requiredOutcomeIntents: [String] = []
    ) -> QwenPlayPlanValidation {
        var failures: [String] = []
        if plan.id.isEmpty { failures.append("plan_id_missing") }
        if plan.nodes.isEmpty { failures.append("nodes_missing") }
        if plan.nodes.count > 64 { failures.append("too_many_nodes") }
        if Set(plan.participants).count != plan.participants.count {
            failures.append("duplicate_participants")
        }
        for participant in plan.participants where !availableActorIDs.contains(participant) {
            failures.append("participant_missing:\(participant)")
        }
        let nodeIDs = Set(plan.nodes.map(\.id))
        if !nodeIDs.contains(plan.entryNodeID) { failures.append("entry_node_missing") }
        if nodeIDs.count != plan.nodes.count { failures.append("duplicate_node_id") }
        for node in plan.nodes {
            let prefix = "node:\(node.id)"
            if node.id.isEmpty { failures.append("\(prefix):id_missing") }
            if node.actorIDs.isEmpty { failures.append("\(prefix):actors_missing") }
            for actor in node.actorIDs {
                if !availableActorIDs.contains(actor) { failures.append("\(prefix):actor_missing:\(actor)") }
                if !plan.participants.contains(actor) { failures.append("\(prefix):actor_not_participant:\(actor)") }
            }
            if node.intent.isEmpty { failures.append("\(prefix):intent_missing") }
            if let candidates = node.actionCandidates,
               candidates.isEmpty || Set(candidates).count != candidates.count || candidates.contains(where: \.isEmpty) {
                failures.append("\(prefix):action_candidates_invalid")
            }
            if let target = node.targetID, !availableActorIDs.contains(target) {
                failures.append("\(prefix):target_missing:\(target)")
            }
            for next in [node.onSuccess, node.onBlocked].compactMap({ $0 }) where !nodeIDs.contains(next) {
                failures.append("\(prefix):next_missing:\(next)")
            }
            switch node.kind {
            case .rendezvous:
                if node.targetID == nil { failures.append("\(prefix):rendezvous_target_missing") }
                if node.actorIDs.first == node.targetID { failures.append("\(prefix):mover_equals_target") }
                if node.onBlocked == nil { failures.append("\(prefix):blocked_branch_missing") }
            case .resolveObstacle:
                if node.targetRole != .blockingActor {
                    failures.append("\(prefix):blocking_actor_role_required")
                }
                if node.onSuccess == nil { failures.append("\(prefix):success_branch_missing") }
            case .interact:
                break
            }
        }
        for criterion in plan.successCriteria ?? [] {
            if criterion.actorIDs.isEmpty || criterion.actorIDs.contains(where: { !availableActorIDs.contains($0) }) {
                failures.append("success_criterion_actor_missing")
            }
            if criterion.kind == .interactionCompleted && (criterion.intent?.isEmpty != false) {
                failures.append("success_criterion_intent_missing")
            }
        }
        let nodeIntents = Set(plan.nodes.map(\.intent))
        let criterionIntents = Set((plan.successCriteria ?? []).compactMap(\.intent))
        for intent in requiredOutcomeIntents {
            if !nodeIntents.contains(intent) { failures.append("required_node_intent_missing:\(intent)") }
            if !criterionIntents.contains(intent) { failures.append("required_success_intent_missing:\(intent)") }
        }
        return QwenPlayPlanValidation(failures: Array(Set(failures)).sorted())
    }
}

/// Fast-brain graph resolver. It alone receives routes and chooses concrete
/// travel/obstacle beats from the current data world.
public enum FastPlayResolver {
    public static func resolve(
        _ plan: QwenPlayPlan,
        playSpace: VirtualPlaySpace,
        availableActorIDs: Set<String>,
        decisionProvider: any FastPlayDecisionProvider = DeterministicFastPlayDecisionProvider()
    ) throws -> ResolvedQwenPlayPlan {
        let validation = QwenPlayPlanValidator.validate(plan, availableActorIDs: availableActorIDs)
        guard validation.failures.isEmpty else { throw QwenPlayPlanError.invalid(validation.failures) }
        let nodes = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0) })
        var anchors = playSpace.actorAnchors
        var beats: [StoryBeat] = []
        var trace: [String] = []
        var decisions: [QwenNodeDecision] = []
        var actionDecisions: [QwenFastActionDecision] = []
        var currentID: String? = plan.entryNodeID
        var transitions = 0

        while let id = currentID, let node = nodes[id], transitions < 128 {
            transitions += 1
            switch node.kind {
            case .interact:
                beats.append(beat(node, targetID: node.targetID))
                trace.append("\(id):interaction")
                decisions.append(QwenNodeDecision(
                    planID: plan.id, currentNodeID: id, observation: "completed",
                    eligibleNodeIDs: [node.onSuccess].compactMap { $0 },
                    selectedNodeID: node.onSuccess))
                currentID = node.onSuccess
            case .resolveObstacle:
                // Obstacle nodes are entered by rendezvous resolution with a
                // concrete blocker; a free-standing node is invalid.
                throw QwenPlayPlanError.invalid(["node:\(id):obstacle_without_blocker"])
            case .rendezvous:
                guard let mover = node.actorIDs.first, let target = node.targetID,
                      let origin = anchors[mover], let destination = anchors[target],
                      let route = shortestRoute(from: origin, to: destination, edges: playSpace.edges) else {
                    throw QwenPlayPlanError.invalid(["node:\(id):route_unavailable"])
                }
                let blockers = route.flatMap(\.blockedByActorIDs)
                    .filter { $0 != mover && $0 != target }
                if let blocker = blockers.first {
                    guard let blockedID = node.onBlocked,
                          let blockedNode = nodes[blockedID],
                          blockedNode.kind == .resolveObstacle else {
                        throw QwenPlayPlanError.invalid(["node:\(id):blocked_branch_invalid"])
                    }
                    let candidates = blockedNode.actionCandidates ?? [blockedNode.intent]
                    guard let selected = decisionProvider.selectAction(
                        node: blockedNode, actorID: mover,
                        observation: "blocked_by:\(blocker)", candidates: candidates),
                          candidates.contains(selected) else {
                        throw QwenPlayPlanError.invalid(["node:\(blockedID):fast_action_missing"])
                    }
                    beats.append(beat(blockedNode, targetID: blocker, intent: selected))
                    actionDecisions.append(QwenFastActionDecision(
                        nodeID: blockedID, actorID: mover,
                        observation: "blocked_by:\(blocker)",
                        candidates: candidates, selected: selected))
                    trace.append("\(id):blocked:\(blocker)->\(blockedID)")
                    decisions.append(QwenNodeDecision(
                        planID: plan.id, currentNodeID: id,
                        observation: "blocked_by:\(blocker)",
                        eligibleNodeIDs: [node.onSuccess, node.onBlocked].compactMap { $0 },
                        selectedNodeID: blockedID))
                    decisions.append(QwenNodeDecision(
                        planID: plan.id, currentNodeID: blockedID,
                        observation: "obstacle_resolved:\(blocker)",
                        eligibleNodeIDs: [blockedNode.onSuccess].compactMap { $0 },
                        selectedNodeID: blockedNode.onSuccess))
                } else {
                    decisions.append(QwenNodeDecision(
                        planID: plan.id, currentNodeID: id, observation: "route_clear",
                        eligibleNodeIDs: [node.onSuccess, node.onBlocked].compactMap { $0 },
                        selectedNodeID: node.onSuccess))
                }
                for edge in route {
                    beats.append(StoryBeat(
                        id: "\(id)-travel-\(edge.id)", actorIDs: [mover],
                        intent: edge.traversalIntent, durationTicks: 1))
                    anchors[mover] = edge.to
                    trace.append("\(id):fast-route:\(edge.id)")
                }
                beats.append(beat(node, targetID: target))
                trace.append("\(id):rendezvous-complete")
                currentID = node.onSuccess
            }
        }
        if transitions >= 128 { throw QwenPlayPlanError.invalid(["node_transition_limit"]) }
        return ResolvedQwenPlayPlan(
            episode: StoryEpisode(
                id: "qwen/\(plan.id)", title: plan.title,
                participants: plan.participants, beats: beats),
            resolutionTrace: trace,
            nodeDecisions: decisions,
            fastActionDecisions: actionDecisions,
            finalActorAnchors: anchors)
    }

    private static func beat(
        _ node: QwenPlayNode, targetID: String?, intent: String? = nil
    ) -> StoryBeat {
        StoryBeat(
            id: node.id, actorIDs: node.actorIDs, intent: intent ?? node.intent,
            durationTicks: node.durationTicks, targetID: targetID)
    }

    private static func shortestRoute(
        from: String, to: String, edges: [VirtualPlayEdge]
    ) -> [VirtualPlayEdge]? {
        if from == to { return [] }
        var queue: [(String, [VirtualPlayEdge])] = [(from, [])]
        var visited: Set<String> = [from]
        while !queue.isEmpty {
            let (anchor, path) = queue.removeFirst()
            for edge in edges.filter({ $0.from == anchor }).sorted(by: { $0.id < $1.id }) {
                let next = path + [edge]
                if edge.to == to { return next }
                if visited.insert(edge.to).inserted { queue.append((edge.to, next)) }
            }
        }
        return nil
    }
}

public enum QwenPlayOutcomeEvaluator {
    public static func evaluate(
        plan: QwenPlayPlan,
        resolved: ResolvedQwenPlayPlan,
        storyCompleted: Bool,
        requiredOutcomeIntents: [String] = []
    ) -> QwenPlayOutcomeVerdict {
        var failures: [String] = []
        if !storyCompleted { failures.append("story_not_completed") }
        let completedIntents = Set(resolved.episode.beats.map(\.intent))
        for intent in requiredOutcomeIntents where !completedIntents.contains(intent) {
            failures.append("required_outcome_missing:\(intent)")
        }
        for criterion in plan.successCriteria ?? [] {
            switch criterion.kind {
            case .actorsCoLocated:
                let anchors = Set(criterion.actorIDs.compactMap { resolved.finalActorAnchors[$0] })
                if anchors.count != 1 || criterion.actorIDs.contains(where: { resolved.finalActorAnchors[$0] == nil }) {
                    failures.append("actors_not_colocated:\(criterion.actorIDs.joined(separator: ","))")
                }
            case .interactionCompleted:
                if let intent = criterion.intent, !completedIntents.contains(intent) {
                    failures.append("interaction_missing:\(intent)")
                }
            }
        }
        return QwenPlayOutcomeVerdict(passed: failures.isEmpty, failures: failures)
    }
}
