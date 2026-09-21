import AppKit
import CoreGraphics

/// 全局屏幕几何。
///
/// 世界模拟统一使用「翻转全局坐标」：原点 = 主屏左上角，x 向右、y 向下。
/// 这与 `CGWindowListCopyWindowInfo` 返回的 bounds 直接同系，窗口世界不需要换算；
/// 只有把宠物 NSPanel 摆上屏幕那一刻才换回 AppKit 坐标（原点左下、y 向上）。
enum Screens {

    struct Box: Equatable {
        var left: CGFloat
        var top: CGFloat
        var right: CGFloat
        var bottom: CGFloat

        var width: CGFloat { right - left }
        var height: CGFloat { bottom - top }

        func contains(x: CGFloat, y: CGFloat) -> Bool {
            x >= left && x <= right && y >= top && y <= bottom
        }
    }

    /// 主屏在 AppKit 坐标里的上沿（= 主屏高度），翻转坐标的换算基准。
    static var primaryTopY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// 所有显示器的并集（翻转坐标），宠物活动的世界边界。
    static func virtualBox() -> Box {
        guard !NSScreen.screens.isEmpty else {
            return Box(left: 0, top: 0, right: 1440, bottom: 900)
        }
        var box = flippedBox(of: NSScreen.screens[0])
        for screen in NSScreen.screens.dropFirst() {
            let b = flippedBox(of: screen)
            box.left = min(box.left, b.left)
            box.top = min(box.top, b.top)
            box.right = max(box.right, b.right)
            box.bottom = max(box.bottom, b.bottom)
        }
        return box
    }

    /// 包含点 p 的显示器的工作区（去掉菜单栏 / Dock，翻转坐标）。
    /// p 不落在任何屏幕上时返回主屏工作区。
    static func workBox(containing p: CGPoint) -> Box {
        guard let screen = NSScreen.screens.first(where: { flippedBox(of: $0).contains(x: p.x, y: p.y) })
                ?? NSScreen.main else {
            return Box(left: 0, top: 0, right: 1440, bottom: 900)
        }
        return flippedBox(of: screen, visible: true)
    }

    static func screenBox(containing p: CGPoint) -> Box {
        workBoxOfScreen(containing: p, visible: false)
    }

    static func workBoxOfScreen(containing p: CGPoint, visible: Bool) -> Box {
        guard let screen = NSScreen.screens.first(where: { flippedBox(of: $0).contains(x: p.x, y: p.y) })
                ?? NSScreen.main else {
            return Box(left: 0, top: 0, right: 1440, bottom: 900)
        }
        return flippedBox(of: screen, visible: visible)
    }

    /// 所有显示器的工作区（翻转坐标），每屏一条。
    static func allWorkBoxes() -> [Box] {
        NSScreen.screens.map { flippedBox(of: $0, visible: true) }
    }

    /// 合并后的连续地板段。等高（差 ≤1pt）且横向间距 ≤120pt 的屏幕底沿
    /// 合并成一段 —— 宠物可以无缝走过去；高低不同的屏幕是「台阶」，
    /// 由 PetModel 的 floorBeyond 逻辑决定走过去时掉落还是掉头。
    static func mergedFloorSegments() -> [(left: CGFloat, right: CGFloat, y: CGFloat)] {
        mergeFloorSegments(allWorkBoxes())
    }

    /// 纯函数，离线可测：把各屏工作区底沿合并成地板段。
    static func mergeFloorSegments(_ boxes: [Box]) -> [(left: CGFloat, right: CGFloat, y: CGFloat)] {
        var segments: [(left: CGFloat, right: CGFloat, y: CGFloat)] = []
        for box in boxes {
            segments.append((left: box.left, right: box.right, y: box.bottom))
        }
        segments.sort {
            if $0.y == $1.y { return $0.left < $1.left }
            return $0.y < $1.y
        }
        var merged: [(left: CGFloat, right: CGFloat, y: CGFloat)] = []
        for seg in segments {
            var target: Int?
            for (i, m) in merged.enumerated() {
                let sameHeight = abs(m.y - seg.y) <= 1
                let touches = seg.left <= m.right + 120 && seg.right >= m.left - 120
                if sameHeight && touches {
                    target = i
                    break
                }
            }
            if let i = target {
                merged[i].left = min(merged[i].left, seg.left)
                merged[i].right = max(merged[i].right, seg.right)
            } else {
                merged.append(seg)
            }
        }
        merged.sort { $0.left < $1.left }
        return merged
    }

    /// AppKit 全局 rect（原点左下）→ 翻转 box。
    static func flippedBox(of screen: NSScreen, visible: Bool = false) -> Box {
        let frame = visible ? screen.visibleFrame : screen.frame
        let primaryMax = primaryTopY
        return Box(
            left: frame.minX,
            top: primaryMax - frame.maxY,
            right: frame.maxX,
            bottom: primaryMax - frame.minY
        )
    }

    /// 翻转坐标 y（一个点）→ AppKit 坐标 y。
    static func appKitY(flippedY: CGFloat) -> CGFloat {
        primaryTopY - flippedY
    }

    /// 已知顶沿的翻转 rect → AppKit origin.y。纯函数，便于单测。
    static func appKitOriginY(flippedTop: CGFloat, height: CGFloat, primaryMax: CGFloat) -> CGFloat {
        primaryMax - flippedTop - height
    }

    /// 翻转 rect → AppKit rect。用于摆放 NSPanel。
    static func appKitRect(flippedTop: CGFloat, x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: x,
            y: appKitOriginY(flippedTop: flippedTop, height: height, primaryMax: primaryTopY),
            width: width,
            height: height
        )
    }
}
