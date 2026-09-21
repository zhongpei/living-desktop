import CoreGraphics
import Foundation

// 锚点 —— 窗口地形的几何半张脸。
//
// 大脑与场景配方不碰坐标：`move_to(window_42.top_right)` 就是全部输入；
// 运行时在这里把锚点解析成走位点 / 起跳目标。窗口挪走、关掉、最小化时
// 解析返回 nil，场景步骤优雅失败（场景中断 → 回目标规划），绝不追空窗口。

/// 窗口上的可到达位置。top* = 窗台（栖息面），bottom* = 底沿台阶。
enum AnchorSlot: String, Equatable, CaseIterable {
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var isTop: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight: return true
        case .bottomLeft, .bottomCenter, .bottomRight: return false
        }
    }

    /// 锚点在窗口 bounds 内的横向分数（0~1）。
    var frac: CGFloat {
        switch self {
        case .topLeft, .bottomLeft: return 0.15
        case .topCenter, .bottomCenter: return 0.5
        case .topRight, .bottomRight: return 0.85
        }
    }
}

/// 一条锚点引用："window_<CGWindowID>.<slot>" 或虚拟锚 "floor_near"。
struct AnchorSpec: Equatable {
    var windowID: CGWindowID?
    var slot: AnchorSlot
    var virtual: String?

    /// 解析失败返回 nil（窗口没了 / id 不合法）。
    static func parse(_ text: String) -> AnchorSpec? {
        if text == "floor_near" {
            return AnchorSpec(windowID: nil, slot: .bottomCenter, virtual: text)
        }
        guard text.hasPrefix("window_") else { return nil }
        let rest = text.dropFirst("window_".count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        guard let id = UInt32(rest[..<dot]), let slot = AnchorSlot(rawValue: String(rest[rest.index(after: dot)...])) else {
            return nil
        }
        return AnchorSpec(windowID: CGWindowID(id), slot: slot, virtual: nil)
    }

    var id: String {
        if let virtual { return virtual }
        return "window_\(windowID ?? 0).\(slot.rawValue)"
    }
}

/// 世界里的一条可选锚点（大脑快照的 nearby 条目）。
struct AnchorEntry: Equatable {
    var spec: AnchorSpec
    /// 翻转全局坐标落点（top* 是窗台脚位，bottom* 是台阶脚位）。
    var point: CGPoint
    var distance: Int
    var owner: String
    var activity: AppActivity
    var affordances: [Affordance]

    var snapshotID: String { spec.id }
}

enum AnchorResolver {

    /// 从窗口集合收集有界锚点表（每扇窗口 top 与 bottom 各一条近端槽位，
    /// 按距离排序，供快照 enum 与场景解析共用）。
    /// - Parameters:
    ///   - slotsPerWindow: 每扇窗口暴露几条锚（快照限 2 条防 enum 膨胀；解析时给 nil = 全部）。
    static func nearbyAnchors(
        windows: [WindowEntity],
        petX: CGFloat,
        limit: Int? = nil,
        slotsPerWindow: Int? = 2
    ) -> [AnchorEntry] {
        var entries: [AnchorEntry] = []
        for w in windows {
            // 距离最近的槽位优先：横向离宠物近的一端 + 同端上下。
            let chosen: [AnchorSlot]
            if let n = slotsPerWindow {
                let nearTop: AnchorSlot = petX < w.bounds.midX ? .topLeft : .topRight
                let nearBottom: AnchorSlot = petX < w.bounds.midX ? .bottomLeft : .bottomRight
                chosen = Array([nearTop, nearBottom].prefix(n))
            } else {
                chosen = AnchorSlot.allCases
            }
            for slot in chosen {
                let point = point(on: w, slot: slot)
                entries.append(AnchorEntry(
                    spec: AnchorSpec(windowID: w.id, slot: slot, virtual: nil),
                    point: point,
                    distance: Int(abs(point.x - petX)),
                    owner: w.owner,
                    activity: AppActivity(rawValue: w.activity) ?? .unknown,
                    affordances: Affordance.affordances(for: AppActivity(rawValue: w.activity) ?? .unknown)))
            }
        }
        entries.sort { $0.distance < $1.distance }
        if let limit { entries = Array(entries.prefix(limit)) }
        return entries
    }

    /// 解析一条 spec 的当前落点（窗口实时性由调用方的 windows 快照保证；
    /// 栖息跟随由 PetModel 的 perch 机制负责，这里只给初始目标）。
    static func resolve(_ spec: AnchorSpec, windows: [WindowEntity]) -> (point: CGPoint, window: WindowEntity?)? {
        if let virtual = spec.virtual, virtual == "floor_near" {
            return (CGPoint(x: 0, y: 0), nil)  // 落点由控制器按宠物脚下地板段现算
        }
        guard let id = spec.windowID, let w = windows.first(where: { $0.id == id }) else { return nil }
        return (point(on: w, slot: spec.slot), w)
    }

    static func point(on w: WindowEntity, slot: AnchorSlot) -> CGPoint {
        let x = w.bounds.minX + w.bounds.width * slot.frac
        let y = slot.isTop ? w.topY : w.bottomY
        return CGPoint(x: x, y: y)
    }
}
