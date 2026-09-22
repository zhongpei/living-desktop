import AppKit
import MyPetContent
import MyPetCore
import MyPetEngine
import MyPetRender

/// Owns the production Cast clock, body consumption, and AppKit projections.
/// AppDelegate supplies shared dependencies but never ticks this session.
@MainActor
final class CastSession: NSObject {
    private let settingsProvider: () -> Settings?
    private var settings: Settings? { settingsProvider() }
    private let visualsByActor: [String: URL]
    private let castPacks: [CastPack]
    private let resolvedCastPacks: [ResolvedCastPack]
    private let storyPacks: [StoryPack]
    private let layoutCoordinator: SpatialLayoutCoordinator
    private let perceptionHub: PerceptionHub
    private let sharedNeedle: NeedleBrain
    private let sharedLocalBrain: LocalBrain
    private let sharedTeacherBrain: TeacherBrain
    private var castRuntime: CastRuntime?
    private var castControllers: [String: PetController] = [:]
    private let castSceneGraph = SceneGraph(rootID: "cast-scene")
    private let castOverlays = CastOverlayPresentation()
    private var castTimer: Timer?
    private var castFrameClock: FixedStepClock?
    private var lastCastFrameAt = ProcessInfo.processInfo.systemUptime
    private var castDepartureDeadlines: [String: Int64] = [:]
    private var reportedMissingCastVisuals = Set<String>()
    private var controller: PetController?
    var onSync: (([String]) -> Void)?

    var primaryController: PetController? { controller }
    var activeMemberIDs: [String] { castRuntime?.activeMemberIDs ?? [] }

    init(
        settingsProvider: @escaping () -> Settings?,
        visualsByActor: [String: URL],
        castPacks: [CastPack],
        resolvedCastPacks: [ResolvedCastPack],
        storyPacks: [StoryPack],
        layoutCoordinator: SpatialLayoutCoordinator,
        perceptionHub: PerceptionHub,
        sharedNeedle: NeedleBrain,
        sharedLocalBrain: LocalBrain,
        sharedTeacherBrain: TeacherBrain
    ) {
        self.settingsProvider = settingsProvider
        self.visualsByActor = visualsByActor
        self.castPacks = castPacks
        self.resolvedCastPacks = resolvedCastPacks
        self.storyPacks = storyPacks
        self.layoutCoordinator = layoutCoordinator
        self.perceptionHub = perceptionHub
        self.sharedNeedle = sharedNeedle
        self.sharedLocalBrain = sharedLocalBrain
        self.sharedTeacherBrain = sharedTeacherBrain
    }

    func updateSettings(_ settings: Settings) {
        for pet in castControllers.values { pet.updateSettings(settings) }
    }

    @discardableResult
    func inviteManually(memberID: String) -> Bool {
        castRuntime?.inviteManually(memberID: memberID) ?? false
    }

    func expandCapacity(to count: Int) {
        castRuntime?.expandCapacity(to: count)
    }

    @discardableResult
    func depart(memberID: String) -> Bool {
        castRuntime?.depart(memberID: memberID) ?? false
    }

    // MARK: 角色组运行时

