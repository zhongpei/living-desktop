import AppKit
import MyPetContent
import MyPetCore
import MyPetEngine

/// 菜单栏：快捷动作 + 玩法开关 + 状态 + 设置入口；完整配置在设置窗。
final class Tray: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var onQuit: (() -> Void)?
    var onToggle: ((Toggle) -> Void)?
    var onInputPluginToggle: ((String) -> Void)?
    var onPointerInputToggle: (() -> Void)?
    var onPointerInputRateChange: ((Int) -> Void)?
    /// 角色组／角色选择变化；AppDelegate 负责持久化并把选择交给世界运行时。
    var onCastSelectionChange: ((CastSelection) -> Void)?
    /// 邀请一个候选角色出场；是否允许、是否已满由 CastRuntime 决定。
    var onCastInvite: ((String) -> Void)?
    /// Summon every enabled visual character, expanding the active limit.
    var onSummonAllCast: (() -> Void)?
    /// Remove one currently visible role through its normal departure path.
    var onCastDepart: ((String) -> Void)?
    /// Close the legacy single-role controller when no CastRuntime is active.
    var onSingleRoleExit: (() -> Void)?
    /// 打开设置窗。
    var onOpenSettings: (() -> Void)?
    /// 打开本地 Qwen Prompt 分析与管理。
    var onOpenPromptManager: (() -> Void)?
    var onOpenContentManager: (() -> Void)?
    /// 打开业务化脑路日志窗。
    var onOpenLogs: (() -> Void)?
    /// 召唤道具（placed = 召唤到面前落地；否则召唤到手上）。
    var onSummonProp: ((String, Bool) -> Void)?

    private(set) var petIDs: [String] = []
    private(set) var currentPetID = ""
    private(set) var castPacks: [CastPack] = []
    private var castSelection = CastSelection()
    private var activeCastMemberIDs = Set<String>()
    private let gameplayCatalog: GameplayCatalog?
    /// 大脑模式是否可用（模型在位）。不可用时菜单直接说明原因。
    var brainAvailable = true
    /// 「当前状态」子菜单内容（打开菜单时由控制器刷新）。
    var statusLines: () -> [String] = { [] }
    private(set) weak var attachedMenu: NSMenu?

    /// 纯函数，离线可测：大脑菜单项标题——模式对用户可见、可比较。
    static func brainTitle(enabled: Bool, available: Bool) -> String {
        guard available else { return "行动脑：Needle 3（未找到模型，当前随机动作）" }
        return enabled ? "行动脑：Needle 3 本地模型" : "行动脑：随机动作（省资源）"
    }

    /// 纯函数，离线可测：生成宠物切换菜单项（当前项打勾）。
    static func makePetItems(pets: [String], current: String,
                             action: Selector?, target: AnyObject?) -> [NSMenuItem] {
        pets.map { id in
            let item = NSMenuItem(title: id, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = id
            item.state = id == current ? .on : .off
            return item
        }
    }

    /// 纯函数，离线可测：状态子菜单（禁用态文本行）。
    static func makeStatusItems(_ lines: [String]) -> [NSMenuItem] {
        lines.map { line in
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
    }

    /// 纯函数，离线可测：召唤道具菜单项（representedObject = "id|placed"）。
    static func makeSummonItems(_ props: [(id: String, label: String)], placed: Bool,
                                action: Selector?, target: AnyObject?) -> [NSMenuItem] {
        props.map { prop in
            let item = NSMenuItem(title: prop.label, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = "\(prop.id)|\(placed)"
            return item
        }
    }

    static func summonableProps(catalog: GameplayCatalog?) -> [(id: String, label: String)] {
        let ids: [String]
        if let catalog {
            ids = catalog.plugins.first {
                $0.implementationID == GameplayImplementationID.props.rawValue &&
                    $0.surfaces.contains("tray")
            }?.propIDs ?? []
        } else {
            ids = PropCatalog.ids
        }
        return Set(ids).compactMap { PropCatalog.def($0) }
            .map { (id: $0.id, label: $0.label) }
            .sorted { $0.id < $1.id }
    }

    /// 更新单角色模式的当前角色；角色管理只提供查看和退出，不做隐式替换。
    func updatePets(_ ids: [String], current: String) {
        petIDs = ids
        currentPetID = current
        rebuild()
    }

    func updateCastCatalog(
        _ packs: [CastPack],
        selection: CastSelection,
        activeMemberIDs: [String] = []
    ) {
        let active = Set(activeMemberIDs)
        guard packs != castPacks || selection != castSelection || active != activeCastMemberIDs else {
            return
        }
        castPacks = packs
        castSelection = selection
        activeCastMemberIDs = active
        rebuild()
    }

    func updateSettings(_ settings: Settings) {
        self.settings = settings
        self.castSelection = settings.castSelection
        rebuild()
    }

    private var settings: Settings

    /// 托盘图标查找：.app 内置 Resources → 仓库 desktop/Resources（swift run）。
    /// 找不到返回 nil，调用方回退 emoji。
    static func trayIconURL(bundle: Bundle = .main,
                            executablePath: String = CommandLine.arguments.first ?? "") -> URL? {
        let fm = FileManager.default
        if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL.appendingPathComponent("tray-cat.png")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let exe = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/tray-cat.png")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// 装配托盘状态项：猫图优先（18pt 高，保持素材宽高比），缺图回退 emoji。
    private func installStatusButton() {
        guard let url = Self.trayIconURL(), let image = NSImage(contentsOf: url) else {
            statusItem.button?.title = "🐈"
            return
        }
        let aspect = image.size.width / max(image.size.height, 1)
        image.size = NSSize(width: 18 * aspect, height: 18)
        image.isTemplate = false // 彩色猫，深浅菜单栏都可见
        statusItem.button?.image = image
    }

    init(settings: Settings) {
        self.settings = settings
        self.castSelection = settings.castSelection
        self.gameplayCatalog = ContentResourceLocator.gameplayCatalog()
        super.init()
        installStatusButton()
        rebuild()
    }

    enum Toggle: String {
        case perching = "栖息在窗口上"
        case foregroundFollow = "跟随前台应用"
        case windowPull = "拉扯窗口（辅助功能）"
        case launchAtLogin = "登录时启动"
        case actionBrain = "行动脑（Needle 3）"
        case teacherBrain = "高阶教师脑（llama.cpp Qwen VL）"
        case localPersonaSpeech = "人物台词（本地 Qwen 0.8B）"
        case localDecisionBrain = "目标决策（本地 Qwen，实验）"
        case speech = "角色台词"
        case voicePlayback = "播放动作语音"
        case scenes = "场景玩法（目标-场景执行环）"
        case props = "道具"
        case senses = "AX 屏幕感知（辅助功能）"
        case ocr = "OCR 屏幕感知（屏幕录制）"
    }

    enum MenuID {
        static let perching = NSUserInterfaceItemIdentifier("perching")
        static let foreground = NSUserInterfaceItemIdentifier("foreground")
        static let pull = NSUserInterfaceItemIdentifier("pull")
        static let login = NSUserInterfaceItemIdentifier("login")
        static let actionBrain = NSUserInterfaceItemIdentifier("actionBrain")
        static let teacherBrain = NSUserInterfaceItemIdentifier("teacherBrain")
        static let localPersonaSpeech = NSUserInterfaceItemIdentifier("localPersonaSpeech")
        static let localDecisionBrain = NSUserInterfaceItemIdentifier("localDecisionBrain")
        static let speech = NSUserInterfaceItemIdentifier("speech")
        static let voicePlayback = NSUserInterfaceItemIdentifier("voicePlayback")
        static let scenes = NSUserInterfaceItemIdentifier("scenes")
        static let props = NSUserInterfaceItemIdentifier("props")
        static let senses = NSUserInterfaceItemIdentifier("senses")
        static let ocr = NSUserInterfaceItemIdentifier("ocr")
        static let gameplay = NSUserInterfaceItemIdentifier("gameplay")
        static let brain = NSUserInterfaceItemIdentifier("brain")
        static let perception = NSUserInterfaceItemIdentifier("perception")
        static let general = NSUserInterfaceItemIdentifier("general")
    }

    func rebuild() {
        let menu = NSMenu()
        menu.delegate = self

        let roles = NSMenuItem(title: "角色", action: nil, keyEquivalent: "")
        let roleMenu: NSMenu
        if !castPacks.isEmpty {
            roleMenu = buildCurrentRolesMenu()
        } else {
            let submenu = NSMenu(title: "角色")
            if !currentPetID.isEmpty {
                let current = NSMenuItem(title: currentPetID, action: nil, keyEquivalent: "")
                current.isEnabled = false
                submenu.addItem(current)
                let exit = NSMenuItem(title: "退出桌面", action: #selector(exitSingleRole), keyEquivalent: "")
                exit.target = self
                submenu.addItem(exit)
            } else {
                let empty = NSMenuItem(title: "尚无角色", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            }
            roleMenu = submenu
        }
        let importItem = NSMenuItem(title: "导入 / 管理内容包…",
                                    action: #selector(openContentManager), keyEquivalent: "")
        importItem.target = self
        roleMenu.insertItem(importItem, at: 0)
        roleMenu.insertItem(.separator(), at: 1)
        roles.submenu = roleMenu
        menu.addItem(roles)

        // 召唤道具：手上（宠物拿着，场景收尾自然放下）/ 面前（落地待着后淡出）。
        let propList = Self.summonableProps(catalog: gameplayCatalog)
        let propSubmenu = NSMenu(title: "道具")
        for (title, placed) in [("召唤到手上", false), ("召唤到面前", true)] {
            let sub = NSMenu(title: title)
            for item in Self.makeSummonItems(
                propList, placed: placed,
                action: #selector(summonProp(_:)), target: self
            ) {
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            propSubmenu.addItem(parent)
        }
        let propItem = NSMenuItem(title: "道具", action: nil, keyEquivalent: "")
        propItem.submenu = propSubmenu
        propItem.isEnabled = !propList.isEmpty
        menu.addItem(propItem)

        menu.addItem(.separator())

        // 按用户心智模型拆开入口：玩法、大脑、感知和通用设置互不混排。
        let gameplay = NSMenuItem(title: "玩法", action: nil, keyEquivalent: "")
        gameplay.identifier = MenuID.gameplay
        gameplay.submenu = buildGameplayMenu()
        menu.addItem(gameplay)

        let brain = NSMenuItem(title: "大脑", action: nil, keyEquivalent: "")
        brain.identifier = MenuID.brain
        brain.submenu = buildBrainMenu()
        menu.addItem(brain)

        let perception = NSMenuItem(title: "感知", action: nil, keyEquivalent: "")
        perception.identifier = MenuID.perception
        perception.submenu = buildPerceptionMenu()
        menu.addItem(perception)

        let general = NSMenuItem(title: "通用", action: nil, keyEquivalent: "")
        general.identifier = MenuID.general
        general.submenu = buildGeneralMenu()
        menu.addItem(general)

        menu.addItem(.separator())
        menu.addItem(withTitle: "查看日志…", action: #selector(openLogs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "退出 Living Desktop", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        attachedMenu = menu
    }

    private func buildCastMenu() -> NSMenu {
        let submenu = NSMenu(title: "角色组与剧情")
        let mode = NSMenuItem(
            title: castSelection.mode == .random ? "随机角色：开启" : "随机角色：关闭",
            action: #selector(toggleCastMode), keyEquivalent: "")
        mode.target = self
        mode.state = castSelection.mode == .random ? .on : .off
        submenu.addItem(mode)

        let count = NSMenuItem(
            title: "当前最多 \(castSelection.maxActiveMembers) 位角色",
            action: nil, keyEquivalent: "")
        count.isEnabled = false
        submenu.addItem(count)
        let rotation = NSMenuItem(
            title: castSelection.automaticRotationEnabled
                ? "自动轮换角色：开启"
                : "自动轮换角色：关闭",
            action: #selector(toggleCastRotation), keyEquivalent: "")
        rotation.target = self
        rotation.state = castSelection.automaticRotationEnabled ? .on : .off
        rotation.toolTip = "间隔：\(castSelection.rotationIntervalTicks) tick"
        submenu.addItem(rotation)
        submenu.addItem(.separator())

        let groups = Dictionary(grouping: castPacks, by: { $0.groupID })
        for groupID in groups.keys.sorted() {
            guard let packs = groups[groupID] else { continue }
            let visibleGroupName = packs.first?.displayName ?? groupID
            let groupMenu = NSMenu(title: visibleGroupName)
            let groupItem = NSMenuItem(
                title: "启用本组（\(packs.count) 个剧组）",
                action: #selector(toggleCastGroup(_:)), keyEquivalent: "")
            groupItem.target = self
            groupItem.representedObject = groupID
            groupItem.state = isGroupEnabled(groupID) ? .on : .off
            groupMenu.addItem(groupItem)
            groupMenu.addItem(.separator())

            for pack in packs.sorted(by: { $0.id < $1.id }) {
                let packMenu = NSMenu(title: pack.displayName)
                let packHeader = NSMenuItem(title: pack.displayName, action: nil, keyEquivalent: "")
                packHeader.isEnabled = false
                packMenu.addItem(packHeader)
                for member in pack.members.sorted(by: { $0.id < $1.id }) {
                    let item = NSMenuItem(
                        title: "\(isMemberEnabled(member.id) ? "✓" : "○") \(member.displayName)",
                        action: #selector(toggleCastMember(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = member.id
                    item.toolTip = "\(member.role) · \(member.arrivalStyle?.rawValue ?? "walk")"
                    packMenu.addItem(item)
                }
                let packItem = NSMenuItem(title: pack.displayName, action: nil, keyEquivalent: "")
                packItem.submenu = packMenu
                groupMenu.addItem(packItem)
            }

            let groupItemParent = NSMenuItem(title: visibleGroupName, action: nil, keyEquivalent: "")
            groupItemParent.submenu = groupMenu
            submenu.addItem(groupItemParent)
        }

        return submenu
    }

    private func buildCurrentRolesMenu() -> NSMenu {
        let menu = NSMenu(title: "角色")
        let activeMembers = castPacks.flatMap(\.members)
            .filter { activeCastMemberIDs.contains($0.id) }
            .sorted { $0.displayName < $1.displayName }
        if activeMembers.isEmpty {
            let empty = NSMenuItem(title: "当前没有角色在场", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for member in activeMembers {
                let memberMenu = NSMenu(title: member.displayName)
                let exit = NSMenuItem(
                    title: "让 \(member.displayName) 退出",
                    action: #selector(departCastMember(_:)), keyEquivalent: "")
                exit.target = self
                exit.representedObject = member.id
                memberMenu.addItem(exit)
                let parent = NSMenuItem(title: "✓ \(member.displayName)", action: nil, keyEquivalent: "")
                parent.submenu = memberMenu
                menu.addItem(parent)
            }
        }
        menu.addItem(.separator())
        let summonAll = NSMenuItem(
            title: "全部候选角色入场",
            action: #selector(summonAllCast), keyEquivalent: "")
        summonAll.target = self
        menu.addItem(summonAll)

        for pack in castPacks.sorted(by: { $0.displayName < $1.displayName }) {
            let packMenu = NSMenu(title: pack.displayName)
            for member in pack.members where member.kind == .character && member.visualPackID != nil {
                let active = activeCastMemberIDs.contains(member.id)
                let item = NSMenuItem(
                    title: active ? "✓ \(member.displayName)（已在场）" : "让 \(member.displayName) 入场",
                    action: #selector(inviteCastMember(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = member.id
                item.toolTip = member.role
                item.isEnabled = !active
                packMenu.addItem(item)
            }
            guard !packMenu.items.isEmpty else { continue }
            let parent = NSMenuItem(title: pack.displayName, action: nil, keyEquivalent: "")
            parent.submenu = packMenu
            menu.addItem(parent)
        }
        return menu
    }

    private func isGroupEnabled(_ groupID: String) -> Bool {
        castSelection.allGroupsEnabled || castSelection.enabledGroupIDs.contains(groupID)
    }

    private func isMemberEnabled(_ memberID: String) -> Bool {
        castSelection.allMembersEnabled || castSelection.enabledMemberIDs.contains(memberID)
    }

    /// 玩法子菜单（完整字段在设置窗“玩法”页）。
    private func buildGameplayMenu() -> NSMenu {
        let submenu = NSMenu(title: "玩法")
        submenu.addItem(checkmarkItem(Toggle.voicePlayback, id: MenuID.voicePlayback,
                                      on: settings.voicePlaybackEnabled))
        if let gameplayCatalog {
            for plugin in gameplayCatalog.plugins where plugin.surfaces.contains("tray") {
                guard let item = gameplayMenuItem(for: plugin) else { continue }
                submenu.addItem(item)
            }
        } else {
            submenu.addItem(checkmarkItem(Toggle.speech, id: MenuID.speech, on: settings.speechEnabled))
            submenu.addItem(checkmarkItem(Toggle.scenes, id: MenuID.scenes, on: settings.scenesEnabled))
            submenu.addItem(checkmarkItem(Toggle.props, id: MenuID.props, on: settings.propsEnabled))
            submenu.addItem(checkmarkItem(Toggle.perching, id: MenuID.perching, on: settings.perchingEnabled))
            submenu.addItem(checkmarkItem(Toggle.foregroundFollow, id: MenuID.foreground, on: settings.foregroundFollow))
            submenu.addItem(checkmarkItem(Toggle.windowPull, id: MenuID.pull, on: settings.windowPullEnabled))
        }
        return submenu
    }

    private func gameplayMenuItem(for plugin: GameplayPlugin) -> NSMenuItem? {
        guard let implementation = GameplayImplementationID(rawValue: plugin.implementationID) else {
            return nil
        }
        switch implementation {
        case .speech:
            return checkmarkItem(Toggle.speech, id: MenuID.speech, on: settings.speechEnabled,
                                 title: plugin.displayNames.defaultText)
        case .scenes:
            return checkmarkItem(Toggle.scenes, id: MenuID.scenes, on: settings.scenesEnabled,
                                 title: plugin.displayNames.defaultText)
        case .props:
            return checkmarkItem(Toggle.props, id: MenuID.props, on: settings.propsEnabled,
                                 title: plugin.displayNames.defaultText)
        case .perching:
            return checkmarkItem(Toggle.perching, id: MenuID.perching, on: settings.perchingEnabled,
                                 title: plugin.displayNames.defaultText)
        case .foregroundFollow:
            return checkmarkItem(Toggle.foregroundFollow, id: MenuID.foreground, on: settings.foregroundFollow,
                                 title: plugin.displayNames.defaultText)
        case .windowPull:
            return checkmarkItem(Toggle.windowPull, id: MenuID.pull, on: settings.windowPullEnabled,
                                 title: plugin.displayNames.defaultText)
        }
    }

    /// 三档大脑独立入口；高阶教师脑关闭不影响玩法兜底。
    private func buildBrainMenu() -> NSMenu {
        let submenu = NSMenu(title: "大脑")
        submenu.addItem(checkmarkItem(Toggle.actionBrain, id: MenuID.actionBrain,
                                      on: settings.actionBrainEnabled && brainAvailable))
        submenu.addItem(checkmarkItem(Toggle.localPersonaSpeech, id: MenuID.localPersonaSpeech,
                                      on: settings.localBrainSpeechEnabled))
        submenu.addItem(checkmarkItem(Toggle.localDecisionBrain, id: MenuID.localDecisionBrain,
                                      on: settings.localBrainEnabled))
        submenu.addItem(checkmarkItem(Toggle.teacherBrain, id: MenuID.teacherBrain,
                                      on: settings.teacherBrainEnabled))
        submenu.addItem(.separator())
        let prompts = NSMenuItem(title: "Prompt 分析与管理…",
                                 action: #selector(openPromptManager), keyEquivalent: "")
        prompts.target = self
        prompts.identifier = NSUserInterfaceItemIdentifier("brain.prompt-manager")
        submenu.addItem(prompts)
        return submenu
    }

    /// 外界输入的快速开关；TTL、字符预算和白名单仍只在设置窗完整编辑。
    private func buildPerceptionMenu() -> NSMenu {
        let submenu = NSMenu(title: "感知")
        let inputParent = NSMenuItem(title: "外部输入", action: nil, keyEquivalent: "")
        inputParent.submenu = buildInputPluginMenu()
        submenu.addItem(inputParent)
        return submenu
    }

    private func buildGeneralMenu() -> NSMenu {
        let submenu = NSMenu(title: "通用")
        submenu.addItem(checkmarkItem(Toggle.launchAtLogin, id: MenuID.login,
                                      on: settings.launchAtLogin))
        return submenu
    }

    private func buildInputPluginMenu() -> NSMenu {
        let menu = NSMenu(title: "外部输入")
        let pointer = NSMenuItem(title: "鼠标靠近反应", action: #selector(togglePointerInput), keyEquivalent: "")
        pointer.target = self
        pointer.identifier = NSUserInterfaceItemIdentifier("pointer-input.enabled")
        pointer.state = settings.pointerInputEnabled ? .on : .off
        menu.addItem(pointer)
        let rate = NSMenuItem(title: "鼠标采样频率", action: nil, keyEquivalent: "")
        let rates = NSMenu(title: "鼠标采样频率")
        for hz in [20, 40, 60] {
            let item = NSMenuItem(title: "\(hz) Hz", action: #selector(setPointerInputRate(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("pointer-input.hz.\(hz)")
            item.representedObject = hz
            item.state = settings.pointerInputHz == hz ? .on : .off
            rates.addItem(item)
        }
        rate.submenu = rates
        menu.addItem(rate)
        menu.addItem(.separator())
        for pluginID in settings.inputPlugins.plugins.keys.sorted() {
            guard let config = settings.inputPlugins.configuration(for: pluginID) else { continue }
            let item = NSMenuItem(
                title: config.displayName,
                action: #selector(toggleInputPlugin(_:)),
                keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("input-plugin.\(pluginID)")
            item.representedObject = pluginID
            item.state = config.enabled ? .on : .off
            item.toolTip = "\(config.channel.rawValue) · TTL \(config.ttlTicks) ticks"
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleCastMode() {
        var next = castSelection
        next.mode = next.mode == .manual ? .random : .manual
        castSelection = next
        onCastSelectionChange?(next)
    }

    @objc private func toggleCastRotation() {
        var next = castSelection
        next.automaticRotationEnabled.toggle()
        // A menu toggle cannot edit the numeric setting; keep it useful by
        // choosing a conservative one-minute default when first enabled.
        if next.automaticRotationEnabled, next.rotationIntervalTicks == 0 {
            next.rotationIntervalTicks = 1_200
        }
        castSelection = next
        onCastSelectionChange?(next)
    }

    @objc private func toggleCastGroup(_ sender: NSMenuItem) {
        guard let groupID = sender.representedObject as? String else { return }
        let all = Array(Set(castPacks.map(\.groupID))).sorted()
        castSelection = castSelection.togglingGroup(groupID, allGroupIDs: all)
        onCastSelectionChange?(castSelection)
    }

    @objc private func toggleCastMember(_ sender: NSMenuItem) {
        guard let memberID = sender.representedObject as? String else { return }
        let all = castPacks.flatMap { $0.members.map(\.id) }
        castSelection = castSelection.togglingMember(memberID, allMemberIDs: all)
        onCastSelectionChange?(castSelection)
    }

    @objc private func inviteCastMember(_ sender: NSMenuItem) {
        guard let memberID = sender.representedObject as? String else { return }
        onCastInvite?(memberID)
    }

    @objc private func summonAllCast() { onSummonAllCast?() }

    @objc private func departCastMember(_ sender: NSMenuItem) {
        guard let memberID = sender.representedObject as? String else { return }
        onCastDepart?(memberID)
    }

    @objc private func exitSingleRole() { onSingleRoleExit?() }

    @objc private func summonProp(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String else { return }
        let parts = payload.split(separator: "|")
        guard parts.count == 2, let placed = Bool(String(parts[1])) else { return }
        onSummonProp?(String(parts[0]), placed)
    }

    @objc private func openLogs() { onOpenLogs?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openPromptManager() { onOpenPromptManager?() }
    @objc private func openContentManager() { onOpenContentManager?() }

    private func checkmarkItem(
        _ toggle: Toggle,
        id: NSUserInterfaceItemIdentifier,
        on: Bool,
        title: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title ?? toggle.rawValue,
            action: #selector(toggleSetting(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.identifier = id
        item.state = on ? .on : .off
        return item
    }

    @objc private func quit() { onQuit?() }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        let toggle: Toggle
        switch sender.identifier {
        case MenuID.perching: toggle = .perching
        case MenuID.foreground: toggle = .foregroundFollow
        case MenuID.pull: toggle = .windowPull
        case MenuID.login: toggle = .launchAtLogin
        case MenuID.actionBrain: toggle = .actionBrain
        case MenuID.teacherBrain: toggle = .teacherBrain
        case MenuID.localPersonaSpeech: toggle = .localPersonaSpeech
        case MenuID.localDecisionBrain: toggle = .localDecisionBrain
        case MenuID.speech: toggle = .speech
        case MenuID.voicePlayback: toggle = .voicePlayback
        case MenuID.scenes: toggle = .scenes
        case MenuID.props: toggle = .props
        case MenuID.senses: toggle = .senses
        case MenuID.ocr: toggle = .ocr
        default: return
        }
        onToggle?(toggle)
    }

    @objc private func toggleInputPlugin(_ sender: NSMenuItem) {
        guard let pluginID = sender.representedObject as? String else { return }
        onInputPluginToggle?(pluginID)
    }

    @objc private func togglePointerInput() { onPointerInputToggle?() }

    @objc private func setPointerInputRate(_ sender: NSMenuItem) {
        guard let hz = sender.representedObject as? Int else { return }
        onPointerInputRateChange?(hz)
    }

    /// 辅助功能授权引导弹窗。
    func showAccessibilityPrompt() {
        let alert = NSAlert()
        alert.messageText = "开启「拉扯窗口」需要辅助功能权限"
        alert.informativeText = """
        宠物拉扯真实窗口用的是 macOS 辅助功能 API（Accessibility）。
        点击「打开系统设置」后，把 Living Desktop 加入「辅助功能」允许列表，\
        再回来重新勾选即可。不授权也不影响宠物的基础玩法。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openAccessibilitySettings()
        }
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// 屏幕录制授权引导弹窗（OCR 感知用；「新鲜生效」——勾选后新读取立即有效）。
    func openScreenRecordingPrompt() {
        let alert = NSAlert()
        alert.messageText = "开启「OCR 屏幕感知」需要屏幕录制权限"
        alert.informativeText = """
        OCR 感知只会截取 profile 表内应用（当前：微信）的窗口画面做文字识别，\
        识别结果会随完整脑路快照保存在本机，供查看日志还原当次输入。
        点击「打开系统设置」后把 Living Desktop 加入「屏幕录制」允许列表，\
        勾选后无需重启，下一次读取立即生效。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openScreenRecordingSettings()
        }
    }
}

extension Tray: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // 打开菜单时刷新玩法勾选态。
        func refresh(_ submenu: NSMenu?) {
            guard let submenu else { return }
            for item in submenu.items {
                switch item.identifier {
                case MenuID.perching: item.state = settings.perchingEnabled ? .on : .off
                case MenuID.foreground: item.state = settings.foregroundFollow ? .on : .off
                case MenuID.pull: item.state = settings.windowPullEnabled ? .on : .off
                case MenuID.login: item.state = settings.launchAtLogin ? .on : .off
                case MenuID.actionBrain:
                    item.title = Self.brainTitle(enabled: settings.actionBrainEnabled, available: brainAvailable)
                    item.state = settings.actionBrainEnabled && brainAvailable ? .on : .off
                case MenuID.teacherBrain: item.state = settings.teacherBrainEnabled ? .on : .off
                case MenuID.localPersonaSpeech: item.state = settings.localBrainSpeechEnabled ? .on : .off
                case MenuID.localDecisionBrain: item.state = settings.localBrainEnabled ? .on : .off
                case MenuID.speech: item.state = settings.speechEnabled ? .on : .off
                case MenuID.voicePlayback: item.state = settings.voicePlaybackEnabled ? .on : .off
                case MenuID.scenes: item.state = settings.scenesEnabled ? .on : .off
                case MenuID.props: item.state = settings.propsEnabled ? .on : .off
                case MenuID.senses: item.state = settings.sensesEnabled ? .on : .off
                case MenuID.ocr: item.state = settings.ocrEnabled ? .on : .off
                default:
                    if item.identifier?.rawValue == "pointer-input.enabled" {
                        item.state = settings.pointerInputEnabled ? .on : .off
                    } else if item.identifier?.rawValue.hasPrefix("pointer-input.hz.") == true,
                              let hz = item.representedObject as? Int {
                        item.state = settings.pointerInputHz == hz ? .on : .off
                    }
                    if let pluginID = item.representedObject as? String,
                       item.identifier?.rawValue.hasPrefix("input-plugin.") == true {
                        item.state = settings.inputPlugins.isEnabled(pluginID) ? .on : .off
                    }
                }
                refresh(item.submenu)
            }
        }
        refresh(menu)
        if menu == attachedMenu, let gameplay = menu.items.first(where: { $0.identifier == MenuID.gameplay }) {
            // 主菜单：在玩法子菜单前插一节实时状态（先移除旧的）。
            menu.items.filter { $0.identifier == .init("status") }.forEach(menu.removeItem)
            let statusParent = NSMenuItem(title: "当前状态", action: nil, keyEquivalent: "")
            statusParent.identifier = NSUserInterfaceItemIdentifier("status")
            let statusMenu = NSMenu(title: "当前状态")
            for item in Self.makeStatusItems(statusLines()) {
                statusMenu.addItem(item)
            }
            statusParent.submenu = statusMenu
            if let idx = menu.items.firstIndex(of: gameplay) {
                menu.insertItem(statusParent, at: idx)
            }
        }
    }
}
