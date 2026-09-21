import Foundation

public struct LayoutPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A data-only description of a desktop window. It deliberately has no
/// AppKit identity: the harness tests the observations and events a window
/// would produce, not whether macOS currently has such a window.
public enum VirtualWindowState: String, Codable, CaseIterable, Sendable {
    case normal
    case maximized
    case minimized
    case closed
}

public struct VirtualUIElement: Codable, Equatable, Sendable {
    public var role: String
    public var title: String
    public var value: String?

    public init(role: String, title: String, value: String? = nil) {
        self.role = role
        self.title = title
        self.value = value
    }
}

public struct VirtualWindowContent: Codable, Equatable, Sendable {
    public var activity: String?
    public var text: [String]
    public var focusedElementRole: String?
    public var focusedElementValue: String?
    public var salientElements: [VirtualUIElement]

    public init(
        activity: String? = nil,
        text: [String] = [],
        focusedElementRole: String? = nil,
        focusedElementValue: String? = nil,
        salientElements: [VirtualUIElement] = []
    ) {
        self.activity = activity
        self.text = text
        self.focusedElementRole = focusedElementRole
        self.focusedElementValue = focusedElementValue
        self.salientElements = salientElements
    }
}

public struct VirtualWindow: Codable, Equatable, Sendable {
    public var id: EntityID
    public var app: String
    public var bundleID: String?
    public var title: String
    public var frame: LayoutRect
    public var state: VirtualWindowState
    public var focused: Bool
    public var occluded: Bool
    public var zIndex: Int
    public var content: VirtualWindowContent
    public var revision: Int

    private enum CodingKeys: String, CodingKey {
        case id, app, bundleID, title, frame, state, focused, occluded, zIndex, content, revision
    }

    public init(
        id: EntityID,
        app: String,
        title: String,
        frame: LayoutRect,
        state: VirtualWindowState = .normal,
        focused: Bool = false,
        occluded: Bool = false,
        zIndex: Int = 10,
        content: VirtualWindowContent = VirtualWindowContent(),
        bundleID: String? = nil,
        revision: Int = 0
    ) {
        self.id = id
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.state = state
        self.focused = focused
        self.occluded = occluded
        self.zIndex = zIndex
        self.content = content
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(EntityID.self, forKey: .id),
            app: try values.decode(String.self, forKey: .app),
            title: try values.decode(String.self, forKey: .title),
            frame: try values.decode(LayoutRect.self, forKey: .frame),
            state: try values.decodeIfPresent(VirtualWindowState.self, forKey: .state) ?? .normal,
            focused: try values.decodeIfPresent(Bool.self, forKey: .focused) ?? false,
            occluded: try values.decodeIfPresent(Bool.self, forKey: .occluded) ?? false,
            zIndex: try values.decodeIfPresent(Int.self, forKey: .zIndex) ?? 10,
            content: try values.decodeIfPresent(VirtualWindowContent.self, forKey: .content)
                ?? VirtualWindowContent(),
            bundleID: try values.decodeIfPresent(String.self, forKey: .bundleID),
            revision: try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0)
    }

    public var alive: Bool { state != .closed }
}

public struct VirtualScreen: Codable, Equatable, Sendable {
    public var id: String
    public var frame: LayoutRect
    public var main: Bool

    public init(id: String, frame: LayoutRect, main: Bool = false) {
        self.id = id
        self.frame = frame
        self.main = main
    }
}

public struct VirtualCursor: Codable, Equatable, Sendable {
    public var position: LayoutPoint
    public var buttonDown: Bool

    public init(position: LayoutPoint = LayoutPoint(x: 0, y: 0), buttonDown: Bool = false) {
        self.position = position
        self.buttonDown = buttonDown
    }
}

public struct VirtualUser: Codable, Equatable, Sendable {
    public var id: EntityID
    public var focusedWindowID: EntityID?
    public var activity: String?
    public var idleSinceTick: Int64?

