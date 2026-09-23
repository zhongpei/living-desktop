import Foundation
import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    func testCombatModuleDoesNotOwnGenericPhysicsImplementations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let combatDirectory = root.appendingPathComponent("Sources/MyPetCombat")
        let sources = try FileManager.default.contentsOfDirectory(
            at: combatDirectory,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        for forbidden in [
            "static let gravityPerFrame",
            "private func integrate(",
            "private func resolvePushboxes(",
            "enum CombatSurfaceKind",
            "struct CombatEnvironment",
        ] {
            XCTAssertFalse(sources.contains(forbidden), "MyPetCombat still owns: \(forbidden)")
        }
    }

    func testLegacyPetModelDoesNotIntegrateASecondBodyOrSynchronizePose() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/MyPet/Pet/PetModel.swift"),
            encoding: .utf8)
        let combat = try String(
            contentsOf: root.appendingPathComponent("Sources/MyPetCombat/CombatWorld.swift"),
            encoding: .utf8)

        for forbidden in [
            "private func updateGrounded(",
            "private func updateAirborne(",
            "private func updateTossed(",
            "PetMath.stepToss(",
        ] {
            XCTAssertFalse(model.contains(forbidden), "PetModel still integrates: \(forbidden)")
        }
        XCTAssertFalse(combat.contains("func synchronizePose("))
    }
}
