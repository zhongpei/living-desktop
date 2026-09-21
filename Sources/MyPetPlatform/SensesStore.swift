import Foundation

// 感知结果的宿主侧缓存（阶段 E2）。
//
// 语义（最终决策）：
// - 传感器事件 = 感知失效通知，不是宠物行为事件。脏了 → 防抖 → 重新 sense →
//   BrainContextSnapshot 变化 → 由大脑决定是否值得反应。v1 没有 AXObserver，脏标记只来自
//   前台应用变化这类确定性事件；TTL 兜底刷新。
// - 感知只在内存中更新，统一脑路日志在决策发生时保存当次快照。

public final class SensesStore {

    /// 观察的有效期（秒）。大脑决策间隔 4~10s，取稍长于它的窗口。
    public var ttl: Double = 6
    /// 脏标记后的防抖冷却（秒），防止打字流疯狂触发重感。
    public var resenseCooldown: Double = 2

    public private(set) var observation: SensorObservation?
    public private(set) var isDirty = false
    private var dirtyAt: Double = 0

    /// 当前可用观察；过期返回 nil（调用方据此发起新的 sense）。
    public init() {}

    public func current(now: Double) -> SensorObservation? {
        guard let o = observation, now - o.timestamp <= ttl else { return nil }
        return o
    }

    public func update(_ o: SensorObservation) {
        observation = o
        isDirty = false
    }

    public func clear() {
        observation = nil
        isDirty = false
    }

    /// 感知失效：前台变化、（将来）AX 值变化等。
    public func markDirty(now: Double) {
        guard !isDirty else { return }
        isDirty = true
        dirtyAt = now
    }

    /// 脏了且过了防抖冷却 → 该重新 sense 了。
    public func shouldResense(now: Double) -> Bool {
        isDirty && now - dirtyAt >= resenseCooldown
    }

    /// 注入大脑快照的 senses 段；过期或禁用返回 nil。
    public func sensesSection(now: Double) -> String? {
        guard let o = current(now: now) else { return nil }
        return SensorContract.sensesJSON(o)
    }
}
