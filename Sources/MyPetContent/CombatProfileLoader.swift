import CryptoKit
import Foundation
import MyPetCombat

public struct CombatAssetProof: Codable, Equatable, Sendable {
    public var action: String
    public var animationHash: String
    public var boxHash: String?

    public init(action: String, animationHash: String, boxHash: String? = nil) {
        self.action = action
        self.animationHash = animationHash
        self.boxHash = boxHash
    }
}

public struct CombatReadinessEvidence: Codable, Equatable, Sendable {
    public var moves: [String: CombatAssetProof]
    public var states: [String: CombatAssetProof]
    public var manualReady: Bool
    public var aiReady: Bool

    public init(
        moves: [String: CombatAssetProof], states: [String: CombatAssetProof],
        manualReady: Bool, aiReady: Bool
    ) {
        self.moves = moves
        self.states = states
        self.manualReady = manualReady
        self.aiReady = aiReady
    }
}

public struct PetPackCombatFile: Codable, Equatable, Sendable {
    public var version: Int
    public var status: String?
    public var realCombatReady: Bool?
    public var profile: CombatProfile
    public var evidence: CombatReadinessEvidence?

    public init(
        version: Int = 1, status: String? = nil,
        realCombatReady: Bool? = nil, profile: CombatProfile,
        evidence: CombatReadinessEvidence? = nil
    ) {
        self.version = version
        self.status = status
        self.realCombatReady = realCombatReady
        self.profile = profile
        self.evidence = evidence
    }
}

public enum CombatProfileReadiness: String, Codable, Equatable, Sendable {
    case unavailable
    case presentationOnly
    case realCombatReady
}

public struct CombatProfileDiagnostic: Codable, Equatable, Sendable {
    public var code: String
    public var detail: String

    public init(_ code: String, _ detail: String) {
        self.code = code
        self.detail = detail
    }
}

public struct CombatProfileLoadResult: Equatable, Sendable {
    public var profile: CombatProfile?
    public var schemaVersion: Int?
    public var readiness: CombatProfileReadiness
    public var diagnostics: [CombatProfileDiagnostic]
}

public enum CombatAssetHasher {
    public static func animationHash(action: String, in packURL: URL) throws -> String {
        let directory = packURL.appendingPathComponent("actions/\(action)", isDirectory: true)
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted()
        guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        var hasher = SHA256()
        var fileCount = 0
        for path in files {
            let url = directory.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            fileCount += 1
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: url))
            hasher.update(data: Data([0]))
        }
        guard fileCount > 0 else { throw CocoaError(.fileNoSuchFile) }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func boxHash(for move: CombatMoveDefinition) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(move.hit))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum CombatProfileLoader {
    public static let requiredStateActions = [
        "combat_ready", "guard_high", "guard_low", "dodge", "crouch",
        "jump", "hit_react_light", "hit_react_heavy", "knockdown",
        "downed", "get_up", "victory", "defeat",
    ]

    public static func load(from packURL: URL?) -> CombatProfile? {
        inspect(from: packURL, capabilities: ["combat"]).profile
    }

    public static func inspect(
        from packURL: URL?, capabilities: Set<String>
    ) -> CombatProfileLoadResult {
        guard let packURL else { return result(nil, nil, .unavailable, "combat_pack_missing") }
        let url = packURL.appendingPathComponent("combat.json")
        guard let data = try? Data(contentsOf: url) else {
            return result(nil, nil, .unavailable, "combat_profile_missing")
        }
        struct Header: Decodable { let version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return result(nil, nil, .unavailable, "combat_profile_invalid")
        }
        guard header.version == 1 || header.version == 2 else {
            return result(nil, header.version, .unavailable, "combat_version_unsupported")
        }
        guard let file = try? JSONDecoder().decode(PetPackCombatFile.self, from: data) else {
            return result(nil, header.version, .unavailable, "combat_profile_invalid")
        }
        guard header.version == 2 else {
            return result(file.profile, 1, .presentationOnly, "combat_v1_transitional")
        }
        return validateV2(file, packURL: packURL, capabilities: capabilities)
    }

    private static func validateV2(
        _ file: PetPackCombatFile, packURL: URL, capabilities: Set<String>
    ) -> CombatProfileLoadResult {
        var diagnostics: [CombatProfileDiagnostic] = []
        func add(_ code: String, _ detail: String = "") {
            diagnostics.append(CombatProfileDiagnostic(code, detail))
        }
        guard file.realCombatReady == true else {
            add("combat_ready_not_declared")
            return CombatProfileLoadResult(
                profile: file.profile, schemaVersion: 2,
                readiness: .presentationOnly, diagnostics: diagnostics)
        }
        if !capabilities.contains("combat") { add("combat_capability_missing") }
        if file.profile.moves.count < 6 { add("combat_move_coverage_incomplete") }
        let authoredButtons = Set(file.profile.moves.flatMap { move in
            move.command.steps.flatMap(\.requiredButtons)
        })
        if authoredButtons != Set(CombatButton.allCases) {
            add("combat_button_coverage_incomplete")
        }
        if Set(file.profile.moves.map(\.id)).count != file.profile.moves.count {
            add("combat_move_id_duplicate")
        }
        if file.profile.hurtBoxes.isEmpty { add("combat_hurt_box_missing") }
        guard let evidence = file.evidence else {
            add("combat_evidence_missing")
            return CombatProfileLoadResult(
                profile: file.profile, schemaVersion: 2,
                readiness: .presentationOnly, diagnostics: diagnostics)
        }
        if !evidence.manualReady { add("combat_manual_evidence_missing") }
        if !evidence.aiReady { add("combat_ai_evidence_missing") }

        for move in file.profile.moves {
            if move.hit.damage > 0 && move.hit.attackBoxes.isEmpty {
                add("combat_hit_box_missing", move.id)
            }
            guard let proof = evidence.moves[move.id] else {
                add("combat_move_proof_missing", move.id)
                continue
            }
            if proof.action != move.visualAction {
                add("combat_animation_binding_mismatch", move.id)
            }
            validateAnimation(proof, packURL: packURL, subject: move.id, add: add)
            let actualBoxHash = try? CombatAssetHasher.boxHash(for: move)
            if proof.boxHash == nil || proof.boxHash != actualBoxHash {
                add("combat_box_hash_mismatch", move.id)
            }
        }
        for state in requiredStateActions {
            guard let proof = evidence.states[state] else {
                add("combat_state_proof_missing", state)
                continue
            }
            if proof.action != state { add("combat_state_binding_mismatch", state) }
            validateAnimation(proof, packURL: packURL, subject: state, add: add)
        }
        return CombatProfileLoadResult(
            profile: file.profile, schemaVersion: 2,
            readiness: diagnostics.isEmpty ? .realCombatReady : .presentationOnly,
            diagnostics: diagnostics)
    }

    private static func validateAnimation(
        _ proof: CombatAssetProof, packURL: URL, subject: String,
        add: (String, String) -> Void
    ) {
        guard let actual = try? CombatAssetHasher.animationHash(
            action: proof.action, in: packURL) else {
            add("combat_animation_missing", subject)
            return
        }
        if proof.animationHash != actual { add("combat_animation_hash_mismatch", subject) }
    }

    private static func result(
        _ profile: CombatProfile?, _ version: Int?, _ readiness: CombatProfileReadiness,
        _ code: String
    ) -> CombatProfileLoadResult {
        CombatProfileLoadResult(
            profile: profile, schemaVersion: version, readiness: readiness,
            diagnostics: [CombatProfileDiagnostic(code, "")])
    }
}
