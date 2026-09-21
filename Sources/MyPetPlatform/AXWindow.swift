import ApplicationServices
import CoreGraphics
import Foundation

/// MyPetPlatform 内部可通过 Accessibility 操纵的真实窗口。
///
/// 属性读写的调用模式提取自 Rectangle（MIT License, © 2019-2026 Ryan Hanson）
/// 的 AXExtension.swift / AccessibilityElement.swift，按 MyPet 需求裁剪重写：
/// 只保留「按 CGWindowID 找窗口元素 + 读写位置」这一条路径。
final class AXWindow {

    private let element: AXUIElement

    private init(_ element: AXUIElement) {
        self.element = element
    }

    // MARK: 查找

    /// 在目标进程的 AX 窗口列表里匹配 CGWindowID。
    static func window(matching id: CGWindowID, pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return nil }
        for w in windows {
            if let wid = windowID(of: w), wid == id {
                return AXWindow(w)
            }
        }
        // 兜底：窗口服务器不肯发 window id 时按 frame 匹配。
        return nil
    }

    /// `_AXUIElementGetWindow` 是 Apple 未公开导出、但长期稳定的符号，
    /// Rectangle / 多数窗口管理器都以它做 CGWindowID ↔ AX 元素的桥。
    private static let axGetWindow: @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError = {
        let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow")
        return unsafeBitCast(sym, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        guard axGetWindow(element, &id) == .success else { return nil }
        return id
    }

    // MARK: 位置

    var position: CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    @discardableResult
    func setPosition(_ p: CGPoint) -> Bool {
        var point = p
        guard let axValue = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue) == .success
    }

    /// AX 调用是同步跨进程 IPC：目标应用卡住时默认会阻塞好几秒。
    /// 拖拽期间必须收短超时，别把宠物自己的帧循环也拖死。
    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }
}
