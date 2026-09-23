import CoreGraphics
import Foundation
import MyPetCombat
import MyPetCore
import MyPet2D

/// 世界读取接口：PetModel 只依赖它，测试时塞假世界。
/// 生产环境由 SystemWorld（WindowWorld + Screens + 系统空闲时间）实现。
protocol WorldReading: AnyObject {
    func liveBounds(_ id: CGWindowID) -> CGRect?
    func surfaces(near x: CGFloat, footY: CGFloat) -> [(surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)]
    func floorBeyond(edgeX: CGFloat, direction: CGFloat) -> (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)?
    func workBox(at point: CGPoint) -> Screens.Box
    func virtualBox() -> Screens.Box
    func idleSeconds() -> Double
}

/// 旧 AppKit 调用面的只读身体投影与动作意图适配器。位置、速度、支撑面和
/// 碰撞的唯一事实都在共享 `BodyWorld`；这里不再维护第二份物理状态。
///
/// 栖息模型（Surface Attachment）：站上窗口顶沿后记住 {windowID, frac}，
/// 之后位置每帧由窗口实时 bounds 推导 —— 窗口怎么动，宠物就怎么动，无需重新决策。
final class PetModel {

    enum State: Equatable {
        case grounded   // 站在地板 / 窗口底沿
        case perched    // 栖息在窗口顶沿（带 frac 绑定）
        case airborne   // 跳跃 / 坠落
        case dragged
        case tossed
        case asleep
    }

    // ---- 渲染器 / 控制器只读投影 ----
    private(set) var x: CGFloat {
        get { CGFloat(body.position.x) }
        set { bodyWorld.update(entityID) { $0.position.x = Double(newValue) } }
    }
    private(set) var yFeet: CGFloat {
        get { CGFloat(body.position.y) }
        set { bodyWorld.update(entityID) { $0.position.y = Double(newValue) } }
    }
    /// Compatibility velocity is points/second; BodyWorld stores points/frame.
    private(set) var vx: CGFloat {
        get { CGFloat(body.velocity.x * Double(BodyWorld.framesPerSecond)) }
        set { bodyWorld.update(entityID) { $0.velocity.x = Double(newValue) / Double(BodyWorld.framesPerSecond) } }
    }
    private(set) var vy: CGFloat {
        get { CGFloat(body.velocity.y * Double(BodyWorld.framesPerSecond)) }
        set { bodyWorld.update(entityID) { $0.velocity.y = Double(newValue) / Double(BodyWorld.framesPerSecond) } }
    }
    private(set) var facingRight: Bool {
        get { body.facing == .right }
        set { bodyWorld.update(entityID) { $0.facing = newValue ? .right : .left } }
    }
    private(set) var state: State {
        get {
            switch body.locomotion {
            case .grounded: return body.currentSurfaceID?.hasSuffix(":top") == true ? .perched : .grounded
            case .airborne: return .airborne
            case .dragged: return .dragged
            case .tossed: return .tossed
            case .sleeping: return .asleep
            }
        }
        set {
            bodyWorld.update(entityID) { body in
                switch newValue {
                case .grounded, .perched: body.locomotion = .grounded
                case .airborne: body.locomotion = .airborne
                case .dragged: body.locomotion = .dragged
                case .tossed: body.locomotion = .tossed
                case .asleep: body.locomotion = .sleeping
                }
            }
        }
    }
    private(set) var walking = false
    /// 栖息绑定：窗口 + 顶沿横向分数 0...1。
    private(set) var perch: (id: CGWindowID, frac: CGFloat)?
    /// 当前站立面的横向活动范围。
    private(set) var stance: (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)?

    /// 显示高度（pt）。可热更新（设置窗滑杆实时预览）：bodyRadius、
    /// 栖息换算等都从它派生，下一帧物理即按新尺寸运转。
    var displayHeight: CGFloat {
        didSet {
            guard var definition = bodyWorld.definition(for: entityID) else { return }
            definition.visualScale = max(0.05, Double(displayHeight) / 110.0)
            bodyWorld.setDefinition(definition)
        }
    }
    var bodyRadius: CGFloat { displayHeight * 0.42 }

