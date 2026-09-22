import Foundation
import MyPetCore

extension GameKernel {
    /// Scenario construction lives with deterministic simulation, not Core.
    public convenience init(scenario: HarnessScenario) {
        var world = WorldState()
        for entity in scenario.entities {
            world.entities[entity.id.raw] = entity
            world.planEpochs[entity.id.raw] = 0
        }
        for window in scenario.desktop.windows.values.sorted(by: { $0.id.raw < $1.id.raw }) {
            if world.entities[window.id.raw] == nil {
                world.entities[window.id.raw] = EntityState(
                    id: window.id, kind: .window,
                    revision: window.revision, alive: window.alive)
                world.planEpochs[window.id.raw] = 0
            }
        }
        for slot in scenario.slots { world.slots[slot.key] = slot }
        for window in world.entities.values where window.kind == .window && window.alive {
            for slotID in ["top.left", "top.right"] {
                let key = "\(window.id.raw)/\(slotID)"
                if world.slots[key] == nil {
                    world.slots[key] = InteractionSlot(entityID: window.id, slotID: slotID)
                }
            }
        }
        let inbox = EventInbox()
        for scheduled in scenario.events {
            inbox.enqueue(scheduled.event, atTick: scheduled.atTick)
        }
        self.init(snapshot: KernelSnapshot(
            clock: SimClock(stepMilliseconds: scenario.stepMilliseconds),
            world: world, pendingEvents: inbox.pendingEvents,
            nextSequence: inbox.sequence, trace: [], manualViolations: []))
    }
}
