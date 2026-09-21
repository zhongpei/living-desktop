import CoreGraphics
import Foundation

/// 宠物世界的纯数学：栖息定位、跳跃初速、抛掷反弹、拉窗弹簧。
/// 全部无副作用、无 AppKit 依赖 —— 状态机的可测核心。
enum PetMath {

    // ---- 栖息（Surface Attachment）----

    /// 窗口顶沿上的横向位置：left + margin + frac × 可用宽。
    static func perchX(bounds: CGRect, frac: CGFloat, margin: CGFloat) -> CGFloat {
        let usable = max(bounds.width - margin * 2, 8)
        return bounds.minX + margin + clamp(frac, 0, 1) * usable
    }

    /// 脚踩窗口顶沿时的 y。若头顶会钻进菜单栏，改为站在标题栏上（顶沿往下让位）。
    /// - Parameters:
    ///   - topY: 窗口顶沿（翻转坐标）
    ///   - petHeight: 宠物显示高度
    ///   - workTop: 所在屏工作区顶沿（菜单栏下沿）
    ///   - baselineRatio: 素材脚底在 cell 中的基线比例
    ///   - titleBarInset: 有标题栏空间时，向窗口内让位的最小距离
    static func perchFeetY(topY: CGFloat, petHeight: CGFloat, workTop: CGFloat,
                           baselineRatio: CGFloat = 0.88,
                           titleBarInset: CGFloat = 24) -> CGFloat {
        let onTop = topY
        // 面板的可见顶沿是 `feetY - height * baselineRatio`，而不是
        // `feetY - height`。旧算法只看整张 cell，高角色仍可能把上半身
        // 放进菜单栏/屏幕外；这里直接以真实脚底基线计算最低安全脚位。
        let minimumVisibleFeet = workTop + petHeight * baselineRatio
        guard onTop - petHeight * baselineRatio < workTop else { return onTop }
        return max(onTop + titleBarInset, minimumVisibleFeet)
    }

    /// 由横向位置反推栖息分数 frac（拉窗时宠物跟着光标滑动要用）。
    static func perchFrac(x: CGFloat, bounds: CGRect, margin: CGFloat) -> CGFloat {
        let usable = max(bounds.width - margin * 2, 8)
        return clamp((x - bounds.minX - margin) / usable, 0, 1)
    }

    // ---- 跳跃 ----

    /// 跳上高差 rise 所需的竖直初速（重力 g 向下为正）。额外加 clearance 余量。
    static func leapVelocity(rise: CGFloat, gravity: CGFloat, clearance: CGFloat = 24) -> CGFloat {
        -sqrt(max(0, 2 * gravity * (rise + clearance)))
    }

    /// 竖直初速 v 在重力 g 下能到的最高点。
    static func apexHeight(velocity: CGFloat, gravity: CGFloat) -> CGFloat {
        velocity * velocity / (2 * gravity)
    }

    // ---- 抛掷 ----

    /// 抛掷物理一步：重力 + 空气阻力 + 四壁反弹。
    /// - Parameters:
    ///   - radius: 宠物半宽（各向同性近似）
    ///   - restitutionY/X: 反弹恢复系数
    static func stepToss(position: CGPoint, velocity: CGPoint, dt: Double,
                         gravity: CGFloat, airDrag: Double,
                         bounds: PetMath.Box, radius: CGFloat,
                         restitutionY: CGFloat = 0.5, restitutionX: CGFloat = 0.58) -> (CGPoint, CGPoint, TossEvent) {
        var p = position
        var v = velocity
        var event = TossEvent.none

        v.y += gravity * CGFloat(dt)
        v.x *= CGFloat(1 - airDrag * dt)

        p.x += v.x * CGFloat(dt)
        p.y += v.y * CGFloat(dt)

        if p.y > bounds.bottom - radius {
            p.y = bounds.bottom - radius
            v.y = -v.y * restitutionY
            v.x *= 0.74
            event = .floor
        }
        if p.y < bounds.top + radius {
            p.y = bounds.top + radius
            v.y = abs(v.y) * 0.4
            event = .ceiling
        }
        if p.x < bounds.left + radius {
            p.x = bounds.left + radius
            v.x = abs(v.x) * restitutionX
            event = .wall
        }
        if p.x > bounds.right - radius {
            p.x = bounds.right - radius
            v.x = -abs(v.x) * restitutionX
            event = .wall
        }
        return (p, v, event)
    }

    enum TossEvent { case none, floor, ceiling, wall }

    struct Box {
        var left: CGFloat
        var top: CGFloat
        var right: CGFloat
        var bottom: CGFloat
    }

    // ---- 拉窗弹簧 ----

    /// 宠物走 x，窗口动 stretch × strength，但最多 ±maxPull —— 小动物很努力，窗口很重。
    static func pullDelta(stretch: CGFloat, strength: CGFloat = 0.4, maxPull: CGFloat = 120) -> CGFloat {
        clamp(stretch * strength, -maxPull, maxPull)
    }

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        v < lo ? lo : (v > hi ? hi : v)
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v < lo ? lo : (v > hi ? hi : v)
    }
}
