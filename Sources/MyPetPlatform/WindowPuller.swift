import AppKit
import ApplicationServices
import CoreGraphics

/// 「宠物拉窗口」执行器：拖动栖息中的宠物时，窗口被弹簧拽着走。
///
/// delta = clamp(stretch × pullStrength, ±maxPull) —— 小动物很努力，窗口很重。
///
/// AX 写位置是同步跨进程 IPC，绝不能在鼠标事件回调里连发：
/// serial 队列 + latest-wins 合并（只有最后一次写会真正执行），
/// 这个坑与解法来自 ModDrag 的实践，实现为本仓库自有代码。
public final class WindowPuller {
    private static var didPromptForTrust = false

    private var axWindow: AXWindow?
    private var positionWriter: LatestValueWorker<CGPoint>?
    private var anchor = CGPoint.zero
    public private(set) var isActive = false

    /// 弹簧参数（game.md §13）。
    public var pullStrength: CGFloat = 0.4
    public var maxPull: CGFloat = 120

    public init() {}

    /// 每个应用的「窗口手感质量」：Finder 轻、重应用沉，纯游戏手感非物理事实。
    public static func windowMass(forApp owner: String) -> CGFloat {
        if owner == "Finder" { return 0.8 }
        if ["Xcode", "Google Chrome", "Safari", "Firefox"].contains(owner) { return 1.3 }
        return 1.0
    }

    /// 开始拉：锚定窗口左上角的原始位置。
    public func begin(windowID: CGWindowID, pid: pid_t) {
        guard let ax = AXWindow.window(matching: windowID, pid: pid) else { return }
        ax.setMessagingTimeout(0.05)
        guard let origin = ax.position else { return }
        axWindow = ax
        positionWriter = LatestValueWorker(
            label: "mypet.window-pull", qos: .userInteractive
        ) { point in
            _ = ax.setPosition(point)
        }
        anchor = origin
        isActive = true
    }

    /// 光标移动 → 计算弹簧 delta → 合并写入。cursor 均为翻转坐标。
    /// AX 的 kAXPositionAttribute 与 CGWindowList 同系：主屏左上原点、y 向下，
    /// 与世界模拟的翻转坐标一致，无需换算。
    public func update(cursor: CGPoint, cursorStart: CGPoint, mass: CGFloat = 1.0) {
        guard isActive else { return }
        let strength = pullStrength / mass
        let dx = Self.pullDelta(stretch: cursor.x - cursorStart.x, strength: strength, maxPull: maxPull)
        let dy = Self.pullDelta(stretch: cursor.y - cursorStart.y, strength: strength, maxPull: maxPull)
        let target = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        positionWriter?.submit(target)
    }

    /// 松口：窗口留在当前位置。
    public func end() {
        positionWriter?.cancelPendingAndWait()
        positionWriter = nil
        axWindow?.setMessagingTimeout(0)
        axWindow = nil
        isActive = false
    }

    /// 当前是否拥有辅助功能权限（不弹窗）。
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 请求辅助功能权限：跳系统设置并提示用户。返回当前（授权前的）信任状态。
    @discardableResult
    public static func promptForTrust() -> Bool {
        guard !didPromptForTrust else { return AXIsProcessTrusted() }
        didPromptForTrust = true
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func pullDelta(stretch: CGFloat, strength: CGFloat, maxPull: CGFloat) -> CGFloat {
        min(max(stretch * strength, -maxPull), maxPull)
    }
}
