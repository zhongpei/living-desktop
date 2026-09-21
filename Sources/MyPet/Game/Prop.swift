import AppKit
import CoreGraphics
import Foundation
import MyPetContent
import MyPetCore
import MyPetRender

// Props —— 玩法丰富度的第二支柱（game.md 第十节）。
//
// v2 重构（2026-09-20 讨论定稿）：道具是**完全独立的世界实体**（PropEntity），
// 不再是焊在宠物身上的挂件：
//
//   spawnHeld ──→ held（被拿着，合成进宠物面板，零撕裂）
//                   │ putDown（道具精灵从手部滑到地面 0.35s + 宠物点头节拍）
//                   ▼
//                placed（独立窗口 + 独立世界坐标：宠物去别的窗口活动，
//                        它原地待着；素材多帧就循环微动画，如茶冒热气）
//                   │ ttl 到期 / 场景清理
//                   ▼
//                despawning（0.4s alpha 淡出）→ 消失
//
// pickUp 反向：placed →（滑进手部）→ held。拿/放都用「道具自己动 + 宠物
// 打节拍」表达（现有素材零新增），资源契约预留 pick_up/put_down clip 候选。
//
// 尺寸规则：世界尺寸 = displayHeight × def.scale（随宠物缩放，修死 pt 的缺陷）。
// 美术解析顺序：角色包 props/ → 共享 props/（bundle 或仓库 Resources/props/）
// → emoji 兜底（渲染进统一画布，不再是裸文本）。

struct PropDef: Equatable {
    var id: String
    var displayName: LocalizedLabel
    var emoji: String
    /// 世界尺寸 = 宠物显示高度 × scale（道具与宠物的体感比例）。
    var scale: CGFloat

    var label: String { displayName.defaultText }
}

enum PropCatalog {

    static let defs: [String: PropDef] = [
        // Q 版基准（2026-09-20 用户反馈道具偏小，整体 ×~1.4）：道具相对
        // Q 版角色要「夸张地大」才可读；用户还可在设置窗再乘 propScale 倍率。
        "laptop": PropDef(id: "laptop", displayName: .init(zhHans: "笔记本电脑", en: "Laptop"), emoji: "💻", scale: 0.46),
        "book": PropDef(id: "book", displayName: .init(zhHans: "书", en: "Book"), emoji: "📖", scale: 0.36),
        "tea": PropDef(id: "tea", displayName: .init(zhHans: "茶", en: "Tea"), emoji: "🍵", scale: 0.30),
        "coffee": PropDef(id: "coffee", displayName: .init(zhHans: "咖啡", en: "Coffee"), emoji: "☕️", scale: 0.30),
        "phone": PropDef(id: "phone", displayName: .init(zhHans: "手机", en: "Phone"), emoji: "📱", scale: 0.26),
        "ball": PropDef(id: "ball", displayName: .init(zhHans: "毛线球", en: "Yarn Ball"), emoji: "🧶", scale: 0.28),
        "popcorn": PropDef(id: "popcorn", displayName: .init(zhHans: "爆米花", en: "Popcorn"), emoji: "🍿", scale: 0.36),
        "headphone": PropDef(id: "headphone", displayName: .init(zhHans: "耳机", en: "Headphones"), emoji: "🎧", scale: 0.30),
        "apple": PropDef(id: "apple", displayName: .init(zhHans: "苹果", en: "Apple"), emoji: "🍎", scale: 0.24),
        "pillow": PropDef(id: "pillow", displayName: .init(zhHans: "枕头", en: "Pillow"), emoji: "🛏", scale: 0.40),
        "chair": PropDef(id: "chair", displayName: .init(zhHans: "小椅", en: "Chair"), emoji: "🪑", scale: 0.42),
        "umbrella": PropDef(id: "umbrella", displayName: .init(zhHans: "雨伞", en: "Umbrella"), emoji: "☂️", scale: 0.38),
    ]

    static func def(_ id: String) -> PropDef? { defs[id] }

    /// 快照/工具 schema 的合法集。
    static var ids: [String] { defs.keys.sorted() }
}

// MARK: - 实体

enum PropState: Equatable {
    case held
    case placed
    /// 淡出中（fadeIn→fadeOut 由 despawnAt 驱动，到点移除）。
    case despawning
}

/// 世界里的一个道具实体。同一时刻宠物最多持有一个（两只手），
/// 但 placed 的道具独立存在、独立计时——宠物走开后它原地待着。
/// state 由同文件的 PropController 状态机迁移（fileprivate(set)）。
final class PropEntity {