    // ---- 动作意图参数（位置积分由 BodyWorld 负责）----
    static let walkSpeed: CGFloat = 90
    /// 用户召唤速度（「过来！」要明显快于闲逛，否则观感就是没反应）。
    static let hurrySpeed: CGFloat = 260
    static let napAfterIdle: Double = 180

    /// 走到窗沿尽头时选择「跳下去」的概率（否则掉头继续走）。测试可注成 1。
    var edgeDropChance: Double = 0.35

    /// 走出屏边 / 窗沿后的着地续走方向（跨屏：掉落到隔壁屏幕后接着走）。
    private var pendingWalkDir: CGFloat?

    private let world: WorldReading
    private let entityID: EntityID
    private let bodyWorld: BodyWorld
    private var bodyFrameClock = BodyFrameAccumulator()

    // 拖拽
    private var grabOffset = CGPoint.zero
    // 拉窗（拖拽栖息宠物 = 拖它的窗口）
    private(set) var pulling = false

    init(
        world: WorldReading,
        displayHeight: CGFloat,
        startAt point: CGPoint,
        entityID: EntityID = EntityID("pet"),
        bodyWorld: BodyWorld = BodyWorld()
    ) {
        self.world = world
        self.entityID = entityID
        self.bodyWorld = bodyWorld
        self.displayHeight = displayHeight
        if bodyWorld.state(for: entityID) == nil {
            bodyWorld.register(
                BodyDefinition(
                    entityID: entityID,
                    pushRadius: Double(displayHeight * 0.42)),
                state: BodyState(
                    entityID: entityID,
                    position: Vec2(x: Double(point.x), y: Double(point.y)),
                    locomotion: .airborne))
        }
    }

    private var body: BodyState {
        guard let body = bodyWorld.state(for: entityID) else {
            preconditionFailure("BodyWorld no longer contains \(entityID.raw)")
        }
        return body
    }

    // ============ 指令（大脑 / 菜单 / 鼠标进来）============

    /// 出生：站上某点所在工作区的地板。
    func spawn(onFloorAt p: CGPoint) {
        let work = world.workBox(at: p)
        x = work.left + work.width * 0.62
        yFeet = work.bottom
        state = .grounded
        stance = (surface: .floor, y: work.bottom, left: work.left, right: work.right)
    }

    /// 当前步行速度（闲逛 vs 用户召唤）。
    private(set) var currentWalkSpeed: CGFloat = walkSpeed

    func startWalk(_ direction: CGFloat, speed: CGFloat = PetModel.walkSpeed) {
        guard canAct else { return }
        walking = true
        facingRight = direction >= 0
        currentWalkSpeed = speed
    }

    /// 用户召唤：可靠到达目标 x。
    /// 同段地板 → 召唤速度直接走；跨段/跨屏/从窗口下地 → 空降到目标地板上方，
    /// 落地即达（地板断档 >120pt 时走路永远过不去，这是多显示器召唤失效的根因）。
    func summonTo(targetX: CGFloat) {
        guard canAct else { return }
        if let s = stance, s.surface == .floor, targetX >= s.left, targetX <= s.right {
            startWalk(targetX - x, speed: Self.hurrySpeed)
            return
        }
        // 目标所在地板段（virtualBox 底沿之下必然能扫到所有地板）。
        let v = world.virtualBox()
        let seg = world.surfaces(near: targetX, footY: v.bottom).first {
            $0.surface == .floor && targetX >= $0.left && targetX <= $0.right
        }
        guard let seg else { return } // 目标不在任何地板上：忽略
        x = PetMath.clamp(targetX, seg.left + bodyRadius * 0.6, seg.right - bodyRadius * 0.6)
        yFeet = max(seg.y - displayHeight, v.top + displayHeight)
        perch = nil
        stance = seg
        vx = 0
        vy = 0
        walking = false
        state = .airborne // 自由落体降落在目标点
    }

