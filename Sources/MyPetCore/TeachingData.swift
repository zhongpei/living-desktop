import CryptoKit
import Foundation

public enum TeachingMode: String, Codable, CaseIterable, Sendable {
    case none
    case localQwen = "local-qwen"
    case apiTeacher = "api-teacher"
    case hybrid
}

public enum TeachingTask: String, Codable, Sendable {
    case goal
    case action
    case directorNode = "director-node"
}

public enum TeacherTier: String, Codable, Sendable {
    case local
    case remote
}

public enum TrainingGrade: String, Codable, Sendable {
    case raw
    case silver
    case gold
    case diagnostic
    case rejected
}

public enum DecisionBoundaryError: Error, Equatable {
    case missingID
    case missingTrajectory
    case missingActor
    case emptyInput
    case emptyOptions
    case duplicateOptions
    case invalidPolicySelection
}

/// Immutable input and ordered candidate set observed by one policy decision.
/// Teacher annotations and execution outcomes are stored separately and join
/// through decisionID plus candidateFingerprint.
public struct ActionDecisionBoundary: Codable, Equatable, Sendable {
    public let decisionID: String
    public let trajectoryID: String
    public let step: Int
    public let tick: Int64
    public let task: TeachingTask
    public let actorID: String
    public let providerID: String
    public let modelInput: String
    public let orderedOptions: [String]
    public let candidateFingerprint: String
    public let policySelected: String?
    public let policyRawOutput: String?
    public let requestID: String?

    public init(
        decisionID: String,
        trajectoryID: String,
        step: Int,
        tick: Int64,
        task: TeachingTask,
        actorID: String,
        providerID: String,
        modelInput: String,
        orderedOptions: [String],
        policySelected: String? = nil,
        policyRawOutput: String? = nil,
        requestID: String? = nil
    ) throws {
        guard !decisionID.isEmpty else { throw DecisionBoundaryError.missingID }
        guard !trajectoryID.isEmpty else { throw DecisionBoundaryError.missingTrajectory }
        guard !actorID.isEmpty else { throw DecisionBoundaryError.missingActor }
        guard !modelInput.isEmpty else { throw DecisionBoundaryError.emptyInput }
        guard !orderedOptions.isEmpty else { throw DecisionBoundaryError.emptyOptions }
        guard Set(orderedOptions).count == orderedOptions.count else {
            throw DecisionBoundaryError.duplicateOptions
        }
        if let policySelected, !orderedOptions.contains(policySelected) {
            throw DecisionBoundaryError.invalidPolicySelection
        }
        self.decisionID = decisionID
        self.trajectoryID = trajectoryID
        self.step = max(0, step)
        self.tick = tick
        self.task = task
        self.actorID = actorID
        self.providerID = providerID
        self.modelInput = modelInput
        self.orderedOptions = orderedOptions
        self.candidateFingerprint = Self.fingerprint(orderedOptions)
        self.policySelected = policySelected
        self.policyRawOutput = policyRawOutput
        self.requestID = requestID
    }

