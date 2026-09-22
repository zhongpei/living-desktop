import AppKit
import XCTest
import MyPetContent
import MyPetCore
@testable import MyPetEngine
import MyPetSimulation

@testable import MyPetApp

final class PetPackLibraryTests: XCTestCase {

    private func makePackDir(in root: URL, id: String, withManifest: Bool = true, withFrames: Bool = true) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withManifest {
            let manifest: [String: Any] = [
                "id": id, "format": "petpack-v2", "generator": "test",
                "sprite": ["cell_width": 192, "cell_height": 208],
                "clips": withFrames
                    ? ["base/idle": ["frames": 1, "fps": 5.0, "playback": "loop"]]
                    : [:]
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        }
        if withFrames {
            let clips = dir.appendingPathComponent("base/idle", isDirectory: true)
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            try rep.representation(using: .png, properties: [:])!
                .write(to: clips.appendingPathComponent("frame_00.png"))
        }
    }

    // ---- 库枚举 ----

    func testAvailablePacksEnumeratesSortedAndSkipsIncomplete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makePackDir(in: root, id: "rei_chibi")
        try makePackDir(in: root, id: "mochi_cat")
        try makePackDir(in: root, id: "broken", withManifest: false) // 无 manifest → 不算宠物
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let packs = PetPackLibrary.availablePacks(in: root)
        XCTAssertEqual(packs.map { $0.id }, ["mochi_cat", "rei_chibi"]) // 字母序，跳过坏目录
    }

    // ---- -pet 启动参数 ----

    func testRequestedPetArg() {
        XCTAssertEqual(PetPackLibrary.requestedPet(from: ["MyPet", "-pet", "rei_chibi"]), "rei_chibi")
        XCTAssertNil(PetPackLibrary.requestedPet(from: ["MyPet"]))
        XCTAssertNil(PetPackLibrary.requestedPet(from: ["MyPet", "-pet"])) // 缺值
    }

    // ---- 菜单勾选与切换接线 ----

    func testMakePetItemsMarksCurrent() {
        let items = Tray.makePetItems(pets: ["mochi_cat", "rei_chibi"], current: "rei_chibi",
                                      action: nil, target: nil)
        XCTAssertEqual(items.map { $0.title }, ["mochi_cat", "rei_chibi"])
        XCTAssertEqual(items.map { $0.state }, [.off, .on])
        XCTAssertEqual(items[0].representedObject as? String, "mochi_cat")
    }

    func testTraySingleRoleMenuOnlyShowsCurrentRoleAndExit() throws {
        _ = NSApplication.shared
        let tray = Tray(settings: Settings())
        var exited = false
        tray.onSingleRoleExit = { exited = true }
        tray.updatePets(["mochi_cat", "rei_chibi"], current: "mochi_cat")

        let roleMenu = try XCTUnwrap(
            tray.attachedMenu?.items.first { $0.title == "角色" }?.submenu)
        XCTAssertTrue(roleMenu.items.contains { $0.title == "mochi_cat" })
        XCTAssertFalse(roleMenu.items.contains { $0.title.contains("rei_chibi") })
        let exit = try XCTUnwrap(roleMenu.items.first { $0.title == "退出桌面" })
        NSApp.sendAction(exit.action!, to: exit.target, from: exit)
        XCTAssertTrue(exited)
    }

    func testTrayCurrentRolesShowsActiveExitAndCandidateEntry() throws {
        _ = NSApplication.shared
        let tray = Tray(settings: Settings())
        let pack = CastPack(
            id: "journey_west",
            groupID: "journey_west",
            displayName: "西游记小队",
            summary: "",
            members: [
                CastMember(
                    id: "sun_wukong", kind: .character, displayName: "孙悟空",
                    visualPackID: "sun_wukong", role: "guardian"),
                CastMember(
                    id: "tang_sanzang", kind: .character, displayName: "唐三藏",
                    visualPackID: "tang_sanzang", role: "leader")
            ])
        var invited: [String] = []
        tray.onCastInvite = { invited.append($0) }
        tray.updateCastCatalog(
            [pack], selection: CastSelection(), activeMemberIDs: ["sun_wukong"])

        let roles = try XCTUnwrap(
            tray.attachedMenu?.items.first { $0.title == "角色" }?.submenu)
        let active = try XCTUnwrap(roles.items.first { $0.title == "✓ 孙悟空" }?.submenu)
        XCTAssertTrue(active.items.contains { $0.title == "让 孙悟空 退出" })
        XCTAssertTrue(roles.items.contains { $0.title == "全部候选角色入场" })
        let packMenu = try XCTUnwrap(roles.items.first { $0.title == "西游记小队" }?.submenu)
        let entry = try XCTUnwrap(packMenu.items.first { $0.representedObject as? String == "sun_wukong" })
        XCTAssertEqual(entry.title, "✓ 孙悟空（已在场）")
        XCTAssertFalse(entry.isEnabled)
        let invite = try XCTUnwrap(
            packMenu.items.first { $0.representedObject as? String == "tang_sanzang" })
        NSApp.sendAction(invite.action!, to: invite.target, from: invite)
        XCTAssertEqual(invited, ["tang_sanzang"])
        XCTAssertNil(tray.attachedMenu?.items.first { $0.title == "切换宠物" })
    }

    func testTrayHasStandaloneBrainLogMenu() {
        let tray = Tray(settings: Settings())
        let item = tray.attachedMenu?.items.first { $0.title == "查看日志…" }
        XCTAssertNotNil(item)
        XCTAssertNotNil(item?.action)
        XCTAssertTrue(item?.target === tray)
    }

    func testTrayLeavesRoleActionsToRightClickRing() {
        let tray = Tray(settings: Settings())
        let titles = tray.attachedMenu?.items.map(\.title) ?? []
        XCTAssertFalse(titles.contains("召唤"), "召唤只用于角色，不再冒充道具入口")
        XCTAssertTrue(titles.contains("道具"))
        XCTAssertFalse(titles.contains("动作测试"))
        XCTAssertFalse(titles.contains("打个招呼"))
        XCTAssertFalse(titles.contains("睡觉 / 醒来"))
    }

    // ---- 托盘图标查找 ----

    /// 造一个最小 .app bundle（Contents/Info.plist + Contents/Resources/tray-cat.png）。
    private func makeFakeAppBundle(in root: URL, withIcon: Bool) throws -> Bundle {
        let app = root.appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try "<plist/>".data(using: .utf8)!
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if withIcon {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            try rep.representation(using: .png, properties: [:])!
                .write(to: app.appendingPathComponent("Contents/Resources/tray-cat.png"))
        }
        return try XCTUnwrap(Bundle(url: app))
    }

    func testTrayIconURLFoundInBundleResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trayicon-\(UUID().uuidString)", isDirectory: true)
        let bundle = try makeFakeAppBundle(in: root, withIcon: true)
        let url = Tray.trayIconURL(bundle: bundle, executablePath: "/nonexistent/MyPet")
        XCTAssertEqual(url, bundle.resourceURL?.appendingPathComponent("tray-cat.png"))
    }

    func testTrayIconURLWalksUpFromExecutableForSwiftRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trayicon-\(UUID().uuidString)", isDirectory: true)
        let bundle = try makeFakeAppBundle(in: root, withIcon: false)
        // swift run 场景：仓库 desktop/Resources 在可执行文件上溯路径里。
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("desktop/Resources"), withIntermediateDirectories: true)
        try Data([0x89]).write(to: root.appendingPathComponent("desktop/Resources/tray-cat.png"))
        let exe = root.appendingPathComponent("desktop/.build/debug/MyPet").path
        XCTAssertEqual(Tray.trayIconURL(bundle: bundle, executablePath: exe),
                       root.appendingPathComponent("desktop/Resources/tray-cat.png"))
    }

    func testTrayIconURLNilWhenNowhere() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trayicon-\(UUID().uuidString)", isDirectory: true)
        let bundle = try makeFakeAppBundle(in: root, withIcon: false)
        XCTAssertNil(Tray.trayIconURL(bundle: bundle, executablePath: "/nonexistent/MyPet"))
    }
}
