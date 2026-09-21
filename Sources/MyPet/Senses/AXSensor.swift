import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Accessibility 感知器（阶段 E2，进程内实现）。
//
// 范围取「聚焦上下文」而非全树（E0 实测 + 最终决策）：active app / window title /
// focused element / 祖先链 / 同父兄弟 ±3 / 选中文字 / 少量 salient 元素。
// 大脑关心「用户正在干什么」，不关心页面一共有 237 个按钮。
//
// 并发与超时：AX 是同步跨进程 IPC（WindowPuller 的教训），所有调用走专用串行队列，
// app 元素 0.1s messaging timeout——目标应用卡死时单次调用最多损失 0.1s，
// 决不阻塞 40fps 主循环。若 E0.5/E3 数据表明需要更强隔离，再切子进程 transport，
// SensorContract 的数据形状不变。
final class AXSensor {

    private let queue = DispatchQueue(label: "mypet.ax-sensor", qos: .utility)
    private var nextRequestID = 1

    var isEnabled: Bool { AXIsProcessTrusted() }

    /// 发起一次聚焦上下文感知。now 为调用方时钟（与决策节奏同源，供 TTL 比较）。
    /// 回调在主队列；返回 nil = 读取失败（无权限/无窗口）。
    func sense(pid: pid_t, now: Double, completion: @escaping (SensorObservation?) -> Void) {
        let requestID = nextRequestID
        nextRequestID += 1
        queue.async { [weak self] in
            let result = self?.readFocusContext(pid: pid, requestID: requestID, now: now)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: 读取（AXWalker 同款逻辑的生产版，全部有界）

    private func readFocusContext(pid: pid_t, requestID: Int, now: Double) -> SensorObservation? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        // 尽力而为地请求完整无障碍模式（Chromium 系需要；失败忽略）。
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        var o = SensorObservation(requestID: requestID, timestamp: now,
                                  app: name, pid: Int(pid), windowTitle: "")

        guard let window = asElement(attribute(app, kAXFocusedWindowAttribute as CFString))
            ?? firstWindow(of: app) else { return nil }
        o.windowTitle = string(window, kAXTitleAttribute as CFString, limit: 60)

        guard let focused = asElement(attribute(app, kAXFocusedUIElementAttribute as CFString, requiredType: AXUIElementGetTypeID())) else {
            // 有窗口没聚焦元素也算一次有效观察（用户在看，没在碰）。
            return o
        }
        var truncated = false
        let (info, _) = element(focused, pid: pid, path: "f", budget: &truncated)
        o.focused = AXElementDTO(id: info.id, role: info.role, title: info.title, value: info.value, focused: true)
        o.selectedText = string(focused, kAXSelectedTextAttribute as CFString, limit: 80)

        // 祖先链（≤6 层）+ 同父兄弟 ±3。
        var ancestors: [String] = []
        var current: AXUIElement? = focused
        var siblingsDone = false
        for _ in 0..<6 {
            guard let cur = current,
                  let parent = asElement(attribute(cur, kAXParentAttribute as CFString, requiredType: AXUIElementGetTypeID())),
                  let kids = attribute(parent, kAXChildrenAttribute as CFString) as? [AXUIElement] else { break }
            if let i = kids.firstIndex(where: { CFEqual($0, cur) }) {
                if ancestors.count < 6 {
                    let (pInfo, _) = element(parent, pid: pid, path: "p\(ancestors.count)", budget: &truncated)
                    ancestors.append(pInfo.role)
                }
                if !siblingsDone {
                    siblingsDone = true
                    let lo = max(0, i - 3), hi = min(kids.count - 1, i + 3)
                    for j in lo...hi where j != i {
                        let (sInfo, _) = element(kids[j], pid: pid, path: "s\(j)", budget: &truncated)
                        if worthSampling(sInfo) {
                            o.siblings.append(AXElementDTO(id: sInfo.id, role: sInfo.role,
                                                           title: sInfo.title, value: sInfo.value))
                        }
                    }
                }
            }
            current = parent
        }
        o.ancestors = ancestors

        // salient：窗口内有界扫描，只要按钮/链接/标题（≤12 个，≤300 节点预算）。
        var salient: [AXElementDTO] = []
        var budget = 300
        var stack: [(AXUIElement, String)] = [(window, "w")]
        while let (el, path) = stack.popLast() {
            budget -= 1
            if budget <= 0 || salient.count >= 12 { break }
            let (eInfo, kids) = element(el, pid: pid, path: path, budget: &truncated)
            if ["button", "link", "heading"].contains(eInfo.role), !eInfo.title.isEmpty {
                salient.append(AXElementDTO(id: eInfo.id, role: eInfo.role, title: eInfo.title))
            }
            for (i, c) in kids.enumerated().reversed() {
                stack.append((c, "\(path).\(i)"))
            }
        }
        o.salient = salient
        o.truncated = truncated
        return o
    }

    // MARK: 小件

    private func firstWindow(of app: AXUIElement) -> AXUIElement? {
        (attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement])?.first
    }

    /// CF 条件转换在该 SDK 下按错误处理，统一走显式类型 ID 检查。
    private func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private func attribute(_ el: AXUIElement, _ name: CFString, requiredType: CFTypeID? = nil) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name, &value) == .success, let value else { return nil }
        if let requiredType, CFGetTypeID(value) != requiredType { return nil }
        return value
    }

    private func string(_ el: AXUIElement, _ name: CFString, limit: Int) -> String {
        guard let v = attribute(el, name) as? String else { return "" }
        return String(v.prefix(limit))
    }

    private func element(_ el: AXUIElement, pid: pid_t, path: String, budget: inout Bool)
        -> (info: (id: String, role: String, title: String, value: String), children: [AXUIElement]) {
        let attrs: [CFString] = [
            kAXRoleAttribute as CFString, kAXTitleAttribute as CFString,
            kAXValueAttribute as CFString, kAXChildrenAttribute as CFString,
        ]
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, [], &values)
        if err != .success {
            budget = true
            return (("", "", "", ""), [])
        }
        let list = values as? [Any] ?? []
        func text(_ i: Int) -> String {
            guard i < list.count, let s = list[i] as? String else { return "" }
            return String(s.prefix(SensorContract.textLimit))
        }
        // 批量结果与请求顺序一致：0 role / 1 title / 2 value / 3 children（缺失为占位）。
        let kids: [AXUIElement] = list.count > 3 ? (list[3] as? [AXUIElement]) ?? [] : []
        return (("ax:\(pid):\(path)", normalizeRole(text(0)), text(1), text(2)), kids)
    }

    /// "AXButton" → "button"。
    private func normalizeRole(_ raw: String) -> String {
        raw.hasPrefix("AX") ? String(raw.dropFirst(2)).lowercased() : raw.lowercased()
    }

    private func worthSampling(_ e: (id: String, role: String, title: String, value: String)) -> Bool {
        !e.title.isEmpty || !e.value.isEmpty
            || ["button", "link", "textfield", "textarea", "popupbutton"].contains(e.role)
    }
}
