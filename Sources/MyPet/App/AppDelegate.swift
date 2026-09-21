import AppKit
import MyPetContent
import MyPetCore
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
    /// 生产 Cast 的唯一时钟、面板和 Story 身体 owner。
    private var castSession: CastSession?
    /// 发现的全部宠物包（id → 目录），按字母序。
    private var library: [(id: String, url: URL)] = []
    /// 发现的角色组与剧情包；它们独立于单个 petpack，可按设置动态启用。
    private var castPacks: [CastPack] = []
    private var resolvedCastPacks: [ResolvedCastPack] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 日志格式尚未对外发布：每次启动只分析本次会话，避免旧链路污染当前诊断。
        BrainTraceLog.startFreshSession()
        NSApp.setActivationPolicy(.accessory) // 无 Dock 图标（swift run 时兜底 LSUIElement）

        discoverLibrary()
        discoverCastPacks()
        var settings = Settings.load()
        settings.castSelection = settings.castSelection.normalized(availablePacks: castPacks)
        self.settings = settings
        guard !library.isEmpty else { return }

        let tray = Tray(settings: settings)
        self.tray = tray
        wireTray(tray)

        // 优先级：-pet 启动参数 > 上次选择 > 库里第一只。空的 currentPet 视为未选择。
        let saved = settings.currentPet.isEmpty ? nil : settings.currentPet
        let requested = PetPackLibrary.requestedPet() ?? saved ?? library.first?.id
        if settings.castSelection.isRuntimeEnabled, !castPacks.isEmpty {
            startCastRuntime()
        } else {
            activatePet(requested ?? library[0].id)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCastRuntime()
        controller?.stop()
        settings?.save()
    }

    // MARK: 素材库

    /// 汇总所有查找根里的宠物包（按 id 去重：.app 内置包优先于仓库路径）。
    private func discoverLibrary() {
        var seen = Set<String>()
        for root in PetPackLibrary.roots() {
            for entry in PetPackLibrary.availablePacks(in: root) where !seen.contains(entry.id) {
                seen.insert(entry.id)
                library.append(entry)
            }
        }
        if library.isEmpty {
            let alert = NSAlert()
                alert.messageText = "找不到任何宠物素材（petpack）"
                alert.informativeText = "请先运行 desktop/scripts/sync_assets.py 从素材工厂同步素材，或用 MYPET_PETPACK 指向素材库目录。"
            alert.runModal()
            NSApp.terminate(nil)
        } else {
            NSLog("MyPet: 可用宠物 %@", library.map { $0.id }.joined(separator: ", "))
        }
    }

    private func discoverCastPacks() {
        let source = CastPackLibrary.loadAvailable()
        guard let resourcesRoot = CastContentLibrary.roots().first else {
            resolvedCastPacks = []
            castPacks = []
            NSLog("MyPet: 未发现角色内容目录，角色组模式不可用")
            return
        }
        do {
            let catalog = try CastContentLibrary.load(resourcesRoot: resourcesRoot)
            let resolved = try catalog.resolve(source)
            resolvedCastPacks = resolved
            castPacks = resolved.map(\.pack)
        } catch {
            resolvedCastPacks = []
            castPacks = []
            NSLog("MyPet: 角色内容解析失败，拒绝启用未解析 CastPack: %@", String(describing: error))
            return
        }
        if castPacks.isEmpty {
            NSLog("MyPet: 未发现角色组资源，继续使用单宠物模式")
        } else {
            NSLog("MyPet: 可用角色组 %@", castPacks.map { $0.id }.joined(separator: ", "))
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
            let pack = try ClipLibrary.load(from: entry.url)
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
                needle: sharedNeedle,
                localBrain: sharedLocalBrain,
                teacherBrain: sharedTeacherBrain)
            controller = newController
            newController.start()

            NSLog("MyPet: 当前宠物 = %@（%@，%d 个 clip）", id, entry.url.path, pack.clipCount)
            if let tray {
                wireTray(tray)
                tray.updatePets(library.map { $0.id }, current: id)
                tray.updateCastCatalog(castPacks, selection: settings.castSelection)
            }
        } catch {
            NSLog("MyPet: petpack 加载失败 %@ — %@", entry.url.path, error.localizedDescription)
        }
    }

    // MARK: 设置

    private func showSettings() {
        guard let settings else { return }
        if settingsWindow == nil {
            let win = SettingsWindowController(settings: settings, castPacks: castPacks)
            win.onApply = { [weak self] applied in
                self?.applySettings(applied)
            }
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

    private func showBrainLogs() {
        if brainLogWindow == nil {
            brainLogWindow = BrainLogWindowController()
        }
        brainLogWindow?.show()
    }

    /// 设置窗保存 / 菜单开关 共用的落盘 + 热更新路径。
    private func applySettings(_ applied: Settings) {
        var normalized = applied
        normalized.castSelection = normalized.castSelection.normalized(availablePacks: castPacks)
        normalized.storySettings.intervalTicks = max(0, normalized.storySettings.intervalTicks)
        normalized.storySettings.maxDurationTicks = max(1, normalized.storySettings.maxDurationTicks)
        normalized.save()
        settings = normalized
        if normalized.castSelection.isRuntimeEnabled, !castPacks.isEmpty {
            startCastRuntime()
        } else if castSession != nil {
            let fallback = normalized.currentPet.isEmpty ? (library.first?.id ?? "") : normalized.currentPet
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
            library: library,
            castPacks: castPacks,
            resolvedCastPacks: resolvedCastPacks,
            layoutCoordinator: layoutCoordinator,
            perceptionHub: perceptionHub,
            sharedNeedle: sharedNeedle,
            sharedLocalBrain: sharedLocalBrain,
            sharedTeacherBrain: sharedTeacherBrain)
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
        tray.onOpenSettings = { [weak self] in self?.showSettings() }
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
            case .localDecisionBrain:
                settings.localBrainEnabled.toggle()
                if settings.localBrainEnabled, !LocalBrainModel.isInstalled {
                    NSLog("MyPet: 本地决策脑已开启但模型未就位（设置 → 大脑 → 下载 / 校验模型）")
                } else {
                    NSLog("MyPet: 本地决策脑 = %@（可与高阶教师脑并行）",
                          settings.localBrainEnabled ? "开" : "关")
                }
            case .speech:
                settings.speechEnabled.toggle()
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
            }
            self.applySettings(settings)
        }
    }
}
