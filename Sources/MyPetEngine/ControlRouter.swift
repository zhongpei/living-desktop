import Foundation
import MyPetCombat
import MyPetCore

public enum ControlSource: String, Codable, Hashable, Sendable {
    case autonomous, authored, manual, pointer
}

public struct RoutedFighterInput: Codable, Equatable, Sendable {
    public var input: FighterInputFrame
    public var authority: CombatControlAuthority

    public init(input: FighterInputFrame, authority: CombatControlAuthority) {
        self.input = input
        self.authority = authority
    }
}

/// Deterministic source arbitration. Every source produces FighterInputFrame;
/// no source receives an action-starting escape hatch around CommandMatcher.
public struct ControlRouter: Codable, Equatable, Sendable {
    private struct Slot: Codable, Equatable, Sendable {
        var input: FighterInputFrame
    }

    private var slots: [String: [ControlSource: Slot]] = [:]
    private static let priority: [ControlSource] = [.pointer, .manual, .authored, .autonomous]

    public init() {}

    public mutating func activate(
        _ source: ControlSource,
        for actorID: EntityID,
        input: FighterInputFrame = .neutral
    ) {
        slots[actorID.raw, default: [:]][source] = Slot(input: input)
    }

    public mutating func setInput(
        _ input: FighterInputFrame,
        source: ControlSource,
        for actorID: EntityID
    ) {
        guard slots[actorID.raw]?[source] != nil else { return }
        slots[actorID.raw]?[source] = Slot(input: input)
    }

    public mutating func deactivate(_ source: ControlSource, for actorID: EntityID) {
        slots[actorID.raw]?[source] = nil
        if slots[actorID.raw]?.isEmpty == true { slots[actorID.raw] = nil }
    }

    public mutating func removeActor(_ actorID: EntityID) {
        slots[actorID.raw] = nil
    }

    public mutating func releaseAllManualInput(for actorID: EntityID) {
        guard slots[actorID.raw]?[.manual] != nil else { return }
        slots[actorID.raw]?[.manual] = Slot(input: .neutral)
    }

    public func isActive(_ source: ControlSource, for actorID: EntityID) -> Bool {
        slots[actorID.raw]?[source] != nil
    }

    public func hasAnyActive(_ sources: Set<ControlSource>) -> Bool {
        slots.values.contains { actorSlots in
            sources.contains(where: { actorSlots[$0] != nil })
        }
    }

    public func actorIDs(activeIn sources: Set<ControlSource>) -> [EntityID] {
        slots.compactMap { id, actorSlots in
            sources.contains(where: { actorSlots[$0] != nil }) ? EntityID(id) : nil
        }.sorted { $0.raw < $1.raw }
    }

    public func resolve(for actorID: EntityID) -> RoutedFighterInput? {
        guard let actorSlots = slots[actorID.raw] else { return nil }
        for source in Self.priority {
            guard let slot = actorSlots[source] else { continue }
            return RoutedFighterInput(input: slot.input, authority: source.authority)
        }
        return nil
    }
}

private extension ControlSource {
    var authority: CombatControlAuthority {
        switch self {
        case .autonomous: return .autonomous
        case .authored: return .authored
        case .manual: return .manual
        case .pointer: return .pointer
        }
    }
}
