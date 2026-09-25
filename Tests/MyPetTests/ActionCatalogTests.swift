import XCTest
import MyPetCore
@testable import MyPetEngine
import MyPetSimulation

@testable import MyPetApp

final class ActionCatalogTests: XCTestCase {

    func testCapabilityFamiliesGateBeforeClipResolution() {
        XCTAssertEqual(ActionCatalog.requiredCapability(for: .attack), "combat")
        XCTAssertEqual(ActionCatalog.requiredCapability(for: .windowClimb), "window")
        XCTAssertEqual(ActionCatalog.requiredCapability(for: .propTake), "prop")
        XCTAssertEqual(ActionCatalog.requiredCapability(for: .socialTalk), "social")
        XCTAssertEqual(ActionCatalog.requiredCapability(for: .mechActivate), "mech")
        XCTAssertNil(ActionCatalog.requiredCapability(for: .idle))
    }

    func testCombatEntryIntentsAreRuntimeRequests() {
        XCTAssertTrue(ActionCatalog.startsCombat(.combatReady))
        XCTAssertTrue(ActionCatalog.startsCombat(.attack))
        XCTAssertTrue(ActionCatalog.startsCombat(.taunt))
        XCTAssertFalse(ActionCatalog.startsCombat(.defend))
        XCTAssertFalse(ActionCatalog.startsCombat(.victory))
        XCTAssertEqual(ActionCatalog.menuIntent(for: "战斗"), .combatReady)
    }

    func testSemanticMappingsKeepAStablePriorityOrder() {
        XCTAssertEqual(ActionCatalog.candidates(for: .greet),
                       ["greet", "greet_wave", "wave", "happy", "nod"])
        XCTAssertEqual(ActionCatalog.candidates(for: .tease),
                       ["tease", "taunt", "mock_turn", "flirt", "tail_wag", "nod", "happy", "wave"])
        XCTAssertEqual(ActionCatalog.candidates(for: .happy),
                       ["happy", "celebrate", "jump", "tail_wag", "wave", "nod"])
        XCTAssertEqual(ActionCatalog.candidates(for: .think),
                       ["think", "read", "sit_idle", "nod", "look"])
        XCTAssertEqual(ActionCatalog.candidates(for: .complain),
                       ["complain", "annoyed", "nod", "think", "wave"])
        XCTAssertEqual(ActionCatalog.candidates(for: .rest),
                       ["sleep_loop", "sleep", "doze", "yawn", "sit_idle"])
    }

    func testFoundationLifecycleWindowAndCombatSemanticsResolveExactFirst() {
        let exactPairs: [(ActionIntent, String)] = [
            (.idle, "idle"), (.walk, "walk"), (.standUp, "stand_up"),
            (.lookAround, "look_around"), (.point, "point"), (.beckon, "beckon"),
            (.surprised, "surprised"), (.annoyed, "annoyed"), (.talk, "talk"),
            (.listen, "listen"), (.nod, "nod"), (.shakeHead, "shake_head"),
            (.sleep, "sleep"), (.recover, "recover"), (.crouch, "crouch"),
            (.stretch, "stretch"), (.yawn, "yawn"),
            (.enterScene, "enter_scene"), (.exitScene, "exit_scene"),
            (.perchWindow, "perch_window"), (.taunt, "taunt"),
            (.combatReady, "combat_ready"), (.attack, "attack"),
            (.defend, "defend"), (.dodge, "dodge"), (.hitReact, "hit_react"),
            (.victory, "victory"), (.defeat, "defeat"), (.retreat, "retreat"),
        ]
        for (intent, clip) in exactPairs {
            XCTAssertEqual(ActionCatalog.resolve(intent, available: [clip, "idle"]), clip)
        }
    }

