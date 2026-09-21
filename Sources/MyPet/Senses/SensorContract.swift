import Foundation

// 感知最小契约（阶段 E2）。
//
// 决策记录（2026-09-20，实验门控路线）：
// - 进程边界是实验结果而非架构前提（E0.5 矩阵 + 延迟数据决定 in-process / subprocess），
//   因此契约只定义数据形状，不绑定传输方式；将来换成子进程只换 transport 层。
// - pull / request-response 为主（sense→result），push 事件只做「感知失效通知」
//   （markDirty → 重新 sense → BrainContextSnapshot 变化 → 由大脑决定行为），事件不直接触发宠物动作。
// - 元素 id 是 sensor 内部 opaque handle（"ax:<pid>:<path>"），宿主与大脑不解释其结构，
//   为将来 provider 兼具 act 能力（AXPress）预留 target 生命周期。

/// 屏幕上的一个元素。字段刻意少：观察够用，act 靠 opaque id。
struct AXElementDTO: Codable, Equatable {
    var id: String
    var role: String
    var title: String = ""
    var value: String = ""
    var frame: [Double]?
    var focused: Bool = false
}

/// 一次 sense 的完整观察结果（focused-context 范围）。
struct SensorObservation: Codable, Equatable {
    var requestID: Int
    /// 控制器时钟秒（与决策节奏同源），用于 TTL。
    var timestamp: Double
    var app: String
    var pid: Int
    var windowTitle: String
    var focused: AXElementDTO?
    /// 聚焦元素的祖先 role 链（由近到远，≤6）。
    var ancestors: [String] = []
    /// 同父兄弟中聚焦点附近 ±3 的有信息量元素。
    var siblings: [AXElementDTO] = []
    /// 聚焦文本控件的选区文字（可能为空）。
    var selectedText: String = ""
    /// 窗口内少量 salient 交互元素（按钮/链接，阅读序 ≤12）。
    var salient: [AXElementDTO] = []
    /// OCR 文本行（第二传感器；≤6 行×60 字符，与 AX 上下文共用 BrainContextSnapshot 预算）。
    var ocrLines: [String] = []
    /// 命中预算被截断时置位（诚实标注不完整）。
    var truncated: Bool = false
}

/// 感知失效通知（v1 只有前台变化这类确定性事件；AXObserver 待实验）。
struct SensorEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case foregroundAppChanged
        case windowClosed
    }
    var kind: Kind
    var timestamp: Double
    /// 相关 pid（如有）。
    var pid: Int?
}

/// 契约的纯函数部分：DTO ↔ JSON、有界化。离线可测。
enum SensorContract {

    /// 文本截断上限（字符）。
    static let textLimit = 48
    /// senses 注入快照的字符预算（硬上限）。
    static let budgetChars = 1200

    static func truncate(_ s: String, _ n: Int = textLimit) -> String {
        String(s.prefix(n))
    }

    /// observation → 注入大脑快照的 "senses" 段（JSON 对象文本）。
    /// 超预算时按 salient → nearby → ocr → ancestors 逐段丢弃（truncated 置位），绝不超限。
    static func sensesJSON(_ o: SensorObservation, budget: Int = budgetChars) -> String? {
        func build(_ o: SensorObservation, dropSalient: Bool, dropNearby: Bool,
                   dropOCR: Bool, dropAncestors: Bool) -> [String: Any] {
            var obj: [String: Any] = [
                "source": o.ocrLines.isEmpty && dropOCR ? "accessibility" : "ax+ocr",
                "app": truncate(o.app, 40),
            ]
            if !o.windowTitle.isEmpty { obj["window"] = truncate(o.windowTitle, 60) }

            var focusObj: [String: Any] = [:]
            if let f = o.focused {
                focusObj["role"] = f.role
                if !f.value.isEmpty { focusObj["value"] = truncate(f.value) }
                if !f.title.isEmpty { focusObj["title"] = truncate(f.title) }
            }
            if !o.selectedText.isEmpty { focusObj["selected_text"] = truncate(o.selectedText, 80) }
            if !focusObj.isEmpty { obj["focus"] = focusObj }

            if !o.ocrLines.isEmpty, !dropOCR { obj["ocr"] = o.ocrLines }
            if !o.ancestors.isEmpty, !dropAncestors { obj["focus_ancestors"] = o.ancestors }
            func slim(_ e: AXElementDTO) -> [String: Any] {
                var d: [String: Any] = ["role": e.role]
                if !e.title.isEmpty { d["title"] = truncate(e.title) }
                if !e.value.isEmpty { d["value"] = truncate(e.value) }
                return d
            }
            if !o.siblings.isEmpty, !dropNearby { obj["nearby"] = o.siblings.map(slim) }
            if !o.salient.isEmpty, !dropSalient { obj["actions_available"] = o.salient.map(slim) }
            if o.truncated || dropSalient || dropNearby || dropAncestors || dropOCR { obj["truncated"] = true }
            return obj
        }

        func encode(_ o: SensorObservation, dropSalient: Bool, dropNearby: Bool,
                    dropOCR: Bool, dropAncestors: Bool) -> String? {
            let obj = build(o, dropSalient: dropSalient, dropNearby: dropNearby,
                            dropOCR: dropOCR, dropAncestors: dropAncestors)
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        // 五级降档：全量 → 砍 salient → 砍 nearby → 砍 ocr → 砍 ancestors（只剩 focus/window）。
        let levels: [(Bool, Bool, Bool, Bool)] = [
            (false, false, false, false),
            (true, false, false, false),
            (true, true, false, false),
            (true, true, true, false),
            (true, true, true, true),
        ]
        for (ds, dn, docr, da) in levels {
            guard let text = encode(o, dropSalient: ds, dropNearby: dn, dropOCR: docr, dropAncestors: da) else { return nil }
            if text.count <= budget { return text }
        }
        return nil
    }
}
