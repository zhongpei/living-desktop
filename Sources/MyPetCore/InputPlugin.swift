import Foundation

/// 外部输入的统一分类。传感器只负责采集，插件配置决定哪些内容能进入游戏世界。
public enum InputChannel: String, Codable, CaseIterable, Sendable {
    case windowTitle
    case accessibility
    case ocr
    case chat
    case code
    case browser
}

public struct InputObservation: Codable, Equatable, Sendable {
    public var id: String
    public var pluginID: String
    public var channel: InputChannel
    public var appName: String
    public var bundleID: String?
    public var windowTitle: String
    public var text: String
    public var capturedAtTick: Int64
    public var expiresAtTick: Int64?

    public init(
        id: String,
        pluginID: String,
        channel: InputChannel,
        appName: String = "",
        bundleID: String? = nil,
        windowTitle: String = "",
        text: String,
        capturedAtTick: Int64,
        expiresAtTick: Int64? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.channel = channel
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.text = text
        self.capturedAtTick = capturedAtTick
        self.expiresAtTick = expiresAtTick
    }

    public func isValid(at tick: Int64) -> Bool {
        capturedAtTick <= tick && (expiresAtTick.map { tick < $0 } ?? true)
    }

    /// Stable identity for de-duplication and deterministic digests; raw fields
    /// remain available in the observation and its persisted training record.
    public var fingerprint: String {
        var hash: UInt64 = 1469598103934665603
        for byte in "\(pluginID)|\(channel.rawValue)|\(appName)|\(windowTitle)|\(text)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

public struct InputPluginConfiguration: Codable, Equatable, Sendable {
    public var displayName: String
    public var channel: InputChannel
    public var enabled: Bool
    public var ttlTicks: Int64
    public var maxCharacters: Int
    public var preemptive: Bool
    public var priority: PriorityBand
    /// Empty means every app; entries match app name or bundle-id prefix.
    public var allowedApplications: [String]

    public init(
        displayName: String,
        channel: InputChannel,
        enabled: Bool = false,
        ttlTicks: Int64 = 120,
        maxCharacters: Int = 1200,
        preemptive: Bool = false,
        priority: PriorityBand = .brainReactive,
        allowedApplications: [String] = []
    ) {
        self.displayName = displayName
        self.channel = channel
        self.enabled = enabled
        self.ttlTicks = max(1, ttlTicks)
        self.maxCharacters = max(1, maxCharacters)
        self.preemptive = preemptive
        self.priority = priority
        self.allowedApplications = allowedApplications
    }
}

public struct InputPluginCatalog: Codable, Equatable, Sendable {
    public var plugins: [String: InputPluginConfiguration]

    public init(plugins: [String: InputPluginConfiguration] = InputPluginCatalog.defaults().plugins) {
        self.plugins = plugins
    }

    public static func defaults() -> InputPluginCatalog {
        InputPluginCatalog(plugins: [
            "window-title": InputPluginConfiguration(displayName: "窗口标题", channel: .windowTitle),
            "accessibility": InputPluginConfiguration(displayName: "辅助功能内容", channel: .accessibility),
            "ocr": InputPluginConfiguration(displayName: "OCR 内容", channel: .ocr),
            "chat-content": InputPluginConfiguration(displayName: "聊天内容", channel: .chat),
            "code-content": InputPluginConfiguration(displayName: "编码内容", channel: .code),
            "browser-content": InputPluginConfiguration(displayName: "浏览器内容", channel: .browser),
        ])
    }

    public func configuration(for pluginID: String) -> InputPluginConfiguration? {
        plugins[pluginID]
    }

    public func isEnabled(_ pluginID: String) -> Bool {
        plugins[pluginID]?.enabled == true
    }

    public mutating func setEnabled(_ enabled: Bool, for pluginID: String) {
        guard var config = plugins[pluginID] else { return }
        config.enabled = enabled
        plugins[pluginID] = config
    }

    /// 把 observation 过滤并转成内核事件；被关闭、过期、错插件或不在白名单时返回 nil。
    public func route(_ observation: InputObservation, at tick: Int64) -> GameEvent? {
        guard let config = plugins[observation.pluginID],
              config.channel == observation.channel,
              config.enabled,
              observation.isValid(at: tick),
              applicationAllowed(observation, config: config) else { return nil }
        var accepted = observation
        accepted.text = String(observation.text.prefix(config.maxCharacters))
        // The source may provide an earlier expiry, but it must not be able to
        // extend the user-configured plugin TTL. This keeps every input source
        // on the same bounded lifecycle even when an adapter overestimates its
        // freshness window.
        let configuredExpiry = tick + config.ttlTicks
        accepted.expiresAtTick = min(observation.expiresAtTick ?? configuredExpiry, configuredExpiry)
        return GameEvent(
            kind: .contentObservation,
            inputObservation: accepted,
            inputPreemptive: config.preemptive,
            inputPriority: config.priority)
    }

    private func applicationAllowed(_ observation: InputObservation, config: InputPluginConfiguration) -> Bool {
        let allowlist = config.allowedApplications
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !allowlist.isEmpty else { return true }
        let values = [observation.appName, observation.bundleID ?? ""].map { $0.lowercased() }
        return allowlist.contains { allowed in
            values.contains { value in value == allowed || value.hasPrefix(allowed) }
        }
    }
}
