import AppKit
import MyPetContent
import MyPetPlatform
import MyPetCore
import MyPetEngine

/// 设置窗：完整配置的唯一入口（菜单只留快捷开关）。
///
/// 六页：通用 / 玩法 / 角色 / 大脑 / 感知 / 诊断；玩法、大脑、感知再分二级 Tab。
/// 「大脑」页承载模型配置：端点 / 模型（可探测）/ 密钥 / 连通性测试，
/// 探测与测试直接打当前表单里的端点（不必先保存）。
/// 授权状态页内实时刷新；「保存」不关闭窗口，「保存并关闭」应用后关闭。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    /// 应用草稿（保存时回调给 AppDelegate 落盘 + 热更新）。
    var onApply: ((Settings) -> Void)?
    /// 拖动滑杆时的实时预览：不落盘，直接喂给控制器热更新（宠物/道具当场变大变小）。
    var onPreview: ((Settings) -> Void)?
    var onOpenContentManager: (() -> Void)?
    var onOpenStoryLibrary: (() -> Void)?
    /// 本地决策脑真实聊天测试；由 AppDelegate 复用当前 PetController 的 actor。
    var localChatTester: (() async -> LocalBrain.ChatTestResult)?

    private var draft: Settings
    /// 最近一次保存的设置；关闭时仅撤销尚未保存的滑杆预览。
    private var lastSaved: Settings
    private let gameplayCatalog: GameplayCatalog?
    private var hasUnsavedPreview = false

    // ---- 字段引用 ----
    private var launchAtLoginBox: NSButton!
    private var heightSlider: NSSlider!
    private var heightLabel: NSTextField!
    private var propScaleSlider: NSSlider!
    private var propScaleLabel: NSTextField!

    private var scenesBox: NSButton!
    private var propsBox: NSButton!
    private var perchingBox: NSButton!
    private var foregroundBox: NSButton!
    private var windowPullBox: NSButton!
    private var pullStatusLabel: NSTextField!

    private var teacherBrainBox: NSButton!
    private var baseURLField: NSTextField!
    private var modelCombo: NSComboBox!
    private var apiKeyField: NSSecureTextField!
    private var probeButton: NSButton!
    private var testButton: NSButton!
    private var brainStatusLabel: NSTextField!
    private var teacherTemperatureField: NSTextField!
    private var teacherTopPField: NSTextField!
    private var teacherTopKField: NSTextField!
    private var teacherMaxTokensField: NSTextField!
    private var teacherSeedField: NSTextField!
    private var teacherReasoningField: NSTextField!
    private var logBox: NSButton!
    private var speechBox: NSButton!
    private var voicePlaybackBox: NSButton!
    private var actionBrainBox: NSButton!
    private var actionBrainStatusLabel: NSTextField!
    private var localDecisionBrainBox: NSButton!
    private var localBrainStatusLabel: NSTextField!
    private var localDownloadButton: NSButton!
    private var localTestButton: NSButton!
    private var localGoalTemperatureField: NSTextField!
    private var localGoalTopPField: NSTextField!
    private var localGoalTopKField: NSTextField!
    private var localGoalMaxTokensField: NSTextField!
    private var localGoalSeedField: NSTextField!
    private var localChatTemperatureField: NSTextField!
    private var localChatTopPField: NSTextField!
    private var localChatTopKField: NSTextField!
    private var localChatMaxTokensField: NSTextField!
    private var localChatSeedField: NSTextField!
    private var goalMinIntervalField: NSTextField!
    private var goalMaxIntervalField: NSTextField!
    private var actionMinIntervalField: NSTextField!
    private var actionMaxIntervalField: NSTextField!
    private var actionMaxTokensField: NSTextField!

    private var sensesBox: NSButton!
    private var axStatusLabel: NSTextField!
    private var ocrBox: NSButton!
    private var ocrStatusLabel: NSTextField!
    private struct InputPluginControls {
        let id: String
        let enabled: NSButton
        let preemptive: NSButton
        let ttl: NSTextField
        let maxCharacters: NSTextField
        let applications: NSTextField
    }
    private var inputPluginControls: [InputPluginControls] = []

    private var diagLabel: NSTextField!

    private let castPacks: [CastPack]
    private var castModePopup: NSPopUpButton!
    private var castMemberBoxes: [(id: String, box: NSButton)] = []
    private var castGroupBoxes: [(group: NSButton, members: [NSButton])] = []
    private var castRandomCountField: NSTextField!
    private var castMaxActiveField: NSTextField!
    private var castInvitationsBox: NSButton!
    private var castRotationBox: NSButton!
    private var castRotationIntervalField: NSTextField!
    private var storyEnabledBox: NSButton!
    private var storyRepeatBox: NSButton!
    private var storyIntervalField: NSTextField!
    private var storyMaxDurationField: NSTextField!
    private var storyForegroundInterruptBox: NSButton!
    private var storyContentInterruptBox: NSButton!
    private var storyRelationsBox: NSButton!

    init(settings: Settings, castPacks: [CastPack] = []) {
        self.draft = settings
        self.lastSaved = settings
        self.castPacks = castPacks
        self.gameplayCatalog = ContentResourceLocator.gameplayCatalog()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Living Desktop 设置"
        window.contentMinSize = NSSize(width: 700, height: 640)
        window.contentMaxSize = NSSize(width: 700, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        refreshPermissionLabels()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        refreshPermissionLabels()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 布局

    private func buildContent() -> NSView {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("通用", buildGeneralTab()))
        tabs.addTabViewItem(tab("玩法", buildGameplayTab()))
        tabs.addTabViewItem(tab("角色", buildCastTab()))
        tabs.addTabViewItem(tab("大脑", buildBrainTab()))
        tabs.addTabViewItem(tab("感知", buildSensesTab()))
        tabs.addTabViewItem(tab("诊断", buildDiagnosticsTab()))

        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        let saveAndClose = NSButton(title: "保存并关闭", target: self,
                                    action: #selector(saveAndCloseSettings))
        saveAndClose.bezelStyle = .rounded
        saveAndClose.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(closeWithoutSaving))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [cancel, save, saveAndClose])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.setCustomSpacing(70, after: cancel)

        let root = NSStackView(views: [tabs, buttonRow])
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabs.widthAnchor.constraint(equalToConstant: 668),
            tabs.heightAnchor.constraint(equalToConstant: 550),
        ])
        return container
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    @objc private func openContentManager() { onOpenContentManager?() }
    @objc private func openStoryLibrary() { onOpenStoryLibrary?() }

    private func formStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    private func checkbox(_ title: String, _ on: Bool, _ action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.state = on ? .on : .off
        return box
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 500
        return label
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return box
    }

    private func row(_ title: String, _ field: NSView, width: CGFloat = 330,
                     labelWidth: CGFloat = 72) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        field.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func numberField(_ value: String, placeholder: String = "") -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return field
    }

    /// 长表单共用同一可滚动容器；短表单仍从顶部开始。
    private func scrollFormStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.required, for: .vertical)

        let document = TopAlignedSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        // The document must grow with long forms; the clip view is only a minimum
        // for short forms. Otherwise the last label is clipped with no scroll range.
        document.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor).isActive = true
        document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true
        let preferredContentHeight = document.heightAnchor.constraint(equalTo: stack.heightAnchor)
        preferredContentHeight.priority = .defaultLow
        preferredContentHeight.isActive = true
        return scroll
    }

    // MARK: 通用

    private func buildGeneralTab() -> NSView {
        launchAtLoginBox = checkbox("登录时启动", draft.launchAtLogin, #selector(toggleDraft(_:)))
        heightSlider = NSSlider(value: Double(draft.displayHeight), minValue: 70, maxValue: 180,
                                target: self, action: #selector(heightChanged(_:)))
        heightSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        heightLabel = NSTextField(labelWithString: "\(Int(draft.displayHeight)) pt")
        let heightRow = NSStackView(views: [NSTextField(labelWithString: "宠物大小"), heightSlider, heightLabel])
        heightRow.orientation = .horizontal
        heightRow.spacing = 10

        propScaleSlider = NSSlider(value: draft.propScale * 100, minValue: 60, maxValue: 200,
                                   target: self, action: #selector(propScaleChanged(_:)))
        propScaleSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        propScaleLabel = NSTextField(labelWithString: "\(Int(draft.propScale * 100))%")
        let propRow = NSStackView(views: [NSTextField(labelWithString: "道具大小"), propScaleSlider, propScaleLabel])
        propRow.orientation = .horizontal
        propRow.spacing = 10

        let openData = NSButton(title: "打开数据目录", target: self, action: #selector(openDataFolder))
        openData.bezelStyle = .rounded
        let openPackages = NSButton(title: "打开内容包管理…", target: self,
                                    action: #selector(openContentManager))
        openPackages.bezelStyle = .rounded

        return formStack([launchAtLoginBox, heightRow, propRow, openData,
                          separator(), openPackages,
                          note("在这里导入、启停和移除角色、角色组与剧情包。"),
                          note("宠物/道具大小可即时预览；点击「保存」后生效，未保存的预览会在关闭时还原。")])
    }

    // MARK: 玩法

    private func buildGameplayTab() -> NSView {
        let tabs = NSTabView()
        tabs.addTabViewItem(tab("基础玩法", buildBaseGameplayTab()))
        tabs.addTabViewItem(tab("剧情与关系", buildStoryTab()))
        return tabs
    }

    private func buildBaseGameplayTab() -> NSView {
        scenesBox = checkbox(gameplayLabel("scenes", fallback: "场景玩法"), draft.scenesEnabled, #selector(toggleDraft(_:)))
        propsBox = checkbox(gameplayLabel("props", fallback: "道具"), draft.propsEnabled, #selector(toggleDraft(_:)))
        perchingBox = checkbox(gameplayLabel("perching", fallback: "栖息在窗口上"), draft.perchingEnabled, #selector(toggleDraft(_:)))
        foregroundBox = checkbox(gameplayLabel("foreground-follow", fallback: "跟随前台应用"), draft.foregroundFollow, #selector(toggleDraft(_:)))
        windowPullBox = checkbox(gameplayLabel("window-pull", fallback: "拉扯窗口"), draft.windowPullEnabled, #selector(toggleDraft(_:)))
        pullStatusLabel = note("")
        let basics = NSTextField(labelWithString: "基础玩法")
        basics.font = .boldSystemFont(ofSize: 13)
        let windows = NSTextField(labelWithString: "窗口互动")
        windows.font = .boldSystemFont(ofSize: 13)
        return formStack([
            basics,
            scenesBox,
            propsBox,
            perchingBox,
            note("关闭场景玩法后，角色仍会随机闲逛；角色、剧情和外界输入分别在对应页面设置。"),
            separator(),
            windows,
            foregroundBox,
            windowPullBox,
            pullStatusLabel,
            note("前台反应不依赖 AX/OCR；拉扯窗口需要辅助功能授权。"),
        ])
    }

    private func gameplayLabel(_ id: String, fallback: String) -> String {
        gameplayCatalog?.plugins.first { $0.id == id }?.displayNames.defaultText ?? fallback
    }

    // MARK: 大脑

    // MARK: 角色组与入退场

    private func buildCastTab() -> NSView {
        castModePopup = NSPopUpButton()
        castModePopup.addItems(withTitles: ["手动安排", "启动时自动入场", "随机入场"])
        let modeIndex = draft.castSelection.mode == .random
            ? 2 : (draft.castSelection.automaticArrivalsEnabled ? 1 : 0)
        castModePopup.selectItem(at: modeIndex)
        castModePopup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        castRandomCountField = numberField("\(draft.castSelection.randomCount)")
        castMaxActiveField = numberField("\(draft.castSelection.maxActiveMembers)")
        castInvitationsBox = checkbox(
            "允许剧情中的角色邀请其他候选角色入场",
            draft.castSelection.invitationsEnabled,
            #selector(toggleDraft(_:)))
        castRotationBox = checkbox(
            "定时让一个角色退出，再让下一位候选角色入场",
            draft.castSelection.automaticRotationEnabled,
            #selector(toggleDraft(_:)))
        castRotationIntervalField = numberField(
            "\(max(1, draft.castSelection.rotationIntervalTicks / 20))", placeholder: "例如 60")

        let strategy = formStack([
            note("设置启动入场与自动轮换；手动入退场仍在菜单栏“角色”中操作。"),
            row("入场方式", castModePopup),
            row("随机人数（仅随机入场）", castRandomCountField, labelWidth: 170),
            row("桌面最多角色", castMaxActiveField, labelWidth: 170),
            castInvitationsBox,
            castRotationBox,
            row("轮换间隔（秒）", castRotationIntervalField, labelWidth: 170),
            note("手动安排：启动时不自动增加角色；启动时自动入场：按候选顺序进入；随机入场：从候选角色中随机选择指定人数。"),
        ])

        let selectedMembers = Set(draft.castSelection.enabledMemberIDs)
        var candidates: [NSView] = [note("勾选允许参与的角色；按角色组排列，每组最多三列。")]
        if castPacks.isEmpty {
            candidates.append(note("尚未发现角色配置；当前仍可使用基础单角色模式。"))
        } else {
            for pack in castPacks.sorted(by: { $0.displayName < $1.displayName }) {
                let members = pack.members.filter {
                    $0.kind == .character && $0.visualPackID != nil
                }
                let boxes = members.map { member in
                    let box = checkbox(
                        member.displayName,
                        draft.castSelection.allMembersEnabled || selectedMembers.contains(member.id),
                        #selector(toggleCastMember(_:)))
                    box.widthAnchor.constraint(equalToConstant: 185).isActive = true
                    castMemberBoxes.append((member.id, box))
                    return box
                }
                guard !boxes.isEmpty else { continue }
                let group = checkbox("全选本组 · \(pack.displayName)",
                                     boxes.allSatisfy { $0.state == .on },
                                     #selector(toggleCastGroup(_:)))
                castGroupBoxes.append((group, boxes))
                candidates += [separator(), group]
                let rows: [[NSView]] = stride(from: 0, to: boxes.count, by: 3).map { start in
                    (0..<3).map { offset in
                        start + offset < boxes.count ? boxes[start + offset] : NSView()
                    }
                }
                if !rows.isEmpty {
                    let grid = NSGridView(views: rows)
                    grid.rowSpacing = 8
                    grid.columnSpacing = 12
                    candidates.append(grid)
                }
            }
        }
        let tabs = NSTabView()
        tabs.addTabViewItem(tab("入场策略", strategy))
        tabs.addTabViewItem(tab("候选角色", scrollFormStack(candidates)))
        return tabs
    }

    private func buildStoryTab() -> NSView {
        storyEnabledBox = checkbox(
            "自动演剧情",
            draft.storySettings.enabled,
            #selector(toggleDraft(_:)))
        storyRepeatBox = checkbox(
            "剧情完成后自动循环选择下一段",
            draft.storySettings.repeatEpisodes,
            #selector(toggleDraft(_:)))
        storyIntervalField = numberField(
            "\(draft.storySettings.intervalTicks)", placeholder: "0 = 上一段结束后立即允许")
        storyMaxDurationField = numberField(
            "\(draft.storySettings.maxDurationTicks)", placeholder: "1200 = 60 秒")
        storyForegroundInterruptBox = checkbox(
            "前台切换可以抢占剧情",
            draft.storySettings.interruptOnForeground,
            #selector(toggleDraft(_:)))
        storyContentInterruptBox = checkbox(
            "聊天 / 编码 / 浏览器内容可以抢占剧情",
            draft.storySettings.interruptOnContent,
            #selector(toggleDraft(_:)))
        storyRelationsBox = checkbox(
            "允许剧情提交关系效果",
            draft.storySettings.relationshipEffectsEnabled,
            #selector(toggleDraft(_:)))

        let packSummary = castPacks.isEmpty
            ? "尚未发现角色组；单角色玩法仍可运行。"
            : "当前可用角色组：\(castPacks.map(\.displayName).sorted().joined(separator: "、"))"
        let browse = NSButton(title: "查看剧情内容…", target: self,
                              action: #selector(openStoryLibrary))
        browse.bezelStyle = .rounded
        return scrollFormStack([
            browse,
            note("查看当前已启用剧情包的剧集、参与者、节拍和分支；本页开关不会影响查看。"),
            separator(),
            storyEnabledBox,
            storyRepeatBox,
            row("剧情间隔（核心 tick）", storyIntervalField),
            row("单段最长（核心 tick）", storyMaxDurationField),
            storyForegroundInterruptBox,
            storyContentInterruptBox,
            storyRelationsBox,
            note("1 tick = 50ms；默认 1200 tick 约 60 秒。鼠标直接互动始终可以抢占剧情。"),
            note("剧情只提交声明式关系效果；关闭关系效果仍会记录剧情完成事实。"),
            separator(),
            note(packSummary),
        ])
    }

    private func buildBrainTab() -> NSView {
        return buildBrainTabs()
    }

    private func buildBrainTabs() -> NSView {
        logBox = checkbox("完整脑路日志（仅保存在本机）", draft.brainTraceEnabled, #selector(toggleDraft(_:)))
        speechBox = checkbox(gameplayLabel("speech", fallback: "让宠物说话"),
                             draft.speechEnabled, #selector(toggleDraft(_:)))
        voicePlaybackBox = checkbox("播放动作语音（角色专属动作的录制台词）",
                                    draft.voicePlaybackEnabled, #selector(toggleDraft(_:)))
        goalMinIntervalField = numberField(String(format: "%.3g", draft.goalBrainMinInterval))
        goalMaxIntervalField = numberField(String(format: "%.3g", draft.goalBrainMaxInterval))

        let shared = NSStackView(views: [
            note("三个大脑可独立开关；同时运行时本地决策脑驱动行为，高阶教师脑只产训练标签。"),
            logBox, speechBox, voicePlaybackBox,
            row("目标最短间隔", goalMinIntervalField),
            row("目标最长间隔", goalMaxIntervalField),
        ])
        shared.orientation = .vertical
        shared.alignment = .leading
        shared.spacing = 8
        shared.translatesAutoresizingMaskIntoConstraints = false

        let brainTabs = NSTabView()
        brainTabs.translatesAutoresizingMaskIntoConstraints = false
        brainTabs.addTabViewItem(tab("行动脑", buildActionBrainTab()))
        brainTabs.addTabViewItem(tab("本地决策脑", buildLocalBrainTab()))
        brainTabs.addTabViewItem(tab("高阶教师脑", buildTeacherBrainTab()))

        let container = NSView()
        container.addSubview(shared)
        container.addSubview(brainTabs)
        NSLayoutConstraint.activate([
            shared.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            shared.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            shared.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            brainTabs.topAnchor.constraint(equalTo: shared.bottomAnchor, constant: 8),
            brainTabs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            brainTabs.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            brainTabs.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            brainTabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        return container
    }

    private func buildTeacherBrainTab() -> NSView {
        teacherBrainBox = checkbox("高阶教师脑：llama.cpp + Qwen VL（只产目标与训练标签）",
                                   draft.teacherBrainEnabled, #selector(toggleDraft(_:)))
        baseURLField = NSTextField(string: draft.teacherBrainBaseURL)
        baseURLField.placeholderString = "http://192.168.2.60:8001/v1"

        modelCombo = NSComboBox()
        modelCombo.usesDataSource = false
        modelCombo.completes = true
        modelCombo.stringValue = draft.teacherBrainModel
        modelCombo.placeholderString = "留空 = 点「探测模型」自动填充"

        apiKeyField = NSSecureTextField(string: draft.teacherBrainAPIKey)
        apiKeyField.placeholderString = "本机 llama.cpp 通常留空"

        probeButton = NSButton(title: "探测模型", target: self, action: #selector(probeModels))
        probeButton.bezelStyle = .rounded
        testButton = NSButton(title: "测试对话", target: self, action: #selector(testChat))
        testButton.bezelStyle = .rounded
        brainStatusLabel = note("未测试。")

        teacherTemperatureField = numberField(String(format: "%.3g", draft.teacherBrainTemperature))
        teacherTopPField = numberField(String(format: "%.3g", draft.teacherBrainTopP))
        teacherTopKField = numberField("\(draft.teacherBrainTopK)")
        teacherMaxTokensField = numberField("\(draft.teacherBrainMaxTokens)")
        teacherSeedField = numberField(draft.teacherBrainSeed.map(String.init) ?? "", placeholder: "空 = 随机")
        teacherReasoningField = NSTextField(string: draft.teacherBrainReasoningEffort)
        teacherReasoningField.placeholderString = "空 = server default（llama.cpp）"
        teacherReasoningField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let probeRow = NSStackView(views: [probeButton, testButton])
        probeRow.orientation = .horizontal
        probeRow.spacing = 10

        return scrollFormStack([
            teacherBrainBox,
            row("端点", baseURLField),
            row("模型", modelCombo),
            row("API 密钥", apiKeyField),
            probeRow,
            brainStatusLabel,
            separator(),
            note("本机 llama.cpp + Qwen VL。目标请求使用 schema-constrained JSON；以下采样只作用于 Goal，没有独立的语音采样参数。"),
            row("目标温度", teacherTemperatureField),
            row("目标 Top-p", teacherTopPField),
            row("目标 Top-k", teacherTopKField),
            row("目标 tokens", teacherMaxTokensField),
            row("目标 Seed", teacherSeedField),
            row("思考等级", teacherReasoningField),
            note("端点若不支持 schema 约束，客户端仍会解析并做语义校验；不能把 HTTP 200 当成约束成功。"),
        ])
    }

    private func buildLocalBrainTab() -> NSView {
        localDecisionBrainBox = checkbox("本地决策脑：端侧 MLX Qwen3.5 0.8B（与教师脑可同时运行）",
                                          draft.localBrainEnabled, #selector(toggleDraft(_:)))
        localBrainStatusLabel = note("")
        localDownloadButton = NSButton(title: "从 URL 下载并验证", target: self, action: #selector(downloadLocalBrain))
        localDownloadButton.bezelStyle = .rounded
        localTestButton = NSButton(title: "测试对话", target: self, action: #selector(testLocalChat))
        localTestButton.bezelStyle = .rounded
        localGoalTemperatureField = numberField(String(format: "%.3g", draft.localBrainGoalTemperature))
        localGoalTopPField = numberField(String(format: "%.3g", draft.localBrainGoalTopP))
        localGoalTopKField = numberField("\(draft.localBrainGoalTopK)")
        localGoalMaxTokensField = numberField("\(draft.localBrainGoalMaxTokens)")
        localGoalSeedField = numberField(draft.localBrainGoalSeed.map(String.init) ?? "", placeholder: "空 = 随机")
        localChatTemperatureField = numberField(String(format: "%.3g", draft.localBrainChatTemperature))
        localChatTopPField = numberField(String(format: "%.3g", draft.localBrainChatTopP))
        localChatTopKField = numberField("\(draft.localBrainChatTopK)")
        localChatMaxTokensField = numberField("\(draft.localBrainChatMaxTokens)")
        localChatSeedField = numberField(draft.localBrainChatSeed.map(String.init) ?? "", placeholder: "空 = 随机")

        let actionRow = NSStackView(views: [localDownloadButton, localTestButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10

        return scrollFormStack([
            localDecisionBrainBox,
            actionRow,
            localBrainStatusLabel,
            separator(),
            note("聊天：本地脑生成短气泡 JSON；失败时自动回退 Quips。"),
            row("聊天温度", localChatTemperatureField),
            row("聊天 Top-p", localChatTopPField),
            row("聊天 Top-k", localChatTopKField),
            row("聊天 tokens", localChatMaxTokensField),
            row("聊天 Seed", localChatSeedField),
            separator(),
            note("目标 JSON：只输出结构化 GoalDecision；MLX 侧使用固定 schema prompt、解析、语义校验和一次重试。"),
            row("目标温度", localGoalTemperatureField),
            row("目标 Top-p", localGoalTopPField),
            row("目标 Top-k", localGoalTopKField),
            row("目标 tokens", localGoalMaxTokensField),
            row("目标 Seed", localGoalSeedField),
            note("本地模型约 872MB，从以下 URL 逐文件下载到本机数据目录，并按清单字节数验证；前缀缓存按任务分开。\n" +
                 LocalBrainModel.rawBaseURL.absoluteString),
        ])
    }

    private func buildActionBrainTab() -> NSView {
        actionBrainBox = checkbox("行动脑：Needle 3 决定「现在做什么」（动作级）",
                                  draft.actionBrainEnabled, #selector(toggleDraft(_:)))
        actionBrainStatusLabel = note("")
        actionMinIntervalField = numberField(String(format: "%.3g", draft.actionBrainMinInterval))
        actionMaxIntervalField = numberField(String(format: "%.3g", draft.actionBrainMaxInterval))
        actionMaxTokensField = numberField("\(draft.actionBrainMaxTokens)")

        return scrollFormStack([
            actionBrainBox,
            actionBrainStatusLabel,
            row("动作最短间隔", actionMinIntervalField),
            row("动作最长间隔", actionMaxIntervalField),
            row("动作 JSON tokens", actionMaxTokensField),
            note("Needle 3 负责具体动作 JSON / tool call。C API 当前只暴露 max_new_tokens，因此不虚构 temperature、top-p 等参数。"),
        ])
    }

    // MARK: 感知

    private func buildSensesTab() -> NSView {
        inputPluginControls.removeAll()
        var windowViews: [NSView] = [
            note("窗口标题、辅助功能和 OCR 可分别开关；权限状态在本页底部。")
        ]
        var contentViews: [NSView] = [
            note("聊天、编码与浏览器内容只提供有界观察，不直接执行动作。")
        ]
        for id in ["window-title", "accessibility", "ocr",
                   "chat-content", "code-content", "browser-content"] {
            guard let config = draft.inputPlugins.configuration(for: id) else { continue }
            var views = [NSView]()
            let enabled = checkbox(config.displayName, config.enabled, #selector(toggleDraft(_:)))
            let preemptive = checkbox("内容变化允许抢占当前低优先级计划", config.preemptive,
                                      #selector(toggleDraft(_:)))
            let ttl = numberField(String(config.ttlTicks))
            let maxCharacters = numberField(String(config.maxCharacters))
            let applications = NSTextField(string: config.allowedApplications.joined(separator: ", "))
            applications.placeholderString = "空 = 所有应用；逗号分隔应用名或 bundle id"
            applications.widthAnchor.constraint(equalToConstant: 330).isActive = true
            inputPluginControls.append(InputPluginControls(
                id: id, enabled: enabled, preemptive: preemptive, ttl: ttl,
                maxCharacters: maxCharacters, applications: applications))
            views += [separator(), enabled, row("TTL ticks", ttl),
                      row("最大字符", maxCharacters),
                      row("应用白名单", applications, width: 380), preemptive]
            if ["window-title", "accessibility", "ocr"].contains(id) {
                windowViews += views
            } else {
                contentViews += views
            }
            if id == "accessibility" { sensesBox = enabled }
            if id == "ocr" { ocrBox = enabled }
        }
        axStatusLabel = note("")
        let axButton = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openAXSettings))
        axButton.bezelStyle = .rounded

        ocrStatusLabel = note("")
        let ocrButton = NSButton(title: "请求屏幕录制授权", target: self, action: #selector(requestScreenPermission))
        ocrButton.bezelStyle = .rounded

        windowViews += [separator(), axStatusLabel, axButton,
                        separator(), ocrStatusLabel, ocrButton]
        contentViews.append(note("只有显式允许抢占的插件会让旧计划失效；关闭插件后不会继续采集。"))
        let tabs = NSTabView()
        tabs.addTabViewItem(tab("窗口与权限", scrollFormStack(windowViews)))
        tabs.addTabViewItem(tab("内容输入", scrollFormStack(contentViews)))
        return tabs
    }

    // MARK: 诊断

    private func buildDiagnosticsTab() -> NSView {
        diagLabel = note("")
        let openLogs = NSButton(title: "打开日志目录", target: self, action: #selector(openDataFolder))
        openLogs.bezelStyle = .rounded
        let clearTrace = NSButton(title: "清空脑路日志", target: self, action: #selector(clearBrainTraceLog))
        clearTrace.bezelStyle = .rounded
        let clearMemory = NSButton(title: "清空记忆", target: self, action: #selector(clearMemoryStore))
        clearMemory.bezelStyle = .rounded
        let buttons = NSStackView(views: [openLogs, clearTrace, clearMemory])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        return formStack([diagLabel, buttons,
                          note("brain_trace.jsonl / memory.json 都在数据目录。" +
                               "查看日志会按 Trace 关联目标、动作、场景和结局；可随时删除，不影响宠物运行。")])
    }

    // MARK: 刷新

    /// 授权状态与诊断数字在窗口激活时刷新。
    func refreshPermissionLabels() {
        axStatusLabel?.stringValue = WindowPuller.isTrusted()
            ? "✅ 辅助功能：已授权"
            : "⚠️ 辅助功能：未授权（拉窗 / AX 感知需要）"
        ocrStatusLabel?.stringValue = OCRSensor.permissionGranted
            ? "✅ 屏幕录制：已授权"
            : "⚠️ 屏幕录制：未授权（OCR 感知需要）"
        pullStatusLabel?.stringValue = WindowPuller.isTrusted()
            ? "✅ 窗口交互权限：已授权"
            : "⚠️ 窗口交互权限：未授权（仅影响拉扯窗口，不影响其他玩法）"

        let model = NeedleBrain.modelURL()
        actionBrainStatusLabel?.stringValue = model != nil
            ? "✅ 模型在位：\(model!.lastPathComponent)"
            : "⚠️ 未找到 needle3.cact（fetch_needle.sh 下载后放入资源目录）"

        refreshLocalBrainStatus()

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet", isDirectory: true)
        func lines(_ name: String) -> String {
            let url = support.appendingPathComponent(name)
            guard let data = try? String(contentsOf: url, encoding: .utf8) else { return "0" }
            return String(data.split(separator: "\n").count)
        }
        let memoryCount = (try? JSONDecoder().decode([MemoryEntry].self,
            from: Data(contentsOf: support.appendingPathComponent("memory.json"))))?.count ?? 0
        diagLabel?.stringValue = """
        brain_trace.jsonl：\(lines("brain_trace.jsonl")) 条统一事件
        memory.json：\(memoryCount) 条记忆
        """
    }

    private func collectDraft() {
        draft.launchAtLogin = launchAtLoginBox.state == .on
        draft.displayHeight = CGFloat(heightSlider.doubleValue)
        draft.propScale = propScaleSlider.doubleValue / 100
        draft.scenesEnabled = scenesBox.state == .on
        draft.propsEnabled = propsBox.state == .on
        draft.perchingEnabled = perchingBox.state == .on
        draft.foregroundFollow = foregroundBox.state == .on
        draft.windowPullEnabled = windowPullBox.state == .on
        draft.teacherBrainEnabled = teacherBrainBox.state == .on
        draft.teacherBrainBaseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        draft.teacherBrainModel = modelCombo.stringValue.trimmingCharacters(in: .whitespaces)
        draft.teacherBrainAPIKey = apiKeyField.stringValue
        draft.teacherBrainTemperature = boundedDouble(teacherTemperatureField, fallback: 0.8,
                                                      lower: 0, upper: 2)
        draft.teacherBrainTopP = boundedDouble(teacherTopPField, fallback: 1.0,
                                               lower: 0, upper: 1)
        draft.teacherBrainTopK = max(0, parsedInt(teacherTopKField, fallback: 0))
        draft.teacherBrainMaxTokens = max(1, parsedInt(teacherMaxTokensField, fallback: 220))
        draft.teacherBrainSeed = parsedOptionalInt(teacherSeedField)
        draft.teacherBrainReasoningEffort = teacherReasoningField.stringValue.trimmingCharacters(in: .whitespaces)
        draft.brainTraceEnabled = logBox.state == .on
        draft.speechEnabled = speechBox.state == .on
        draft.voicePlaybackEnabled = voicePlaybackBox.state == .on
        draft.actionBrainEnabled = actionBrainBox.state == .on
        draft.localBrainEnabled = localDecisionBrainBox.state == .on
        draft.localBrainGoalTemperature = boundedDouble(localGoalTemperatureField, fallback: 0.0,
                                                        lower: 0, upper: 2)
        draft.localBrainGoalTopP = boundedDouble(localGoalTopPField, fallback: 1.0,
                                                 lower: 0, upper: 1)
        draft.localBrainGoalTopK = max(0, parsedInt(localGoalTopKField, fallback: 0))
        draft.localBrainGoalMaxTokens = max(1, parsedInt(localGoalMaxTokensField, fallback: 160))
        draft.localBrainGoalSeed = parsedOptionalInt(localGoalSeedField)
        draft.localBrainChatTemperature = boundedDouble(localChatTemperatureField, fallback: 0.3,
                                                        lower: 0, upper: 2)
        draft.localBrainChatTopP = boundedDouble(localChatTopPField, fallback: 0.8,
                                                 lower: 0, upper: 1)
        draft.localBrainChatTopK = max(0, parsedInt(localChatTopKField, fallback: 20))
        draft.localBrainChatMaxTokens = max(1, parsedInt(localChatMaxTokensField, fallback: 48))
        draft.localBrainChatSeed = parsedOptionalInt(localChatSeedField)
        draft.goalBrainMinInterval = parsedDouble(goalMinIntervalField, fallback: 45.0)
        draft.goalBrainMaxInterval = parsedDouble(goalMaxIntervalField, fallback: 90.0)
        draft.actionBrainMinInterval = parsedDouble(actionMinIntervalField, fallback: 4.0)
        draft.actionBrainMaxInterval = parsedDouble(actionMaxIntervalField, fallback: 10.0)
        draft.actionBrainMaxTokens = max(1, parsedInt(actionMaxTokensField, fallback: 128))
        draft.sensesEnabled = sensesBox.state == .on
        draft.ocrEnabled = ocrBox.state == .on
        for entry in inputPluginControls {
            guard var config = draft.inputPlugins.configuration(for: entry.id) else { continue }
            config.enabled = entry.enabled.state == .on
            config.preemptive = entry.preemptive.state == .on
            config.ttlTicks = Int64(max(1, parsedInt(entry.ttl,
                                                     fallback: Int(config.ttlTicks))))
            config.maxCharacters = max(1, parsedInt(entry.maxCharacters,
                                                   fallback: config.maxCharacters))
            config.allowedApplications = entry.applications.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            draft.inputPlugins.plugins[entry.id] = config
        }
        // 保留旧键的镜像，确保旧版本/测试构造的设置仍能工作。
        draft.sensesEnabled = draft.inputPlugins.isEnabled("accessibility")
        draft.ocrEnabled = draft.inputPlugins.isEnabled("ocr")

        let allMembers = Set(castMemberBoxes.map(\.id))
        let selectedMembers = Set(castMemberBoxes.filter { $0.box.state == .on }.map(\.id))
        let castMode = castModePopup.indexOfSelectedItem
        draft.castSelection.mode = castMode == 2 ? .random : .manual
        draft.castSelection.automaticArrivalsEnabled = castMode != 0
        draft.castSelection.allGroupsEnabled = true
        draft.castSelection.enabledGroupIDs = []
        draft.castSelection.allMembersEnabled = selectedMembers == allMembers
        draft.castSelection.enabledMemberIDs = draft.castSelection.allMembersEnabled
            ? [] : selectedMembers.sorted()
        draft.castSelection.randomCount = max(1, parsedInt(castRandomCountField, fallback: 1))
        draft.castSelection.maxActiveMembers = max(1, parsedInt(castMaxActiveField, fallback: 1))
        draft.castSelection.invitationsEnabled = castInvitationsBox.state == .on
        draft.castSelection.automaticRotationEnabled = castRotationBox.state == .on
        draft.castSelection.rotationIntervalTicks = max(
            0, Int64(parsedInt(castRotationIntervalField, fallback: 60)) * 20)

        draft.storySettings.enabled = storyEnabledBox.state == .on
        draft.storySettings.repeatEpisodes = storyRepeatBox.state == .on
        draft.storySettings.intervalTicks = max(
            0, Int64(parsedInt(storyIntervalField, fallback: 0)))
        draft.storySettings.maxDurationTicks = max(
            1, Int64(parsedInt(storyMaxDurationField, fallback: 1_200)))
        draft.storySettings.interruptOnForeground = storyForegroundInterruptBox.state == .on
        draft.storySettings.interruptOnContent = storyContentInterruptBox.state == .on
        draft.storySettings.relationshipEffectsEnabled = storyRelationsBox.state == .on
    }

    private func parsedDouble(_ field: NSTextField, fallback: Double) -> Double {
        Double(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? fallback
    }

    private func boundedDouble(_ field: NSTextField, fallback: Double,
                               lower: Double, upper: Double) -> Double {
        min(upper, max(lower, parsedDouble(field, fallback: fallback)))
    }

    private func parsedInt(_ field: NSTextField, fallback: Int) -> Int {
        Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? fallback
    }

    private func parsedOptionalInt(_ field: NSTextField) -> Int? {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Int(text)
    }

    // MARK: 本地大脑

    private func refreshLocalBrainStatus() {
        guard localBrainStatusLabel != nil else { return }
        if LocalBrainModel.isInstalled {
            localBrainStatusLabel.stringValue =
                "✅ 已就位 · \(ByteCountFormatter.string(fromByteCount: Int64(LocalBrainModel.requiredBytes), countStyle: .file)) · " +
                LocalBrainModel.installDirectory.path
            localDownloadButton.isEnabled = true
            localDownloadButton.title = "重新验证模型"
            localTestButton.isEnabled = true
        } else {
            let missing = LocalBrainModel.missingFiles(in: LocalBrainModel.installDirectory).count
            localBrainStatusLabel.stringValue =
                "⚠️ 未就位（缺 \(missing) 个文件，约 " +
                ByteCountFormatter.string(fromByteCount: Int64(LocalBrainModel.requiredBytes), countStyle: .file) +
                "，ModelScope）"
            localDownloadButton.isEnabled = true
            localDownloadButton.title = "从 URL 下载并验证"
            localTestButton.isEnabled = false
        }
    }

    @objc private func downloadLocalBrain() {
        localDownloadButton.isEnabled = false
        localTestButton.isEnabled = false
        localBrainStatusLabel.stringValue = "下载中…"
        Task { [weak self] in
            let downloader = ModelDownloader()
            do {
                _ = try await downloader.installLocalBrain { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.localBrainStatusLabel.stringValue = String(
                            format: "下载中 %@ · %.0f%%",
                            progress.path as NSString,
                            progress.overallFraction * 100)
                    }
                }
                await MainActor.run {
                    self?.refreshLocalBrainStatus()
                }
            } catch {
                await MainActor.run {
                    self?.localBrainStatusLabel.stringValue = "❌ \(error.localizedDescription)"
                    self?.localDownloadButton.isEnabled = true
                    self?.localTestButton.isEnabled = LocalBrainModel.isInstalled
                }
            }
        }
    }

    @objc private func testLocalChat() {
        guard let localChatTester else {
            localBrainStatusLabel.stringValue = "❌ 本地测试暂不可用（控制器未就绪）"
            return
        }
        localTestButton.isEnabled = false
        localBrainStatusLabel.stringValue = "本地测试对话中…"
        Task { [weak self] in
            let result = await localChatTester()
            await MainActor.run {
                guard let self else { return }
                self.localTestButton.isEnabled = LocalBrainModel.isInstalled
                let ms = Int(result.latency * 1000)
                self.localBrainStatusLabel.stringValue = result.error.map {
                    "❌ \($0) · \(ms)ms"
                } ?? "✅ \(ms)ms 回复：\(result.text ?? "")（\(result.emotion ?? "neutral")）"
            }
        }
    }

    // MARK: 动作

    @objc private func saveSettings() {
        collectDraft()
        onApply?(draft)
        lastSaved = draft
        hasUnsavedPreview = false
    }

    @objc private func saveAndCloseSettings() {
        saveSettings()
        window?.performClose(nil)
    }

    @objc private func toggleCastGroup(_ sender: NSButton) {
        guard let entry = castGroupBoxes.first(where: { $0.group === sender }) else { return }
        for member in entry.members { member.state = sender.state }
    }

    @objc private func toggleCastMember(_ sender: NSButton) {
        guard let entry = castGroupBoxes.first(where: { $0.members.contains { $0 === sender } }) else { return }
        entry.group.state = entry.members.allSatisfy { $0.state == .on } ? .on : .off
    }

    @objc private func closeWithoutSaving() {
        window?.performClose(nil)
    }

    @objc private func toggleDraft(_ sender: NSButton) {}

    @objc private func heightChanged(_ sender: NSSlider) {
        heightLabel.stringValue = "\(Int(sender.doubleValue)) pt"
        previewLive()
    }

    @objc private func propScaleChanged(_ sender: NSSlider) {
        propScaleLabel.stringValue = "\(Int(sender.doubleValue))%"
        previewLive()
    }

    /// 拖动滑杆 = 实时预览：草稿不落盘，直接热更新控制器，
    /// 宠物/道具当场按新尺寸运转；取消关闭时还原回打开时的设置。
    private func previewLive() {
        collectDraft()
        hasUnsavedPreview = true
        onPreview?(draft)
    }

    @objc private func openDataFolder() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func openAXSettings() {
        Tray.openAccessibilitySettings()
    }

    @objc private func requestScreenPermission() {
        OCRSensor.requestPermission()
        // 「新鲜生效」：勾选后新进程立即有权限；这里延迟刷新一下状态文案。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshPermissionLabels()
        }
    }

    @objc private func probeModels() {
        let config = TeacherBrain.Config(
            baseURL: baseURLField.stringValue.trimmingCharacters(in: .whitespaces),
            model: modelCombo.stringValue,
            apiKey: apiKeyField.stringValue)
        guard !config.baseURL.isEmpty else {
            brainStatusLabel.stringValue = "⚠️ 请先填端点"
            return
        }
        brainStatusLabel.stringValue = "探测中… \(config.baseURL)/models"
        probeButton.isEnabled = false
        TeacherBrain.probeModels(config: config) { [weak self] ids, error in
            guard let self else { return }
            self.probeButton.isEnabled = true
            if let error {
                self.brainStatusLabel.stringValue = "❌ 探测失败：\(error)"
            } else {
                self.modelCombo.removeAllItems()
                for id in ids { self.modelCombo.addItem(withObjectValue: id) }
                if self.modelCombo.stringValue.isEmpty, let first = ids.first {
                    self.modelCombo.stringValue = first
                }
                self.brainStatusLabel.stringValue = "✅ 可用模型：\(ids.joined(separator: "、"))"
            }
            self.refreshPermissionLabels()
        }
    }

    @objc private func testChat() {
        let config = TeacherBrain.Config(
            baseURL: baseURLField.stringValue.trimmingCharacters(in: .whitespaces),
            model: modelCombo.stringValue.trimmingCharacters(in: .whitespaces),
            apiKey: apiKeyField.stringValue,
            planSampling: currentTeacherSampling())
        guard !config.model.isEmpty else {
            brainStatusLabel.stringValue = "⚠️ 请先选模型（可点「探测模型」）"
            return
        }
        let t0 = Date()
        brainStatusLabel.stringValue = "测试对话中…"
        testButton.isEnabled = false
        TeacherBrain.testChat(config: config) { [weak self] reply, error in
            guard let self else { return }
            self.testButton.isEnabled = true
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            self.brainStatusLabel.stringValue = error != nil
                ? "❌ \(error!) · \(ms)ms"
                : "✅ \(ms)ms 回复：\(reply)"
        }
    }

    private func currentTeacherSampling() -> TeacherBrain.PlanSampling {
        TeacherBrain.PlanSampling(
            temperature: boundedDouble(teacherTemperatureField, fallback: 0.8, lower: 0, upper: 2),
            topP: boundedDouble(teacherTopPField, fallback: 1.0, lower: 0, upper: 1),
            topK: max(0, parsedInt(teacherTopKField, fallback: 0)),
            maxTokens: max(1, parsedInt(teacherMaxTokensField, fallback: 220)),
            seed: parsedOptionalInt(teacherSeedField),
            reasoningEffort: teacherReasoningField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    @objc private func clearBrainTraceLog() {
        BrainTraceLog.clear()
        refreshPermissionLabels()
    }

    @objc private func clearMemoryStore() {
        MemoryStore().clear()
        refreshPermissionLabels()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermissionLabels()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 仅撤销最后一次保存后发生的实时预览；已保存的更改继续生效。
        if hasUnsavedPreview {
            onPreview?(lastSaved)
        }
        return true
    }
}

private final class TopAlignedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
