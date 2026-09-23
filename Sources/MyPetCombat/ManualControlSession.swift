import Foundation

/// Platform-neutral names for the physical keys offered by the desktop adapter.
public enum KeyboardControlKey: String, Codable, CaseIterable, Hashable, Sendable {
    case arrowLeft, arrowRight, arrowUp, arrowDown
    case keyZ, keyX, keyC, keyA, keyS, keyD
    case keyQ, keyW, keyE, keyR
}

/// Logical controls consumed by FighterInputFrame. These are intentionally
/// separate from physical keyboard keys and from character move IDs.
public enum ManualControlKey: String, Codable, CaseIterable, Hashable, Sendable {
    case left, right, up, down
    case buttonX, buttonY, buttonZ, buttonA, buttonS, buttonD
    case tag, assist, powerUp, defensiveBurst
}

public struct ManualControlMapping: Codable, Equatable, Sendable {
    public var id: String
    public var bindings: [KeyboardControlKey: ManualControlKey]

    public init(id: String, bindings: [KeyboardControlKey: ManualControlKey]) {
        self.id = id
        self.bindings = bindings
    }

    public static let standard = ManualControlMapping(id: "standard", bindings: [
        .arrowLeft: .left, .arrowRight: .right,
        .arrowUp: .up, .arrowDown: .down,
        .keyZ: .buttonX, .keyX: .buttonY, .keyC: .buttonZ,
        .keyA: .buttonA, .keyS: .buttonS, .keyD: .buttonD,
        .keyQ: .tag, .keyW: .assist, .keyE: .powerUp, .keyR: .defensiveBurst,
    ])
}

/// Persistable per-character override catalog. Character move profiles still
/// map logical commands to moves; this catalog only maps physical keys to the
/// shared logical input vocabulary.
public struct ManualControlMappingCatalog: Codable, Equatable, Sendable {
    public var defaultMapping: ManualControlMapping
    public private(set) var characterMappings: [String: ManualControlMapping]

    public init(
        defaultMapping: ManualControlMapping = .standard,
        characterMappings: [String: ManualControlMapping] = [:]
    ) {
        self.defaultMapping = defaultMapping
        self.characterMappings = characterMappings
    }

    public mutating func set(_ mapping: ManualControlMapping, for characterID: String) {
        characterMappings[characterID] = mapping
    }

    public mutating func remove(for characterID: String) {
        characterMappings[characterID] = nil
    }

    public func mapping(for characterID: String) -> ManualControlMapping {
        characterMappings[characterID] ?? defaultMapping
    }
}

/// Platform-neutral pressed-key state for an explicit manual-control session.
/// AppKit only maps native key codes into these values; focus and lifecycle
/// changes atomically emit a neutral FighterInputFrame.
public struct ManualControlSession: Codable, Equatable, Sendable {
    public private(set) var isActive = false
    public private(set) var mapping: ManualControlMapping
    public private(set) var pressedKeys = Set<KeyboardControlKey>()

    public init(mapping: ManualControlMapping = .standard) {
        self.mapping = mapping
    }

    @discardableResult
    public mutating func begin(mapping: ManualControlMapping? = nil) -> FighterInputFrame {
        if let mapping { self.mapping = mapping }
        isActive = true
        pressedKeys.removeAll()
        return .neutral
    }

    @discardableResult
    public mutating func press(_ key: KeyboardControlKey) -> FighterInputFrame {
        guard isActive else { return .neutral }
        pressedKeys.insert(key)
        return input
    }

    @discardableResult
    public mutating func release(_ key: KeyboardControlKey) -> FighterInputFrame {
        guard isActive else { return .neutral }
        pressedKeys.remove(key)
        return input
    }

    @discardableResult
    public mutating func focusLost() -> FighterInputFrame {
        pressedKeys.removeAll()
        return .neutral
    }

    @discardableResult
    public mutating func end() -> FighterInputFrame {
        isActive = false
        pressedKeys.removeAll()
        return .neutral
    }

    public var input: FighterInputFrame {
        guard isActive else { return .neutral }
        var buttons = Set<CombatButton>()
        let logicalKeys = Set(pressedKeys.compactMap { mapping.bindings[$0] })
        let mappings: [(ManualControlKey, CombatButton)] = [
            (.buttonX, .x), (.buttonY, .y), (.buttonZ, .z),
            (.buttonA, .a), (.buttonS, .s), (.buttonD, .d),
        ]
        for (key, button) in mappings where logicalKeys.contains(key) {
            buttons.insert(button)
        }
        var systemControls = Set<CombatSystemControl>()
        let systemMappings: [(ManualControlKey, CombatSystemControl)] = [
            (.tag, .tag), (.assist, .assist),
            (.powerUp, .powerUp), (.defensiveBurst, .defensiveBurst),
        ]
        for (key, control) in systemMappings where logicalKeys.contains(key) {
            systemControls.insert(control)
        }
        return FighterInputFrame(
            left: logicalKeys.contains(.left),
            right: logicalKeys.contains(.right),
            up: logicalKeys.contains(.up),
            down: logicalKeys.contains(.down),
            buttons: buttons,
            systemControls: systemControls)
    }
}