    public init(
        id: EntityID = EntityID("user"),
        focusedWindowID: EntityID? = nil,
        activity: String? = nil,
        idleSinceTick: Int64? = nil
    ) {
        self.id = id
        self.focusedWindowID = focusedWindowID
        self.activity = activity
        self.idleSinceTick = idleSinceTick
    }
}

public enum VirtualPermissionDomain: String, Codable, CaseIterable, Sendable {
    case none
    case accessibility
    case screenCapture
}

public struct VirtualPermissions: Codable, Equatable, Sendable {
    public var accessibility: Bool
    public var screenCapture: Bool

    public init(accessibility: Bool = true, screenCapture: Bool = true) {
        self.accessibility = accessibility
        self.screenCapture = screenCapture
    }

    public func allows(_ domain: VirtualPermissionDomain) -> Bool {
        switch domain {
        case .none: return true
        case .accessibility: return accessibility
        case .screenCapture: return screenCapture
        }
    }
}

public struct VirtualSensorProfile: Codable, Equatable, Sendable {
    public var pluginID: String
    public var channel: InputChannel
    public var available: Bool
    public var latencyMilliseconds: Int64
    public var permission: VirtualPermissionDomain

    public init(
        pluginID: String,
        channel: InputChannel,
        available: Bool = true,
        latencyMilliseconds: Int64 = 0,
        permission: VirtualPermissionDomain = .none
    ) {
        self.pluginID = pluginID
        self.channel = channel
        self.available = available
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.permission = permission
    }

    public func latencyTicks(stepMilliseconds: Int64) -> Int64 {
        guard latencyMilliseconds > 0 else { return 0 }
        return max(1, (latencyMilliseconds + max(1, stepMilliseconds) - 1) / max(1, stepMilliseconds))
    }
}

public struct VirtualSensorObservation: Codable, Equatable, Sendable {
    public var observation: InputObservation
    public var permission: VirtualPermissionDomain
    /// nil means use the configured sensor profile latency.
    public var latencyTicks: Int64?

    public init(
        observation: InputObservation,
        permission: VirtualPermissionDomain = .none,
        latencyTicks: Int64? = nil
    ) {
        self.observation = observation
        self.permission = permission
        self.latencyTicks = latencyTicks
    }
}

/// The sensor side of the seam. It describes AX/OCR/content output and
/// failure/latency; it never imports or calls a platform sensor API.
public struct SensorSimulator: Codable, Equatable, Sendable {
    public var profiles: [String: VirtualSensorProfile]
    public var permissions: VirtualPermissions

    public init(
        profiles: [VirtualSensorProfile] = [],
        permissions: VirtualPermissions = VirtualPermissions()
    ) {
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.pluginID, $0) })
        self.permissions = permissions
    }

    public init(
        profiles: [String: VirtualSensorProfile],
        permissions: VirtualPermissions = VirtualPermissions()
    ) {
        self.profiles = profiles
        self.permissions = permissions
    }

    public func profile(for pluginID: String) -> VirtualSensorProfile? {
        profiles[pluginID]
    }

    public func observation(
        for window: VirtualWindow,
        at tick: Int64,
        stepMilliseconds: Int64 = 50
    ) -> VirtualSensorObservation? {
        observations(for: window, at: tick, stepMilliseconds: stepMilliseconds).first
    }

    public func observations(
        for window: VirtualWindow,
        at tick: Int64,
        stepMilliseconds: Int64 = 50
    ) -> [VirtualSensorObservation] {
        let candidates = profiles.values
            .filter { $0.available }
            .sorted { $0.pluginID < $1.pluginID }
        return candidates.compactMap { profile in
            guard permissions.allows(profile.permission) else { return nil }
            let text: String
            switch profile.channel {
            case .windowTitle:
                text = window.title
            case .accessibility:
                text = window.content.focusedElementValue ?? window.content.text.first ?? ""
            case .ocr, .chat, .code, .browser:
                text = window.content.text.joined(separator: "\n")
            }
            let observation = InputObservation(
                id: "\(profile.pluginID)-\(window.id.raw)-\(tick)",
                pluginID: profile.pluginID,
                channel: profile.channel,
                appName: window.app,
                bundleID: window.bundleID,
                windowTitle: window.title,
                text: text,
                capturedAtTick: tick)
            return VirtualSensorObservation(
                observation: observation,
                permission: profile.permission,
                latencyTicks: profile.latencyTicks(stepMilliseconds: stepMilliseconds))
        }
    }
}