    func stopWalk() {
        walking = false
        currentWalkSpeed = Self.walkSpeed
    }

    /// 让语义剧情动作先朝向它的目标；这是身体层的最小目标适配，
    /// 不改变位置、槽位或世界状态。目标消失时表现层可以省略调用。
    func faceToward(_ targetX: CGFloat) {
        guard canAct else { return }
        facingRight = targetX >= x
    }

    /// 原地小跳。上抬 2px 防止起跳帧被「重新落回原地」。
    func hop() {
        guard canAct else { return }
        detach()
        yFeet -= 2
        vy = -520
        vx = 0
    }

    /// 朝目标窗口跃起并尝试落上它的顶沿。距离太远就只是朝那个方向大跳。
    func leapTo(window: WindowEntity) {
        guard canAct else { return }
        let targetX = window.bounds.midX
        // 翻转坐标 y 向下：「要爬升的高度」= 脚下 y − 窗顶 y。
        let rise = max(yFeet - window.topY, 0)
        vx = PetMath.clamp((targetX - x) * 1.2, -900, 900)
        let gravityPerSecond = BodyWorld.gravityPerFrame *
            Double(BodyWorld.framesPerSecond * BodyWorld.framesPerSecond)
        vy = PetMath.leapVelocity(
            rise: min(rise, 720), gravity: CGFloat(gravityPerSecond))
        facingRight = vx >= 0
        detach()
    }

    /// 走向屏幕上某点（菜单「过来」等）。
    func strollTo(_ targetX: CGFloat) {
        guard canAct else { return }
        if abs(targetX - x) < 24 { return }
        startWalk(targetX - x)
    }

    func sleep() {
        guard state == .grounded || state == .perched else { return }
        state = .asleep
        walking = false
    }

    func wake() {
        guard state == .asleep else { return }
        state = perch != nil ? .perched : .grounded
    }

    func beginDrag(at cursor: CGPoint) {
        if state == .perched, perch != nil {
            pulling = true
            grabOffset = .zero
        } else {
            pulling = false
            grabOffset = CGPoint(x: x - cursor.x, y: yFeet - cursor.y)
        }
        walking = false
        bodyWorld.beginDrag(entityID: entityID, position: Vec2(x: Double(x), y: Double(yFeet)))
    }

    func drag(to cursor: CGPoint, dt: Double) {
        guard state == .dragged else { return }
        if pulling {
            guard let perch, let bounds = world.liveBounds(perch.id) else {
                // 窗口没了，退化为普通拖拽。
                pulling = false
                grabOffset = .zero
                return
            }
            let margin = bodyRadius * 0.95
            let frac = PetMath.perchFrac(x: cursor.x, bounds: bounds, margin: margin)
            self.perch = (perch.id, frac)
            let feetY = perchFeetY(in: bounds)
            positionOn(bounds: bounds, feetY: feetY, frac: frac)
        } else {
            let nx = cursor.x + grabOffset.x
            let ny = cursor.y + grabOffset.y
            bodyWorld.drag(
                entityID: entityID,
                position: Vec2(x: Double(nx), y: Double(ny)),
                elapsedSeconds: dt)
        }
    }

    func endDrag(wasClick: Bool) {
        guard state == .dragged else { return }
        if wasClick {
            bodyWorld.endDrag(entityID: entityID, wasClick: true)
            return
        }
        if pulling {
            pulling = false
            if let perch {
                let id = Self.windowSurfaceID(perch.id, edge: "top")
                bodyWorld.update(entityID) { body in
                    body.locomotion = .grounded
                    body.currentSurfaceID = id
                    body.surfaceFraction = Double(perch.frac)
                    body.velocity = Vec2()
                }
            }
            return
        }
        bodyWorld.endDrag(entityID: entityID, wasClick: false)
    }

