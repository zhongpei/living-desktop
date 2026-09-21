import CoreGraphics

/// 桌面世界里的一扇真实窗口。对宠物来说它就是一个平台（Platform），
/// game-v2 之后还是一块有语义的地形（activity/affordances 见 Game/AppActivity.swift）。
struct WindowEntity: Equatable {
    /// CGWindowID，窗口关闭 / 最小化 / 切 Space 后即失效。
    let id: CGWindowID
    let pid: pid_t
    /// 窗口服务器直接给的应用名（owner），读取它不需要任何权限。
    let owner: String
    /// 翻转全局坐标（原点 = 主屏左上，y 向下），与 CGWindowList 同系。
    let bounds: CGRect
    /// Optional title from the window server. It is empty without the relevant
    /// macOS permission, but remains useful as a fast title channel when present.
    var windowTitle: String = ""
    /// 运行中进程的 bundleID（NSRunningApplication 免授权可查；离线测试为 nil）。
    var bundleID: String? = nil
    /// 活动语义（AppActivity.rawValue；未归类为 "unknown"）。
    var activity: String = AppActivity.unknown.rawValue

    /// 窗口顶沿的 y（可栖息面）。
    var topY: CGFloat { bounds.minY }
    /// 窗口底沿的 y（可当作台阶的矮沿）。
    var bottomY: CGFloat { bounds.maxY }

    var appActivity: AppActivity { AppActivity(rawValue: activity) ?? .unknown }
}

/// 可站立的面。窗口顶沿是「窗台」，窗口底沿是「台阶」，桌面地板是兜底。
enum Surface: Equatable {
    case floor
    case windowTop(CGWindowID)
    case windowBottom(CGWindowID)
}