    func testTeaseResolvesToRoleSpecificFallbacks() {
        XCTAssertEqual(ActionCatalog.resolve(.tease, available: ["flirt", "happy"]), "flirt")
        XCTAssertEqual(ActionCatalog.resolve(.tease, available: ["tail_wag", "happy"]), "tail_wag")
        XCTAssertEqual(ActionCatalog.resolve(.tease, available: ["mock_turn", "happy"]), "mock_turn")
        XCTAssertEqual(ActionCatalog.resolve(.tease, available: ["nod", "happy"]), "nod")
        XCTAssertEqual(ActionCatalog.resolve(.tease, available: ["happy", "wave"]), "happy")
        XCTAssertNil(ActionCatalog.resolve(.tease, available: ["think"]))
    }

    func testEveryDeclaredActionFamilyHasAConcreteFallbackChain() {
        for intent in ActionIntent.allCases {
            XCTAssertFalse(ActionCatalog.candidates(for: intent).isEmpty,
                           "(intent.rawValue) must have a deterministic fallback chain")
        }
        XCTAssertEqual(ActionCatalog.resolve(.windowClimbDown,
                                             available: ["climb_down"]), "climb_down")
        XCTAssertEqual(ActionCatalog.resolve(.propThrow,
                                             available: ["throw"]), "throw")
        XCTAssertEqual(ActionCatalog.resolve(.socialHighFive,
                                             available: ["high_five"]), "high_five")
        XCTAssertEqual(ActionCatalog.resolve(.mechRespond,
                                             available: ["respond"]), "respond")
    }

    func testRightClickMenuKeepsCommonActionsFlatAndExtensionsInMore() {
        XCTAssertFalse(ActionCatalog.primaryMenuItems.isEmpty)
        XCTAssertTrue(ActionCatalog.primaryMenuItems.contains { $0.intent == .perchWindow })
        XCTAssertFalse(ActionCatalog.primaryMenuItems.contains { $0.intent == .windowClimb })
        XCTAssertTrue(ActionCatalog.primaryMenuItems.contains { $0.intent == .propThrow })
        XCTAssertTrue(ActionCatalog.primaryMenuItems.contains { $0.intent == .socialArgue })
        XCTAssertTrue(ActionCatalog.extendedMenuItems.contains { $0.intent == .mechActivate })

        let primary = Set(ActionCatalog.primaryMenuItems.map(\.intent))
        let extended = Set(ActionCatalog.extendedMenuItems.map(\.intent))
        XCTAssertTrue(primary.isDisjoint(with: extended))
        XCTAssertEqual(primary.count, ActionCatalog.primaryMenuItems.count)
        XCTAssertEqual(extended.count, ActionCatalog.extendedMenuItems.count)
        XCTAssertFalse(ActionCatalog.primaryMenuItems.contains { $0.label == "动作" })
        for item in ActionCatalog.primaryMenuItems + ActionCatalog.extendedMenuItems {
            XCTAssertFalse(item.labels.zhHans.isEmpty)
            XCTAssertFalse(item.englishLabel.isEmpty)
            XCTAssertNotEqual(item.labels.zhHans, item.englishLabel)
        }
    }

    func testRightClickRuntimeMenuShowsCommonAndExactCharacterActionsOnly() {
        let items = ActionCatalog.rightClickMenuItems(
            available: ["wave", "happy", "think", "sleep_loop", "attack", "idle"])
        let intents = Set(items.map(\.intent))

        XCTAssertTrue(intents.isSuperset(of: [.greet, .happy, .think, .rest]))
        XCTAssertTrue(intents.contains(.attack))
        XCTAssertFalse(intents.contains(.defend), "fallback-only actions must not flood the menu")
        XCTAssertFalse(intents.contains(.windowClimb))
    }

    func testChatInputRecognizesOnlyDeclaredMenuSemantics() {
        XCTAssertEqual(ActionCatalog.menuIntent(for: "请攀爬窗口"), .perchWindow)
        XCTAssertEqual(ActionCatalog.menuIntent(for: "睡觉吧"), .rest)
        XCTAssertEqual(ActionCatalog.menuIntent(for: "启动机甲"), .mechActivate)
        XCTAssertNil(ActionCatalog.menuIntent(for: "今天过得怎么样？"))
    }

}
