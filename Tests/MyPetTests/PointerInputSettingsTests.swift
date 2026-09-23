import AppKit
import XCTest
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
        let senses = try XCTUnwrap(pages.tabViewItems.first { $0.label == "感知" })
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
