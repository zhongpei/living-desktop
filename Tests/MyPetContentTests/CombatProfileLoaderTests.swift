import Foundation
import MyPetCombat
@testable import MyPetContent
import XCTest

final class CombatProfileLoaderTests: XCTestCase {
    func testApprovedRepositoryCombatPacksPassDesktopReadinessGate() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MyPetContentTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // desktop
            .deletingLastPathComponent() // mypet

        for characterID in ["lin_daiyu", "pan_jinlian", "wu_song"] {
            let pack = repositoryRoot
                .appendingPathComponent("desktop-assets/Resources/petpack/\(characterID)")
            let result = CombatProfileLoader.inspect(from: pack, capabilities: ["combat"])
            XCTAssertEqual(result.readiness, .realCombatReady, characterID)
            XCTAssertTrue(result.diagnostics.isEmpty, "\(characterID): \(result.diagnostics)")
        }
    }

    func testMissingCombatFileKeepsLegacyPackPlayable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(CombatProfileLoader.load(from: root))
    }

    func testVersionedCombatProfileRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = CombatProfile(
            maxHP: 1200,
            moves: [CombatMoveDefinition(
                id: "jab", command: .button(.x),
                startupFrames: 3, activeFrames: 2, recoveryFrames: 6,
                hit: CombatHitDefinition(damage: 25),
                visualAction: "attack")])
        let file = PetPackCombatFile(profile: profile)
        try JSONEncoder().encode(file).write(to: root.appendingPathComponent("combat.json"))

        let loaded = try XCTUnwrap(CombatProfileLoader.load(from: root))
        XCTAssertEqual(loaded, profile)
        XCTAssertEqual(loaded.maxHP, 1200)
        XCTAssertEqual(loaded.moves.first?.visualAction, "attack")
    }

    func testV1ProfileIsReadableButNeverRealCombatReady() throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(PetPackCombatFile(
            version: 1, profile: CombatProfile())).write(
                to: root.appendingPathComponent("combat.json"))

        let result = CombatProfileLoader.inspect(from: root, capabilities: ["combat"])

        XCTAssertNotNil(result.profile)
        XCTAssertEqual(result.readiness, .presentationOnly)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "combat_v1_transitional" })
    }

    func testUnknownVersionHasExplicitDiagnosticAndNoProfile() throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"version\":99,\"profile\":{}}".utf8).write(
            to: root.appendingPathComponent("combat.json"))

        let result = CombatProfileLoader.inspect(from: root, capabilities: ["combat"])

        XCTAssertNil(result.profile)
        XCTAssertEqual(result.readiness, .unavailable)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "combat_version_unsupported" })
    }

    func testV2RejectsReadyClaimWhenAnimationOrBoxHashIsStale() throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = sixMoveProfile()
        for move in profile.moves { try writeAction(move.visualAction, at: root) }
        let evidence = CombatReadinessEvidence(
            moves: Dictionary(uniqueKeysWithValues: profile.moves.map {
                ($0.id, CombatAssetProof(
                    action: $0.visualAction,
                    animationHash: "sha256:stale",
                    boxHash: "sha256:stale"))
            }),
            states: [:], manualReady: true, aiReady: true)
        try JSONEncoder().encode(PetPackCombatFile(
            version: 2, status: "candidate", realCombatReady: true,
            profile: profile, evidence: evidence)).write(
                to: root.appendingPathComponent("combat.json"))

        let result = CombatProfileLoader.inspect(from: root, capabilities: ["combat"])

        XCTAssertEqual(result.readiness, .presentationOnly)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "combat_animation_hash_mismatch" })
        XCTAssertTrue(result.diagnostics.contains { $0.code == "combat_box_hash_mismatch" })
    }

    func testV2RequiresCombatCapabilityAndCompleteStateProofs() throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = sixMoveProfile()
        let moveEvidence = try Dictionary(uniqueKeysWithValues: profile.moves.map { move in
            try writeAction(move.visualAction, at: root)
            return (move.id, CombatAssetProof(
                action: move.visualAction,
                animationHash: try CombatAssetHasher.animationHash(
                    action: move.visualAction, in: root),
                boxHash: try CombatAssetHasher.boxHash(for: move)))
        })
        let evidence = CombatReadinessEvidence(
            moves: moveEvidence, states: [:], manualReady: true, aiReady: true)
        try JSONEncoder().encode(PetPackCombatFile(
            version: 2, status: "candidate", realCombatReady: true,
            profile: profile, evidence: evidence)).write(
                to: root.appendingPathComponent("combat.json"))

        let withoutCapability = CombatProfileLoader.inspect(from: root, capabilities: [])
        XCTAssertTrue(withoutCapability.diagnostics.contains {
            $0.code == "combat_capability_missing"
        })
        let incomplete = CombatProfileLoader.inspect(from: root, capabilities: ["combat"])
        XCTAssertTrue(incomplete.diagnostics.contains {
            $0.code == "combat_state_proof_missing"
        })
        XCTAssertEqual(incomplete.readiness, .presentationOnly)
    }

    func testV2RequiresAllSixLogicalButtons() throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = sixMoveProfile()
        profile.moves = profile.moves.map { move in
            CombatMoveDefinition(
                id: move.id, command: .button(.x),
                startupFrames: move.startupFrames, activeFrames: move.activeFrames,
                recoveryFrames: move.recoveryFrames, hit: move.hit,
                visualAction: move.visualAction)
        }
        try JSONEncoder().encode(PetPackCombatFile(
            version: 2, realCombatReady: true, profile: profile,
            evidence: CombatReadinessEvidence(
                moves: [:], states: [:], manualReady: true, aiReady: true))).write(
                    to: root.appendingPathComponent("combat.json"))

        let result = CombatProfileLoader.inspect(from: root, capabilities: ["combat"])

        XCTAssertTrue(result.diagnostics.contains {
            $0.code == "combat_button_coverage_incomplete"
        })
        XCTAssertEqual(result.readiness, .presentationOnly)
    }

    func testCompleteV2EvidenceEnablesRealCombat() throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = sixMoveProfile()
        let moveEvidence = try Dictionary(uniqueKeysWithValues: profile.moves.map { move in
            try writeAction(move.visualAction, at: root)
            return (move.id, CombatAssetProof(
                action: move.visualAction,
                animationHash: try CombatAssetHasher.animationHash(
                    action: move.visualAction, in: root),
                boxHash: try CombatAssetHasher.boxHash(for: move)))
        })
        let stateEvidence = try Dictionary(uniqueKeysWithValues:
            CombatProfileLoader.requiredStateActions.map { action in
                try writeAction(action, at: root)
                return (action, CombatAssetProof(
                    action: action,
                    animationHash: try CombatAssetHasher.animationHash(action: action, in: root)))
            })
        try JSONEncoder().encode(PetPackCombatFile(
            version: 2, status: "approved", realCombatReady: true,
            profile: profile,
            evidence: CombatReadinessEvidence(
                moves: moveEvidence, states: stateEvidence,
                manualReady: true, aiReady: true))).write(
                    to: root.appendingPathComponent("combat.json"))

        let result = CombatProfileLoader.inspect(from: root, capabilities: ["combat"])

        XCTAssertEqual(result.readiness, .realCombatReady)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    private func makePackRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeAction(_ action: String, at root: URL) throws {
        let directory = root.appendingPathComponent("actions/\(action)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(action.utf8).write(to: directory.appendingPathComponent("frame_00.webp"))
    }

    private func sixMoveProfile() -> CombatProfile {
        CombatProfile(moves: CombatButton.allCases.map { button in
            CombatMoveDefinition(
                id: "normal_\(button.rawValue)", command: .button(button),
                startupFrames: 3, activeFrames: 2, recoveryFrames: 6,
                hit: CombatHitDefinition(damage: 25),
                visualAction: "normal_\(button.rawValue)")
        })
    }
}
