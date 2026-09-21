import CoreGraphics
import Foundation
import MyPetCore
import MyPetPlatform

// BrainContextSnapshot v1 —— 大脑的唯一世界边界（下一阶段核心接口）。
//
// 原则：AX / OCR / 未来 VLM / 系统事件先投影为有界结构化快照供大脑消费；
// 原始 observation/input 记录在本机单独保留，供训练和回放，不做脱敏。传感器换实现
// （AX 换 OCR、VL 换模型）不动这里以下，也不动 Brain 以上。
//
// 预算：整个结构序列化后 ~600 字符级别，teacher / needle 快照都能背得动。

/// 外部世界快照（纯外部视角；宠物内部状态在 BrainState）。
struct BrainContextSnapshot: Codable, Equatable {
    var capturedAt: Double
    var activeApp: String
    var windowTitle: String
    /// app 级活动语义（coding/chatting/watching…，AppActivityCatalog 归类，零权限）。
    var appActivity: String
    /// 焦点级活动：editing_text / browsing / idle / unknown。
    var userActivity: String
    /// 聚焦控件角色（textarea 等），空 = 未知。
    var focusRole: String
    /// 可见上下文文本行（AX 值 / OCR 行），每行 ≤60 字符、≤6 行。
    var visibleContext: [String]
    /// 突出 UI（"button:发送"），≤8 项。
    var salientUI: [String]
    /// 附近窗口（"window_123 (Chrome, coding)"），≤5。
    var nearbyWindows: [String]
    /// 最近世界事件环（"18s ago user switched to Chrome"），≤5。
    var recentEvents: [String]
}

/// 纯函数装配（离线可测）。
enum BrainContextSnapshotBuilder {

    static let contextLineLimit = 6
    static let contextCharLimit = 60
    static let salientLimit = 8
    static let windowLimit = 5

    /// 从运行时各源装配。senses 可为 nil（感知关/过期）。
    static func build(
        clock: Double,
        foreground: WindowEntity?,
        idleSeconds: Double,
        windows: [WindowEntity],
        senses: SensorObservation?,
        inputObservations: [InputObservation] = [],
        recentEvents: [String]
    ) -> BrainContextSnapshot {
        var ws = BrainContextSnapshot(
            capturedAt: clock,
            activeApp: foreground?.owner ?? "",
            // CGWindowList 的 window name 是窗口标题快速线索；它不依赖
            // AX/OCR 的内容通道。AX/OCR 后续到达时仍会由 senses 覆盖它。
            windowTitle: foreground?.windowTitle ?? "",
            appActivity: foreground?.appActivity.rawValue ?? AppActivity.unknown.rawValue,
            userActivity: "unknown",
            focusRole: "",
            visibleContext: [],
            salientUI: [],
            nearbyWindows: [],
            recentEvents: Array(recentEvents.suffix(5)))

        // 用户空闲 → 一切活动归 idle（app 语义也不再可信）。
        if idleSeconds > 120 {
            ws.appActivity = AppActivity.unknown.rawValue
            ws.userActivity = "idle"
        }

        if foreground != nil {
            ws.nearbyWindows = windows.prefix(windowLimit).map { entity -> String in
                let act = entity.appActivity
                return act == .unknown
                    ? "window_\(entity.id) (\(entity.owner))"
                    : "window_\(entity.id) (\(entity.owner), \(act.rawValue))"
            }
        }

        if let senses {
            if !senses.windowTitle.isEmpty {
                ws.windowTitle = senses.windowTitle
            }
            ws.focusRole = senses.focused?.role ?? ""
            ws.salientUI = senses.salient.prefix(salientLimit)
                .map { "\($0.role):\($0.title)" }
        }

        // Core content observations are the same bounded inputs that caused
        // the kernel to expedite/preempt a plan. Keep them in the GoalBrain
        // snapshot too; otherwise the event is logged and acted upon but the
        // brain never sees what the user actually wrote/read.
        let sensorLines = senses.map { contextLines(from: $0) } ?? []
        ws.visibleContext = mergeContextLines(
            inputContextLines(from: inputObservations), sensorLines)

        ws.userActivity = Self.deriveActivity(idleSeconds: idleSeconds, focusRole: ws.focusRole)
        return ws
    }

    /// 聚焦元素的值优先，其次选区文字、OCR 行，再次兄弟文字与 salient 标题
    /// ——「用户正在看/写什么」。AX 值与 OCR 行共用 6 行预算。
    static func contextLines(from senses: SensorObservation) -> [String] {
        var lines: [String] = []
        if let focusValue = senses.focused?.value, !focusValue.isEmpty {
            lines.append(focusValue)
        }
        if !senses.selectedText.isEmpty {
            lines.insert("选中: \(senses.selectedText)", at: 0)
        }
        for line in senses.ocrLines where lines.count < contextLineLimit {
            lines.append(line)
        }
        for s in senses.siblings {
            if lines.count >= contextLineLimit { break }
            let text = s.value.isEmpty ? s.title : s.value
            if !text.isEmpty { lines.append(text) }
        }
        for s in senses.salient where lines.count < contextLineLimit {
            if !s.title.isEmpty { lines.append(s.title) }
        }
        return lines.map { String($0.prefix(contextCharLimit)) }
    }

    /// Semantic plugin text is labelled so the small local brain can
    /// distinguish a chat message from source code or a browser page. The
    /// caller supplies only live kernel observations; this helper remains
    /// renderer- and persistence-free.
    static func inputContextLines(from observations: [InputObservation]) -> [String] {
        var seen = Set<String>()
        return observations
            .filter { $0.channel != .windowTitle }
            .sorted {
                if $0.capturedAtTick != $1.capturedAtTick {
                    return $0.capturedAtTick > $1.capturedAtTick
                }
                let left = inputPriority($0.channel)
                let right = inputPriority($1.channel)
                if left != right { return left < right }
                return $0.id < $1.id
            }
            .compactMap { observation in
                let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, seen.insert(text).inserted else { return nil }
                return "[\(observation.channel.rawValue)] \(text)"
            }
    }

    private static func inputPriority(_ channel: InputChannel) -> Int {
        switch channel {
        case .chat, .code, .browser: return 0
        case .ocr, .accessibility: return 1
        case .windowTitle: return 2
        }
    }

    private static func mergeContextLines(_ primary: [String], _ secondary: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for line in primary + secondary {
            let bounded = String(line.prefix(contextCharLimit))
            let dedupeKey = bounded.replacingOccurrences(of: "^\\[[^]]+\\] ", with: "", options: .regularExpression)
            guard !bounded.isEmpty, seen.insert(dedupeKey).inserted else { continue }
            result.append(bounded)
            if result.count == contextLineLimit { break }
        }
        return result
    }

    static func deriveActivity(idleSeconds: Double, focusRole: String) -> String {
        if idleSeconds > 120 { return "idle" }
        if ["textarea", "textfield"].contains(focusRole) { return "editing_text" }
        if !focusRole.isEmpty { return "browsing" }
        return "unknown"
    }
}
