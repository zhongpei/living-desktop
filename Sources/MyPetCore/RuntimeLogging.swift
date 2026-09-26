import Foundation
import OSLog

/// Runtime diagnostics emitted by the desktop and combat engine.
///
/// The application owns this level so the menu can change verbosity without
/// rebuilding the running cast. The OSLog subsystem stays stable, which makes
/// a combat trace queryable without the AppKit/WindowServer noise mixed into
/// the default process stream.
public enum RuntimeLogLevel: String, Codable, CaseIterable, Sendable {
    case off
    case error
    case info
    case debug

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .error: return "错误"
        case .info: return "信息"
        case .debug: return "调试（默认）"
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .off: return 0
        case .error: return 1
        case .info: return 2
        case .debug: return 3
        }
    }

    /// Menu order keeps the most useful diagnostic mode first.
    public static var menuOrder: [RuntimeLogLevel] { [.debug, .info, .error, .off] }
}

/// Small process-wide logger shared by the app and deterministic runtime.
///
/// All writes are gated before string interpolation, and the lock makes menu
/// changes safe while the combat timer is advancing on another callback.
public final class RuntimeLogger: @unchecked Sendable {
    public static let shared = RuntimeLogger()

    public static let subsystem = "com.zhongpei.livingdesktop"

    private let lock = NSLock()
    private let logger = Logger(subsystem: subsystem, category: "runtime")
    private var configuredLevel: RuntimeLogLevel = .debug

    private init() {}

    public var level: RuntimeLogLevel {
        lock.lock()
        defer { lock.unlock() }
        return configuredLevel
    }

    public func configure(_ level: RuntimeLogLevel) {
        lock.lock()
        configuredLevel = level
        lock.unlock()
    }

    public func isEnabled(_ level: RuntimeLogLevel) -> Bool {
        lock.lock()
        let enabled = configuredLevel.priority >= level.priority && configuredLevel != .off
        lock.unlock()
        return enabled
    }

    public func debug(_ category: String, _ message: @autoclosure () -> String) {
        emit(.debug, category: category, message: message)
    }

    public func info(_ category: String, _ message: @autoclosure () -> String) {
        emit(.info, category: category, message: message)
    }

    public func error(_ category: String, _ message: @autoclosure () -> String) {
        emit(.error, category: category, message: message)
    }

    private func emit(
        _ level: RuntimeLogLevel,
        category: String,
        message: () -> String
    ) {
        guard isEnabled(level) else { return }
        // Use the persistent OSLog default level after our own gate. This keeps
        // debug output available to `log show` instead of relying on the
        // machine's separate OSLog debug collection policy.
        let rendered = message()
        logger.log(level: .default,
                   "[\(level.rawValue, privacy: .public)] [\(category, privacy: .public)] \(rendered, privacy: .public)")
    }
}