/// An app profile is test data, not an assertion about a currently installed
/// app. It makes repeatable AX/OCR coverage scenarios easy to author.
public struct AppProfile: Codable, Equatable, Sendable {
    public var id: String
    public var app: String
    public var defaultActivity: String
    public var sensorProfiles: [VirtualSensorProfile]

    public init(
        id: String,
        app: String,
        defaultActivity: String,
        sensorProfiles: [VirtualSensorProfile] = []
    ) {
        self.id = id
        self.app = app
        self.defaultActivity = defaultActivity
        self.sensorProfiles = sensorProfiles
    }

    public static let chrome = AppProfile(
        id: "chrome", app: "Chrome", defaultActivity: "browsing",
        sensorProfiles: [VirtualSensorProfile(
            pluginID: "accessibility", channel: .accessibility,
            permission: .accessibility)])
    public static let wechat = AppProfile(
        id: "wechat", app: "WeChat", defaultActivity: "chatting",
        sensorProfiles: [VirtualSensorProfile(
            pluginID: "ocr", channel: .ocr, latencyMilliseconds: 120,
            permission: .screenCapture)])
    public static let codex = AppProfile(
        id: "codex", app: "Codex", defaultActivity: "coding",
        sensorProfiles: [VirtualSensorProfile(
            pluginID: "accessibility", channel: .accessibility,
            permission: .accessibility)])
}

public enum VirtualUserActionKind: String, Codable, CaseIterable, Sendable {
    case focusWindow
    case switchApp
    case type
    case talk
    case idle
    case moveCursor
    case clickActor
    case poke
    case dragActor
    case releaseActor
    case closeWindow
}

public struct VirtualUserAction: Codable, Equatable, Sendable {
    public var kind: VirtualUserActionKind
    public var windowID: EntityID?
    public var actorID: EntityID?
    public var text: String?
    public var position: LayoutPoint?

    public init(
        kind: VirtualUserActionKind,
        windowID: EntityID? = nil,
        actorID: EntityID? = nil,
        text: String? = nil,
        position: LayoutPoint? = nil
    ) {
        self.kind = kind
        self.windowID = windowID
        self.actorID = actorID
        self.text = text
        self.position = position
    }
}

public enum VirtualDesktopEventAction: Equatable, Sendable {
    case upsertWindow(VirtualWindow)
    case moveWindow(EntityID, LayoutRect)
    case resizeWindow(EntityID, Double, Double)
    case setWindowState(EntityID, VirtualWindowState)
    case setWindowOccluded(EntityID, Bool)
    case focusWindow(EntityID?)
    case closeWindow(EntityID)
    case setPermission(VirtualPermissionDomain, Bool)
    case user(VirtualUserAction)
    case emitObservation(VirtualSensorObservation)
}

