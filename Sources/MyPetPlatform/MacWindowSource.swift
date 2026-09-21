import AppKit
import CoreGraphics
import Foundation

public struct PlatformWindow: Equatable, Sendable {
    public var id: CGWindowID
    public var pid: pid_t
    public var owner: String
    public var bounds: CGRect
    public var title: String
    public var bundleID: String?

    public init(id: CGWindowID, pid: pid_t, owner: String, bounds: CGRect,
                title: String = "", bundleID: String? = nil) {
        self.id = id
        self.pid = pid
        self.owner = owner
        self.bounds = bounds
        self.title = title
        self.bundleID = bundleID
    }
}

/// Real macOS window discovery. It owns CGWindow/NSWorkspace calls and exports
/// plain immutable facts; gameplay decides what those facts mean.
public final class MacWindowSource {
    public private(set) var windows: [PlatformWindow] = []
    public private(set) var foreground: PlatformWindow?

    private let ownPID: pid_t

    public init(ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownPID = ownPID
    }

    public func poll() {
        windows = Self.decodeWindows(ownPID: ownPID)
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            foreground = windows.first { $0.pid == frontPID }
        } else {
            foreground = nil
        }
    }

    public func liveBounds(_ id: CGWindowID) -> CGRect? {
        guard id != 0,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let item = list.first,
              item[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = item[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public static func decodeWindows(
        ownPID: pid_t, list: [[String: Any]]? = nil,
        skippedOwners: Set<String> = defaultSkippedOwners,
        minimumSize: CGSize = CGSize(width: 220, height: 140)
    ) -> [PlatformWindow] {
        let raw = list ?? ((CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]) ?? [])
        return raw.compactMap {
            decodeWindow($0, ownPID: ownPID, skippedOwners: skippedOwners, minimumSize: minimumSize)
        }
    }

    public static func decodeWindow(
        _ item: [String: Any], ownPID: pid_t,
        skippedOwners: Set<String> = defaultSkippedOwners,
        minimumSize: CGSize = CGSize(width: 220, height: 140)
    ) -> PlatformWindow? {
        guard item[kCGWindowLayer as String] as? Int == 0 else { return nil }
        let pid = item[kCGWindowOwnerPID as String] as? Int ?? 0
        guard pid != ownPID else { return nil }
        let owner = item[kCGWindowOwnerName as String] as? String ?? ""
        guard !skippedOwners.contains(owner),
              (item[kCGWindowAlpha as String] as? Double ?? 1) >= 0.05,
              let rawBounds = item[kCGWindowBounds as String] as? [String: Any],
              let x = rawBounds["X"] as? Double, let y = rawBounds["Y"] as? Double,
              let width = rawBounds["Width"] as? Double, let height = rawBounds["Height"] as? Double,
              width.isFinite, height.isFinite,
              width >= minimumSize.width, height >= minimumSize.height
        else { return nil }
        let id = item[kCGWindowNumber as String] as? Int ?? 0
        guard id != 0 else { return nil }
        let title = item[kCGWindowName as String] as? String ?? ""
        let bundleID = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
        return PlatformWindow(
            id: CGWindowID(id), pid: pid_t(pid), owner: owner,
            bounds: CGRect(x: x, y: y, width: width, height: height),
            title: String(title.prefix(120)), bundleID: bundleID)
    }

    public static let defaultSkippedOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "Wallpaper", "WindowManager",
        "universalaccessd", "Screenshot",
    ]
}
