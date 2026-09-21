import AppKit
import MyPetCore

/// 应用委托：装配 设置 → 素材库 → 控制器 → 菜单栏/设置窗，然后交给主循环。
/// 所有宠物（petpack 库）默认全部打包进 Resources，菜单可随时切换。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var settings: Settings?
    private var controller: PetController?
    private var tray: Tray?
    private var settingsWindow: SettingsWindowController?
    private var brainLogWindow: BrainLogWindowController?
    /// 所有同时可见角色共用，防止各自面板独立摆放造成重叠。
    private let layoutCoordinator = SpatialLayoutCoordinator()
    /// 桌面级 WindowWorld / AX / OCR 只采集一次，再广播给每个角色内核。
    private let perceptionHub = PerceptionHub()
    /// 大脑是进程级资源：多角色共享模型/串行 C API，各角色只共享适配器，
    /// 不共享 WorldState、BrainState 或当前目标。
    private let sharedNeedle = NeedleBrain()
    private let sharedLocalBrain = LocalBrain()
    private let sharedTeacherBrain = TeacherBrain()
    /// 角色组的事件时钟与面板集合；面板只跟随 Core 已确认的 alive 状态。
    private var castRuntime: CastRuntime?
    private var castControllers: [String: PetController] = [:]
    /// Cast controllers share one SceneGraph so actor/hand/prop reparenting
    /// has one spatial tree instead of one local tree per panel.
    private let castSceneGraph = SceneGraph(rootID: "cast-scene")
    /// CastPack 道具的独立表现面板；生命周期仍由 CastRuntime 决定。
    private var castPropOverlays: [String: CastPropOverlay] = [:]
    /// 专属机甲 sprite 尚未入库时的确定性几何降级层。
    private var castMechOverlays: [String: CastMechOverlay] = [:]
    private var castTimer: Timer?
    /// Core 已确认离场后，渲染面板保留到 transition plan 完成。
    private var castDepartureDeadlines: [String: Int64] = [:]
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

            let spawn = controller?.petPosition
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
                guard let controller = self?.controller else {
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
            if castRuntime == nil {
                startCastRuntime()
            } else {
                rebuildCastRuntime()
            }
        } else if castRuntime != nil {
            let fallback = normalized.currentPet.isEmpty ? (library.first?.id ?? "") : normalized.currentPet
            stopCastRuntime()
            if !fallback.isEmpty { activatePet(fallback) }
        } else {
            controller?.updateSettings(normalized)
        }
        tray?.updateSettings(normalized)
    }

    private func updateVisibleControllers(_ settings: Settings) {
        controller?.updateSettings(settings)
        for pet in castControllers.values where pet !== controller {
            pet.updateSettings(settings)
        }
    }

    // MARK: 角色组运行时

    private func startCastRuntime() {
        guard let settings, !castPacks.isEmpty else { return }
        if castRuntime == nil, let old = controller {
            old.stop()
            old.closePanel()
        }
        stopCastRuntime()

        let runtime: CastRuntime
        if !resolvedCastPacks.isEmpty {
            runtime = CastRuntime(
                resolvedPacks: resolvedCastPacks,
                selection: settings.castSelection,
                seed: UInt64(Date().timeIntervalSince1970),
                storyConfiguration: settings.storySettings.coreConfiguration)
        } else {
            runtime = CastRuntime(
                packs: castPacks,
                selection: settings.castSelection,
                seed: UInt64(Date().timeIntervalSince1970),
                storyConfiguration: settings.storySettings.coreConfiguration)
        }
        castRuntime = runtime
        _ = runtime.start()
        _ = runtime.tick()
        syncCastControllers()

        let timer = Timer(timeInterval: 1.0 / 40.0, target: self,
                          selector: #selector(tickCastRuntime), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        castTimer = timer
    }

    private func rebuildCastRuntime() {
        guard castRuntime != nil else {
            startCastRuntime()
            return
        }
        startCastRuntime()
    }

    private func stopCastRuntime() {
        let wasCastActive = castRuntime != nil || !castControllers.isEmpty
        castTimer?.invalidate()
        castTimer = nil
        for pet in castControllers.values {
            pet.stop()
            pet.closePanel()
        }
        castControllers.removeAll()
        castSceneGraph.removeAll()
        for overlay in castPropOverlays.values { overlay.close() }
        castPropOverlays.removeAll()
        for overlay in castMechOverlays.values { overlay.close() }
        castMechOverlays.removeAll()
        castDepartureDeadlines.removeAll()
        castRuntime = nil
        if wasCastActive {
            controller = nil
            perceptionHub.ownerID = nil
        }
    }

    @objc private func tickCastRuntime() {
        guard let runtime = castRuntime else { return }
        _ = runtime.tick()
        syncCastControllers()
    }

    private func syncCastControllers() {
        guard let settings, let runtime = castRuntime else { return }
        let activeIDs = Set(runtime.activeMemberIDs)
        let nowTick = runtime.kernel.clock.tick

        // 离场与入场都经过 Core 统一的表现计划。角色可能在过渡窗口内
        // 被重新邀请；此时取消收起，继续使用原来的面板实例。
        for id in activeIDs {
            if castDepartureDeadlines.removeValue(forKey: id) != nil {
                castControllers[id]?.cancelCastDeparture()
            }
        }
        for id in Array(castControllers.keys) where !activeIDs.contains(id) {
            guard let pet = castControllers[id] else { continue }
            if castDepartureDeadlines[id] == nil {
                let style = runtime.director.member(id)?.arrivalStyle
                pet.playDeparture(style: style)
                let duration = runtime.director.transitionPlan(
                    for: id, phase: .departure)?.durationTicks
                    ?? CastTransitionPlan.departure(for: style).durationTicks
                castDepartureDeadlines[id] = nowTick + duration
            }
            guard nowTick >= (castDepartureDeadlines[id] ?? nowTick + 1) else { continue }
            pet.stop()
            pet.closePanel()
            castControllers.removeValue(forKey: id)
            castDepartureDeadlines.removeValue(forKey: id)
        }

        let orderedIDs = runtime.activeMemberIDs.sorted()
        let renderableIDs = orderedIDs.filter { id in
            guard let member = runtime.director.member(id),
                  let visualID = member.visualPackID else { return false }
            return library.contains { $0.id == visualID }
        }
        perceptionHub.ownerID = renderableIDs.first.map(EntityID.init)
        for (index, id) in orderedIDs.enumerated() {
            guard castControllers[id] == nil,
                  let member = runtime.director.member(id),
                  let visualID = member.visualPackID,
                  let entry = library.first(where: { $0.id == visualID }) else {
                if let member = runtime.director.member(id), member.visualPackID == nil {
                    NSLog("MyPet: 角色 %@ 已入场，但没有 visualPackID，暂不创建面板", member.id)
                } else if let member = runtime.director.member(id) {
                    NSLog("MyPet: 角色 %@ 的视觉包 %@ 不存在，暂不创建面板", member.id, member.visualPackID ?? "")
                }
                continue
            }
            do {
                let pack = try ClipLibrary.load(from: entry.url)
                let spawn = castSpawn(index: index, count: max(orderedIDs.count, 1))
                let pet = PetController(
                    library: pack,
                    settings: settings,
                    spawnAt: spawn,
                    actorID: EntityID(id),
                    layoutCoordinator: layoutCoordinator,
                    perceptionHub: perceptionHub,
                    gameplayKernel: runtime.kernel,
                    sceneGraph: castSceneGraph,
                    characterDefinition: runtime.characterDefinition(for: id),
                    capabilities: member.capabilities,
                    needle: sharedNeedle,
                    localBrain: sharedLocalBrain,
                    teacherBrain: sharedTeacherBrain)
                castControllers[id] = pet
                pet.playArrival(style: member.arrivalStyle)
                pet.start()
            } catch {
                NSLog("MyPet: 角色 %@ 的视觉包加载失败 %@ — %@", id, entry.url.path, error.localizedDescription)
            }
        }

        // 第二个角色入场会重新分配第一个角色的安全框；逐个回写 AppKit 面板。
        for pet in castControllers.values { pet.relayout() }

        let castLayout = syncCastPropOverlays(runtime: runtime, settings: settings)
        syncCastCharacterFrames(layout: castLayout)
        syncCastMechOverlays(runtime: runtime, layout: castLayout)
        let targetFrames = Dictionary(uniqueKeysWithValues: castLayout.entities.compactMap { entity -> (String, LayoutRect)? in
            guard let frame = entity.frame, entity.renderable else { return nil }
            return (entity.id.raw, frame)
        })

        // StoryDirector 的节拍在 Core 中先完成全员行为确认，再把一次性的
        // 语义动作交给各自身体。没有视觉包的道具/机甲仍可参与规则和关系，
        // 这里只跳过它们的渲染，不影响剧情提交。
        for action in runtime.consumeStoryActions() {
            let targetX = action.targetID.flatMap { targetFrames[$0] }
                .map { CGFloat($0.x + $0.width / 2) }
            castControllers[action.actorID.raw]?.performStoryIntent(
                action.intent, targetX: targetX)
        }

        // A hand-off is a presentation cue emitted by Core at the successful
        // release boundary. It animates from the currently projected prop to
        // the receiver's shared attachment geometry; it never edits a slot or
        // a SceneGraph parent in AppKit.
        let now = ProcessInfo.processInfo.systemUptime
        for event in runtime.consumeStoryHandoffEvents() {
            guard let overlay = castPropOverlays[event.handoff.propID],
                  let from = targetFrames[event.handoff.propID],
                  let toActor = targetFrames[event.handoff.toActorID] else { continue }
            overlay.beginHandoff(
                from: from,
                toActorFrame: toActor,
                now: now,
                durationTicks: event.handoff.durationTicks)
        }

        // 逻辑上可以在场但没有 visualPackID 的机甲/道具不能轮询桌面感知；
        // owner 必须始终落在真正可见的角色上，否则内容事件会被“隐形”实体消费。
        perceptionHub.ownerID = renderableIDs.first.map(EntityID.init)
        controller = activeIDs.sorted().compactMap { castControllers[$0] }.first
        tray?.updatePets(library.map { $0.id }, current: settings.currentPet)
        tray?.updateCastCatalog(
            castPacks,
            selection: settings.castSelection,
            activeMemberIDs: runtime.activeMemberIDs)
    }

    /// 把 Core 的 CastVisualProjection 接入真实工作区。道具是独立浮层，
    /// 不借用某个角色的 PropController，避免“角色走开后道具跟着走”的错误。
    private func syncCastPropOverlays(
        runtime: CastRuntime,
        settings: Settings
    ) -> CastLayoutSnapshot {
        let work = Screens.workBox(containing: .zero)
        let bounds = LayoutRect(
            x: Double(work.left), y: Double(work.top),
            width: Double(work.width), height: Double(work.height))
        let actorHeight = Double(settings.displayHeight)
        let actorSizes = Dictionary(uniqueKeysWithValues: castControllers.compactMap {
            id, controller -> (String, CastVisualSize)? in
            let cell = controller.library.cellSize
            guard cell.width > 0, cell.height > 0 else { return nil }
            return (
                id,
                CastVisualSize(
                    width: Double(cell.width / cell.height) * actorHeight,
                    height: actorHeight))
        })
        let projection = CastVisualProjection.project(
            runtime: runtime,
            in: bounds,
            actorHeight: actorHeight,
            actorSizes: actorSizes,
            renderableMemberIDs: Set(castControllers.keys))

        guard settings.propsEnabled else {
            for overlay in castPropOverlays.values { overlay.close() }
            castPropOverlays.removeAll()
            return projection
        }
        let visibleProps = Dictionary(uniqueKeysWithValues: projection.entities
            .filter { $0.kind == .prop && $0.renderable }
            .compactMap { entity -> (String, LayoutRect)? in
                guard let frame = entity.frame else { return nil }
                return (entity.id.raw, frame)
            })
        let activeProps = Dictionary(uniqueKeysWithValues: runtime.activeProps.map { ($0.id, $0) })

        for id in Array(castPropOverlays.keys) where visibleProps[id] == nil || activeProps[id] == nil {
            castPropOverlays.removeValue(forKey: id)?.close()
        }
        for (id, frame) in visibleProps {
            guard let prop = activeProps[id] else { continue }
            if castPropOverlays[id] == nil {
                castPropOverlays[id] = CastPropOverlay(prop: prop)
            }
            castPropOverlays[id]?.update(frame: frame, now: ProcessInfo.processInfo.systemUptime)
        }
        return projection
    }

    /// All visible cast characters, including attached pilots and social
    /// contacts, consume the same frame that drives prop/mech overlays.
    private func syncCastCharacterFrames(layout: CastLayoutSnapshot) {
        let frames = Dictionary(uniqueKeysWithValues: layout.entities.compactMap {
            entity -> (String, LayoutRect)? in
            guard entity.kind == .actor, entity.renderable, let frame = entity.frame else { return nil }
            return (entity.id.raw, frame)
        })
        for (id, pet) in castControllers {
            pet.applyCastProjectionFrame(frames[id])
        }
    }

    private func syncCastMechOverlays(
        runtime: CastRuntime,
        layout: CastLayoutSnapshot
    ) {
        let visibleMechs = Dictionary(uniqueKeysWithValues: layout.entities.compactMap {
            entity -> (String, CastVisualEntity)? in
            guard entity.kind == .mech,
                  entity.visualPackID == nil,
                  entity.renderable,
                  entity.frame != nil else { return nil }
            return (entity.id.raw, entity)
        })
        for id in Array(castMechOverlays.keys) where visibleMechs[id] == nil {
            castMechOverlays.removeValue(forKey: id)?.close()
        }
        for (id, entity) in visibleMechs {
            guard let member = runtime.director.member(id), let frame = entity.frame else { continue }
            if castMechOverlays[id] == nil {
                castMechOverlays[id] = CastMechOverlay(member: member)
            }
            let pilotName = layout.entities.first {
                $0.kind == .actor && $0.attachedToID?.raw == id
            }?.displayName
            castMechOverlays[id]?.update(frame: frame, pilotName: pilotName)
        }
    }

    private func castSpawn(index: Int, count: Int) -> CGPoint {
        let work = Screens.workBox(containing: .zero)
        let fraction = CGFloat(index + 1) / CGFloat(count + 1)
        let x = work.left + work.width * fraction
        return CGPoint(x: x, y: work.bottom - (settings?.displayHeight ?? 110))
    }

    // MARK: 菜单接线

    private func wireTray(_ tray: Tray) {
        tray.onSummonProp = { [weak self] id, placed in
            self?.controller?.summonProp(id, placed: placed)
        }
        tray.onQuit = { NSApp.terminate(nil) }
        tray.onCastSelectionChange = { [weak self] selection in
            guard let self, var settings = self.settings else { return }
            settings.castSelection = selection.normalized(availablePacks: self.castPacks)
            self.applySettings(settings)
        }
        tray.onCastInvite = { [weak self] memberID in
            guard let self, var settings = self.settings else { return }
            guard let runtime = self.castRuntime else {
                settings.castSelection.allMembersEnabled = false
                settings.castSelection.enabledMemberIDs = [memberID]
                settings.castSelection.maxActiveMembers = 1
                settings.castSelection.automaticArrivalsEnabled = true
                settings.castSelection.invitationsEnabled = true
                self.applySettings(settings)
                return
            }
            if runtime.activeMemberIDs.count >= settings.castSelection.maxActiveMembers {
                settings.castSelection.maxActiveMembers += 1
                settings.save()
                self.settings = settings
                runtime.expandCapacity(to: settings.castSelection.maxActiveMembers)
                self.tray?.updateSettings(settings)
            }
            if runtime.inviteManually(memberID: memberID) {
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
            if let runtime = self.castRuntime {
                settings.save()
                self.settings = settings
                runtime.expandCapacity(to: uniqueIDs.count)
                for id in uniqueIDs where !runtime.activeMemberIDs.contains(id) {
                    _ = runtime.inviteManually(memberID: id)
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
            _ = self?.castRuntime?.depart(memberID: memberID)
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
            guard let self, let c = self.controller else { return [] }
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