    let def: PropDef
    /// 空间层节点。x/footY 是现有渲染和兼容 API 的镜像，不再是挂接关系的来源。
    let spatialNode: SceneNode
    fileprivate(set) var state: PropState
    /// 兼容镜像坐标（翻转系）。placed 时是 spatialNode 的世界锚点；held 时
    /// 保留旧 API 使用的角色脚位，真实挂接位置由 spatialNode 提供。
    var x: CGFloat
    var footY: CGFloat
    /// 面朝（held 渲染的手部侧别用）。
    var facingRight = true
    /// placed 的消失时刻（控制器时钟）；nil = 不倒计时（跟随场景清理）。
    var ttlDeadline: Double?
    /// putDown / pickUp 的位移补间：从手部到地面（或反向）。
    var tween: (from: CGPoint, to: CGPoint, start: Double, duration: Double)?
    /// despawn 淡出起点。
    var fadeStart: Double?
    /// placed 微动画的帧钟。
    var frameClock: Double = 0

    init(def: PropDef, state: PropState, x: CGFloat, footY: CGFloat) {
        self.def = def
        self.spatialNode = SceneNode(id: "prop-\(UUID().uuidString)")
        self.state = state
        self.x = x
        self.footY = footY
    }

    /// 世界尺寸（pt，道具自身基准，不含用户倍率）。
    func size(displayHeight: CGFloat) -> CGFloat { displayHeight * def.scale }

    /// 实际渲染尺寸 = displayHeight × scale × 用户倍率。
    func effectiveSize(displayHeight: CGFloat, userScale: Double) -> CGFloat {
        displayHeight * def.scale * CGFloat(userScale)
    }

    /// 手部世界坐标（held 渲染锚点）：身侧半臂高。
    static func holdPoint(petX: CGFloat, petYFeet: CGFloat, facingRight: Bool,
                          displayHeight: CGFloat) -> CGPoint {
        let side: CGFloat = facingRight ? 1 : -1
        return CGPoint(x: petX + side * displayHeight * 0.30,
                       y: petYFeet - displayHeight * 0.45)
    }
}

// MARK: - 素材解析（角色包 → 共享包 → emoji 兜底）

enum PropSprites {

    /// 帧序列解析顺序：
    /// 1. 角色包 props/<id>/frame_NN.webp（多帧 = placed 微动画）
    /// 2. 角色包 props/<id>.webp
    /// 3. 共享 props/<id>/frame_NN.webp（bundle Resources/props 或仓库 Resources/props）
    /// 4. 共享 props/<id>.webp
    /// 空 = emoji 兜底。
    static func frameURLs(for id: String, packURL: URL?) -> [URL] {
        let fm = FileManager.default
        var singleCandidates: [URL] = []
        var frameDirs: [URL] = []
        if let packURL {
            frameDirs.append(packURL.appendingPathComponent("props/\(id)", isDirectory: true))
            singleCandidates.append(packURL.appendingPathComponent("props/\(id).webp"))
        }
        for shared in sharedRoots() {
            frameDirs.append(shared.appendingPathComponent(id, isDirectory: true))
            singleCandidates.append(shared.appendingPathComponent("\(id).webp"))
        }
        for dir in frameDirs {
            let frames = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "webp" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let frames, !frames.isEmpty { return frames }
        }
        return singleCandidates.first { fm.fileExists(atPath: $0.path) }.map { [$0] } ?? []
    }