    func start() {
        guard let settings, !castPacks.isEmpty else { return }
        stop()

        let runtime: CastRuntime
        if !resolvedCastPacks.isEmpty {
            runtime = CastRuntime(
                resolvedPacks: resolvedCastPacks,
                stories: storyPacks,
                selection: settings.castSelection,
                seed: UInt64(Date().timeIntervalSince1970),
                bodyExecutionMode: .external,
                storyConfiguration: settings.storySettings.coreConfiguration)
        } else {
            runtime = CastRuntime(
                packs: castPacks,
                stories: storyPacks,
                selection: settings.castSelection,
                seed: UInt64(Date().timeIntervalSince1970),
                bodyExecutionMode: .external,
                storyConfiguration: settings.storySettings.coreConfiguration)
        }
        castRuntime = runtime
        perceptionHub.resetWindowLifecycle(knownEntities: Array(runtime.runtime.world.entities.values))
        _ = runtime.start()
        _ = runtime.tick()
        syncCastControllers()
        castFrameClock = FixedStepClock(stepMilliseconds: runtime.clock.stepMilliseconds)
        lastCastFrameAt = ProcessInfo.processInfo.systemUptime

        let timer = Timer(timeInterval: 1.0 / 40.0, target: self,
                          selector: #selector(tickCastRuntime), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        castTimer = timer
    }

    func stop() {
        let wasCastActive = castRuntime != nil || !castControllers.isEmpty
        castTimer?.invalidate()
        castTimer = nil
        castFrameClock = nil
        for pet in castControllers.values {
            pet.stop()
            pet.closePanel()
        }
        castControllers.removeAll()
        castSceneGraph.removeAll()
        castOverlays.close()
        castDepartureDeadlines.removeAll()
        reportedMissingCastVisuals.removeAll()
        castRuntime = nil
        if wasCastActive {
            controller = nil
            perceptionHub.ownerID = nil
        }
    }

    /// A package switch is an explicit terminal event, not a file-system
    /// disappearance. Retire story and actors at a Kernel boundary before
    /// releasing AppKit projections and their image sources.
    func retireForPackageChange() {
        if let runtime = castRuntime {
            castTimer?.invalidate()
            castTimer = nil
            runtime.runtime.abortStory(runtime.storyDirector)
            for id in runtime.activeMemberIDs { _ = runtime.depart(memberID: id) }
            _ = runtime.tick()
        }
        stop()
    }

    @objc private func tickCastRuntime() {
        guard let runtime = castRuntime else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.25, max(0, now - lastCastFrameAt))
        lastCastFrameAt = now
        let steps = castFrameClock?.advance(elapsedSeconds: dt) ?? 0
        if steps == 0 { syncCastControllers() }
        for _ in 0..<steps {
            _ = runtime.tick()
            syncCastControllers()
        }
        let effects = runtime.runtime.drainPresentationEffects()
        for (id, pet) in castControllers {
            pet.tickFrame(presentationEffects: effects.filter { $0.actorID.raw == id })
        }
    }

    private func syncCastControllers() {
        guard let settings, let runtime = castRuntime else { return }
        let activeIDs = Set(runtime.activeMemberIDs)
        let nowTick = runtime.clock.tick

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
            runtime.director.member(id)?.visualPackID != nil && visualsByActor[id] != nil
        }
        for (index, id) in orderedIDs.enumerated() {
            if castControllers[id] != nil { continue }
            guard let member = runtime.director.member(id) else { continue }
            guard member.visualPackID != nil, let visualURL = visualsByActor[id] else {
                if reportedMissingCastVisuals.insert(id).inserted {
                    if member.visualPackID == nil {
                        NSLog("MyPet: 角色 %@ 已入场，但没有 visualPackID，暂不创建面板", member.id)
                    } else {
                        NSLog("MyPet: 角色 %@ 的视觉包 %@ 不存在，暂不创建面板", member.id, member.visualPackID ?? "")
                    }
                }
                continue
            }
            do {
                let pack = try ClipLibrary.load(from: visualURL)
                let spawn = castSpawn(index: index, count: max(orderedIDs.count, 1))
                let pet = PetController(
                    library: pack,
                    settings: settings,
                    spawnAt: spawn,
                    actorID: EntityID(id),
                    layoutCoordinator: layoutCoordinator,
                    perceptionHub: perceptionHub,
                    gameplayRuntime: runtime.runtime,
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
                if reportedMissingCastVisuals.insert(id).inserted {
                    NSLog("MyPet: 角色 %@ 的视觉包加载失败 %@ — %@", id, visualURL.path, error.localizedDescription)
                }
            }
        }

        // 第二个角色入场会重新分配第一个角色的安全框；逐个回写 AppKit 面板。
        for pet in castControllers.values { pet.relayout() }

        let castLayout = makeCastLayout(runtime: runtime, settings: settings)
        syncCastCharacterFrames(layout: castLayout)
        syncCastOverlays(runtime: runtime, settings: settings, layout: castLayout)
        let targetFrames = Dictionary(uniqueKeysWithValues: castLayout.entities.compactMap { entity -> (String, LayoutRect)? in
            guard let frame = entity.frame, entity.renderable else { return nil }
            return (entity.id.raw, frame)
        })

        // StoryDirector 的节拍在 Core 中先完成全员行为确认；StoryAction
        // 只定位对应的 BodyCommand，身体参数一律以已授权命令为准。
        // 没有视觉包的道具/机甲仍可参与规则和关系，
        // 这里只跳过它们的渲染，不影响剧情提交。
        for action in runtime.consumeStoryActions() {
            guard let behaviorID = action.behaviorID,
                  let command = runtime.runtime.takeBodyCommand(behaviorID: behaviorID) else { continue }
            let targetX = command.target.flatMap { targetFrames[$0.entityID.raw] }
                .map { CGFloat($0.x + $0.width / 2) }
            guard let pet = castControllers[command.actorID.raw] else {
                // A logic participant without a visual pack still completes
                // deterministically; presentation absence is reported by the
                // asset audit rather than corrupting the story state machine.
                runtime.runtime.submitBodyResult(BodyResult(
                    behaviorID: command.behaviorID,
                    executionToken: command.executionToken,
                    outcome: .completed))
                continue
            }
            pet.performStoryIntent(command.intent, targetX: targetX) { [weak self, weak runtime] success in
                guard let self, let runtime, self.castRuntime === runtime else { return }
                runtime.runtime.submitBodyResult(BodyResult(
                    behaviorID: command.behaviorID,
                    executionToken: command.executionToken,
                    outcome: success ? .completed : .failed))
            }
        }

        // A hand-off is a presentation cue emitted by Core at the successful
        // release boundary. It animates from the currently projected prop to
        // the receiver's shared attachment geometry; it never edits a slot or
        // a SceneGraph parent in AppKit.
        let now = ProcessInfo.processInfo.systemUptime
        for event in runtime.consumeStoryHandoffEvents() {
            guard let from = targetFrames[event.handoff.propID],
                  let toActor = targetFrames[event.handoff.toActorID] else { continue }
            castOverlays.beginHandoff(
                propID: event.handoff.propID, from: from, toActorFrame: toActor,
                now: now,
                durationTicks: event.handoff.durationTicks,
                stepMilliseconds: runtime.clock.stepMilliseconds)
        }

        // 逻辑上可以在场但没有 visualPackID 的机甲/道具不能轮询桌面感知；
        // owner 必须始终落在真正可见的角色上，否则内容事件会被“隐形”实体消费。
        perceptionHub.ownerID = renderableIDs.first { castControllers[$0] != nil }
            .map(EntityID.init)
        controller = activeIDs.sorted().compactMap { castControllers[$0] }.first
        onSync?(runtime.activeMemberIDs)
    }

