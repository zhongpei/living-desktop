import AppKit
import MyPetCore

/// Local Qwen speech prompt editor. The shipped policy remains immutable;
/// settings persist only user differences and the selected preset.
@MainActor
final class PromptManagerWindowController: NSWindowController {
    var onSave: ((Bool, LocalSpeechPromptOverrides) -> Void)?
    var onTest: ((CharacterDefinition, LocalSpeechPolicy, SpeechIntent, String?, Bool, BrainProfile.Sampling) async -> LocalBrain.PromptTestResult)?

    private let builtIn: LocalSpeechPolicy
    private let baseTemperature: Double
    private let defaultSampling: BrainProfile.Sampling
    private let characters: [CharacterDefinition]
    private var usesCustom: Bool
    private var overrides: LocalSpeechPromptOverrides
    private var editingScene: LocalSpeechSceneID = .greet

    private let presetPopup = NSPopUpButton()
    private let characterPopup = NSPopUpButton()
    private let scenePopup = NSPopUpButton()
    private let roleEditor = PromptManagerWindowController.editor()
    private let responsibilityEditor = PromptManagerWindowController.editor()
    private let factEditor = PromptManagerWindowController.editor()
    private let outputEditor = PromptManagerWindowController.editor()
    private let sceneEditor = PromptManagerWindowController.editor()
    private let contextEditor = PromptManagerWindowController.editor()
    private let fewShotCheckbox = NSButton(checkboxWithTitle: "测试时注入角色 Few-shot", target: nil, action: nil)
    private let temperatureField = NSTextField(string: "")
    private let topPField = NSTextField(string: "")
    private let topKField = NSTextField(string: "")
    private let maxTokensField = NSTextField(string: "")
    private let seedField = NSTextField(string: "")
    private let analysisView = PromptManagerWindowController.editor()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var testButton: NSButton!

