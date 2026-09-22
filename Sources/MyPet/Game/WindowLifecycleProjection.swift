import CoreGraphics
import MyPetCore

/// Projects macOS window samples into the same lifecycle events used by
/// VirtualDesktop. Title changes are content, not geometry invalidations.
final class WindowLifecycleProjection {
    private struct Sample: Equatable {
        let pid: pid_t
        let owner: String
        let bounds: CGRect
        let activity: String

        init(_ window: WindowEntity) {
            pid = window.pid
            owner = window.owner
            bounds = window.bounds
            activity = window.activity
        }
    }

    private var visible: [UInt32: Sample] = [:]
    private var aliveIDs: Set<UInt32>
    private var knownRevisions: [UInt32: Int] = [:]

    init(knownEntities: [EntityState] = []) {
        var alive: Set<UInt32> = []
        for entity in knownEntities where entity.kind == .window {
            guard let id = UInt32(entity.id.raw) else { continue }
            knownRevisions[id] = entity.revision
            if entity.alive { alive.insert(id) }
        }
        aliveIDs = alive
    }

    func events(for windows: [WindowEntity]) -> [GameEvent] {
        let current = Dictionary(windows.map { (UInt32($0.id), Sample($0)) },
                                 uniquingKeysWith: { first, _ in first })
        var events: [GameEvent] = []
        for id in aliveIDs.filter({ current[$0] == nil }).sorted() {
            events.append(GameEvent(kind: .destroyEntity, entityID: EntityID(String(id))))
        }
        for id in current.keys.sorted() {
            guard let sample = current[id], visible[id] != sample else { continue }
            let entityID = EntityID(String(id))
            if let previous = visible[id],
               previous.pid != sample.pid || previous.owner != sample.owner {
                // CGWindowID can be recycled between polls. End the previous
                // window lifetime so its claims/attachments cannot survive.
                events.append(GameEvent(kind: .destroyEntity, entityID: entityID))
            }
            if knownRevisions[id] == nil {
                knownRevisions[id] = 0
                events.append(GameEvent(kind: .registerEntity,
                                        entity: EntityState(id: entityID, kind: .window)))
            } else {
                knownRevisions[id, default: 0] += 1
                events.append(GameEvent(kind: .windowChanged,
                                        entity: EntityState(id: entityID, kind: .window,
                                                            revision: knownRevisions[id]!)))
            }
        }
        visible = current
        aliveIDs = Set(current.keys)
        return events
    }
}
