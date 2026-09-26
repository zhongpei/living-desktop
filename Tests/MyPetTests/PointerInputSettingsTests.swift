import AppKit
import XCTest
import MyPetCore
@testable import MyPetApp

@MainActor
final class PointerInputSettingsTests: XCTestCase {
    func testDefaultsPersistenceAndRateValidation() throws {
        var settings = Settings()
        XCTAssertTrue(settings.pointerInputEnabled)
        XCTAssertEqual(settings.pointerInputHz, 20)
        XCTAssertEqual(settings.pointerSampleInterval, 0.05, accuracy: 0.0001)

        settings.pointerInputEnabled = false
        settings.pointerInputHz = 60
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.pointerInputEnabled)
        XCTAssertEqual(restored.pointerInputHz, 60)
        XCTAssertEqual(restored.pointerSampleInterval, 1.0 / 60.0, accuracy: 0.0001)

        let bad = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        var changed = bad
        changed["pointerInputHz"] = 999
        let normalized = try JSONDecoder().decode(Settings.self,
            from: JSONSerialization.data(withJSONObject: changed))
        XCTAssertEqual(normalized.pointerInputHz, 20)
    }

    func testTrayPlacesPointerInputUnderExternalInputMenu() throws {
        _ = NSApplication.shared
        let tray = Tray(settings: Settings())
        let perception = try XCTUnwrap(tray.attachedMenu?.items.first { $0.title == "感知" }?.submenu)
        let external = try XCTUnwrap(perception.items.first { $0.title == "外部输入" }?.submenu)
        XCTAssertTrue(external.items.contains { $0.title == "鼠标靠近反应" && $0.state == .on })
        let rates = try XCTUnwrap(external.items.first { $0.title == "鼠标采样频率" }?.submenu)
        XCTAssertEqual(rates.items.map(\.title), ["20 Hz", "40 Hz", "60 Hz"])
        XCTAssertEqual(rates.items.map(\.state), [.on, .off, .off])
        var toggled = false
        var selectedRate: Int?
        tray.onPointerInputToggle = { toggled = true }
        tray.onPointerInputRateChange = { selectedRate = $0 }
        let pointer = try XCTUnwrap(external.items.first { $0.title == "鼠标靠近反应" })
        NSApp.sendAction(try XCTUnwrap(pointer.action), to: pointer.target, from: pointer)
        let sixty = try XCTUnwrap(rates.items.first { $0.title == "60 Hz" })
        NSApp.sendAction(try XCTUnwrap(sixty.action), to: sixty.target, from: sixty)
        XCTAssertTrue(toggled)
        XCTAssertEqual(selectedRate, 60)

        var changed = Settings()
        changed.pointerInputEnabled = false
        changed.pointerInputHz = 60
        tray.updateSettings(changed)
        let updated = try XCTUnwrap(tray.attachedMenu?.items.first { $0.title == "感知" }?
            .submenu?.items.first { $0.title == "外部输入" }?.submenu)
        XCTAssertEqual(updated.items.first { $0.title == "鼠标靠近反应" }?.state, .off)
        XCTAssertEqual(updated.items.first { $0.title == "鼠标采样频率" }?
            .submenu?.items.map(\.state), [.off, .off, .on])
    }

    func testTrayExposesLeaveAllCombatShortcut() throws {
        _ = NSApplication.shared
        let tray = Tray(settings: Settings())
        let item = try XCTUnwrap(
            tray.attachedMenu?.items.first { $0.title == "全部人员脱离战斗" })
        var invoked = false
        tray.onLeaveAllCombat = { invoked = true }

        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)

        XCTAssertTrue(invoked)
    }

    func testTrayBrainMenuOpensPromptManager() throws {
        _ = NSApplication.shared
        let tray = Tray(settings: Settings())
        let brain = try XCTUnwrap(tray.attachedMenu?.items.first { $0.title == "大脑" }?.submenu)
        let item = try XCTUnwrap(brain.items.first { $0.title == "Prompt 分析与管理…" })
        var opened = false
        tray.onOpenPromptManager = { opened = true }
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        XCTAssertTrue(opened)
    }

    func testTrayUsesSingleGameFeatureSettingsMenu() throws {
        _ = NSApplication.shared
        let tray = Tray(settings: Settings())
        let items = try XCTUnwrap(tray.attachedMenu?.items)
        XCTAssertNil(items.first { $0.title == "玩法" })
        let game = try XCTUnwrap(items.first { $0.title == "游戏功能设置" }?.submenu)
        for title in ["游戏功能总开关", "场景玩法", "自动战斗", "战斗 HUD",
                      "中立 NPC 误伤参战", "自动时钟调频", "打开游戏功能设置…"] {
            XCTAssertNotNil(game.items.first { $0.title == title }, title)
        }
    }

    func testTrayExposesRuntimeLogLevelMenu() throws {
        _ = NSApplication.shared
        let tray = Tray(settings: Settings())
        let general = try XCTUnwrap(tray.attachedMenu?.items.first { $0.title == "通用" }?.submenu)
        let logParent = try XCTUnwrap(general.items.first { $0.title == "日志级别：调试（默认）" })
        let logMenu = try XCTUnwrap(logParent.submenu)
        XCTAssertEqual(logMenu.items.map(\.title), ["调试（默认）", "信息", "错误", "关闭"])
        XCTAssertEqual(logMenu.items.map(\.state), [.on, .off, .off, .off])

        var selected: RuntimeLogLevel?
        tray.onLogLevelChange = { selected = $0 }
        let info = try XCTUnwrap(logMenu.items.first { $0.title == "信息" })
        NSApp.sendAction(try XCTUnwrap(info.action), to: info.target, from: info)
        XCTAssertEqual(selected, .info)

        var changed = Settings()
        changed.logLevel = .error
        tray.updateSettings(changed)
        let updatedGeneral = try XCTUnwrap(
            tray.attachedMenu?.items.first { $0.title == "通用" }?.submenu)
        let updatedParent = try XCTUnwrap(
            updatedGeneral.items.first { $0.title == "日志级别：错误" })
        XCTAssertEqual(updatedParent.submenu?.items.map(\.state), [.off, .off, .on, .off])
    }

    func testSettingsWindowSavesPointerControls() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(settings: Settings())
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let root = try XCTUnwrap(window.contentView)
        let pages = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTabView }.first)
        let senses = try XCTUnwrap(pages.tabViewItems.first { $0.label == "感知与权限" })
        pages.selectTabViewItem(senses)
        let sensesView = try XCTUnwrap(senses.view)
        let sensesTabs = try XCTUnwrap((sensesView as? NSTabView)
            ?? descendants(sensesView).compactMap { $0 as? NSTabView }.first)
        sensesTabs.selectTabViewItem(at: 0)
        let controls = descendants(root)
        let toggle = try XCTUnwrap(controls.compactMap { $0 as? NSButton }
            .first { $0.title == "鼠标靠近反应" })
        let rates = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles == ["20 Hz", "40 Hz", "60 Hz"] })
        XCTAssertEqual(rates.selectedItem?.tag, 20)
        toggle.performClick(nil)
        rates.selectItem(withTag: 60)
        var applied: Settings?
        controller.onApply = { applied = $0 }
        try XCTUnwrap(controls.compactMap { $0 as? NSButton }
            .first { $0.title == "保存" }).performClick(nil)
        XCTAssertEqual(applied?.pointerInputEnabled, false)
        XCTAssertEqual(applied?.pointerInputHz, 60)
    }
}
