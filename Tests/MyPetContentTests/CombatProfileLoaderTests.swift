import Foundation
import MyPetCombat
@testable import MyPetContent
import XCTest

final class CombatProfileLoaderTests: XCTestCase {
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
}
