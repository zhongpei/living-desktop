import CoreGraphics
import Foundation

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

/// 宠物的身体：状态机 + 平台物理，纯逻辑、翻转坐标、无绘制代码。
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

    // ---- 渲染器 / 控制器读取 ----
    private(set) var x: CGFloat = 0
    private(set) var yFeet: CGFloat = 0
    private(set) var vx: CGFloat = 0
    private(set) var vy: CGFloat = 0
    private(set) var facingRight = true
    private(set) var state: State = .airborne
    private(set) var walking = false
    /// 栖息绑定：窗口 + 顶沿横向分数 0...1。
    private(set) var perch: (id: CGWindowID, frac: CGFloat)?
    /// 当前站立面的横向活动范围。
    private(set) var stance: (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)?

    /// 显示高度（pt）。可热更新（设置窗滑杆实时预览）：bodyRadius、
    /// 栖息换算等都从它派生，下一帧物理即按新尺寸运转。
    var displayHeight: CGFloat
    var bodyRadius: CGFloat { displayHeight * 0.42 }

    // ---- 可调物理参数（clawd 量级，按平台跳跃手感微调）----
    static let gravity: CGFloat = 1600
    static let walkSpeed: CGFloat = 90
    /// 用户召唤速度（「过来！」要明显快于闲逛，否则观感就是没反应）。
    static let hurrySpeed: CGFloat = 260
    static let maxSpeed: CGFloat = 2600
    static let airDrag: Double = 0.32
    static let settleSpeed: CGFloat = 130
    static let settleTime: Double = 0.45
    static let maxTossTime: Double = 7
    static let napAfterIdle: Double = 180

    /// 走到窗沿尽头时选择「跳下去」的概率（否则掉头继续走）。测试可注成 1。
    var edgeDropChance: Double = 0.35

    /// 走出屏边 / 窗沿后的着地续走方向（跨屏：掉落到隔壁屏幕后接着走）。
    private var pendingWalkDir: CGFloat?

    private let world: WorldReading
    private var clock: Double = 0

    // 拖拽
    private var grabOffset = CGPoint.zero
    private var dragVX: CGFloat = 0
    private var dragVY: CGFloat = 0

    // 抛掷
    private var tossT: Double = 0
    private var settleT: Double = 0
    private var spinVel: CGFloat = 0

    // 拉窗（拖拽栖息宠物 = 拖它的窗口）
    private(set) var pulling = false

    init(world: WorldReading, displayHeight: CGFloat, startAt point: CGPoint) {
        self.world = world
        self.displayHeight = displayHeight
        self.x = point.x
        self.yFeet = point.y
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
        vy = PetMath.leapVelocity(rise: min(rise, 720), gravity: Self.gravity)
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
        dragVX = 0
        dragVY = 0
        state = .dragged
        walking = false
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
            if dt > 0.0001 {
                let ivx = (nx - x) / CGFloat(dt)
                let ivy = (ny - yFeet) / CGFloat(dt)
                dragVX += (ivx - dragVX) * 0.35
                dragVY += (ivy - dragVY) * 0.35
            }
            x = nx
            yFeet = ny
        }
    }

    func endDrag(wasClick: Bool) {
        guard state == .dragged else { return }
        if wasClick {
            // 摸摸头：开心一下。
            state = perch != nil ? .perched : .airborne
            if perch == nil { vy = -240 }
            return
        }
        if pulling {
            pulling = false
            state = .perched
            return
        }
        state = .tossed
        tossT = 0
        settleT = 0
        vx = PetMath.clamp(dragVX, -Self.maxSpeed, Self.maxSpeed)
        vy = PetMath.clamp(dragVY, -Self.maxSpeed, Self.maxSpeed)
        spinVel = PetMath.clamp(vx * 0.45, -700, 700)
    }

    /// 拖拽栖息宠物时窗口的原始位置（拉窗弹簧锚点），非拉窗时为 nil。
    func isPulling() -> Bool { pulling }

    // ============ 主循环 ============

    func update(dtIn: Double) {
        let dt = min(dtIn, 0.1)
        clock += dt

        switch state {
        case .grounded: updateGrounded(dt, asleep: false)
        case .asleep: updateGrounded(dt, asleep: true)
        case .perched: updatePerched(dt, asleep: state == .asleep)
        case .airborne: updateAirborne(dt)
        case .dragged: break
        case .tossed: updateTossed(dt)
        }

        clampToVirtual()
    }

    // ---- 站立（地板 / 窗口底沿）----

    private func updateGrounded(_ dt: Double, asleep: Bool) {
        guard let s = refreshStance() else { return } // 支撑面没了 → 掉落

        if !asleep && walking {
            let dir: CGFloat = facingRight ? 1 : -1
            var nx = x + dir * currentWalkSpeed * CGFloat(dt)
            let lo = s.left + bodyRadius * 0.6
            let hi = s.right - bodyRadius * 0.6
            if nx <= lo || nx >= hi {
                let edge = dir > 0 ? s.right : s.left
                // 地板：世界若在隔壁屏幕延续就直接走出去（台阶差自然掉落）；
                // 窗沿：小概率跳下，大概率掉头。
                let nextFloor = s.surface == .floor
                    ? world.floorBeyond(edgeX: edge, direction: dir)
                    : nil
                let leaveEdge = nextFloor != nil
                    || (s.surface != .floor && Double.random(in: 0..<1) < edgeDropChance)
                if leaveEdge {
                    if let next = nextFloor {
                        // 跨屏台阶：绕角下落 —— 水平贴到隔壁地板段边缘后垂直下落。
                        // 不做抛物线（间隙宽时会落到对面地板高度之下而错过整段）。
                        x = dir > 0 ? next.left + bodyRadius * 0.8 : next.right - bodyRadius * 0.8
                        vx = 0
                    } else {
                    x = dir > 0 ? s.right + 2 : s.left - 2
                    vx = dir * currentWalkSpeed
                    }
                    yFeet = s.y + 2 // 下沉脱离支撑面本身，防起落帧回粘
                    detach()
                    pendingWalkDir = dir
                    vy = 0
                    return
                }
                nx = PetMath.clamp(nx, lo, hi)
                facingRight.toggle()
            }
            x = nx
        } else {
            x = PetMath.clamp(x, s.left + bodyRadius * 0.6, s.right - bodyRadius * 0.6)
        }
        yFeet = s.y
        vx = 0
        vy = 0
    }

    // ---- 栖息（窗口顶沿，位置由 live bounds 推导）----

    private func updatePerched(_ dt: Double, asleep: Bool) {
        guard let perch, let bounds = world.liveBounds(perch.id) else {
            // 窗口关闭 / 最小化 / 切 Space：宠物掉下来。
            detach()
            vx = 0
            return
        }
        var frac = perch.frac
        if !asleep && walking {
            let margin = bodyRadius * 0.95
            let usable = max(bounds.width - margin * 2, 8)
            let dir: CGFloat = facingRight ? 1 : -1
            frac = PetMath.clamp(frac + dir * currentWalkSpeed * CGFloat(dt) / usable, 0, 1)
            if frac <= 0 || frac >= 1 {
                if Double.random(in: 0..<1) < edgeDropChance {
                    // 走出窗沿：掉下去（+2px 脱离面，防起落帧回粘）。
                    detach()
                    yFeet += 2
                    vx = dir * currentWalkSpeed
                    vy = 0
                    return
                }
                facingRight.toggle()
            }
            self.perch = (perch.id, frac)
        }
        let feetY = perchFeetY(in: bounds)
        positionOn(bounds: bounds, feetY: feetY, frac: frac)
        vx = 0
        vy = 0
    }

    /// 站窗口顶沿的脚 y，顶沿被菜单栏压住时改站标题栏。
    private func perchFeetY(in bounds: CGRect) -> CGFloat {
        let workTop = world.workBox(at: CGPoint(x: x, y: bounds.minY)).top
        return PetMath.perchFeetY(
            topY: bounds.minY,
            petHeight: displayHeight,
            workTop: workTop,
            baselineRatio: ClipLibrary.baselineRatio
        )
    }

    private func positionOn(bounds: CGRect, feetY: CGFloat, frac: CGFloat) {
        let margin = bodyRadius * 0.95
        x = PetMath.perchX(bounds: bounds, frac: frac, margin: margin)
        yFeet = feetY
    }

    // ---- 空中 ----

    private func updateAirborne(_ dt: Double) {
        let prevY = yFeet
        vy = PetMath.clamp(vy + Self.gravity * CGFloat(dt), -Self.maxSpeed, Self.maxSpeed)
        x += vx * CGFloat(dt)
        yFeet += vy * CGFloat(dt)

        if vy >= 0, let landing = landingBelow(prevY: prevY) {
            land(on: landing)
            return
        }
        // 兜底：坠到世界最深地板之下（跨屏宽间隙等极端路径）就就近落地自愈。
        let v = world.virtualBox()
        if vy >= 0, yFeet >= v.bottom {
            let floors = world.surfaces(near: x, footY: yFeet).filter { $0.surface == .floor }
            let nearest = floors.min {
                Self.distanceToSpan(x, $0.left, $0.right) < Self.distanceToSpan(x, $1.left, $1.right)
            } ?? (surface: Surface.floor, y: v.bottom, left: v.left, right: v.right)
            land(on: nearest)
        }
    }

    /// 一帧里脚底跨过的最高支撑面（翻转坐标 y 向下，「最高」= 最小的 y）。
    /// 严格穿越判定：帧首脚在面之上、帧尾在面之下。不许容差 —— 否则
    /// 刚脱离支撑面的下沉帧会被立刻「吸」回原地。
    private func landingBelow(prevY: CGFloat) -> (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)? {
        var best: (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)?
        for s in world.surfaces(near: x, footY: prevY) {
            guard x >= s.left, x <= s.right else { continue }
            guard prevY <= s.y, yFeet >= s.y else { continue }
            if best == nil || s.y < best!.y { best = s }
        }
        return best
    }

    private func land(on s: (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)) {
        yFeet = s.y
        vx = 0
        vy = 0
        switch s.surface {
        case .windowTop(let id):
            let b = world.liveBounds(id) ?? CGRect(x: s.left, y: s.y, width: 1, height: 1)
            let margin = bodyRadius * 0.95
            perch = (id, PetMath.perchFrac(x: x, bounds: b, margin: margin))
            state = .perched
        case .floor, .windowBottom:
            state = .grounded
        }
        stance = s
        // 跨屏 / 跳窗沿的掉落途中保留了行走意图：落地接着走。
        if let d = pendingWalkDir {
            pendingWalkDir = nil
            walking = true
            facingRight = d > 0
        }
    }

    /// 站立 / 栖息时每帧重读支撑面；没了返回 nil（该掉落了）。
    /// 地板有多段（多显示器）：必须取横向包含脚下的那一段。
    private func refreshStance() -> (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)? {
        guard state != .perched else { return nil } // perched 的支撑检查在 updatePerched 里做
        guard let s = stance else { return nil }
        let candidates = world.surfaces(near: x, footY: yFeet).filter { $0.surface == s.surface }
        let current = candidates.first { x >= $0.left && x <= $0.right }
            ?? candidates.min { Self.distanceToSpan(x, $0.left, $0.right) < Self.distanceToSpan(x, $1.left, $1.right) }
        guard let s2 = current else { detach(); return nil }
        stance = s2
        return s2
    }

    private static func distanceToSpan(_ x: CGFloat, _ left: CGFloat, _ right: CGFloat) -> CGFloat {
        if x < left { return left - x }
        if x > right { return x - right }
        return 0
    }

    // ---- 抛掷 ----

    private func updateTossed(_ dt: Double) {
        tossT += dt
        // 横向墙用显示器并集（宠物可以被扔过屏幕边界），纵向用所在屏工作区。
        let work = world.workBox(at: CGPoint(x: x, y: yFeet))
        let v = world.virtualBox()
        let (p, v2, event) = PetMath.stepToss(
            position: CGPoint(x: x, y: yFeet),
            velocity: CGPoint(x: vx, y: vy),
            dt: dt,
            gravity: Self.gravity,
            airDrag: Self.airDrag,
            bounds: PetMath.Box(left: v.left, top: work.top, right: v.right, bottom: work.bottom),
            radius: bodyRadius
        )
        x = p.x
        yFeet = p.y
        vx = v2.x
        vy = v2.y

        // 飞行途中砸到窗口顶沿：顺势蹲上去。
        if let landing = landingBelow(prevY: yFeet - vy * CGFloat(dt)), event == .none {
            land(on: landing)
            return
        }

        let speed = sqrt(vx * vx + vy * vy)
        if event == .floor && speed < Self.settleSpeed {
            settleT += dt
        } else {
            settleT = 0
        }
        if settleT > Self.settleTime || tossT > Self.maxTossTime {
            state = .grounded
            stance = (surface: .floor, y: work.bottom, left: work.left, right: work.right)
            spinVel = 0
        }
    }

    // ---- 通用 ----

    private func clampToVirtual() {
        guard state != .dragged else { return }
        let v = world.virtualBox()
        let m = bodyRadius * 0.35
        if x < v.left + m { x = v.left + m; if vx < 0 { vx = 0 } }
        if x > v.right - m { x = v.right - m; if vx > 0 { vx = 0 } }
        // yFeet 是脚底：头顶不进虚拟区上沿，脚不沉出下沿。
        if yFeet - displayHeight < v.top { yFeet = v.top + displayHeight; if vy < 0 { vy = 0 } }
        if yFeet > v.bottom { yFeet = v.bottom; if vy > 0 { vy = 0 } }
    }

    /// 离开当前支撑面进入空中。
    private func detach() {
        perch = nil
        stance = nil
        pendingWalkDir = nil
        if state != .dragged && state != .tossed {
            state = .airborne
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
