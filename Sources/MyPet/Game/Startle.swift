import CoreGraphics
import Foundation

// Startle —— 「鼠标突然靠近」即时反射检测（game.md §13 第一层，<50ms，不进大脑）。
//
// 纯逻辑：每帧喂入光标与宠物位置，只在「距离近 + 逼近速度大」时触发惊吓。
// 慢慢移过去不触发（那是靠近，不是偷袭）；冷却期内不重复触发。

struct StartleDetector {

    /// 触发距离（pt，与宠物身体中心的距离）。
    var triggerDistance: CGFloat = 110
    /// 最小逼近速度（pt/s；低于此视为正常移动/悬停）。
    var approachSpeed: CGFloat = 700
    /// 触发后的冷却（秒）。
    var cooldown: Double = 6

    private var lastDistance: CGFloat?
    private var lastTime: Double?
    private var lastTriggerAt: Double = -.infinity

    /// 每帧喂入。返回 true = 触发一次惊吓（内部自动进入冷却）。
    mutating func update(cursor: CGPoint, pet: CGPoint, now: Double) -> Bool {
        let distance = hypot(cursor.x - pet.x, cursor.y - pet.y)
        defer {
            lastDistance = distance
            lastTime = now
        }
        guard now - lastTriggerAt >= cooldown else { return false }
        guard let prevDistance = lastDistance, let prevTime = lastTime, now > prevTime else {
            return false
        }
        let closingSpeed = (prevDistance - distance) / CGFloat(now - prevTime)  // 正 = 在逼近
        guard distance < triggerDistance, closingSpeed > approachSpeed else { return false }
        lastTriggerAt = now   // 触发即进冷却
        return true
    }

    /// 重置采样基线并**清除冷却**（语境变了：场景开始/结束、宠物被挪动）。
    mutating func reset() {
        lastDistance = nil
        lastTime = nil
        lastTriggerAt = -.infinity
    }
}
