import AppKit
import CoreGraphics

/// 窗口世界的唯一事实源。
///
/// `CGWindowListCopyWindowInfo` 报告每扇窗口的 owner / layer / bounds，全程零权限；
/// 窗口标题才需要「屏幕录制」权限，而宠物只需要 owner 名，所以永远不去申请。
/// 轮询足够便宜，可以一秒跑几次。
final class WindowWorld {

    private(set) var windows: [WindowEntity] = []
    private(set) var foreground: WindowEntity?

    /// 前台应用变化时回调（切 App、或同一 App 内抬高另一扇窗口）。
    var onForegroundChanged: ((WindowEntity?) -> Void)?

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var lastForegroundID: CGWindowID = 0

    /// 和真实窗口一起住在 layer 0 的系统家具，不是可栖息的平台。
    static let skippedOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "Wallpaper", "WindowManager",
        "universalaccessd", "Screenshot"
    ]

    /// 小于这个尺寸的窗口不配当平台（提示浮窗、小工具之类，站上去太挤）。
    static let minimumPlatformSize = CGSize(width: 220, height: 140)

    func poll() {
        windows = Self.decodeWindows(ownPID: ownPID)
        enrichActivities()

        var fg: WindowEntity?
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            fg = windows.first { $0.pid == frontPID }
        }
        foreground = fg

        let fgID = fg?.id ?? 0
        if fgID != lastForegroundID {
            lastForegroundID = fgID
            onForegroundChanged?(fg)
        }
    }

    /// 零权限语义注入：bundleID 来自运行中进程（免授权），owner 来自 CGWindowList。
    /// 窗口标题只有屏幕录制权限才拿得到，归类退化到 app 级；
    /// 标题级细分（浏览器里看视频 vs 看文档）由 OCR/AX 感知层喂给 WorldState。
    private func enrichActivities() {
        for i in windows.indices {
            let bundleID = NSRunningApplication(processIdentifier: windows[i].pid)?.bundleIdentifier
            windows[i].bundleID = bundleID
            windows[i].activity = AppActivityCatalog.classify(
                owner: windows[i].owner,
                bundleID: bundleID,
                windowTitle: windows[i].windowTitle).rawValue
        }
    }

    /// CGWindowList 字典 → [WindowEntity]。静态纯函数，离线可测。
    static func decodeWindows(ownPID: pid_t, list: [[String: Any]]? = nil) -> [WindowEntity] {
        let raw: [[String: Any]]
        if let list {
            raw = list
        } else {
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            raw = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        }
        // 列表自带前后层叠序（最前在前）。
        return raw.compactMap { decodeWindow($0, ownPID: ownPID) }
    }

    static func decodeWindow(_ d: [String: Any], ownPID: pid_t) -> WindowEntity? {
        // 只要普通窗口层。
        guard (d[kCGWindowLayer as String] as? Int) == 0 else { return nil }

        let pid = (d[kCGWindowOwnerPID as String] as? Int) ?? 0
        if pid == ownPID { return nil }

        let owner = (d[kCGWindowOwnerName as String] as? String) ?? ""
        if skippedOwners.contains(owner) { return nil }

        if let alpha = d[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }

        guard let b = d[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let w = b["Width"] as? Double, let h = b["Height"] as? Double,
              w.isFinite, h.isFinite else { return nil }

        let rect = CGRect(x: x, y: y, width: w, height: h)
        guard rect.width >= minimumPlatformSize.width,
              rect.height >= minimumPlatformSize.height else { return nil }

        let id = (d[kCGWindowNumber as String] as? Int) ?? 0
        guard id != 0 else { return nil }

        let title = (d[kCGWindowName as String] as? String) ?? ""

        return WindowEntity(
            id: CGWindowID(id),
            pid: pid_t(pid),
            owner: owner,
            bounds: rect,
            windowTitle: String(title.prefix(120))
        )
    }

    func window(_ id: CGWindowID) -> WindowEntity? {
        windows.first { $0.id == id }
    }

    /// 直接向窗口服务器重取这扇窗口的实时 bounds，栖息其上的宠物因此能跟着窗口走。
    /// 窗口关闭 / 最小化 / 挪去别的 Space 时返回 nil —— 宠物该掉下来了。
    func liveBounds(_ id: CGWindowID) -> CGRect? {
        guard id != 0 else { return nil }
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let d = list.first else { return nil }
        // 最小化 / 隐藏的窗口干脆没有 kCGWindowIsOnscreen 这个键。
        guard (d[kCGWindowIsOnscreen as String] as? Bool) == true else { return nil }
        guard let b = d[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let w = b["Width"] as? Double, let h = b["Height"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 一扇值得拜访的窗口：多半是前台的，偶尔换换口味。
    func interestingWindow() -> WindowEntity? {
        if windows.isEmpty { return nil }
        if let fg = foreground, Double.random(in: 0..<1) < 0.65 { return fg }
        return windows[Int.random(in: 0..<windows.count)]
    }

    /// 给定脚下位置，收集所有可站立面：全部地板段 + 每扇窗口的顶沿和底沿。
    /// 供物理层做落点判定。
    func surfaces(near x: CGFloat, footY: CGFloat) -> [(surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)] {
        var result: [(Surface, CGFloat, CGFloat, CGFloat)] =
            Screens.mergedFloorSegments().map { (.floor, $0.y, $0.left, $0.right) }
        for w in windows {
            result.append((.windowTop(w.id), w.topY, w.bounds.minX, w.bounds.maxX))
            result.append((.windowBottom(w.id), w.bottomY, w.bounds.minX, w.bounds.maxX))
        }
        return result
    }

    /// 宠物脚下这段地板的范围（用于大脑选散步目标）。
    func floorSpan(near x: CGFloat, footY: CGFloat) -> (left: CGFloat, right: CGFloat, y: CGFloat) {
        let segs = Screens.mergedFloorSegments()
        if let containing = segs.first(where: { x >= $0.left && x <= $0.right }) {
            return containing
        }
        return segs.min {
            abs(($0.left + $0.right) / 2 - x) < abs(($1.left + $1.right) / 2 - x)
        } ?? (x - 720, x + 720, footY)
    }

    /// 走到 edgeX 这条屏边时，隔壁屏幕是否有地板延续（跨屏台阶）。
    /// 有 → 宠物走过去（高低差自然掉落）；没有 → 掉头。
    func floorBeyond(edgeX: CGFloat, direction: CGFloat, within: CGFloat = 160) -> (surface: Surface, y: CGFloat, left: CGFloat, right: CGFloat)? {
        for seg in Screens.mergedFloorSegments() {
            let isBeyond = direction > 0 ? seg.left > edgeX - 2 : seg.right < edgeX + 2
            let isNear = direction > 0 ? seg.left <= edgeX + within : seg.right >= edgeX - within
            if isBeyond && isNear {
                return (surface: .floor, y: seg.y, left: seg.left, right: seg.right)
            }
        }
        return nil
    }
}
