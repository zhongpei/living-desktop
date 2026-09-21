import Foundation

/// 新版统一脑路日志。
///
/// 一个 JSONL 文件承载所有业务事件；每条事件的 trace_id 指向同一次目标规划，
/// 因此查看器不需要用时间窗口猜测不同日志之间的关系。
enum BrainTraceLog {

    private static let queue = DispatchQueue(label: "mypet.brain-trace-log")
    private static let overrideLock = NSLock()
    private static var logURLOverride: URL?
    private static var enabled = true

    private static var defaultLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet/brain_trace.jsonl")
    }

    static var logURL: URL {
        overrideLock.lock()
        defer { overrideLock.unlock() }
        return logURLOverride ?? defaultLogURL
    }

    /// 每次启动都从一份干净的会话日志开始。日志格式尚未对外发布，
    /// 旧会话不参与新会话的业务分析，避免把未收束的历史链路误报为当前问题。
    static func startFreshSession() {
        startFreshSession(in: defaultLogURL.deletingLastPathComponent())
    }

    static func startFreshSession(in directory: URL) {
        removeLegacyLogs(in: directory)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("brain_trace.jsonl"))
    }

    /// 新格式启用时清理明确列出的历史日志文件，不碰其他应用数据。
    static func removeLegacyLogs() {
        removeLegacyLogs(in: defaultLogURL.deletingLastPathComponent())
    }

    static func removeLegacyLogs(in directory: URL) {
        for name in ["slowbrain.jsonl", "teacher.jsonl", "decisions.jsonl"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func append(_ record: [String: Any]) {
        queue.sync {
            guard enabled else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
            let url = logURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.write(Data("\n".utf8))
                try? handle.close()
            } else {
                try? (data + Data("\n".utf8)).write(to: url)
            }
        }
    }

    /// Runtime switch for the user-facing diagnostics setting. The gate lives
    /// at the shared writer so Goal, Needle and fallback records cannot drift
    /// into different interpretations of the same setting.
    static func setEnabled(_ enabled: Bool) {
        queue.sync {
            self.enabled = enabled
        }
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    /// 测试隔离日志路径，防止离线测试把样本写进用户运行时日志。
    static func setLogURLOverrideForTesting(_ url: URL?) {
        overrideLock.lock()
        logURLOverride = url
        overrideLock.unlock()
    }
}