    public static func fingerprint(_ orderedOptions: [String]) -> String {
        let payload = orderedOptions.enumerated()
            .map { "\($0.offset):\($0.element.utf8.count):\($0.element)" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ActionExecutionOutcome: Codable, Equatable, Sendable {
    public let decisionID: String
    public let requestID: String?
    public let accepted: Bool
    public let status: String
    public let reason: String?
    public let startedAtTick: Int64?
    public let endedAtTick: Int64?
    public let finalWorldDigest: String

    public init(
        decisionID: String,
        requestID: String? = nil,
        accepted: Bool,
        status: String,
        reason: String? = nil,
        startedAtTick: Int64? = nil,
        endedAtTick: Int64? = nil,
        finalWorldDigest: String
    ) {
        self.decisionID = decisionID
        self.requestID = requestID
        self.accepted = accepted
        self.status = status
        self.reason = reason
        self.startedAtTick = startedAtTick
        self.endedAtTick = endedAtTick
        self.finalWorldDigest = finalWorldDigest
    }
}

public struct TeacherAudit: Codable, Equatable, Sendable {
    public let policyVerdict: String
    public let outcomeScore: Double
    public let reason: String

    public init(policyVerdict: String, outcomeScore: Double, reason: String) {
        self.policyVerdict = policyVerdict
        self.outcomeScore = min(1, max(0, outcomeScore))
        self.reason = reason
    }
}

public struct TeacherAnnotation: Codable, Equatable, Sendable {
    public let decisionID: String
    public let candidateFingerprint: String
    public let teacherID: String
    public let tier: TeacherTier
    public let preferred: String
    public let acceptable: [String]
    public let confidence: Double
    public let reason: String
    public let rawOutput: String?
    public let audit: TeacherAudit?

    public init(
        decisionID: String,
        candidateFingerprint: String,
        teacherID: String,
        tier: TeacherTier,
        preferred: String,
        acceptable: [String],
        confidence: Double,
        reason: String,
        rawOutput: String? = nil,
        audit: TeacherAudit? = nil
    ) {
        self.decisionID = decisionID
        self.candidateFingerprint = candidateFingerprint
        self.teacherID = teacherID
        self.tier = tier
        self.preferred = preferred
        self.acceptable = acceptable
        self.confidence = min(1, max(0, confidence))
        self.reason = reason
        self.rawOutput = rawOutput
        self.audit = audit
    }
}

public struct CleanedTeachingDecision: Codable, Equatable, Sendable {
    public let boundary: ActionDecisionBoundary
    public let outcome: ActionExecutionOutcome?
    public let localAnnotation: TeacherAnnotation?
    public let remoteAnnotation: TeacherAnnotation?
    public let grade: TrainingGrade
    public let finalPreferred: String?
    public let finalAcceptable: [String]
    public let teacherDisagreement: Bool
    public let failures: [String]
}

public enum TeachingQualityGate {
    public static func classify(
        boundary: ActionDecisionBoundary,
        mode: TeachingMode,
        outcome: ActionExecutionOutcome? = nil,
        local: TeacherAnnotation?,
        remote: TeacherAnnotation?
    ) -> CleanedTeachingDecision {
        var failures: [String] = []
        let prescribed = boundary.orderedOptions.count < 2
        if prescribed { failures.append("prescribed_only") }
        let needsLocal = mode == .localQwen || mode == .hybrid
        let needsRemote = mode == .apiTeacher || mode == .hybrid
        let localValid = needsLocal
            ? validate(local, prefix: "local", boundary: boundary, failures: &failures)
            : false
        let remoteValid = needsRemote
            ? validate(remote, prefix: "remote", boundary: boundary, failures: &failures)
            : false
        let selected: TeacherAnnotation?
        let grade: TrainingGrade
        if prescribed {
            selected = remoteValid ? remote : (localValid ? local : nil)
            grade = .diagnostic
        } else {
            switch mode {
            case .none:
                selected = nil
                grade = .raw
            case .localQwen:
                selected = localValid ? local : nil
                grade = localValid ? .silver : .rejected
            case .apiTeacher:
                selected = remoteValid ? remote : nil
                grade = remoteValid ? .gold : .rejected
            case .hybrid:
                if remoteValid {
                    selected = remote
                    grade = .gold
                } else if localValid {
                    selected = local
                    grade = .silver
                } else {
                    selected = nil
                    grade = .rejected
                }
            }
        }
        let disagreement = localValid && remoteValid &&
            (local?.preferred != remote?.preferred || Set(local?.acceptable ?? []) != Set(remote?.acceptable ?? []))
        return CleanedTeachingDecision(
            boundary: boundary,
            outcome: outcome,
            localAnnotation: local,
            remoteAnnotation: remote,
            grade: grade,
            finalPreferred: selected?.preferred,
            finalAcceptable: selected?.acceptable ?? [],
            teacherDisagreement: disagreement,
            failures: Array(Set(failures)).sorted())
    }

    private static func validate(
        _ annotation: TeacherAnnotation?,
        prefix: String,
        boundary: ActionDecisionBoundary,
        failures: inout [String]
    ) -> Bool {
        guard let annotation else {
            failures.append("\(prefix):missing")
            return false
        }
        var valid = true
        if annotation.decisionID != boundary.decisionID {
            failures.append("\(prefix):decision_id_mismatch"); valid = false
        }
        if annotation.candidateFingerprint != boundary.candidateFingerprint {
            failures.append("\(prefix):fingerprint_mismatch"); valid = false
        }
        if !boundary.orderedOptions.contains(annotation.preferred) {
            failures.append("\(prefix):preferred_not_candidate"); valid = false
        }
        if annotation.acceptable.isEmpty ||
            !annotation.acceptable.allSatisfy(boundary.orderedOptions.contains) {
            failures.append("\(prefix):acceptable_not_candidate"); valid = false
        }
        return valid
    }
}

public enum DecisionCandidateSchema {
    public static func options(from schema: String) throws -> [String] {
        guard let data = schema.data(using: .utf8),
              let tools = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DecisionBoundaryError.emptyOptions
        }
        var result: [String] = []
        for tool in tools {
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            let parameters = function["parameters"] as? [String: Any]
            let properties = parameters?["properties"] as? [String: Any] ?? [:]
            if properties.isEmpty {
                result.append("\(name)()")
                continue
            }
            guard properties.count == 1, let property = properties.sorted(by: { $0.key < $1.key }).first,
                  let specification = property.value as? [String: Any],
                  let values = specification["enum"] as? [String] else { continue }
            result.append(contentsOf: values.map { "\(name)(\($0))" })
        }
        guard !result.isEmpty else { throw DecisionBoundaryError.emptyOptions }
        return result
    }
}
