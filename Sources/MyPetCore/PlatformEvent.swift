import Foundation

/// Delivery semantics at the platform/runtime boundary. Control transitions
/// are never discarded; sampled facts may collapse to the newest value.
public enum PlatformEventDelivery: Codable, Equatable, Sendable {
    case mustDeliver
    case latestWins(key: String)
    case bestEffort
}

public struct PlatformEvent: Codable, Equatable, Sendable {
    public var gameEvent: GameEvent
    public var delivery: PlatformEventDelivery

    public init(_ gameEvent: GameEvent, delivery: PlatformEventDelivery? = nil) {
        self.gameEvent = gameEvent
        self.delivery = delivery ?? Self.defaultDelivery(for: gameEvent)
    }

    private static func defaultDelivery(for event: GameEvent) -> PlatformEventDelivery {
        switch event.kind {
        case .contentObservation:
            guard let observation = event.inputObservation else { return .bestEffort }
            let app = observation.bundleID ?? observation.appName
            return .latestWins(
                key: "content:\(observation.pluginID):\(observation.channel.rawValue):\(app)")
        case .windowChanged:
            return .latestWins(key: "window:\((event.entityID ?? event.entity?.id)?.raw ?? "-")")
        case .permissionChanged:
            return .latestWins(key: "permission:\(event.permissionDomain ?? "-")")
        default:
            return .mustDeliver
        }
    }
}

/// Small thread-safe ingress used by both macOS adapters and VirtualDesktop.
/// `capacity` bounds sampled facts only; user/control transitions are rare and
/// must not disappear merely because sensors produced a burst.
public final class PlatformEventBuffer: @unchecked Sendable {
    private struct Entry {
        var sequence: Int64
        var event: PlatformEvent
    }

    private let lock = NSLock()
    private let capacity: Int
    private var nextSequence: Int64 = 0
    private var entries: [Entry] = []

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { withLock { entries.count } }
    public var latestSequence: Int64 { withLock { nextSequence } }

    public func publish(_ event: PlatformEvent) {
        withLock {
            if case let .latestWins(key) = event.delivery {
                entries.removeAll {
                    guard case let .latestWins(existingKey) = $0.event.delivery else { return false }
                    return existingKey == key
                }
            }
            nextSequence += 1
            entries.append(Entry(sequence: nextSequence, event: event))
            trimSampledEvents()
        }
    }

    public func events(after sequence: Int64) -> (events: [PlatformEvent], latestSequence: Int64) {
        withLock {
            (entries.filter { $0.sequence > sequence }.map(\.event), nextSequence)
        }
    }

    public func drain() -> [PlatformEvent] {
        withLock {
            let result = entries.map(\.event)
            entries.removeAll(keepingCapacity: true)
            return result
        }
    }

    public func removeAll() {
        withLock { entries.removeAll(keepingCapacity: true) }
    }

    private func trimSampledEvents() {
        while entries.lazy.filter({ $0.event.delivery != .mustDeliver }).count > capacity {
            guard let index = entries.firstIndex(where: { $0.event.delivery != .mustDeliver }) else { return }
            entries.remove(at: index)
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
