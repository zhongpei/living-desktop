import Foundation
import MyPetCore

/// A replayable pointer experiment using the same reflex as the AppKit adapter.
/// Samples are desktop coordinates in the project's top-origin layout space.
public struct PointerSample: Codable, Equatable, Sendable {
    public var time: Double
    public var position: LayoutPoint
    public var buttonDown: Bool
    public var actors: [PointerActor]

    public init(time: Double, position: LayoutPoint, buttonDown: Bool = false,
                actors: [PointerActor]) {
        self.time = time
        self.position = position
        self.buttonDown = buttonDown
        self.actors = actors
    }
}

public struct PointerSimulationTrace: Codable, Equatable, Sendable {
    public var sample: PointerSample
    public var targetID: EntityID?
    public var plan: PointerResponsePlan?
    public var cooldownRemaining: Double

    public init(sample: PointerSample, targetID: EntityID?, plan: PointerResponsePlan?,
                cooldownRemaining: Double) {
        self.sample = sample
        self.targetID = targetID
        self.plan = plan
        self.cooldownRemaining = cooldownRemaining
    }
}

public struct PointerSimulation: Codable, Equatable, Sendable {
    public var reflex: PointerReflex
    public private(set) var trace: [PointerSimulationTrace] = []

    public init(config: PointerReflexConfig = PointerReflexConfig()) {
        reflex = PointerReflex(config: config)
    }

    @discardableResult
    public mutating func step(_ sample: PointerSample) -> PointerResponsePlan? {
        let plan = reflex.sample(x: sample.position.x, y: sample.position.y,
                                 time: sample.time, buttonDown: sample.buttonDown,
                                 actors: sample.actors)
        trace.append(PointerSimulationTrace(
            sample: sample, targetID: reflex.targetID, plan: plan,
            cooldownRemaining: reflex.cooldownRemaining(at: sample.time)))
        return plan
    }

    @discardableResult
    public mutating func step(desktop: VirtualDesktop, time: Double,
                              actors: [PointerActor]) -> PointerResponsePlan? {
        step(PointerSample(time: time, position: desktop.cursor.position,
                           buttonDown: desktop.cursor.buttonDown, actors: actors))
    }
}