    /// 拖拽栖息宠物时窗口的原始位置（拉窗弹簧锚点），非拉窗时为 nil。
    func isPulling() -> Bool { pulling }

    // ============ 主循环 ============

    func update(dtIn: Double) {
        let clamped = min(max(dtIn, 0), 0.25)
        for _ in bodyFrameClock.consume(elapsedSeconds: clamped) {
            prepareBodySimulationFrame()
            _ = bodyWorld.advance(bodyEnvironmentSnapshot())
            refreshCompatibilityProjection()
        }
    }

    /// Submits authored locomotion into BodyWorld before its shared 60 Hz step.
    /// Production calls this once per shared world frame; standalone tests use
    /// `update(dtIn:)`, which drives the same method and world implementation.
    func prepareBodySimulationFrame() {
        var state = body
        guard state.locomotion != .dragged else { return }
        if state.locomotion == .sleeping {
            state.velocity = Vec2()
            bodyWorld.update(entityID) { $0 = state }
            return
        }
        guard state.locomotion == .grounded else { return }

        guard walking else {
            state.velocity.x = 0
            bodyWorld.update(entityID) { $0 = state }
            return
        }

        let environment = bodyEnvironmentSnapshot()
        guard let surface = environment.surface(id: state.currentSurfaceID) else {
            state.locomotion = .airborne
            state.currentSurfaceID = nil
            state.surfaceFraction = nil
            bodyWorld.update(entityID) { $0 = state }
            return
        }
        let direction = state.facing == .right ? 1.0 : -1.0
        let speed = Double(currentWalkSpeed) / Double(BodyWorld.framesPerSecond)
        let margin = Double(bodyRadius) * 0.6
        let nextX = state.position.x + direction * speed
        let edge = direction > 0 ? surface.right : surface.left
        let crossesEdge = nextX <= surface.left + margin || nextX >= surface.right - margin
        if crossesEdge {
            if surface.kind == .floor,
               let next = world.floorBeyond(edgeX: CGFloat(edge), direction: CGFloat(direction)) {
                state.position.x = Double(direction > 0
                    ? next.left + bodyRadius * 0.8
                    : next.right - bodyRadius * 0.8)
                state.position.y = Double(surface.y + 2)
                state.velocity = Vec2()
                state.locomotion = .airborne
                state.currentSurfaceID = nil
                state.surfaceFraction = nil
                pendingWalkDir = CGFloat(direction)
            } else if surface.kind != .floor && shouldDropFromWindowEdge() {
                state.position.x = edge + direction * 2
                state.position.y = surface.y + 2
                state.velocity = Vec2(x: direction * speed, y: 0)
                state.locomotion = .airborne
                state.currentSurfaceID = nil
                state.surfaceFraction = nil
                pendingWalkDir = CGFloat(direction)
            } else {
                state.facing = direction > 0 ? .left : .right
                state.velocity.x = -direction * speed
            }
        } else {
            state.velocity.x = direction * speed
        }
        bodyWorld.update(entityID) { $0 = state }
    }

    /// Refreshes compatibility-only metadata from an immutable view over the
    /// already-shared BodyWorld state. It never writes position back to the world.
    func refreshCombatProjection(_ body: CombatBodyState) {
        if body.authority != .scripted || body.healthState != .active {
            walking = body.healthState == .active && body.phase == .neutral &&
                abs(body.velocity.x) > 0.01
            pendingWalkDir = nil
        }
        refreshCompatibilityProjection()
    }

