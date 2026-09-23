import AppKit
import XCTest
import MyPetCore
@testable import MyPetApp

@MainActor
final class SettingsWindowTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func firstTab(in view: NSView) -> NSTabView? {
        (view as? NSTabView) ?? descendants(of: view).compactMap { $0 as? NSTabView }.first
    }

    func testSettingsPagesAndGlobalSaveStayStable() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(settings: Settings())
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let views = descendants(of: try XCTUnwrap(window.contentView))
        let tabs = try XCTUnwrap(views.compactMap { $0 as? NSTabView }.first)
        XCTAssertEqual(tabs.tabViewItems.map(\.label),
                       ["通用", "玩法", "角色", "大脑", "感知", "诊断"])
        XCTAssertEqual(window.title, "Living Desktop 设置")
        let general = try XCTUnwrap(tabs.tabViewItems.first { $0.label == "通用" }?.view)
        XCTAssertTrue(descendants(of: general).compactMap { $0 as? NSButton }
            .contains { $0.title == "打开内容包管理…" })
        let gameplay = try XCTUnwrap(tabs.tabViewItems.first { $0.label == "玩法" }?.view)
        let gameplayTabs = try XCTUnwrap(firstTab(in: gameplay))
        XCTAssertEqual(gameplayTabs.tabViewItems.map(\.label), ["基础玩法", "剧情与关系"])
        let story = try XCTUnwrap(gameplayTabs.tabViewItems.last?.view)
        let browse = try XCTUnwrap(descendants(of: story).compactMap { $0 as? NSButton }
            .first { $0.title == "查看剧情内容…" })
        var opened = false
        controller.onOpenStoryLibrary = { opened = true }
        browse.performClick(nil)
        XCTAssertTrue(opened)
        let basics = try XCTUnwrap(gameplayTabs.tabViewItems.first?.view)
        XCTAssertFalse(descendants(of: basics).contains { $0 is NSTabView || $0 is NSScrollView })
        let senses = try XCTUnwrap(tabs.tabViewItems.first { $0.label == "感知" }?.view)
        XCTAssertEqual(firstTab(in: senses)?.tabViewItems.map(\.label),
                       ["窗口与权限", "内容输入"])
        let role = try XCTUnwrap(tabs.tabViewItems.first { $0.label == "角色" }?.view)
        XCTAssertEqual(firstTab(in: role)?.tabViewItems.map(\.label),
                       ["入场策略", "候选角色", "语言行为"])

        let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.title == "保存" })
        let saveAndClose = try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.title == "保存并关闭" })
        let scenes = try XCTUnwrap(descendants(of: basics).compactMap { $0 as? NSButton }
            .first { $0.title == "场景玩法" })
        var applied: [Bool] = []
        controller.onApply = { applied.append($0.scenesEnabled) }
        scenes.state = .off
        save.performClick(nil)
        scenes.state = .on
        save.performClick(nil)
        XCTAssertEqual(applied, [false, true])
        XCTAssertEqual(save.title, "保存")
        XCTAssertEqual(saveAndClose.title, "保存并关闭")

        let brain = try XCTUnwrap(tabs.tabViewItems.first { $0.label == "大脑" }?.view)
        let brainTabs = try XCTUnwrap(firstTab(in: brain))
        XCTAssertEqual(brainTabs.tabViewItems.map(\.label), ["行动脑", "本地 Qwen", "高阶教师脑"])
        let local = try XCTUnwrap(brainTabs.tabViewItems.first { $0.label == "本地 Qwen" }?.view)
        let localButtons = descendants(of: local).compactMap { $0 as? NSButton }
        XCTAssertEqual(localButtons.first { $0.title == "生成角色台词（已验证）" }?.state, .on)
        XCTAssertEqual(localButtons.first { $0.title == "参与目标决策（实验）" }?.state, .off)
        let size = window.frame.size
        for item in brainTabs.tabViewItems {
            brainTabs.selectTabViewItem(item)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame.size, size)
        }
        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame.size, size)
        }
        scenes.state = .off
        saveAndClose.performClick(nil)
        XCTAssertEqual(applied, [false, true, false])
        XCTAssertFalse(window.isVisible)
    }

    func testCandidateGroupSelectsItsMembers() throws {
        _ = NSApplication.shared
        let members = ["a", "b", "c"].map {
            CastMember(id: $0, kind: .character, displayName: $0,
                       visualPackID: $0, role: "test")
        }
        let pack = CastPack(id: "sample", groupID: "sample", displayName: "测试组",
                            summary: "", members: members)
        var settings = Settings()
        settings.castSelection.allMembersEnabled = false
        settings.castSelection.enabledMemberIDs = []
        let controller = SettingsWindowController(settings: settings, castPacks: [pack])
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let pages = try XCTUnwrap(firstTab(in: root))
        let role = try XCTUnwrap(pages.tabViewItems.first { $0.label == "角色" })
        pages.selectTabViewItem(role)
        let roleTabs = try XCTUnwrap(firstTab(in: try XCTUnwrap(role.view)))
        let candidates = try XCTUnwrap(roleTabs.tabViewItems.first { $0.label == "候选角色" })
        roleTabs.selectTabViewItem(candidates)
        let views = descendants(of: root)
        let group = try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.title == "全选本组 · 测试组" })
        XCTAssertEqual(group.state, .off)
        group.performClick(nil)
        for id in ["a", "b", "c"] {
            XCTAssertEqual(views.compactMap { $0 as? NSButton }
                .first { $0.title == id }?.state, .on)
        }
        var applied: Settings?
        controller.onApply = { applied = $0 }
        try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.title == "保存" }).performClick(nil)
        XCTAssertEqual(applied?.castSelection.allMembersEnabled, true)
        let firstMember = try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.title == "a" })
        firstMember.performClick(nil)
        XCTAssertEqual(group.state, .off)
        group.performClick(nil)
        XCTAssertEqual(firstMember.state, .on)
    }

    func testCharacterLanguageBehaviorCanBeSavedPerCharacter() throws {
        _ = NSApplication.shared
        let member = CastMember(id: "lin_daiyu", kind: .character, displayName: "林黛玉",
                                visualPackID: "lin_daiyu", role: "test")
        let pack = CastPack(id: "dream", groupID: "dream", displayName: "红楼梦",
                            summary: "", members: [member])
        let controller = SettingsWindowController(settings: Settings(), castPacks: [pack])
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let pages = try XCTUnwrap(firstTab(in: root))
        let role = try XCTUnwrap(pages.tabViewItems.first { $0.label == "角色" })
        pages.selectTabViewItem(role)
        let roleTabs = try XCTUnwrap(firstTab(in: try XCTUnwrap(role.view)))
        let language = try XCTUnwrap(roleTabs.tabViewItems.first { $0.label == "语言行为" })
        roleTabs.selectTabViewItem(language)
        let views = descendants(of: root)
        let follow = try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.title == "说话几率跟随角色人格" })
        let ambient = try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.title == "允许自言自语" })
        let chance = try XCTUnwrap(views.compactMap { $0 as? NSSlider }
            .first { $0.minValue == 0 && $0.maxValue == 100 })
        let interval = try XCTUnwrap(views.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "留空 = 人格默认" })
        follow.state = .off
        follow.performClick(nil)
        follow.state = .off
        chance.doubleValue = 22
        chance.sendAction(chance.action, to: chance.target)
        interval.stringValue = "19"
        ambient.state = .off

        var applied: Settings?
        controller.onApply = { applied = $0 }
        let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存" })
        save.performClick(nil)
        let saved = try XCTUnwrap(applied?.characterSpeechSettings["lin_daiyu"])
        XCTAssertEqual(try XCTUnwrap(saved.chance), 0.22, accuracy: 0.001)
        XCTAssertEqual(saved.minimumInterval, 19)
        XCTAssertFalse(saved.ambientEnabled)
    }

    func testStoryLibraryShowsAuthoredEpisode() throws {
        _ = NSApplication.shared
        let member = CastMember(id: "hero", kind: .character, displayName: "主角",
                                visualPackID: "hero", role: "test")
        let group = CastPack(id: "sample", groupID: "sample", displayName: "测试组",
                             summary: "", members: [member])
        let episode = StoryEpisode(id: "meeting", title: "初次相遇", participants: ["hero"],
                                   beats: [StoryBeat(id: "greet", actorIDs: ["hero"], intent: "greet_other")])
        let viewer = StoryLibraryWindowController(
            stories: [StoryPack(id: "sample_story", groupID: "sample", episodes: [episode])],
            groups: [group])
        let window = try XCTUnwrap(viewer.window)
        defer { window.close() }
        let details = descendants(of: try XCTUnwrap(window.contentView)).compactMap { $0 as? NSTextView }
        let text = try XCTUnwrap(details.first?.string)
        XCTAssertTrue(text.contains("初次相遇"))
        XCTAssertTrue(text.contains("主角"))
        XCTAssertTrue(text.contains("greet_other"))
    }

    func testLongBrainFormCanScrollToItsLastLabel() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(settings: Settings())
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let tabs = try XCTUnwrap(firstTab(in: root))
        let brainItem = try XCTUnwrap(tabs.tabViewItems.first { $0.label == "大脑" })
        tabs.selectTabViewItem(brainItem)
        let brain = try XCTUnwrap(tabs.selectedTabViewItem?.view)
        let brainTabs = try XCTUnwrap(firstTab(in: brain))
        for item in brainTabs.tabViewItems {
            brainTabs.selectTabViewItem(item)
            let page = try XCTUnwrap(item.view)
            let scroll = try XCTUnwrap((page as? NSScrollView) ??
                descendants(of: page).compactMap { $0 as? NSScrollView }.first)
            if item.label == "行动脑" {
                let lastNote = try XCTUnwrap(descendants(of: scroll).compactMap { $0 as? NSTextField }
                    .first { $0.stringValue.hasPrefix("Needle 3 负责") })
                lastNote.stringValue = String(repeating: "底部说明文字需要完整显示。", count: 100)
            }
            root.layoutSubtreeIfNeeded()
            let document = try XCTUnwrap(scroll.documentView)
            let stack = try XCTUnwrap(document.subviews.first as? NSStackView)
            XCTAssertGreaterThanOrEqual(document.frame.height, stack.frame.height)
            XCTAssertGreaterThanOrEqual(document.frame.height, scroll.contentView.bounds.height)
            if item.label == "行动脑" {
                XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
            }
            let last = try XCTUnwrap(stack.arrangedSubviews.last)
            XCTAssertLessThanOrEqual(last.frame.maxY, document.bounds.height)
        }
    }

    func testPromptManagerSupportsManualCharacterScenarioSamplingAndAttemptReview() async throws {
        _ = NSApplication.shared
        var settings = Settings()
        settings.localSpeechPromptUsesCustom = true
        let character = CharacterDefinition(
            id: "asuka",
            displayNames: LocalizedLabel(zhHans: "明日香", en: "Asuka"),
            background: LocalizedLabel(zhHans: "测试", en: "Test"),
            personality: CharacterPersonality(), aptitudes: CharacterAptitudes(),
            performancePrompt: LocalizedLabel(zhHans: "测试", en: "Test"))
        let controller = PromptManagerWindowController(
            settings: settings, characters: [character], currentCharacterID: "asuka")
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        var views = descendants(of: root)
        let popups = views.compactMap { $0 as? NSPopUpButton }
        let preset = try XCTUnwrap(popups.first {
            $0.identifier?.rawValue == "prompt.preset"
        })
        let tabs = try XCTUnwrap(views.compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(at: 1)
        views = descendants(of: root)
        let scenes = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "prompt.scene"
        })
        let characters = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "prompt.character"
        })
        XCTAssertEqual(preset.itemTitles, ["内置验证版（只读）", "用户自定义"])
        XCTAssertEqual(scenes.itemTitles, ["打招呼", "活动评论", "调侃", "抗议", "闲聊"])
        XCTAssertEqual(characters.itemTitles, ["明日香"])

        tabs.selectTabViewItem(at: 0)
        views = descendants(of: root)
        let role = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first {
            $0.identifier?.rawValue == "prompt.role"
        })
        role.string = "自定义桌宠编剧"
        var saved: (Bool, LocalSpeechPromptOverrides)?
        controller.onSave = { saved = ($0, $1) }
        try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.title == "保存并应用"
        }).performClick(nil)
        XCTAssertEqual(saved?.0, true)
        XCTAssertEqual(saved?.1.role, "自定义桌宠编剧")

        tabs.selectTabViewItem(at: 1)
        views = descendants(of: root)
        let analysis = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first {
            $0.identifier?.rawValue == "prompt.analysis"
        })
        let context = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first {
            $0.identifier?.rawValue == "prompt.test-context"
        })
        let temperature = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "prompt.temperature"
        })
        let fewShot = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "prompt.few-shot"
        })
        context.string = "代码运行成功，用户继续工作。"
        temperature.stringValue = "0.20"
        fewShot.performClick(nil)
        try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.title == "分析 Prompt"
        }).performClick(nil)
        XCTAssertTrue(analysis.string.contains("[PREFIX MESSAGES]"))
        XCTAssertTrue(analysis.string.contains("scene=greet"))
        XCTAssertTrue(analysis.string.contains("character=asuka"))
        XCTAssertTrue(analysis.string.contains("temperature=0.20"))
        XCTAssertTrue(analysis.string.contains("few_shot=true"))
        XCTAssertTrue(analysis.string.contains("代码运行成功"))

        let called = expectation(description: "manual prompt test")
        controller.onTest = { testedCharacter, _, _, testedContext, includeFewShot, sampling in
            XCTAssertEqual(testedCharacter.id, "asuka")
            XCTAssertEqual(testedContext, "代码运行成功，用户继续工作。")
            XCTAssertTrue(includeFewShot)
            XCTAssertEqual(sampling.temperature, 0.2, accuracy: 0.001)
            called.fulfill()
            return LocalBrain.PromptTestResult(
                prefixMessages: [["role": "system", "content": "SYSTEM"]],
                system: "SYSTEM", user: "USER", output: "哼，总算成功了。",
                attemptOutputs: ["滚开！", "哼，总算成功了。"],
                rejectionReasons: [["blocked:滚开"], []], includeFewShot: includeFewShot,
                sampling: sampling,
                latency: 0.4, error: nil)
        }
        try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.title == "调用本地 Qwen"
        }).performClick(nil)
        await fulfillment(of: [called], timeout: 1)
        await Task.yield()
        XCTAssertTrue(analysis.string.contains("attempt=1 accepted=false"))
        XCTAssertTrue(analysis.string.contains("blocked:滚开"))
        XCTAssertTrue(analysis.string.contains("attempt=2 accepted=true"))
    }
}
