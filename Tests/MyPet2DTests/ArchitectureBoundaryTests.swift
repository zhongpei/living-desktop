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
}
