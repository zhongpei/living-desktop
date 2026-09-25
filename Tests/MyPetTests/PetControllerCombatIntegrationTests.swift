import AppKit
import XCTest
import MyPetContent
import MyPetCore
import MyPetEngine

@testable import MyPetApp

@MainActor
final class PetControllerCombatIntegrationTests: XCTestCase {
    func testMenuCombatRequestReachesSharedCombatWorld() throws {
        _ = NSApplication.shared

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MyPetTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // desktop
            .deletingLastPathComponent() // mypet
        let resources = repositoryRoot.appendingPathComponent("desktop-assets/Resources")
        let firstLibrary = try ClipLibrary.load(
            from: resources.appendingPathComponent("petpack/lin_daiyu"))
        let secondLibrary = try ClipLibrary.load(
            from: resources.appendingPathComponent("petpack/pan_jinlian"))

        var settings = Settings()
        settings.gameFeatures.enabled = true
        settings.gameFeatures.automaticCombatEnabled = true
        settings.gameFeatures.combatHUDEnabled = true

        let combatRuntime = CombatRuntime()
        let gameplayRuntime = GameRuntime(
            bodyExecutionMode: .external, combatRuntime: combatRuntime)
        let coordinator = DesktopCombatCoordinator(
            runtime: gameplayRuntime, combatRuntime: combatRuntime)
        coordinator.configure(settings.gameFeatures)

        let work = Screens.workBox(containing: .zero)
        let first = PetController(
            library: firstLibrary,
            settings: settings,
            spawnAt: CGPoint(x: work.left + work.width * 0.45, y: work.bottom),
            actorID: EntityID("lin_daiyu"),
            gameplayRuntime: gameplayRuntime,
            combatCoordinator: coordinator,
            capabilities: ["combat"])
        let second = PetController(
            library: secondLibrary,
            settings: settings,
            spawnAt: CGPoint(x: work.left + work.width * 0.45 + 80, y: work.bottom),
            actorID: EntityID("pan_jinlian"),
            gameplayRuntime: gameplayRuntime,
            combatCoordinator: coordinator,
            capabilities: ["combat"])
        defer {
            first.stop()
            second.stop()
            first.closePanel()
            second.closePanel()
        }

        let intent = try XCTUnwrap(ActionCatalog.menuIntent(for: "战斗"))
        XCTAssertEqual(intent, .combatReady)
        first.performMenuAction(intent)

        XCTAssertTrue(coordinator.hasActiveSession)
        XCTAssertEqual(
            coordinator.sessionParticipantIDs,
            [EntityID("lin_daiyu"), EntityID("pan_jinlian")])
        XCTAssertEqual(
            coordinator.engagementStatus(actorID: EntityID("lin_daiyu"))?.phase,
            .engaged)
    }
}