    init(settings: Settings, characters: [CharacterDefinition] = [],
         currentCharacterID: String? = nil,
         builtIn: LocalSpeechPolicy = RuntimeSpeechPolicy.builtIn) {
        self.builtIn = builtIn
        self.baseTemperature = settings.localBrainChatTemperature
        self.defaultSampling = BrainProfile.Sampling(
            temperature: settings.localBrainChatTemperature,
            topP: settings.localBrainChatTopP,
            topK: settings.localBrainChatTopK,
            maxTokens: settings.localBrainChatMaxTokens,
            seed: settings.localBrainChatSeed)
        self.characters = characters.sorted { $0.displayName < $1.displayName }
        self.usesCustom = settings.localSpeechPromptUsesCustom
        self.overrides = settings.localSpeechPromptOverrides
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Qwen Prompt 分析与管理"
        window.contentMinSize = NSSize(width: 800, height: 680)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
        if let currentCharacterID,
           let item = characterPopup.itemArray.first(where: {
               $0.representedObject as? String == currentCharacterID
           }) {
            characterPopup.select(item)
        }
        window.center()
        loadEditors()
        loadSamplingDefaults()
        analyzePrompt()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() -> NSView {
        presetPopup.addItems(withTitles: ["内置验证版（只读）", "用户自定义"])
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        presetPopup.identifier = NSUserInterfaceItemIdentifier("prompt.preset")

        for character in characters {
            characterPopup.addItem(withTitle: character.displayName)
            characterPopup.lastItem?.representedObject = character.id
        }
        if characters.isEmpty { characterPopup.addItem(withTitle: "无可用角色") }
        characterPopup.isEnabled = !characters.isEmpty
        characterPopup.target = self
        characterPopup.action = #selector(characterChanged)
        characterPopup.identifier = NSUserInterfaceItemIdentifier("prompt.character")

        for scene in LocalSpeechSceneID.allCases {
            scenePopup.addItem(withTitle: Self.sceneName(scene))
            scenePopup.lastItem?.representedObject = scene.rawValue
        }
        scenePopup.target = self
        scenePopup.action = #selector(sceneChanged)
        scenePopup.identifier = NSUserInterfaceItemIdentifier("prompt.scene")

        contextEditor.identifier = NSUserInterfaceItemIdentifier("prompt.test-context")
        contextEditor.string = "代码运行成功，用户继续工作。"
        roleEditor.identifier = NSUserInterfaceItemIdentifier("prompt.role")
        responsibilityEditor.identifier = NSUserInterfaceItemIdentifier("prompt.responsibility")
        factEditor.identifier = NSUserInterfaceItemIdentifier("prompt.fact")
        outputEditor.identifier = NSUserInterfaceItemIdentifier("prompt.output")
        sceneEditor.identifier = NSUserInterfaceItemIdentifier("prompt.scene-direction")
        temperatureField.identifier = NSUserInterfaceItemIdentifier("prompt.temperature")
        topPField.identifier = NSUserInterfaceItemIdentifier("prompt.top-p")
        topKField.identifier = NSUserInterfaceItemIdentifier("prompt.top-k")
        maxTokensField.identifier = NSUserInterfaceItemIdentifier("prompt.max-tokens")
        seedField.identifier = NSUserInterfaceItemIdentifier("prompt.seed")
        fewShotCheckbox.identifier = NSUserInterfaceItemIdentifier("prompt.few-shot")
        fewShotCheckbox.state = .off
        fewShotCheckbox.target = self
        fewShotCheckbox.action = #selector(analyzePrompt)
        analysisView.isEditable = false
        analysisView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        analysisView.identifier = NSUserInterfaceItemIdentifier("prompt.analysis")

        let reset = NSButton(title: "恢复内置内容", target: self, action: #selector(resetCustom))
        let analyze = NSButton(title: "分析 Prompt", target: self, action: #selector(analyzePrompt))
        testButton = NSButton(title: "调用本地 Qwen", target: self, action: #selector(testPrompt))
        let save = NSButton(title: "保存并应用", target: self, action: #selector(savePrompt))
        save.keyEquivalent = "\r"
        for button in [reset, analyze, save] { button.bezelStyle = .rounded }
        testButton.bezelStyle = .rounded

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("基础 Prompt", basePromptPage()))
        tabs.addTabViewItem(tab("场景与测试", scenePage()))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.preferredMaxLayoutWidth = 720
        let buttons = NSStackView(views: [reset, analyze, testButton, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let root = NSStackView(views: [row("预制", presetPopup), tabs, statusLabel, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabs.widthAnchor.constraint(equalTo: root.widthAnchor),
            tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        return container
    }

    private func basePromptPage() -> NSView {
        let stack = NSStackView(views: [
            note("默认值来自 Resources/brain/local-speech.json。自定义模式只保存与默认值不同的字段；留空也表示继承默认。"),
            editorRow("角色任务", roleEditor),
            editorRow("职责边界", responsibilityEditor),
            editorRow("事实约束", factEditor),
            editorRow("输出约束", outputEditor),
            note("人物姓名、性格和 DialogueProfile 仍由当前角色自动注入，不需要复制到这里。"),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return stack
    }

    private func scenePage() -> NSView {
        let selectors = NSStackView(views: [row("角色", characterPopup, width: 220),
                                            row("场景预制", scenePopup, width: 180)])
        selectors.orientation = .horizontal
        selectors.spacing = 18
        let parameters = NSStackView(views: [
            compactField("温度", temperatureField, width: 54),
            compactField("Top-p", topPField, width: 54),
            compactField("Top-k", topKField, width: 48),
            compactField("Tokens", maxTokensField, width: 54),
            compactField("Seed", seedField, width: 68),
        ])
        parameters.orientation = .horizontal
        parameters.spacing = 10
        let stack = NSStackView(views: [
            selectors,
            editorRow("场景方向", sceneEditor, height: 62),
            editorRow("已确认场景", contextEditor, height: 58),
            fewShotCheckbox,
            parameters,
            note("Few-shot 仅用于这次手动 A/B，不改变正式运行默认。采样参数只用于本次调用，温度是最终值，不再叠加场景偏移。测试会显示首次输出、一次格式重试及每次拒绝原因。"),
            editorRow("分析 / 输出", analysisView, height: 205),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return stack
    }

    private func compactField(_ title: String, _ field: NSTextField,
                              width: CGFloat) -> NSView {
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        let label = NSTextField(labelWithString: title)
        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        return stack
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private static func editor() -> NSTextView {
        let view = NSTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 12)
        return view
    }

    private func editorRow(_ title: String, _ editor: NSTextView,
                           height: CGFloat = 74) -> NSView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        scroll.widthAnchor.constraint(equalToConstant: 650).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return row(title, scroll, width: 650)
    }

    private func row(_ title: String, _ view: NSView, width: CGFloat = 430) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        view.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        let row = NSStackView(views: [label, view])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.preferredMaxLayoutWidth = 700
        return label
    }

    private func loadEditors() {
        presetPopup.selectItem(at: usesCustom ? 1 : 0)
        let policy = effectivePolicy()
        roleEditor.string = policy.prompt.role
        responsibilityEditor.string = policy.prompt.responsibility
        factEditor.string = policy.prompt.factRule
        outputEditor.string = policy.prompt.outputRule
        loadSceneEditor(policy: policy)
        for editor in [roleEditor, responsibilityEditor, factEditor, outputEditor, sceneEditor] {
            editor.isEditable = usesCustom
            editor.backgroundColor = usesCustom ? .textBackgroundColor : .controlBackgroundColor
        }
        statusLabel.stringValue = usesCustom
            ? "用户自定义已选中；安全词、长度限制和一次重试仍由系统强制执行。"
            : "当前使用内置验证版；切换到“用户自定义”后才能编辑。"
    }

    private func loadSceneEditor(policy: LocalSpeechPolicy? = nil) {
        if let item = scenePopup.itemArray.first(where: {
            $0.representedObject as? String == editingScene.rawValue
        }) {
            scenePopup.select(item)
        }
        sceneEditor.string = (policy ?? effectivePolicy()).scene(editingScene)?.direction ?? ""
    }

    private func loadSamplingDefaults() {
        let offset = builtIn.scene(editingScene)?.temperatureOffset ?? 0
        temperatureField.stringValue = String(
            format: "%.2f", min(1, max(0, baseTemperature + offset)))
        topPField.stringValue = String(format: "%.2f", defaultSampling.topP)
        topKField.stringValue = "\(defaultSampling.topK)"
        maxTokensField.stringValue = "\(defaultSampling.maxTokens)"
        seedField.stringValue = defaultSampling.seed.map(String.init) ?? ""
    }

    private func captureEditors() {
        guard usesCustom else { return }
        overrides.role = overrideValue(roleEditor.string, default: builtIn.prompt.role)
        overrides.responsibility = overrideValue(
            responsibilityEditor.string, default: builtIn.prompt.responsibility)
        overrides.factRule = overrideValue(factEditor.string, default: builtIn.prompt.factRule)
        overrides.outputRule = overrideValue(outputEditor.string, default: builtIn.prompt.outputRule)
        let defaultDirection = builtIn.scene(editingScene)?.direction ?? ""
        overrides.sceneDirections[editingScene.rawValue] = overrideValue(
            sceneEditor.string, default: defaultDirection)
    }

    private func overrideValue(_ value: String, default defaultValue: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == defaultValue ? nil : text
    }

    private func effectivePolicy() -> LocalSpeechPolicy {
        usesCustom ? overrides.applying(to: builtIn) : builtIn
    }

    @objc private func presetChanged() {
        if usesCustom { captureEditors() }
        usesCustom = presetPopup.indexOfSelectedItem == 1
        loadEditors()
        analyzePrompt()
    }

    @objc private func sceneChanged() {
        captureEditors()
        guard let raw = scenePopup.selectedItem?.representedObject as? String,
              let scene = LocalSpeechSceneID(rawValue: raw) else { return }
        editingScene = scene
        loadSceneEditor()
        loadSamplingDefaults()
        analyzePrompt()
    }

    @objc private func characterChanged() { analyzePrompt() }

    @objc private func resetCustom() {
        overrides = .init()
        usesCustom = true
        loadEditors()
        analyzePrompt()
        statusLabel.stringValue = "用户自定义已恢复为内置内容；点击“保存并应用”后生效。"
    }

    @objc private func savePrompt() {
        captureEditors()
        onSave?(usesCustom, overrides)
        statusLabel.stringValue = usesCustom ? "✅ 用户自定义已保存并应用。" : "✅ 已恢复使用内置验证版。"
    }

    @objc private func analyzePrompt() {
        captureEditors()
        let policy = effectivePolicy()
        let profile = BrainProfile.resolved()
        let intent = Self.intent(editingScene)
        let character = selectedCharacter()
        let personality = character.map(Personality.forDefinition) ?? .default
        let prefixMessages = BrainPrefixBuilder.chatPrefixMessages(
            personality: personality, profile: profile, dialogue: character?.dialogue, intent: intent,
            characterName: character?.displayNames.zhHans ?? "未选择角色",
            includeFewShot: fewShotCheckbox.state == .on, policy: policy)
        let user = BrainPrefixBuilder.chatMessage(
            intent: intent, world: Self.previewWorld(), brain: BrainState(),
            personality: personality, confirmedContext: normalizedContext(), policy: policy)
        let sampling = manualSampling()
        analysisView.string = """
        [分析]
        preset=\(usesCustom ? "user-custom" : "builtin-validated")
        character=\(character?.id ?? "none") scene=\(editingScene.rawValue)
        few_shot=\(fewShotCheckbox.state == .on)
        temperature=\(String(format: "%.2f", sampling.temperature)) top_p=\(String(format: "%.2f", sampling.topP)) top_k=\(sampling.topK) max_tokens=\(sampling.maxTokens) seed=\(sampling.seed.map(String.init) ?? "random")
        overrides=\(overrides.isEmpty ? "none" : "active") validation=\(policy.configurationErrors.isEmpty ? "ok" : policy.configurationErrors.joined(separator: ","))

        [PREFIX MESSAGES]
        \(Self.renderPrefix(prefixMessages))

        [CURRENT USER]
        \(user)
        """
    }

    @objc private func testPrompt() {
        captureEditors()
        guard let onTest else {
            statusLabel.stringValue = "❌ Prompt 测试上下文不可用。"
            return
        }
        guard let character = selectedCharacter() else {
            statusLabel.stringValue = "❌ 没有可测试的角色。"
            return
        }
        let policy = effectivePolicy()
        let intent = Self.intent(editingScene)
        let sampling = manualSampling()
        testButton.isEnabled = false
        statusLabel.stringValue = "正在调用本地 Qwen…"
        Task { [weak self] in
            let result = await onTest(
                character, policy, intent, self?.normalizedContext(),
                self?.fewShotCheckbox.state == .on, sampling)
            await MainActor.run {
                guard let self else { return }
                self.testButton.isEnabled = true
                let ms = Int(result.latency * 1_000)
                self.statusLabel.stringValue = result.error.map { "❌ \($0) · \(ms)ms" }
                    ?? "✅ \(ms)ms · 输出已通过运行时校验"
                self.analysisView.string = """
                [RESULT]
                accepted=\(result.output != nil) latency_ms=\(ms)
                error=\(result.error ?? "none")
                few_shot=\(result.includeFewShot)
                temperature=\(String(format: "%.2f", result.sampling.temperature)) top_p=\(String(format: "%.2f", result.sampling.topP)) top_k=\(result.sampling.topK) max_tokens=\(result.sampling.maxTokens) seed=\(result.sampling.seed.map(String.init) ?? "random")

                [PREFIX MESSAGES]
                \(Self.renderPrefix(result.prefixMessages))

                [CURRENT USER]
                \(result.user)

                [ATTEMPTS]
                \(Self.renderAttempts(result))

                [FINAL OUTPUT]
                \(result.output ?? "<rejected; runtime fallback would be used>")
                """
            }
        }
    }

    private func normalizedContext() -> String? {
        let text = contextEditor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }

    private func selectedCharacter() -> CharacterDefinition? {
        guard let id = characterPopup.selectedItem?.representedObject as? String else { return nil }
        return characters.first { $0.id == id }
    }

    private func manualSampling() -> BrainProfile.Sampling {
        let temperature = min(2, max(0, Double(temperatureField.stringValue) ?? defaultSampling.temperature))
        let topP = min(1, max(0, Double(topPField.stringValue) ?? defaultSampling.topP))
        let topK = max(0, Int(topKField.stringValue) ?? defaultSampling.topK)
        let maxTokens = max(1, Int(maxTokensField.stringValue) ?? defaultSampling.maxTokens)
        let seedText = seedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrainProfile.Sampling(
            temperature: temperature, topP: topP, topK: topK,
            maxTokens: maxTokens, seed: seedText.isEmpty ? nil : Int(seedText))
    }

    private static func renderAttempts(_ result: LocalBrain.PromptTestResult) -> String {
        guard !result.attemptOutputs.isEmpty else { return "<no model output>" }
        return result.attemptOutputs.enumerated().map { index, output in
            let reasons = result.rejectionReasons.indices.contains(index)
                ? result.rejectionReasons[index] : []
            return "attempt=\(index + 1) accepted=\(reasons.isEmpty) rejection=\(reasons.isEmpty ? "none" : reasons.joined(separator: ","))\n\(output)"
        }.joined(separator: "\n\n")
    }

    private static func renderPrefix(_ messages: [[String: String]]) -> String {
        messages.enumerated().map { index, message in
            let role = (message["role"] ?? "unknown").uppercased()
            let content = message["content"] ?? ""
            return "[\(index + 1) \(role)]\n\(content.isEmpty ? "<empty prefix boundary>" : content)"
        }.joined(separator: "\n\n")
    }

    private static func intent(_ scene: LocalSpeechSceneID) -> SpeechIntent {
        SpeechIntent(rawValue: scene.rawValue) ?? .chatter
    }

    private static func sceneName(_ scene: LocalSpeechSceneID) -> String {
        switch scene {
        case .greet: "打招呼"
        case .commentActivity: "活动评论"
        case .tease: "调侃"
        case .complain: "抗议"
        case .chatter: "闲聊"
        }
    }

    private static func previewWorld() -> BrainContextSnapshot {
        BrainContextSnapshot(
            capturedAt: 0, activeApp: "当前应用", windowTitle: "", appActivity: "unknown",
            userActivity: "active", focusRole: "", visibleContext: [], salientUI: [],
            nearbyWindows: [], recentEvents: [])
    }
}