    /// 共享道具根目录（bundle 内 + 仓库 Resources/props，双环境兜底）。
    static func sharedRoots() -> [URL] {
        var roots: [URL] = []
        if let resource = Bundle.main.resourceURL {
            roots.append(resource.appendingPathComponent("props", isDirectory: true))
        }
        // swift run：从可执行文件向上找仓库 Resources/props。
        if let exe = CommandLine.arguments.first,
           fmExists(exe) {
            var dir = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("Resources/props", isDirectory: true)
                if fmExists(candidate.path) { roots.append(candidate) }
                dir = dir.deletingLastPathComponent()
            }
        }
        return roots
    }

    private static func fmExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// emoji 兜底：渲染进统一方形画布（修裸文本基线发虚的缺陷）。
    static func emojiImage(_ emoji: String, size: CGFloat) -> CGImage? {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let font = NSFont.systemFont(ofSize: size * 0.72)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let str = NSAttributedString(string: emoji, attributes: attrs)
        let bounds = str.size()
        str.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func cgImage(_ url: URL) -> CGImage? {
        NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - 控制器

/// held 布局（PetView 第二图层用，视图本地坐标，isFlipped）。
struct PropHeldLayout {
    var rect: CGRect
    var image: CGImage
}

/// 道具控制器：实体的生命周期 + 双渲染（held 合成层 / placed 独立窗口）。
/// 宠物移动时由控制器 tick 同步；placed 静置不逐帧动窗口（只在自己有
/// 微动画帧或淡出时才碰）。
final class PropController {

    private(set) var entity: PropEntity?
    /// 当前单角色适配器使用的共享空间树和角色手部插槽。
    /// 多角色运行时会把同一个 SceneGraph 注入多个 actor root；这里不再
    /// 自己创建第二套坐标真相。
    private let sceneGraph: SceneGraph
    private let actorNode: SceneNode
    private let handSocket: SceneNode
    private var panel: OverlayPanel?
    private let library: ClipLibrary
    /// placed 默认滞留秒数（放下后原地待一会再淡出）。
    var placedDefaultTTL: Double = 120
    /// 用户倍率（设置窗「道具大小」，1.0 = 标准基准；乘在每道具 scale 上）。
    var userScale: Double = 1.0
    /// 全局兜底 TTL（防孤儿）。
    var maxTTL: Double = 600
    /// 淡出时长。
    var fadeDuration: Double = 0.4
    /// 拿/放补间时长。
    var tweenDuration: Double = 0.35
    /// 面板渲染开关（单测置 false：只测实体状态机，不建 NSPanel）。
    var panelsEnabled = true

    /// placed 微动画帧缓存：URL → CGImage。
    private var frameCache: [URL: CGImage] = [:]
    /// 最近一次 tick 的宠物显示高度（putDown/pickUp 的手部点位换算用）。
    private var lastDisplayHeight: CGFloat = 110

    convenience init(library: ClipLibrary) {
        let graph = SceneGraph(rootID: "scene")
        let actor = SceneNode(id: "actor")
        let hand = try! actor.addSocket("hand")
        try! graph.add(actor)
        self.init(library: library, sceneGraph: graph, actorNode: actor, handSocket: hand)
    }

    init(library: ClipLibrary, sceneGraph: SceneGraph,
         actorNode: SceneNode, handSocket: SceneNode) {
        precondition(actorNode.parent === sceneGraph.root,
                     "actorNode must belong to sceneGraph.root")
        precondition(handSocket.parent === actorNode && handSocket.kind == .socket,
                     "handSocket must be a socket of actorNode")
        self.sceneGraph = sceneGraph
        self.actorNode = actorNode
        self.handSocket = handSocket
        self.library = library
    }

    /// 把现有身体的最终位姿同步到场景树。场景树不反过来驱动物理。
    private func syncScenePose(petX: CGFloat, petYFeet: CGFloat,
                               facingRight: Bool, displayHeight: CGFloat) {
        actorNode.localPosition = CGPoint(x: petX, y: petYFeet)
        let side: CGFloat = facingRight ? 1 : -1
        handSocket.localPosition = CGPoint(x: side * displayHeight * 0.30,
                                           y: -displayHeight * 0.45)
    }

    private func attachToHand(_ node: SceneNode) -> Bool {
        do {
            try node.reparent(to: handSocket, keepWorldTransform: false)
            node.localPosition = .zero
            return true
        } catch {
            assertionFailure("Prop spatial attach failed: \(error)")
            return false
        }
    }

    private func placeAtWorldRoot(_ node: SceneNode, position: CGPoint) -> Bool {
        do {
            try node.reparent(to: sceneGraph.root, keepWorldTransform: false)
            node.localPosition = position
            return true
        } catch {
            assertionFailure("Prop spatial placement failed: \(error)")
            return false
        }
    }

    private func detachNode(_ node: SceneNode) {
        try? node.reparent(to: nil, keepWorldTransform: false)
    }

    // MARK: 查询

    var isHolding: Bool { entity?.state == .held }
    var heldPropID: String? { (entity?.state == .held) ? entity?.def.id : nil }
    var current: PropEntity? { entity }

    /// 宠物附近是否有可拿的 placed 道具。
    func placedNear(petX: CGFloat, petYFeet: CGFloat, within: CGFloat) -> PropEntity? {
        guard let e = entity, e.state == .placed else { return nil }
        let d = hypot(e.x - petX, e.footY - petYFeet)
        return d <= within ? e : nil
    }

    // MARK: 生命周期

    /// 生成一个被拿着的道具（场景/行动脑语义：宠物拿出道具）。
    @discardableResult
    func spawnHeld(_ id: String, petX: CGFloat, petYFeet: CGFloat, facingRight: Bool,
                   now: Double) -> PropEntity? {
        guard let def = PropCatalog.def(id) else { return nil }
        clear()   // 单实体：换道具时不能把旧节点遗留在场景树里
        syncScenePose(petX: petX, petYFeet: petYFeet,
                      facingRight: facingRight, displayHeight: lastDisplayHeight)
        let e = PropEntity(def: def, state: .held,
                           x: petX, footY: petYFeet)
        e.facingRight = facingRight
        guard attachToHand(e.spatialNode) else { return nil }
        entity = e
        return e
    }

    /// 直接生成一个 placed 道具（用户「召唤到面前」）：落在指定点原地待着，
    /// 默认滞留后淡出。
    @discardableResult
    func spawnPlaced(_ id: String, at x: CGFloat, footY: CGFloat, now: Double,
                     ttl: Double? = nil) -> PropEntity? {
        guard let def = PropCatalog.def(id) else { return nil }
        clear()   // 单实体：换道具时不能把旧节点遗留在场景树里
        let e = PropEntity(def: def, state: .placed, x: x, footY: footY)
        guard placeAtWorldRoot(e.spatialNode, position: CGPoint(x: x, y: footY)) else {
            return nil
        }
        e.ttlDeadline = now + min(ttl ?? placedDefaultTTL, maxTTL)
        entity = e
        return e
    }

    /// 放下：held → placed。道具精灵从手部位置滑到落点（补间），
    /// 宠物侧配合一个点头节拍（由调用方播放）。ttl nil = 默认滞留。
    @discardableResult
    func putDown(at x: CGFloat, footY: CGFloat, now: Double, ttl: Double? = nil) -> Bool {
        guard let e = entity, e.state == .held else { return false }
        let from = e.spatialNode.worldPosition
        guard placeAtWorldRoot(e.spatialNode, position: from) else { return false }
        e.state = .placed
        e.tween = (from: from, to: CGPoint(x: x, y: footY),
                   start: now, duration: tweenDuration)
        e.x = x
        e.footY = footY
        e.ttlDeadline = now + min(ttl ?? placedDefaultTTL, maxTTL)
        makePanel()
        return true
    }

    /// 拿起：placed → held。道具精灵从地面滑进手部（补间期间仍用独立面板
    /// 渲染滑入，到点切合成层）。宠物此刻应已站在道具旁。
    @discardableResult
    func pickUp(petX: CGFloat, petYFeet: CGFloat, facingRight: Bool, now: Double) -> Bool {
        guard let e = entity, e.state == .placed else { return false }
        syncScenePose(petX: petX, petYFeet: petYFeet,
                      facingRight: facingRight, displayHeight: lastDisplayHeight)
        let from = e.spatialNode.worldPosition
        let to = handSocket.worldPosition
        e.state = .held
        e.facingRight = facingRight
        e.x = petX
        e.footY = petYFeet
        e.ttlDeadline = nil
        e.tween = (from: from, to: to, start: now, duration: tweenDuration)
        if panel == nil { makePanel() }
        return true
    }

    /// 消失：淡出（placed）或直接移除（held = 停止合成）。
    func despawn(now: Double) {
        guard let e = entity else { return }
        if e.state == .held {
            detachNode(e.spatialNode)
            removePanel()
            entity = nil
        } else {
            e.state = .despawning
            e.fadeStart = now
        }
    }

    /// 立即移除（切宠物/关闭面板用，无淡出）。
    func clear() {
        if let e = entity {
            detachNode(e.spatialNode)
        }
        entity = nil
        removePanel()
    }

    // MARK: 每帧

    /// petX/petYFeet/facingRight = 宠物实时位姿；displayHeight 供尺寸缩放。
    /// 渲染分派：**有补间 → 独立面板**（放下的滑落/拿起的滑入）；
    /// held 无补间 → 合成层（面板移除）；placed/淡出 → 独立面板。
    func tick(petX: CGFloat, petYFeet: CGFloat, facingRight: Bool,
              displayHeight: CGFloat, now: Double) {
        lastDisplayHeight = displayHeight
        syncScenePose(petX: petX, petYFeet: petYFeet,
                      facingRight: facingRight, displayHeight: displayHeight)
        guard let e = entity else { return }
        e.facingRight = facingRight
        e.frameClock = now

        // 补间推进（putDown 的滑落 / pickUp 的滑入）。pickUp 的终点跟着
        // 手部实时位置走（宠物站定时即定点）。
        if let tween = e.tween {
            let t = min(1, max(0, (now - tween.start) / tween.duration))
            let target: CGPoint
            if e.state == .held {
                target = handSocket.worldPosition
            } else {
                target = tween.to
            }
            let p = interpolate(tween.from, target, t: t)
            if e.spatialNode.parent !== sceneGraph.root {
                guard placeAtWorldRoot(e.spatialNode, position: p) else {
                    clear()
                    return
                }
            }
            e.spatialNode.localPosition = p
            e.x = p.x
            e.footY = p.y
            if t >= 1 {
                e.tween = nil
                if e.state == .held {
                    guard attachToHand(e.spatialNode) else {
                        clear()
                        return
                    }
                    e.x = petX
                    e.footY = petYFeet
                }
            }
        } else if e.state == .held {
            e.x = petX
            e.footY = petYFeet
            if e.spatialNode.parent !== handSocket, !attachToHand(e.spatialNode) {
                clear()
                return
            }
        } else if e.spatialNode.parent === sceneGraph.root {
            // placed / despawning 的世界位置由节点保存；x/footY 只是兼容镜像。
            let position = e.spatialNode.worldPosition
            e.x = position.x
            e.footY = position.y
        }

        switch e.state {
        case .held:
            if e.tween == nil {
                removePanel()   // 无补间的持有走合成层
            }
        case .placed:
            // placed 静置：世界坐标不动（面板也不逐帧动）。
            if let deadline = e.ttlDeadline, now >= deadline {
                e.state = .despawning
                e.fadeStart = now
            }
        case .despawning:
            let t = now - (e.fadeStart ?? now)
            if t >= fadeDuration {
                clear()
                return
            }
            panel?.alphaValue = CGFloat(1 - t / fadeDuration)
        }

        // 面板渲染：补间中 / placed / 淡出。held 无补间时移除面板走合成层。
        if !(e.state == .held && e.tween == nil) {
            if panel == nil, e.state != .held { makePanel() }
            updatePanel(e, displayHeight: displayHeight)
        }
    }

    /// held 道具的合成布局（PetView 本地坐标；nil = 无持有或补间中走面板）。
    func heldLayout(displayHeight: CGFloat) -> PropHeldLayout? {
        guard let e = entity, e.state == .held, e.tween == nil else { return nil }
        let size = e.effectiveSize(displayHeight: displayHeight, userScale: userScale)
        let hold = e.spatialNode.worldPosition
        // 宠物面板本地坐标：面板 x = petX - displayW/2，顶 = petYFeet - baseline。
        let baseline = displayHeight * ClipLibrary.baselineRatio
        let displayW = library.cellSize.width / library.cellSize.height * displayHeight
        let localX = hold.x - size / 2 - (e.x - displayW / 2)
        let localY = (hold.y - size) - (e.footY - baseline)
        guard let image = spriteImage(for: e, size: size) else { return nil }
        return PropHeldLayout(rect: CGRect(x: localX, y: localY, width: size, height: size),
                              image: image)
    }

    // MARK: 内部

    private func interpolate(_ a: CGPoint, _ b: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func spriteImage(for e: PropEntity, size: CGFloat) -> CGImage? {
        let urls = PropSprites.frameURLs(for: e.def.id, packURL: library.packURL)
        if urls.isEmpty {
            return PropSprites.emojiImage(e.def.emoji, size: size)
        }
        // 多帧 = placed 微动画（慢速循环）；单帧静态。
        let url: URL
        if urls.count > 1, e.state != .held {
            let fps = 5.0
            let index = Int(e.frameClock * fps) % urls.count
            url = urls[index]
        } else {
            url = urls[0]
        }
        if let cached = frameCache[url] { return cached }
        let image = PropSprites.cgImage(url)
        if let image { frameCache[url] = image }
        return image
    }

    private func makePanel() {
        guard panelsEnabled, panel == nil else { return }
        let size: CGFloat = 64   // 占位，updatePanel 里按 displayHeight 缩放
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.imageScaling = .scaleProportionallyUpOrDown
        let panel = OverlayPanel(contentView: view, initialFrame: NSRect(x: 0, y: 0, width: size, height: size))
        // placed 在宠物面板（floating+1）之下的浮层：宠物可以从它前面走过。
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func updatePanel(_ e: PropEntity, displayHeight: CGFloat) {
        guard panelsEnabled, let panel else { return }
        let size = e.effectiveSize(displayHeight: displayHeight, userScale: userScale)
        let rect = Screens.appKitRect(
            flippedTop: e.footY - size,   // 道具「站」在 footY 上：顶沿在其上方
            x: e.x - size / 2,
            width: size,
            height: size)
        panel.setFrame(rect, display: false)
        let image = spriteImage(for: e, size: size) ?? PropSprites.emojiImage(e.def.emoji, size: size)
        if let image, let view = panel.contentView as? NSImageView {
            view.image = NSImage(cgImage: image, size: NSSize(width: size, height: size))
        }
    }

    private func removePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}
