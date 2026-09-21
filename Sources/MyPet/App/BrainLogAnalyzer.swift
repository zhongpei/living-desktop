import Foundation

/// 日志窗口的业务筛选项。统一 JSONL 仍保留原始事件，窗口把它们投影成一条可读的脑路。
enum BrainLogFilter: String, CaseIterable {
    case all = "全部脑路"
    case teacher = "高阶教师脑"
    case local = "本地决策脑"
    case policy = "内置策略"
    case needle = "行动脑 Needle"
    case autopilot = "Autopilot"
    case random = "随机脑"
    case outcome = "场景结局"
    case speech = "语言"
    case memory = "记忆"

    func matches(_ trace: BrainLogTrace) -> Bool {
        switch self {
        case .all: return true
        case .teacher: return trace.items.contains { $0.actor == "teacher" }
        case .local: return trace.items.contains { $0.actor == "local" }
        case .policy: return trace.items.contains { $0.actor == "policy" }
        case .needle: return trace.items.contains { $0.actor == "needle" }
        case .autopilot: return trace.items.contains { $0.actor == "autopilot" }
        case .random: return trace.items.contains { $0.actor == "random" }
        case .outcome: return trace.items.contains { $0.kind == .outcome }
        case .speech: return trace.items.contains { $0.kind == .speech }
        case .memory: return trace.items.contains { $0.kind == .memory }
        }
    }
}

struct BrainLogItem: Identifiable {
    enum Kind: String {
        case plan
        case decision
        case speech
        case outcome
        case memory
        case sceneStep
    }

    let id: String
    let traceID: String
    let date: Date
    let kind: Kind
    let actor: String
    let title: String
    let summary: String
    let analysis: [String]
    let details: [(label: String, value: String)]
    let raw: String
    let latencyMs: Int?
    /// 仅目标规划事件有意义；用于在同一 trace 中忽略被拒绝的 shadow 结果。
    let decisionValid: Bool?
}

struct BrainLogTrace: Identifiable {
    let id: String
    let date: Date
    let title: String
    let status: String
    let actorSummary: String
    let items: [BrainLogItem]
    let analysis: [String]
}

struct BrainLogSummary {
    let chainCount: Int
    let completedCount: Int
    let interruptedCount: Int
    let openCount: Int
    let fallbackCount: Int
    let averageLatencyMs: Int
    let itemCount: Int
}

struct BrainLogSnapshot {
    let traces: [BrainLogTrace]
    let summary: BrainLogSummary
    let dataDirectory: URL
}

