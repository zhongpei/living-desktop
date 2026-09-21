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
final class WindowPuller {
    private static var didPromptForTrust = false

    private let queue = DispatchQueue(label: "mypet.window-pull", qos: .userInteractive)
    private var axWindow: AXWindow?
    private var pending: CGPoint?
    private var anchor = CGPoint.zero
    private(set) var isActive = false

    /// 弹簧参数（game.md §13）。
    var pullStrength: CGFloat = 0.4
    var maxPull: CGFloat = 120

    /// 每个应用的「窗口手感质量」：Finder 轻、重应用沉，纯游戏手感非物理事实。
    static func windowMass(forApp owner: String) -> CGFloat {
        if owner == "Finder" { return 0.8 }
        if ["Xcode", "Google Chrome", "Safari", "Firefox"].contains(owner) { return 1.3 }
        return 1.0
    }

    /// 开始拉：锚定窗口左上角的原始位置。
    func begin(window: WindowEntity) {
        guard let ax = AXWindow.window(matching: window.id, pid: window.pid) else { return }
        ax.setMessagingTimeout(0.05)
        guard let origin = ax.position else { return }
        axWindow = ax
        anchor = origin
        isActive = true
    }

    /// 光标移动 → 计算弹簧 delta → 合并写入。cursor 均为翻转坐标。
    /// AX 的 kAXPositionAttribute 与 CGWindowList 同系：主屏左上原点、y 向下，
    /// 与世界模拟的翻转坐标一致，无需换算。
    func update(cursor: CGPoint, cursorStart: CGPoint, mass: CGFloat = 1.0) {
        guard isActive, let ax = axWindow else { return }
        let strength = pullStrength / mass
        let dx = PetMath.pullDelta(stretch: cursor.x - cursorStart.x, strength: strength, maxPull: maxPull)
        let dy = PetMath.pullDelta(stretch: cursor.y - cursorStart.y, strength: strength, maxPull: maxPull)
        let target = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        pending = target
        queue.async { [weak self] in
            guard let self, let p = self.pending else { return }
            self.pending = nil
            ax.setPosition(p)
        }
    }

    /// 松口：窗口留在当前位置。
    func end() {
        queue.sync { pending = nil }
        axWindow?.setMessagingTimeout(0)
        axWindow = nil
        isActive = false
    }

    /// 当前是否拥有辅助功能权限（不弹窗）。
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 请求辅助功能权限：跳系统设置并提示用户。返回当前（授权前的）信任状态。
    @discardableResult
    static func promptForTrust() -> Bool {
        guard !didPromptForTrust else { return AXIsProcessTrusted() }
        didPromptForTrust = true
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
