import Foundation

// Memory —— 高层记忆（game.md 第十五节）。
//
// 只记四类事：用户习惯、关系、重要事件、角色自己的经历。
// 不记屏幕内容 —— 红线：感知明文（窗口标题/可见文字）绝不入记忆，只允许
// 活动级抽象（"用户常在夜里编码"这种粒度，由决策脑产出，本层只做存储与预算）。
//
// 决策脑 prompt 注入最近若干条；决策脑回复可携带一条新记忆（≤40 字）。
// 行动脑（Needle）明确不需要记忆 —— 它只管当下这一步。

struct MemoryEntry: Codable, Equatable {
    /// ISO8601。
    var ts: String
    /// habit / relationship / event / experience。
    var kind: String
    var text: String
    /// 产生这条记忆的目标规划链路；旧 memory.json 没有这个字段时为 nil。
    var traceID: String?
}

final class MemoryStore {

    /// 容量上限（最旧的先挤出）。
    var capacity = 50
    /// 注入决策脑 prompt 的条数。
    var promptLimit = 8
    /// 单条文本上限。
    var textLimit = 40

    private(set) var entries: [MemoryEntry] = []
    private let fileURL: URL

    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet/memory.json")
    }

    init(fileURL: URL = MemoryStore.defaultURL()) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([MemoryEntry].self, from: data) else { return }
        entries = list.suffix(capacity)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 记一条。文本截断 + 去重（近 5 条内同文忽略）。
    func add(kind: String, text: String, traceID: String? = nil) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textLimit))
        guard !trimmed.isEmpty else { return }
        if entries.suffix(5).contains(where: { $0.text == trimmed }) { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        entries.append(MemoryEntry(ts: stamp, kind: kind, text: trimmed, traceID: traceID))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        save()
    }

    /// 决策脑 prompt 的记忆段（最近 promptLimit 条，"[-] text" 行）。
    func promptLines() -> [String] {
        entries.suffix(promptLimit).map { "[\($0.kind)] \($0.text)" }
    }

    /// 诊断：清空。
    func clear() {
        entries = []
        save()
    }
}
