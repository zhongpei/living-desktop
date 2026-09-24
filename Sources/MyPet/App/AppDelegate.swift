import AppKit
import MyPetContent
import MyPetCore
import MyPetEngine
import MyPetPlatform
import MyPetRender

/// 应用委托：装配 设置 → 素材库 → 控制器 → 菜单栏/设置窗，然后交给主循环。
/// 所有宠物（petpack 库）默认全部打包进 Resources，菜单可随时切换。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var settings: Settings?
    private var controller: PetController?
    private var activeController: PetController? { castSession?.primaryController ?? controller }
    private var tray: Tray?
    private var settingsWindow: SettingsWindowController?
    private var promptManagerWindow: PromptManagerWindowController?
    private var contentManagerWindow: ContentManagerWindowController?
    private var storyLibraryWindow: StoryLibraryWindowController?
    private var contentDiagnostics: [String] = []
    private var brainLogWindow: BrainLogWindowController?
    /// 所有同时可见角色共用，防止各自面板独立摆放造成重叠。
    private let layoutCoordinator = SpatialLayoutCoordinator()
    /// 桌面级 WindowWorld / AX / OCR 只采集一次，再广播给每个角色内核。
    private let perceptionHub = PerceptionHub()
    /// 大脑是进程级资源：多角色共享模型/串行 C API，各角色只共享适配器，
    /// 不共享 BrainContextSnapshot、BrainState 或当前目标。
    private let sharedNeedle = NeedleBrain()
    private let sharedLocalBrain = LocalBrain()
    private let sharedTeacherBrain = TeacherBrain()
    private let speechDirector = SpeechDirector()
    /// 生产 Cast 的唯一时钟、面板和 Story 身体 owner。
    private var castSession: CastSession?
    /// 同一内容目录投影供启动、菜单与 Runtime 消费。
    private var contentRegistry: ContentRegistry?
    private var contentCatalog: PackagedContentCatalog?
    private var library: [PackagedRole] { contentCatalog?.roles ?? [] }
    private var castVisualsByActor: [String: URL] { contentCatalog?.visualsByActor ?? [:] }
    private var castPacks: [CastPack] { contentCatalog?.groups.map(\.pack) ?? [] }
    private var resolvedCastPacks: [ResolvedCastPack] { contentCatalog?.groups ?? [] }
    private var storyPacks: [StoryPack] { contentCatalog?.stories ?? [] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 日志格式尚未对外发布：每次启动只分析本次会话，避免旧链路污染当前诊断。
        BrainTraceLog.startFreshSession()
        NSApp.setActivationPolicy(.accessory) // 无 Dock 图标（swift run 时兜底 LSUIElement）

        discoverContent()
        var settings = Settings.load()
        if let migrated = ManualControlMappingStore().migrate(
            into: settings.gameFeatures.controls) {
            settings.gameFeatures.controls = migrated
            settings.save()
        }
        settings.castSelection = settings.castSelection.normalized(availablePacks: castPacks)
        // 优先级：-pet 启动参数 > 上次选择 > 库里第一只。空的 currentPet 视为未选择。
        let saved = settings.currentPet.isEmpty ? nil : settings.currentPet
        let requested = PetPackLibrary.requestedPet() ?? saved
        let selected = library.contains { $0.id == requested } ? requested : library.first?.id
        if requested != nil && requested != selected {
            NSLog("MyPet: 旧角色选择 %@ 不可用，回退到 %@", requested ?? "", selected ?? "无")
        }
        if settings.currentPet != (selected ?? "") {
            settings.currentPet = selected ?? ""
            settings.save()
        }
        self.settings = settings
        let tray = Tray(settings: settings)
        self.tray = tray
        wireTray(tray)
        tray.updatePets(library.map(\.id), current: settings.currentPet)
        tray.updateCastCatalog(castPacks, selection: settings.castSelection)
        if settings.castSelection.isRuntimeEnabled, !castPacks.isEmpty {
            startCastRuntime()
        } else if let selected {
            activatePet(selected)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCastRuntime()
        controller?.stop()
        settings?.save()
    }

    // MARK: 素材库

    private func discoverContent() {
        contentDiagnostics = []
        let roots = ContentResourceLocator.roots()
        let resourcesRoot = roots.first { root in
            FileManager.default.fileExists(atPath: root.appendingPathComponent("packages").path)
        } ?? roots.first ?? Bundle.main.resourceURL ?? FileManager.default.temporaryDirectory
        guard let support = ProcessInfo.processInfo.environment["MYPET_CONTENT_SUPPORT_PATH"]
            .map({ URL(fileURLWithPath: $0, isDirectory: true) }) ??
            FileManager.default.urls(for: .applicationSupportDirectory,
                                     in: .userDomainMask).first?.appendingPathComponent("LivingDesktop") else { return }
        do {
            let registry: ContentRegistry
            if let existing = contentRegistry {
                existing.refresh()
                registry = existing
            } else {
                registry = try ContentRegistry(
                    builtInDirectory: resourcesRoot.appendingPathComponent("packages"),
                    appSupportDirectory: support)
            }
            contentRegistry = registry
            let catalog = ContentCatalogLoader.load(registry: registry,
                relationshipCatalogURL: resourcesRoot.appendingPathComponent("relationships/catalog.json"))
            contentCatalog = catalog
            contentDiagnostics = catalog.diagnostics
            for diagnostic in catalog.diagnostics { NSLog("MyPet content: %@", diagnostic) }
        } catch {
            NSLog("MyPet: 内容登记不可用：%@", String(describing: error))
        }
        NSLog("MyPet: 包目录角色 %d、角色组 %d、剧情 %d",
              library.count, castPacks.count, storyPacks.count)
    }

    /// All package writes cross this App-owned barrier. The old Runtime and
    /// presentations are retired before Content may remove bytes. A failed
    /// operation rebuilds the old selection from still-installed packages.
    private func changeContent(_ operation: (ContentRegistry) throws -> Bool,
                               afterRetirement: ((ContentRegistry) -> Void)? = nil) throws {
        guard let registry = contentRegistry else { throw ContentRegistry.RegistryError.unavailable }
        // Import, enable/disable and logical removal are transactional while
        // the old extracted content is still alive. Failure leaves this world
        // untouched; only a successful mutation crosses the retirement barrier.
        guard try operation(registry) else { return }
        castSession?.retireForPackageChange()
        castSession = nil
        controller?.stop()
        controller?.closePanel()
        controller = nil
        perceptionHub.ownerID = nil
        contentCatalog = nil
        settingsWindow?.close()
        settingsWindow = nil
        afterRetirement?(registry)
        discoverContent()
        resumeContentSession()
    }

    private func resumeContentSession() {
        guard var settings else { return }
        settings.castSelection = settings.castSelection.normalized(availablePacks: castPacks)
        settings.currentPet = library.first(where: { $0.id == settings.currentPet })?.id
            ?? library.first?.id ?? ""
        self.settings = settings
        settings.save()
        tray?.updatePets(library.map(\.id), current: settings.currentPet)
        tray?.updateCastCatalog(castPacks, selection: settings.castSelection)
        if settings.castSelection.isRuntimeEnabled && !castPacks.isEmpty {
            startCastRuntime()
        } else if let selected = library.first(where: { $0.id == settings.currentPet })?.id
                    ?? library.first?.id {
            activatePet(selected)
        }
    }

    func importContentPackages(at urls: [URL], confirmUpdate: Bool) throws -> ContentRegistry.ImportResult {
        var result: ContentRegistry.ImportResult?
        try changeContent { registry in
            result = registry.importPackages(at: urls, confirmUpdate: confirmUpdate)
            return !(result?.imported.isEmpty ?? true)
        }
        guard let result else { throw ContentRegistry.RegistryError.unavailable }
        return result
    }

    func setContentPackageEnabled(_ enabled: Bool, kind: ContentPackageKind, id: String) throws {
        try changeContent { registry in
            try registry.setEnabled(enabled, kind: kind, id: id)
            return true
        }
    }

    func removeContentPackage(kind: ContentPackageKind, id: String) throws {
        var retired: URL?
        try changeContent { registry in
            retired = try registry.removeUserPackage(kind: kind, id: id)
            return true
        } afterRetirement: { registry in
            do {
                try registry.purgeCache(kind: kind, id: id, source: .user)
                if let retired { try registry.finalizeRemoval(at: retired) }
            } catch {
                NSLog("MyPet: 内容已退出会话，旧缓存/归档清理待重试：%@", String(describing: error))
            }
        }
    }

    func removeCorruptContentPackage(at url: URL) throws {
        var retired: URL?
        try changeContent { registry in
            retired = try registry.removeCorruptUserPackage(at: url)
            return true
        } afterRetirement: { registry in
            if let retired {
                do { try registry.finalizeRemoval(at: retired) }
                catch { NSLog("MyPet: 损坏包已退出目录，归档清理待重试：%@", String(describing: error)) }
            }
        }
    }

    /// 激活一只宠物：加载素材、原地重建控制器（旧宠物位置保留）、刷新菜单勾选。
    /// 启动和菜单切换共用这一条路径。
    func activatePet(_ id: String) {
        guard var settings else { return }
        guard let entry = library.first(where: { $0.id == id }) else {
            NSLog("MyPet: 找不到宠物素材包 %@", id)
            return
        }
        do {
            let pack = try ClipLibrary.load(from: entry.visualURL)
            for warning in pack.warnings { NSLog("MyPet petpack: %@", warning) }

            settings.currentPet = id
            settings.save()
            self.settings = settings

            let spawn = activeController?.petPosition
            stopCastRuntime()
            controller?.stop()
            controller?.closePanel()
            perceptionHub.ownerID = EntityID(id)
            let newController = PetController(
                library: pack,
                settings: settings,
                spawnAt: spawn,
                layoutCoordinator: layoutCoordinator,
                perceptionHub: perceptionHub,
                characterDefinition: entry.definition,
                speechDirector: speechDirector,
                needle: sharedNeedle,
                localBrain: sharedLocalBrain,
                teacherBrain: sharedTeacherBrain)
            controller = newController
            newController.start()

            NSLog("MyPet: 当前宠物 = %@（%@，%d 个 clip）", id, entry.visualURL.path, pack.clipCount)
            if let tray {
                wireTray(tray)
                tray.updatePets(library.map { $0.id }, current: id)
                tray.updateCastCatalog(castPacks, selection: settings.castSelection)
            }
        } catch {
            NSLog("MyPet: petpack 加载失败 %@ — %@", entry.visualURL.path, error.localizedDescription)
        }
    }

    // MARK: 设置

    private func showSettings() {
        guard let settings else { return }
        // A closed settings window retains its old draft; reopen from the latest saved settings.
        if settingsWindow?.window?.isVisible != true {
            let win = SettingsWindowController(
                settings: settings,
                castPacks: castPacks,
                characters: library.compactMap(\.definition))
            win.onApply = { [weak self] applied in
                guard let self else { return }
                var merged = applied
                // Prompt 管理器是独立窗口；普通设置窗不编辑这两项，不能用旧草稿覆盖它。
                if let current = self.settings {
                    merged.localSpeechPromptUsesCustom = current.localSpeechPromptUsesCustom
                    merged.localSpeechPromptOverrides = current.localSpeechPromptOverrides
                }
                self.applySettings(merged)
            }
            win.onOpenContentManager = { [weak self] in self?.showContentManager() }
            win.onOpenStoryLibrary = { [weak self] in self?.showStoryLibrary() }
            // 拖动滑杆的实时预览：热更新所有可见控制器，不落盘、不刷菜单。
            win.onPreview = { [weak self] preview in
                self?.updateVisibleControllers(preview)
            }
            win.localChatTester = { [weak self] in
                guard let controller = self?.activeController else {
                    return LocalBrain.ChatTestResult(
                        text: nil, emotion: nil, latency: 0,
                        error: "宠物控制器未就绪")
                }
                return await controller.localBrain.testChat(personality: controller.personality)
            }
            settingsWindow = win
        }
        settingsWindow?.show()
    }

    private func showPromptManager() {
        guard let settings else { return }
        promptManagerWindow?.close()
        let definitions = Dictionary(
            (library.map(\.definition) + resolvedCastPacks.flatMap { $0.characters.values })
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }).values.map { $0 }
        let manager = PromptManagerWindowController(
            settings: settings, characters: definitions,
            currentCharacterID: settings.currentPet)
        manager.onSave = { [weak self] usesCustom, overrides in
            guard let self, var updated = self.settings else { return }
            updated.localSpeechPromptUsesCustom = usesCustom
            updated.localSpeechPromptOverrides = overrides
            self.applySettings(updated)
        }
        manager.onTest = { [weak self] character, policy, intent, context, includeFewShot, sampling in
            guard let self else {
                return LocalBrain.PromptTestResult(
                    prefixMessages: [], system: "", user: "", output: nil, attemptOutputs: [],
                    rejectionReasons: [], includeFewShot: includeFewShot,
                    sampling: sampling, latency: 0,
                    error: "Prompt 测试上下文不可用")
            }
            return await self.sharedLocalBrain.testPrompt(
                personality: Personality.forDefinition(character),
                characterID: character.id, characterName: character.displayNames.zhHans,
                dialogue: character.dialogue, intent: intent,
                confirmedContext: context, includeFewShot: includeFewShot,
                policy: policy, sampling: sampling)
        }
        promptManagerWindow = manager
        manager.show()
    }

    private func showStoryLibrary() {
        // Rebuild from the current catalog; package changes never mutate an open viewer.
        storyLibraryWindow?.close()
        let viewer = StoryLibraryWindowController(stories: storyPacks, groups: castPacks)
        storyLibraryWindow = viewer
        viewer.show()
    }

    private func showContentManager() {
        if contentManagerWindow == nil {
            let manager = ContentManagerWindowController()
            manager.records = { [weak self] in self?.contentRegistry?.list() ?? [] }
            manager.diagnostics = { [weak self] in self?.contentDiagnostics ?? [] }
            manager.onImport = { [weak self] urls, confirm in
                guard let self else { throw ContentRegistry.RegistryError.unavailable }
                return try self.importContentPackages(at: urls, confirmUpdate: confirm)
            }
            manager.onSetEnabled = { [weak self] enabled, kind, id in
                guard let self else { throw ContentRegistry.RegistryError.unavailable }
                try self.setContentPackageEnabled(enabled, kind: kind, id: id)
            }
            manager.onRemove = { [weak self] record in
                guard let self else { throw ContentRegistry.RegistryError.unavailable }
                if let manifest = record.manifest {
                    try self.removeContentPackage(kind: manifest.kind, id: manifest.id)
                } else {
                    try self.removeCorruptContentPackage(at: record.url)
                }
            }
            contentManagerWindow = manager
        }
        contentManagerWindow?.show()
    }

    private func showBrainLogs() {
        if brainLogWindow == nil {
            brainLogWindow = BrainLogWindowController()
        }
        brainLogWindow?.show()
    }

    /// 设置窗保存 / 菜单开关 共用的落盘 + 热更新路径。
    private func applySettings(_ applied: Settings, pointerOnly: Bool = false) {
        var normalized = applied
        normalized.castSelection = normalized.castSelection.normalized(availablePacks: castPacks)
        normalized.storySettings.intervalTicks = max(0, normalized.storySettings.intervalTicks)
        normalized.storySettings.maxDurationTicks = max(1, normalized.storySettings.maxDurationTicks)
        if ![20, 40, 60].contains(normalized.pointerInputHz) { normalized.pointerInputHz = 20 }
        normalized.save()
        settings = normalized
        if pointerOnly, let castSession {
            castSession.updateSettings(normalized)
        } else if normalized.castSelection.isRuntimeEnabled, !castPacks.isEmpty {
            startCastRuntime()
        } else if castSession != nil {
            let fallback = library.first(where: { $0.id == normalized.currentPet })?.id
                ?? library.first?.id ?? ""
            stopCastRuntime()
            if !fallback.isEmpty { activatePet(fallback) }
        } else {
            controller?.updateSettings(normalized)
        }
        tray?.updateSettings(normalized)
    }

    private func updateVisibleControllers(_ settings: Settings) {
        if let castSession {
            castSession.updateSettings(settings)
        } else {
            controller?.updateSettings(settings)
        }
    }

    // MARK: 角色组运行时

    private func startCastRuntime() {
        guard settings != nil, !castPacks.isEmpty else { return }
        if castSession == nil, let old = controller {
            old.stop()
            old.closePanel()
            controller = nil
        }
        castSession?.stop()
        let session = CastSession(
            settingsProvider: { [weak self] in self?.settings },
            visualsByActor: castVisualsByActor,
            castPacks: castPacks,
            resolvedCastPacks: resolvedCastPacks,
            storyPacks: storyPacks,
            layoutCoordinator: layoutCoordinator,
            perceptionHub: perceptionHub,
            sharedNeedle: sharedNeedle,
            sharedLocalBrain: sharedLocalBrain,
            sharedTeacherBrain: sharedTeacherBrain,
            speechDirector: speechDirector)
        session.onSync = { [weak self] activeIDs in
            guard let self, let settings = self.settings else { return }
            self.tray?.updatePets(self.library.map { $0.id }, current: settings.currentPet)
            self.tray?.updateCastCatalog(
                self.castPacks, selection: settings.castSelection, activeMemberIDs: activeIDs)
        }
        castSession = session
        session.start()
    }

    private func stopCastRuntime() {
        guard let session = castSession else { return }
        session.stop()
        castSession = nil
        perceptionHub.ownerID = nil
    }

    // MARK: 菜单接线

    private func wireTray(_ tray: Tray) {
        tray.onSummonProp = { [weak self] id, placed in
            self?.activeController?.summonProp(id, placed: placed)
        }
        tray.onQuit = { NSApp.terminate(nil) }
        tray.onCastSelectionChange = { [weak self] selection in
            guard let self, var settings = self.settings else { return }
            settings.castSelection = selection.normalized(availablePacks: self.castPacks)
            self.applySettings(settings)
        }
        tray.onCastInvite = { [weak self] memberID in
            guard let self, var settings = self.settings else { return }
            guard let session = self.castSession else {
                settings.castSelection.allMembersEnabled = false
                settings.castSelection.enabledMemberIDs = [memberID]
                settings.castSelection.maxActiveMembers = 1
                settings.castSelection.automaticArrivalsEnabled = true
                settings.castSelection.invitationsEnabled = true
                self.applySettings(settings)
                return
            }
            if session.activeMemberIDs.count >= settings.castSelection.maxActiveMembers {
                settings.castSelection.maxActiveMembers += 1
                settings.save()
                self.settings = settings
                session.expandCapacity(to: settings.castSelection.maxActiveMembers)
                self.tray?.updateSettings(settings)
            }
            if session.inviteManually(memberID: memberID) {
                NSLog("MyPet: 已排队手动入场角色 %@", memberID)
            } else {
                NSLog("MyPet: 手动入场角色 %@ 被状态或同时人数上限拒绝", memberID)
            }
        }
        tray.onSummonAllCast = { [weak self] in
            guard let self, var settings = self.settings else { return }
            let visualCharacters = self.castPacks
                .flatMap(\.members)
                .filter { $0.kind == .character && $0.visualPackID != nil }
            let uniqueIDs = Array(Set(visualCharacters.map(\.id))).sorted()
            guard !uniqueIDs.isEmpty else { return }
            settings.castSelection.maxActiveMembers = uniqueIDs.count
            if let session = self.castSession {
                settings.save()
                self.settings = settings
                session.expandCapacity(to: uniqueIDs.count)
                for id in uniqueIDs where !session.activeMemberIDs.contains(id) {
                    _ = session.inviteManually(memberID: id)
                }
                self.tray?.updateSettings(settings)
            } else {
                settings.castSelection.allMembersEnabled = false
                settings.castSelection.enabledMemberIDs = uniqueIDs
                settings.castSelection.automaticArrivalsEnabled = true
                self.applySettings(settings)
            }
        }
        tray.onCastDepart = { [weak self] memberID in
            _ = self?.castSession?.depart(memberID: memberID)
        }
        tray.onSingleRoleExit = { [weak self] in
            guard let self else { return }
            self.controller?.stop()
            self.controller?.closePanel()
            self.controller = nil
            self.perceptionHub.ownerID = nil
            self.tray?.updatePets(self.library.map { $0.id }, current: "")
        }
        tray.onInputPluginToggle = { [weak self] pluginID in
            guard let self, var settings = self.settings else { return }
            let enabled = !settings.inputPlugins.isEnabled(pluginID)
            settings.inputPlugins.setEnabled(enabled, for: pluginID)
            // 旧菜单/旧设置键镜像两个权限型插件，方便无迁移的旧调用方。
            settings.sensesEnabled = settings.inputPlugins.isEnabled("accessibility")
            settings.ocrEnabled = settings.inputPlugins.isEnabled("ocr")
            if pluginID == "accessibility", enabled, !WindowPuller.isTrusted() {
                self.tray?.showAccessibilityPrompt()
            }
            if pluginID == "ocr", enabled, !OCRSensor.permissionGranted {
                OCRSensor.requestPermission()
                self.tray?.openScreenRecordingPrompt()
            }
            self.applySettings(settings)
        }
        tray.onPointerInputToggle = { [weak self] in
            guard let self, var settings = self.settings else { return }
            settings.pointerInputEnabled.toggle()
            self.applySettings(settings, pointerOnly: true)
        }
        tray.onPointerInputRateChange = { [weak self] hz in
            guard let self, var settings = self.settings,
                  [20, 40, 60].contains(hz) else { return }
            settings.pointerInputHz = hz
            self.applySettings(settings, pointerOnly: true)
        }
        tray.onOpenSettings = { [weak self] in self?.showSettings() }
        tray.onOpenPromptManager = { [weak self] in self?.showPromptManager() }
        tray.onOpenContentManager = { [weak self] in self?.showContentManager() }
        tray.onOpenLogs = { [weak self] in self?.showBrainLogs() }
        tray.brainAvailable = NeedleBrain.modelURL() != nil
        tray.statusLines = { [weak self] in
            guard let self, let c = self.activeController else { return [] }
            let r = c.statusReport()
            return ["角色：\(r.pet)", "目标：\(r.goal)", "场景：\(r.scene)",
                    r.needs, r.brains, "最近一句话：\(r.lastSpeech)"]
        }

        tray.onToggle = { [weak self] toggle in
            guard let self, var settings = self.settings else { return }
            switch toggle {
            case .perching:
                settings.perchingEnabled.toggle()
            case .foregroundFollow:
                settings.foregroundFollow.toggle()
            case .windowPull:
                settings.windowPullEnabled.toggle()
                if settings.windowPullEnabled, !WindowPuller.isTrusted() {
                    self.tray?.showAccessibilityPrompt()
                }
            case .launchAtLogin:
                settings.setLaunchAtLogin(!settings.launchAtLogin)
            case .actionBrain:
                settings.actionBrainEnabled.toggle()
                NSLog("MyPet: 行动脑 = %@（Needle 3 / 内置场景兜底）",
                      settings.actionBrainEnabled ? "Needle 3" : "关闭")
            case .teacherBrain:
                settings.teacherBrainEnabled.toggle()
                if settings.teacherBrainEnabled,
                   TeacherBrain.config(settingsBaseURL: settings.teacherBrainBaseURL,
                                       settingsModel: settings.teacherBrainModel,
                                       settingsKey: settings.teacherBrainAPIKey) == nil {
                    NSLog("MyPet: 高阶教师脑已开启但端点未配置，请在设置→大脑里探测并选择模型")
                } else {
                    NSLog("MyPet: 高阶教师脑 = %@", settings.teacherBrainEnabled ? "开" : "关闭")
                }
            case .localPersonaSpeech:
                settings.localBrainSpeechEnabled.toggle()
                if settings.localBrainSpeechEnabled, !LocalBrainModel.isInstalled {
                    NSLog("MyPet: 人物台词已开启但本地模型未就位（设置 → 大脑 → 下载 / 校验模型）")
                } else {
                    NSLog("MyPet: 人物台词 = %@", settings.localBrainSpeechEnabled ? "开" : "关")
                }
            case .localDecisionBrain:
                settings.localBrainEnabled.toggle()
                if settings.localBrainEnabled, !LocalBrainModel.isInstalled {
                    NSLog("MyPet: 目标决策已开启但本地模型未就位（设置 → 大脑 → 下载 / 校验模型）")
                } else {
                    NSLog("MyPet: 目标决策 = %@（实验，可与高阶教师脑并行）",
                          settings.localBrainEnabled ? "开" : "关")
                }
            case .speech:
                settings.speechEnabled.toggle()
            case .voicePlayback:
                settings.voicePlaybackEnabled.toggle()
            case .scenes:
                settings.scenesEnabled.toggle()
            case .props:
                settings.propsEnabled.toggle()
            case .senses:
                settings.sensesEnabled.toggle()
                settings.inputPlugins.setEnabled(settings.sensesEnabled, for: "accessibility")
                if settings.sensesEnabled, !WindowPuller.isTrusted() {
                    self.tray?.showAccessibilityPrompt()
                }
            case .ocr:
                settings.ocrEnabled.toggle()
                settings.inputPlugins.setEnabled(settings.ocrEnabled, for: "ocr")
                if settings.ocrEnabled, !OCRSensor.permissionGranted {
                    OCRSensor.requestPermission()
                    self.tray?.openScreenRecordingPrompt()
                }
            case .gameEnabled:
                settings.gameFeatures.enabled.toggle()
            case .automaticCombat:
                settings.gameFeatures.automaticCombatEnabled.toggle()
            case .combatHUD:
                settings.gameFeatures.combatHUDEnabled.toggle()
            case .neutralNPC:
                settings.gameFeatures.neutralNPC.enabled.toggle()
            case .automaticCadence:
                settings.gameFeatures.cadence.enabled.toggle()
            }
            self.applySettings(settings)
        }
    }
}
