import Foundation

public struct LiveBrainResult: Codable, Equatable, Sendable {
    public let tick: Int64
    public let requested: Bool
    public let enqueued: Bool
    public let reason: String
    public let latencyMilliseconds: Int
    /// Raw local model output. The harness is a local training recorder and
    /// intentionally does not redact or summarize this field.
    public let rawOutput: String?
    public let trajectoryID: String?
    public let actor: String?
    public let modelInput: String?
    public let orderedOptions: [String]?
    public let chosen: String?
    public let providerID: String?

    public init(
        tick: Int64,
        requested: Bool,
        enqueued: Bool,
        reason: String,
        latencyMilliseconds: Int = 0,
        rawOutput: String? = nil,
        trajectoryID: String? = nil,
        actor: String? = nil,
        modelInput: String? = nil,
        orderedOptions: [String]? = nil,
        chosen: String? = nil,
        providerID: String? = nil
    ) {
        self.tick = tick
        self.requested = requested
        self.enqueued = enqueued
        self.reason = reason
        self.latencyMilliseconds = latencyMilliseconds
        self.rawOutput = rawOutput
        self.trajectoryID = trajectoryID
        self.actor = actor
        self.modelInput = modelInput
        self.orderedOptions = orderedOptions
        self.chosen = chosen
        self.providerID = providerID
    }
}

/// Shared, data-only world encoder for headless semantic adapters. Model
/// outputs are decoded by Goal/Needle providers; this type deliberately has no
/// BehaviorRequest parser, so a model cannot bypass the semantic ActionRuntime.
public enum HeadlessContextCodec {

    public static func worldPrompt(world: WorldState, tick: Int64) -> String {
        let entities = world.entities.values.sorted { $0.id.raw < $1.id.raw }.map {
            ["id": $0.id.raw, "kind": $0.kind.rawValue, "alive": $0.alive, "revision": $0.revision] as [String: Any]
        }
        let slots = world.slots.values.sorted { $0.key < $1.key }.map {
            ["key": $0.key, "status": $0.status.rawValue, "capacity": $0.capacity,
             "occupants": $0.occupants.map { $0.actorID.raw }] as [String: Any]
        }
        let object: [String: Any] = [
            "tick": tick,
            "entities": entities,
            "slots": slots,
            "running_behaviors": world.behaviors.values.filter { $0.status == .running }.map {
                ["id": $0.request.id, "actor_id": $0.request.actorID.raw,
                 "intent": $0.request.intent, "remaining_ticks": $0.remainingTicks]
            },
            "facts": world.facts.keys.sorted(),
            "relations": world.relationValues,
            "input_observations": world.inputObservations.values.map { observation -> [String: Any] in
                let bundleID: Any = observation.bundleID.map { $0 as Any } ?? NSNull()
                let expiresAtTick: Any = observation.expiresAtTick.map { $0 as Any } ?? NSNull()
                return ["plugin": observation.pluginID, "channel": observation.channel.rawValue,
                        "app": observation.appName, "bundle_id": bundleID,
                        "window_title": observation.windowTitle, "text": observation.text,
                        "captured_at_tick": observation.capturedAtTick,
                        "expires_at_tick": expiresAtTick]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

}