    func refreshCompatibilityProjection() {
        let state = body
        switch state.locomotion {
        case .grounded:
            if let id = state.currentSurfaceID,
               id.hasPrefix("window:"), id.hasSuffix(":top"),
               let raw = id.split(separator: ":").dropFirst().first,
               let windowID = UInt32(raw) {
                perch = (CGWindowID(windowID), CGFloat(state.surfaceFraction ?? 0.5))
                stance = world.surfaces(near: x, footY: yFeet).first {
                    $0.surface == .windowTop(CGWindowID(windowID))
                }
            } else {
                perch = nil
                stance = world.surfaces(near: x, footY: yFeet).first {
                    abs($0.y - yFeet) <= 2 && x >= $0.left && x <= $0.right
                }
            }
        case .airborne, .dragged, .tossed:
            if state.locomotion != .dragged || !pulling { perch = nil }
            stance = nil
        case .sleeping:
            break
        }
    }

    func bodyEnvironmentSnapshot() -> BodyEnvironment {
        let virtual = world.virtualBox()
        var floorIndex = 0
        let surfaces = world.surfaces(near: x, footY: yFeet).map { item -> MyPet2D.Surface in
            switch item.surface {
            case .floor:
                defer { floorIndex += 1 }
                return MyPet2D.Surface(
                    id: "floor:\(floorIndex):\(Int(item.y.rounded()))",
                    kind: .floor,
                    left: Double(item.left), right: Double(item.right), y: Double(item.y))
            case .windowTop(let id):
                let feetY = world.liveBounds(id).map { perchFeetY(in: $0) } ?? item.y
                return MyPet2D.Surface(
                    id: Self.windowSurfaceID(id, edge: "top"),
                    kind: .windowTop,
                    left: Double(item.left), right: Double(item.right), y: Double(feetY),
                    hostID: EntityID("window:\(id)"))
            case .windowBottom(let id):
                return MyPet2D.Surface(
                    id: Self.windowSurfaceID(id, edge: "bottom"),
                    kind: .windowBottom,
                    left: Double(item.left), right: Double(item.right), y: Double(item.y),
                    hostID: EntityID("window:\(id)"))
            }
        }
        return BodyEnvironment(
            bounds: Rect2D(
                x: Double(virtual.left), y: Double(virtual.top),
                width: Double(virtual.width), height: Double(virtual.height)),
            surfaces: surfaces)
    }

    private static func windowSurfaceID(_ id: CGWindowID, edge: String) -> String {
        "window:\(id):\(edge)"
    }

    private func shouldDropFromWindowEdge() -> Bool {
        if edgeDropChance <= 0 { return false }
        if edgeDropChance >= 1 { return true }
        let salt = entityID.raw.utf8.reduce(Int64(0)) { ($0 * 31 + Int64($1)) % 10_000 }
        let sample = Double((bodyWorld.frame + salt) % 1_000) / 1_000
        return sample < edgeDropChance
    }

    private func perchFeetY(in bounds: CGRect) -> CGFloat {
        let workTop = world.workBox(at: CGPoint(x: x, y: bounds.minY)).top
        return PetMath.perchFeetY(
            topY: bounds.minY,
            petHeight: displayHeight,
            workTop: workTop)
    }

    private func positionOn(bounds: CGRect, feetY: CGFloat, frac: CGFloat) {
        let margin = bodyRadius * 0.95
        bodyWorld.update(entityID) { body in
            body.position = Vec2(
                x: Double(PetMath.perchX(bounds: bounds, frac: frac, margin: margin)),
                y: Double(feetY))
            body.surfaceFraction = Double(frac)
        }
    }

    /// 离开当前支撑面进入空中。
    private func detach() {
        perch = nil
        stance = nil
        pendingWalkDir = nil
        bodyWorld.update(entityID) { body in
            body.currentSurfaceID = nil
            body.surfaceFraction = nil
            if body.locomotion != .dragged && body.locomotion != .tossed {
                body.locomotion = .airborne
            }
        }
        walking = false
    }

    private var canAct: Bool {
        state == .grounded || state == .perched
    }

    /// 大脑 / 渲染关心的快照。
    var isMoving: Bool { walking || sqrt(vx * vx + vy * vy) > 25 }
    var onWindow: Bool { perch != nil || (stance?.surface != .floor && stance != nil) }
}