extension VirtualDesktopEventAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, window, windowID, frame, width, height, state, occluded
        case permission, granted, userAction, sensorObservation
    }

    private enum Kind: String, Codable {
        case upsertWindow, moveWindow, resizeWindow, setWindowState, setWindowOccluded
        case focusWindow, closeWindow, setPermission, user, emitObservation
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .upsertWindow(let window):
            try container.encode(Kind.upsertWindow, forKey: .kind)
            try container.encode(window, forKey: .window)
        case .moveWindow(let id, let frame):
            try container.encode(Kind.moveWindow, forKey: .kind)
            try container.encode(id, forKey: .windowID)
            try container.encode(frame, forKey: .frame)
        case .resizeWindow(let id, let width, let height):
            try container.encode(Kind.resizeWindow, forKey: .kind)
            try container.encode(id, forKey: .windowID)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        case .setWindowState(let id, let state):
            try container.encode(Kind.setWindowState, forKey: .kind)
            try container.encode(id, forKey: .windowID)
            try container.encode(state, forKey: .state)
        case .setWindowOccluded(let id, let occluded):
            try container.encode(Kind.setWindowOccluded, forKey: .kind)
            try container.encode(id, forKey: .windowID)
            try container.encode(occluded, forKey: .occluded)
        case .focusWindow(let id):
            try container.encode(Kind.focusWindow, forKey: .kind)
            try container.encodeIfPresent(id, forKey: .windowID)
        case .closeWindow(let id):
            try container.encode(Kind.closeWindow, forKey: .kind)
            try container.encode(id, forKey: .windowID)
        case .setPermission(let domain, let granted):
            try container.encode(Kind.setPermission, forKey: .kind)
            try container.encode(domain, forKey: .permission)
            try container.encode(granted, forKey: .granted)
        case .user(let action):
            try container.encode(Kind.user, forKey: .kind)
            try container.encode(action, forKey: .userAction)
        case .emitObservation(let observation):
            try container.encode(Kind.emitObservation, forKey: .kind)
            try container.encode(observation, forKey: .sensorObservation)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .upsertWindow:
            self = .upsertWindow(try container.decode(VirtualWindow.self, forKey: .window))
        case .moveWindow:
            self = .moveWindow(
                try container.decode(EntityID.self, forKey: .windowID),
                try container.decode(LayoutRect.self, forKey: .frame))
        case .resizeWindow:
            self = .resizeWindow(
                try container.decode(EntityID.self, forKey: .windowID),
                try container.decode(Double.self, forKey: .width),
                try container.decode(Double.self, forKey: .height))
        case .setWindowState:
            self = .setWindowState(
                try container.decode(EntityID.self, forKey: .windowID),
                try container.decode(VirtualWindowState.self, forKey: .state))
        case .setWindowOccluded:
            self = .setWindowOccluded(
                try container.decode(EntityID.self, forKey: .windowID),
                try container.decode(Bool.self, forKey: .occluded))
        case .focusWindow:
            self = .focusWindow(try container.decodeIfPresent(EntityID.self, forKey: .windowID))
        case .closeWindow:
            self = .closeWindow(try container.decode(EntityID.self, forKey: .windowID))
        case .setPermission:
            self = .setPermission(
                try container.decode(VirtualPermissionDomain.self, forKey: .permission),
                try container.decode(Bool.self, forKey: .granted))
        case .user:
            self = .user(try container.decode(VirtualUserAction.self, forKey: .userAction))
        case .emitObservation:
            self = .emitObservation(
                try container.decode(VirtualSensorObservation.self, forKey: .sensorObservation))
        }
    }
}

public struct VirtualDesktopEvent: Codable, Equatable, Sendable {
    public var atTick: Int64
    public var sequence: Int64
    public var action: VirtualDesktopEventAction

    public init(atTick: Int64, sequence: Int64 = 0, action: VirtualDesktopEventAction) {
        self.atTick = atTick
        self.sequence = sequence
        self.action = action
    }
}

public struct VirtualDesktopTrace: Codable, Equatable, Sendable {
    public var tick: Int64
    public var kind: String
    public var detail: String

    public init(tick: Int64, kind: String, detail: String) {
        self.tick = tick
        self.kind = kind
        self.detail = detail
    }
}

/// The single environment seam for the headless harness. It owns virtual
/// desktop state and only produces GameEvents; GameKernel remains the only
/// writer of gameplay WorldState.
public struct VirtualDesktop: Codable, Equatable, Sendable {
    public private(set) var tick: Int64
    public var stepMilliseconds: Int64
    public var screens: [VirtualScreen]
    public var user: VirtualUser
    public var cursor: VirtualCursor
    public private(set) var windows: [String: VirtualWindow]
    public var sensors: SensorSimulator
    public var inputCatalog: InputPluginCatalog
    public var captureOnFocus: Bool
    public private(set) var scheduledEvents: [VirtualDesktopEvent]
    public private(set) var trace: [VirtualDesktopTrace]
    private var nextSequence: Int64

