import CoreGraphics
import MyPetPlatform

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

    private let source: MacWindowSource
    private struct ForegroundIdentity: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let owner: String
    }
    private var lastForegroundIdentity: ForegroundIdentity?

    init(source: MacWindowSource = MacWindowSource()) {
        self.source = source
    }

    /// 和真实窗口一起住在 layer 0 的系统家具，不是可栖息的平台。
    static let skippedOwners = MacWindowSource.defaultSkippedOwners

    /// 小于这个尺寸的窗口不配当平台（提示浮窗、小工具之类，站上去太挤）。
    static let minimumPlatformSize = CGSize(width: 220, height: 140)

    func poll() {
        source.poll()
        windows = source.windows.map(Self.project)
        observeForeground(source.foreground.map(Self.project))
    }

    func observeForeground(_ window: WindowEntity?) {
        foreground = window
        let identity = window.map { ForegroundIdentity(id: $0.id, pid: $0.pid, owner: $0.owner) }
        guard identity != lastForegroundIdentity else { return }
        lastForegroundIdentity = identity
        onForegroundChanged?(window)
    }

    /// 零权限语义注入：bundleID 来自运行中进程（免授权），owner 来自 CGWindowList。
    /// 窗口标题只有屏幕录制权限才拿得到，归类退化到 app 级；
    /// 标题级细分（浏览器里看视频 vs 看文档）由 OCR/AX 感知层喂给 BrainContextSnapshot。
    private static func project(_ window: PlatformWindow) -> WindowEntity {
        var projected = WindowEntity(
            id: window.id, pid: window.pid, owner: window.owner,
            bounds: window.bounds, windowTitle: window.title, bundleID: window.bundleID)
        projected.activity = AppActivityCatalog.classify(
            owner: window.owner, bundleID: window.bundleID,
            windowTitle: window.title).rawValue
        return projected
    }

    /// CGWindowList 字典 → [WindowEntity]。静态纯函数，离线可测。
    static func decodeWindows(ownPID: pid_t, list: [[String: Any]]? = nil) -> [WindowEntity] {
        MacWindowSource.decodeWindows(
            ownPID: ownPID, list: list, skippedOwners: skippedOwners,
            minimumSize: minimumPlatformSize).map(project)
    }

    static func decodeWindow(_ d: [String: Any], ownPID: pid_t) -> WindowEntity? {
        MacWindowSource.decodeWindow(
            d, ownPID: ownPID, skippedOwners: skippedOwners,
            minimumSize: minimumPlatformSize).map(project)
    }

    func window(_ id: CGWindowID) -> WindowEntity? {
        windows.first { $0.id == id }
    }

    /// 直接向窗口服务器重取这扇窗口的实时 bounds，栖息其上的宠物因此能跟着窗口走。
    /// 窗口关闭 / 最小化 / 挪去别的 Space 时返回 nil —— 宠物该掉下来了。
    func liveBounds(_ id: CGWindowID) -> CGRect? {
        source.liveBounds(id)
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