    /// 把 Core 的 CastVisualProjection 接入真实工作区。道具是独立浮层，
    /// 不借用某个角色的 PropController，避免“角色走开后道具跟着走”的错误。
    private func makeCastLayout(
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
        return CastVisualProjection.project(
            runtime: runtime,
            in: bounds,
            actorHeight: actorHeight,
            actorSizes: actorSizes,
            renderableMemberIDs: Set(castControllers.keys))
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

    private func syncCastOverlays(
        runtime: CastRuntime,
        settings: Settings,
        layout: CastLayoutSnapshot
    ) {
        let activeProps = Dictionary(uniqueKeysWithValues: runtime.activeProps.map { ($0.id, $0) })
        let props: [CastPropVisual] = settings.propsEnabled ? layout.entities.compactMap { entity in
            guard entity.kind == .prop, entity.renderable, let frame = entity.frame,
                  let prop = activeProps[entity.id.raw] else { return nil }
            let visualID = prop.visualPackID ?? prop.id
            return CastPropVisual(
                id: prop.id, visualID: visualID,
                emoji: PropCatalog.def(visualID)?.emoji ?? "◼︎", frame: frame)
        } : []
        let mechs: [CastMechVisual] = layout.entities.compactMap { entity in
            guard entity.kind == .mech, entity.visualPackID == nil,
                  entity.renderable, let frame = entity.frame else { return nil }
            let id = entity.id.raw
            let pilotName = layout.entities.first {
                $0.kind == .actor && $0.attachedToID?.raw == id
            }?.displayName
            return CastMechVisual(id: id, title: entity.displayName,
                                  frame: frame, pilotName: pilotName)
        }
        castOverlays.apply(props: props, mechs: mechs,
                           now: ProcessInfo.processInfo.systemUptime)
    }

    private func castSpawn(index: Int, count: Int) -> CGPoint {
        let work = Screens.workBox(containing: .zero)
        let fraction = CGFloat(index + 1) / CGFloat(count + 1)
        let x = work.left + work.width * fraction
        return CGPoint(x: x, y: work.bottom - (settings?.displayHeight ?? 110))
    }

}