    public init(
        screens: [VirtualScreen] = [],
        windows: [VirtualWindow] = [],
        user: VirtualUser = VirtualUser(),
        cursor: VirtualCursor = VirtualCursor(),
        sensors: SensorSimulator = SensorSimulator(),
        inputCatalog: InputPluginCatalog = InputPluginCatalog(),
        events: [VirtualDesktopEvent] = [],
        stepMilliseconds: Int64 = 50,
        captureOnFocus: Bool = false
    ) {
        self.tick = 0
        self.stepMilliseconds = max(1, stepMilliseconds)
        self.screens = screens
        self.user = user
        self.cursor = cursor
        self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id.raw, $0) })
        self.sensors = sensors
        self.inputCatalog = inputCatalog
        self.captureOnFocus = captureOnFocus
        var normalizedEvents: [VirtualDesktopEvent] = []
        var usedSequences = Set<Int64>()
        var sequence = (events.map(\.sequence).max() ?? -1) + 1
        for event in events {
            var copy = event
            if usedSequences.contains(copy.sequence) {
                copy.sequence = sequence
                sequence += 1
            }
            usedSequences.insert(copy.sequence)
            normalizedEvents.append(copy)
        }
        self.scheduledEvents = normalizedEvents
        self.trace = []
        self.nextSequence = sequence
    }

    public var pendingEvents: [VirtualDesktopEvent] { scheduledEvents }

    public mutating func schedule(_ event: VirtualDesktopEvent) {
        var copy = event
        copy.sequence = nextSequence
        nextSequence += 1
        scheduledEvents.append(copy)
    }

    /// Apply every desktop event up to `targetTick` and return the
    /// observations/user/environment events that the production kernel should
    /// consume at that tick. Trace and persistence retain the complete local input.
    public mutating func advance(to targetTick: Int64) -> [GameEvent] {
        guard targetTick >= tick else { return [] }
        let ready = scheduledEvents
            .filter { $0.atTick <= targetTick }
            .sorted { lhs, rhs in
                lhs.atTick == rhs.atTick ? lhs.sequence < rhs.sequence : lhs.atTick < rhs.atTick
            }
        let readySequences = Set(ready.map(\.sequence))
        scheduledEvents.removeAll { readySequences.contains($0.sequence) }

        var output: [GameEvent] = []
        for event in ready {
            output.append(contentsOf: apply(event, outputTick: targetTick))
        }
        tick = targetTick
        return output
    }

    public func window(_ id: EntityID) -> VirtualWindow? { windows[id.raw] }

    public var focusedWindow: VirtualWindow? {
        windows.values.first(where: { $0.focused && $0.alive && !$0.occluded })
    }

    public func stableDigest() -> String {
        var parts = ["t:\(tick)", "user:\(user.focusedWindowID?.raw ?? "-"):\(user.activity ?? "-")"]
        for screen in screens.sorted(by: { $0.id < $1.id }) {
            parts.append("screen:\(screen.id):\(screen.frame.x):\(screen.frame.y):\(screen.frame.width):\(screen.frame.height)")
        }
        for key in windows.keys.sorted() {
            guard let window = windows[key] else { continue }
            parts.append(
                "w:\(key):\(window.frame.x):\(window.frame.y):\(window.frame.width):\(window.frame.height):\(window.state.rawValue):\(window.focused):\(window.occluded):\(window.revision)")
        }
        parts.append("perm:\(sensors.permissions.accessibility):\(sensors.permissions.screenCapture)")
        return parts.joined(separator: "|")
    }

    private mutating func apply(_ event: VirtualDesktopEvent, outputTick: Int64) -> [GameEvent] {
        switch event.action {
        case .upsertWindow(let incoming):
            return upsert(incoming, tick: outputTick)
        case .moveWindow(let id, let frame):
            guard var window = windows[id.raw], window.alive else { return [] }
            window.frame = frame
            window.revision += 1
            windows[id.raw] = window
            appendTrace(outputTick, "window", "move:\(id.raw)")
            return [GameEvent(kind: .windowChanged, entity: EntityState(
                id: id, kind: .window, revision: window.revision), entityID: id)]
        case .resizeWindow(let id, let width, let height):
            guard var window = windows[id.raw], window.alive else { return [] }
            window.frame.width = max(1, width)
            window.frame.height = max(1, height)
            window.revision += 1
            windows[id.raw] = window
            appendTrace(outputTick, "window", "resize:\(id.raw)")
            return [GameEvent(kind: .windowChanged, entity: EntityState(
                id: id, kind: .window, revision: window.revision), entityID: id)]
        case .setWindowOccluded(let id, let occluded):
            guard var window = windows[id.raw], window.alive else { return [] }
            window.occluded = occluded
            window.revision += 1
            windows[id.raw] = window
            appendTrace(outputTick, "window", "occluded:\(id.raw):\(occluded)")
            return [GameEvent(kind: .windowChanged, entity: EntityState(
                id: id, kind: .window, revision: window.revision), entityID: id)]
        case .setWindowState(let id, let state):
            guard var window = windows[id.raw] else { return [] }
            window.state = state
            window.focused = state != .closed && window.focused
            window.revision += 1
            windows[id.raw] = window
            appendTrace(outputTick, "window", "state:\(id.raw):\(state.rawValue)")
            if state == .closed {
                return [GameEvent(kind: .destroyEntity, entityID: id)]
            }
            return [GameEvent(kind: .windowChanged, entity: EntityState(
                id: id, kind: .window, revision: window.revision), entityID: id)]
        case .focusWindow(let id):
            return focus(id, tick: outputTick)
        case .closeWindow(let id):
            guard var window = windows[id.raw], window.alive else { return [] }
            window.state = .closed
            window.focused = false
            window.revision += 1
            windows[id.raw] = window
            if user.focusedWindowID == id { user.focusedWindowID = nil }
            appendTrace(outputTick, "window", "close:\(id.raw)")
            return [GameEvent(kind: .destroyEntity, entityID: id)]
        case .setPermission(let domain, let granted):
            switch domain {
            case .accessibility: sensors.permissions.accessibility = granted
            case .screenCapture: sensors.permissions.screenCapture = granted
            case .none: break
            }
            appendTrace(outputTick, "permission", "\(domain.rawValue):\(granted ? "granted" : "denied")")
            return [GameEvent(
                kind: .permissionChanged,
                permissionDomain: domain.rawValue,
                permissionAvailable: granted)]
        case .user(let action):
            return apply(action, tick: outputTick)
        case .emitObservation(let sensorObservation):
            return route(sensorObservation, scheduledAt: event.atTick, outputTick: outputTick)
        }
    }

    private mutating func upsert(_ incoming: VirtualWindow, tick: Int64) -> [GameEvent] {
        var window = incoming
        let existed = windows[incoming.id.raw] != nil
        if let old = windows[incoming.id.raw] {
            window.revision = max(window.revision, old.revision + 1)
        }
        windows[incoming.id.raw] = window
        appendTrace(tick, "window", "\(existed ? "update" : "open"):\(window.id.raw)")
        let entity = EntityState(id: window.id, kind: .window, revision: window.revision, alive: window.alive)
        var events: [GameEvent] = [GameEvent(
            kind: existed ? .windowChanged : .registerEntity,
            entity: entity,
            entityID: window.id)]
        if window.focused {
            events.append(contentsOf: focus(window.id, tick: tick))
        }
        return events
    }

    private mutating func focus(_ id: EntityID?, tick: Int64) -> [GameEvent] {
        let focusableID: EntityID? = id.flatMap { candidate in
            guard let window = windows[candidate.raw], window.alive, !window.occluded else { return nil }
            return candidate
        }
        for key in windows.keys {
            let alive = windows[key]?.alive == true
            let visible = windows[key]?.occluded == false
            windows[key]?.focused = (focusableID != nil && key == focusableID?.raw && alive && visible)
        }
        user.focusedWindowID = focusableID
        user.activity = focusableID.flatMap { windows[$0.raw]?.content.activity }
        appendTrace(tick, "user", "focus:\(focusableID?.raw ?? "none")")
        let events: [GameEvent] = [GameEvent(kind: .foregroundChanged, entityID: focusableID)]
        if captureOnFocus, let window = focusableID.flatMap({ windows[$0.raw] }) {
            let observations = sensors.observations(
                for: window, at: tick, stepMilliseconds: stepMilliseconds)
            for observation in observations {
                schedule(VirtualDesktopEvent(atTick: tick, action: .emitObservation(observation)))
            }
        }
        return events
    }

    private mutating func apply(_ action: VirtualUserAction, tick: Int64) -> [GameEvent] {
        switch action.kind {
        case .focusWindow, .switchApp:
            return focus(action.windowID, tick: tick)
        case .closeWindow:
            guard let id = action.windowID else { return [] }
            return apply(VirtualDesktopEvent(atTick: tick, action: .closeWindow(id)), outputTick: tick)
        case .moveCursor:
            if let position = action.position { cursor.position = position }
            appendTrace(tick, "user", "move_cursor")
            return [GameEvent(kind: .userInteraction, actorID: action.actorID, userAction: action.kind.rawValue)]
        case .type, .talk:
            if let id = user.focusedWindowID, var window = windows[id.raw], let text = action.text {
                window.content.text.append(text)
                window.revision += 1
                windows[id.raw] = window
            }
            appendTrace(tick, "user", "\(action.kind.rawValue):text=\(action.text ?? "")")
            return [GameEvent(kind: .userInteraction, actorID: action.actorID,
                              userAction: action.kind.rawValue, userText: action.text)]
        case .idle:
            user.idleSinceTick = tick
            appendTrace(tick, "user", "idle")
            return [GameEvent(kind: .userInteraction, actorID: action.actorID, userAction: action.kind.rawValue)]
        case .clickActor, .poke, .dragActor, .releaseActor:
            appendTrace(tick, "user", "\(action.kind.rawValue):\(action.actorID?.raw ?? "-")")
            return [GameEvent(kind: .userInteraction, actorID: action.actorID, userAction: action.kind.rawValue)]
        }
    }

    private mutating func route(
        _ sensorObservation: VirtualSensorObservation,
        scheduledAt: Int64,
        outputTick: Int64
    ) -> [GameEvent] {
        let observation = sensorObservation.observation
        let profile = sensors.profile(for: observation.pluginID)
        let requiredPermission = sensorObservation.permission != .none
            ? sensorObservation.permission : (profile?.permission ?? .none)
        guard sensors.permissions.allows(requiredPermission) else {
            appendTrace(outputTick, "sensor", "permission_denied:\(observation.pluginID):window=\(observation.windowTitle):text=\(observation.text)")
            return []
        }
        guard profile?.available != false else {
            appendTrace(outputTick, "sensor", "unavailable:\(observation.pluginID):window=\(observation.windowTitle):text=\(observation.text)")
            return []
        }
        let latency = max(0, sensorObservation.latencyTicks ?? profile?.latencyTicks(stepMilliseconds: stepMilliseconds) ?? 0)
        if latency > 0 {
            var delayed = sensorObservation
            delayed.latencyTicks = 0
            schedule(VirtualDesktopEvent(atTick: scheduledAt + latency, action: .emitObservation(delayed)))
            appendTrace(outputTick, "sensor", "delayed:\(observation.pluginID):\(latency):window=\(observation.windowTitle):text=\(observation.text)")
            return []
        }
        guard let event = inputCatalog.route(observation, at: outputTick) else {
            appendTrace(outputTick, "sensor", "filtered:\(observation.pluginID):window=\(observation.windowTitle):text=\(observation.text)")
            return []
        }
        appendTrace(outputTick, "sensor", "routed:\(observation.pluginID):window=\(observation.windowTitle):text=\(observation.text)")
        return [event]
    }

    private mutating func appendTrace(_ tick: Int64, _ kind: String, _ detail: String) {
        trace.append(VirtualDesktopTrace(tick: tick, kind: kind, detail: detail))
    }

}