/// 把 brain_trace.jsonl、memory.json 还原成业务链路。
///
/// 这个模块只负责读取和业务解释；运行时写入格式由 BrainTraceLog 统一负责。
enum BrainLogAnalyzer {

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet", isDirectory: true)
    }

    static func load(
        traceLogURL: URL = BrainTraceLog.logURL,
        memoryURL: URL = dataDirectory.appendingPathComponent("memory.json")
    ) -> BrainLogSnapshot {
        var items: [BrainLogItem] = []
        items += loadJSONLines(at: traceLogURL, parser: parseTrace)
        items += loadMemoryItems(at: memoryURL)

        let grouped = Dictionary(grouping: items) { item in
            item.traceID.isEmpty ? item.id : item.traceID
        }
        let traces = grouped.values.map(makeTrace).sorted { $0.date > $1.date }
        // 0ms 是内置策略/兜底的“没有模型调用”，不应拉低模型平均耗时。
        let latencies = items.compactMap(\.latencyMs).filter { $0 > 0 }
        let completed = traces.filter { $0.status == "已完成" }.count
        let interrupted = traces.filter { $0.status == "已中断" }.count
        let fallback = traces.filter { trace in
            trace.items.contains { $0.actor == "policy" || $0.actor == "autopilot" || $0.actor == "random" }
        }.count
        let summary = BrainLogSummary(
            chainCount: traces.count,
            completedCount: completed,
            interruptedCount: interrupted,
            openCount: max(0, traces.count - completed - interrupted),
            fallbackCount: fallback,
            averageLatencyMs: latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count,
            itemCount: items.count)
        return BrainLogSnapshot(traces: traces, summary: summary, dataDirectory: dataDirectory)
    }

    // MARK: 文件读取

    private static func loadJSONLines(
        at url: URL,
        parser: ([String: Any], String, String) -> BrainLogItem?
    ) -> [BrainLogItem] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).enumerated().compactMap { index, line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return parser(object, "trace-event-\(index)", String(line))
        }
    }

    private static func loadMemoryItems(at url: URL) -> [BrainLogItem] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([MemoryEntry].self, from: data)
        else { return [] }

        let formatter = ISO8601DateFormatter()
        return entries.enumerated().map { index, entry in
            let date = formatter.date(from: entry.ts) ?? .distantPast
            return BrainLogItem(
                id: "memory-\(index)-\(entry.ts)",
                traceID: entry.traceID ?? "",
                date: date,
                kind: .memory,
                actor: "memory",
                title: "沉淀记忆：\(entry.kind)",
                summary: entry.text,
                analysis: ["这条记忆由决策脑在目标规划时产生，后续会进入决策脑的上下文。"],
                details: [
                    ("记忆类型", entry.kind),
                    ("记忆内容", entry.text),
                    ("关联 Trace", entry.traceID ?? "历史记录未关联"),
                ],
                raw: prettyJSON([
                    "ts": entry.ts,
                    "kind": entry.kind,
                    "text": entry.text,
                    "trace_id": entry.traceID ?? "",
                ]),
                latencyMs: nil,
                decisionValid: nil)
        }
    }

    // MARK: brain_trace.jsonl

    private static func parseTrace(_ record: [String: Any], id: String, raw: String) -> BrainLogItem? {
        switch string(record["kind"]) {
        case "decision":
            return parseDecision(record, id: id, raw: raw)
        case "plan", "speech", "outcome", "scene_step":
            return parseGoalEvent(record, id: id, raw: raw)
        default:
            return nil
        }
    }

    private static func parseGoalEvent(_ record: [String: Any], id: String, raw: String) -> BrainLogItem? {
        guard let kind = string(record["kind"]),
              let date = date(record["ts"]) else { return nil }
        let traceID = string(record["trace_id"]) ?? ""
        switch kind {
        case "plan":
            return parsePlan(record, id: id, raw: raw, date: date, traceID: traceID)
        case "speech":
            let actor = string(record["brain_mode"]) ?? string(record["mode"]) ?? "teacher"
            let intent = string(record["intent"]) ?? "unknown"
            let reply = dictionary(record["reply"])
            let text = string(reply?["text"]) ?? "未生成"
            let emotion = string(reply?["emotion"]) ?? "neutral"
            return BrainLogItem(
                id: id, traceID: traceID, date: date, kind: .speech, actor: actor,
                title: "语言生成：\(speechLabel(intent))",
                summary: text,
                analysis: [
                    "行动脑只决定是否需要说话；文本由本地决策脑、高阶教师脑或内置台词模块生成。",
                    "情绪标签：\(emotion)。",
                ],
                details: [
                    ("脑模式", brainLabel(actor)),
                    ("说话意图", speechLabel(intent)),
                    ("回复", prettyJSON(record["reply"] ?? NSNull())),
                    ("耗时", latencyText(record)),
                    ("Trace", traceID.isEmpty ? "历史记录未关联" : traceID),
                ],
                raw: prettyJSON(record),
                latencyMs: int(record["latency_ms"]),
                decisionValid: nil)
        case "outcome":
            return parseOutcome(record, id: id, raw: raw, date: date, traceID: traceID)
        case "scene_step":
            let scene = string(record["scene"]) ?? "unknown"
            let step = string(record["step"]) ?? ""
            return BrainLogItem(
                id: id, traceID: traceID, date: date, kind: .sceneStep,
                actor: "runtime", title: "场景步骤：\(scene)", summary: step,
                analysis: ["这是执行层对当前场景配方的落地记录。"],
                details: [("场景", scene), ("步骤", step), ("Trace", traceID)],
                raw: prettyJSON(record), latencyMs: nil, decisionValid: nil)
        default:
            return nil
        }
    }

    private static func parsePlan(
        _ record: [String: Any], id: String, raw: String, date: Date, traceID: String
    ) -> BrainLogItem {
        let actor = string(record["brain_mode"]) ?? "teacher"
        let chosen = dictionary(record["chosen"])
        let goal = string(chosen?["goal"]) ?? "未形成目标"
        let valid = bool(record["decision_valid"]) ?? true
        let why = string(chosen?["why"])
        let teacherLabel = string(record["teacher_label_status"])
        var analysis: [String] = []

        if let reason = string(record["fallback_reason"]) {
            analysis.append("本轮没有依赖模型：\(reasonLabel(reason))。")
        }
        analysis += needAnalysis(record["brain"])
        if let world = dictionary(record["world"]),
           let activity = string(world["app_activity"]), !activity.isEmpty {
            analysis.append("外部活动被归类为「\(activityLabel(activity))」，它影响了陪伴/旁观类目标的适配。")
        }
        if let personality = dictionary(record["personality"]),
           let style = string(personality["style"]), !style.isEmpty {
            analysis.append("本轮采用「\(style)」人格参数；它决定目标偏好和后续场景表现方式。")
        }
        if !valid {
            analysis.append("模型输出没有通过语义校验，因此不能直接成为目标；运行时会走兜底。")
        }
        if actor == "teacher" {
            analysis.append(teacherLabel == "valid"
                ? "这条高阶教师脑结果是有效训练标签。"
                : "这条高阶教师脑结果无效，不能进入训练标签集。")
        } else if actor == "local" {
            analysis.append("这条本地决策脑结果只用于运行时/学生诊断，不作为最终训练标签。")
        }
        if let why, !why.isEmpty {
            analysis.append("模型给出的业务理由：\(why)")
        }
        if analysis.isEmpty {
            analysis.append("本条记录保存了目标层输入、内部需求和结构化目标，可作为一次决策脑样本。")
        }

        let summary: String
        if let why, !why.isEmpty {
            summary = "\(goalLabel(goal)) · \(why)"
        } else if actor == "policy" {
            summary = "\(goalLabel(goal)) · 内置需求/人格策略"
        } else {
            summary = goalLabel(goal)
        }
        return BrainLogItem(
            id: id, traceID: traceID, date: date, kind: .plan, actor: actor,
            title: "目标规划：\(goalLabel(goal))", summary: summary, analysis: analysis,
            details: [
                ("脑模式", brainLabel(actor)),
                ("目标", goalLabel(goal)),
                ("结构化选择", prettyJSON(record["chosen"] ?? NSNull())),
                ("世界输入", prettyJSON(record["world"] ?? NSNull())),
                ("内部状态", prettyJSON(record["brain"] ?? NSNull())),
                ("人格参数", prettyJSON(record["personality"] ?? NSNull())),
                ("决策脑记忆上下文", prettyJSON(record["memory"] ?? NSNull())),
                ("训练标签", actor == "teacher" ? (teacherLabel ?? (valid ? "valid" : "invalid")) : "非教师结果，不作为训练标签"),
                ("模型原始输出", string(record["output"]) ?? "null"),
                ("校验结果", valid ? "通过" : "拒绝"),
                ("耗时", latencyText(record)),
                ("Trace", traceID.isEmpty ? "历史记录未关联" : traceID),
            ],
            raw: prettyJSON(record),
            latencyMs: int(record["latency_ms"]),
            decisionValid: valid)
    }

    private static func parseOutcome(
        _ record: [String: Any], id: String, raw: String, date: Date, traceID: String
    ) -> BrainLogItem {
        let goal = dictionary(record["goal"])
        let goalKind = string(goal?["kind"]) ?? "未知目标"
        let scene = string(record["scene"])
        let sceneName = scene.map(sceneLabel) ?? "未进入场景"
        let completed = bool(record["completed"]) ?? false
        let reason = string(record["ended_because"]) ?? "unknown"
        let stayed = int(record["stayed_s"]) ?? 0
        let result = completed ? "完成" : "中断"
        var analysis = [
            scene == nil
                ? "目标「\(goalLabel(goalKind))」在进入场景前结束。"
                : "目标「\(goalLabel(goalKind))」通过场景「\(sceneName)」落地。",
            "实际停留 \(stayed) 秒，结果：\(result)。",
        ]
        if bool(record["interrupted_by_user"]) == true {
            analysis.append("这次结束由用户交互打断，不应简单归因于脑的选择失败。")
        } else if !completed {
            analysis.append("结束原因：\(reasonLabel(reason))。")
        }
        return BrainLogItem(
            id: id, traceID: traceID, date: date, kind: .outcome, actor: "runtime",
            title: "场景结局：\(sceneName)",
            summary: "\(result) · \(stayed) 秒 · \(reasonLabel(reason))",
            analysis: analysis,
            details: [
                ("目标", prettyJSON(record["goal"] ?? NSNull())),
                ("场景", sceneName),
                ("停留时间", "\(stayed) 秒"),
                ("完成", completed ? "是" : "否"),
                ("结束原因", reasonLabel(reason)),
                ("用户打断", (bool(record["interrupted_by_user"]) ?? false) ? "是" : "否"),
                ("人格风格", string(record["personality_style"]) ?? "未知"),
                ("Trace", traceID.isEmpty ? "历史记录未关联" : traceID),
            ],
            raw: prettyJSON(record), latencyMs: nil, decisionValid: nil)
    }

    // MARK: 行动脑决策

    private static func parseDecision(_ record: [String: Any], id: String, raw: String) -> BrainLogItem? {
        guard let date = date(record["ts"]) else { return nil }
        let traceID = string(record["trace_id"]) ?? ""
        let actor = string(record["brain_mode"]) ?? "needle"
        let snapshotText = string(record["snapshot"]) ?? "{}"
        let snapshot = parseObject(snapshotText)
        let mode = string(snapshot?["mode"]) ?? "choose_next"
        let chosen = string(record["chosen"]) ?? "invalid"
        let valid = chosen != "invalid"
        let goal = dictionary(snapshot?["goal"])
        let goalName = string(goal?["kind"]).map(goalLabel) ?? "无目标"
        var analysis: [String] = []
        if mode == "scene_decision_point" {
            analysis.append("当前位于场景决策点，行动脑只需要决定继续、离开或插播一次语言/表演。")
        } else {
            analysis.append("当前位于行动边界，行动脑要把「\(goalName)」翻译成一个可执行动作或场景。")
        }
        if valid {
            analysis.append("选择「\(chosen)」通过了当前世界事实的合法性校验。")
        } else {
            analysis.append("模型没有产出可执行且通过校验的动作；运行时会保持当前状态或转入 Autopilot。")
        }
        if let reason = string(record["fallback_reason"]) {
            analysis.append("这次动作来自兜底：\(reasonLabel(reason))。")
        }
        return BrainLogItem(
            id: id, traceID: traceID, date: date, kind: .decision, actor: actor,
            title: "行动决策：\(actionLabel(chosen))",
            summary: "\(brainLabel(actor)) · \(actionLabel(chosen))",
            analysis: analysis,
            details: [
                ("脑模式", brainLabel(actor)),
                ("决策模式", mode == "scene_decision_point" ? "场景决策点" : "行动边界"),
                ("场景语境", sceneLabel(string(record["scene"]) ?? "无场景")),
                ("目标语境", prettyJSON(record["goal"] ?? snapshot?["goal"] ?? NSNull())),
                ("世界事实", prettyJSON(snapshot ?? NSNull())),
                ("感知输入", string(record["senses"]) ?? "未记录"),
                ("模型输入", string(record["model_input"]) ?? snapshotText),
                ("工具约束", string(record["schema"]) ?? prettyJSON(record["schema"] ?? NSNull())),
                ("模型原始输出", string(record["output"]) ?? "null"),
                ("候选调用", prettyJSON(record["calls"] ?? NSNull())),
                ("最终动作", actionLabel(chosen)),
                ("耗时", latencyText(record)),
                ("Trace", traceID.isEmpty ? "历史记录未关联" : traceID),
            ],
            raw: prettyJSON(record),
            latencyMs: int(record["latency_ms"]),
            decisionValid: nil)
    }

    // MARK: 业务分析辅助

    private static func makeTrace(_ items: [BrainLogItem]) -> BrainLogTrace {
        let sorted = items.sorted { $0.date < $1.date }
        // 教师脑可能先产出一个被拒绝的 shadow 结果，随后本地脑/内置策略才
        // 给出真正落地的目标；展示链路应以最后一个有效规划为准。
        let plans = sorted.filter { $0.kind == .plan }
        let plan = plans.last(where: { $0.decisionValid != false }) ?? plans.last
        let outcome = sorted.last { $0.kind == .outcome }
        let status: String
        if let outcome {
            status = outcome.summary.hasPrefix("完成") ? "已完成" : "已中断"
        } else {
            status = "未收束"
        }
        var analysis = plan?.analysis ?? []
        let actors = Array(Set(sorted.map(\.actor))).sorted()
        if actors.contains("needle") && outcome != nil {
            analysis.append("这条脑路已经形成「目标 → 行动脑动作 → 场景结果」闭环。")
        }
        if actors.contains("policy") || actors.contains("autopilot") || actors.contains("random") {
            analysis.append("链路中出现了内置兜底；这表示模型不可用/未通过校验，或当前配置主动选择了无模型路径。")
        }
        if outcome == nil {
            analysis.append("目前没有结局记录，可能场景仍在执行，或应用在结束前退出。")
        }
        return BrainLogTrace(
            id: sorted.first?.traceID.isEmpty == false ? sorted.first!.traceID : sorted.first!.id,
            date: sorted.first?.date ?? .distantPast,
            title: plan?.title ?? sorted.first?.title ?? "未命名脑路",
            status: status,
            actorSummary: actors.map(brainLabel).joined(separator: " → "),
            items: sorted,
            analysis: unique(analysis))
    }

    private static func needAnalysis(_ value: Any?) -> [String] {
        guard let brain = dictionary(value) else { return [] }
        var result: [String] = []
        if let energy = double(brain["energy"]), energy <= 0.2 {
            result.append("能量低于 0.2，休息是目标策略中的硬约束。")
        }
        if let stress = double(brain["stress"]), stress >= 0.65 {
            result.append("应激达到 \(percent(stress))，抗议/休息类目标优先级上升。")
        }
        if let boredom = double(brain["boredom"]), boredom >= 0.85 {
            result.append("无聊达到 \(percent(boredom))，探索类目标权重上升。")
        }
        if let social = double(brain["social_need"]), social >= 0.7 {
            result.append("社交需求达到 \(percent(social))，求关注/陪伴类目标更有动机。")
        }
        return result
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: 值读取与显示

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func parseObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = string(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return string(value) ?? "null"
        }
        return text
    }

    private static func latencyText(_ record: [String: Any]) -> String {
        guard let ms = int(record["latency_ms"]) else { return "未记录" }
        return "\(ms) ms"
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: 业务词汇

    static func brainLabel(_ actor: String) -> String {
        switch actor {
        case "teacher": return "高阶教师脑"
        case "local": return "本地决策脑"
        case "policy": return "内置策略"
        case "needle": return "行动脑 Needle"
        case "autopilot": return "Autopilot 兜底"
        case "random": return "随机脑"
        case "builtin": return "内置台词"
        case "runtime": return "游戏执行层"
        case "memory": return "记忆层"
        default: return actor
        }
    }

    static func goalLabel(_ raw: String) -> String {
        switch raw {
        case "join_user_activity": return "陪用户活动"
        case "watch_with_user": return "一起观看"
        case "seek_attention": return "求关注"
        case "tease_user": return "调侃用户"
        case "complain_to_user": return "向用户抗议"
        case "explore": return "探索"
        case "rest": return "休息"
        case "wander": return "随便走走"
        default: return raw
        }
    }

    static func sceneLabel(_ raw: String) -> String {
        SceneCatalog.recipe(id: raw)?.label ?? raw
    }

    private static func activityLabel(_ raw: String) -> String {
        AppActivity(rawValue: raw)?.rawValue ?? raw
    }

    private static func speechLabel(_ raw: String) -> String {
        SpeechIntent(rawValue: raw)?.rawValue ?? raw
    }

    private static func actionLabel(_ raw: String) -> String {
        raw == "invalid" ? "无有效动作" : raw
    }

    private static func reasonLabel(_ raw: String) -> String {
        if raw.hasPrefix("goal ") {
            return "目标变更：\(raw.dropFirst(5))"
        }
        switch raw {
        case "slow_brain_failed_or_rejected", "goal_brain_failed_or_rejected": return "决策脑失败或输出被拒绝"
        case "slow_brain_unavailable", "goal_brains_unavailable": return "决策脑不可用"
        case "slow_brain_not_due", "goal_brain_not_due": return "决策脑尚未到下一次规划时机"
        case "local_brain_error": return "本地决策脑运行出错"
        case "needle_failed": return "Needle 未形成有效动作"
        case "needle_unavailable_or_failed": return "Needle 不可用或失败"
        case "scenes_disabled_or_needle_disabled": return "场景/Needle 未启用，转入随机脑"
        case "expired": return "目标过期"
        case "grabbed": return "用户抓起宠物"
        case "user grabbed": return "用户抓起宠物"
        case "user command": return "用户指令接管"
        case "application terminated": return "应用退出或切换宠物"
        case "finished": return "场景自然完成"
        case "aborted": return "场景被中止"
        default: return raw
        }
    }
}
