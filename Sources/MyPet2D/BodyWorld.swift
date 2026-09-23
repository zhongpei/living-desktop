import Foundation
import MyPetCore

/// Deterministic, data-only body authority shared by every gameplay ruleset.
public final class BodyWorld {
    public static let framesPerSecond = 60
    public static let gravityPerFrame = 1600.0 / 3600.0

    public private(set) var frame: Int64 = 0
    private var definitions: [String: BodyDefinition] = [:]
    private var bodies: [String: BodyState] = [:]
    private var dragLast: [String: Vec2] = [:]

    public init() {}

    public init(checkpoint: BodyWorldCheckpoint) {
        frame = checkpoint.frame
        definitions = checkpoint.definitions
        bodies = checkpoint.bodies
        dragLast = checkpoint.dragLast
    }

    public func checkpoint() -> BodyWorldCheckpoint {
        BodyWorldCheckpoint(
            frame: frame,
            definitions: definitions,
            bodies: bodies,
            dragLast: dragLast)
    }

    public func register(_ definition: BodyDefinition, state: BodyState) {
        precondition(definition.entityID == state.entityID)
        definitions[definition.entityID.raw] = definition
        bodies[state.entityID.raw] = state
    }

    public func unregister(_ entityID: EntityID) {
        definitions[entityID.raw] = nil
        bodies[entityID.raw] = nil
        dragLast[entityID.raw] = nil
    }

    public func setDefinition(_ definition: BodyDefinition) {
        guard bodies[definition.entityID.raw] != nil else { return }
        definitions[definition.entityID.raw] = definition
    }

    public func state(for entityID: EntityID) -> BodyState? { bodies[entityID.raw] }
    public func definition(for entityID: EntityID) -> BodyDefinition? {
        definitions[entityID.raw]
    }

    public func update(_ entityID: EntityID, _ mutation: (inout BodyState) -> Void) {
        guard var state = bodies[entityID.raw] else { return }
        mutation(&state)
        bodies[entityID.raw] = state
    }

    public func snapshot() -> BodyWorldSnapshot {
        BodyWorldSnapshot(frame: frame, bodies: Array(bodies.values))
    }

    @discardableResult
    public func advance(_ environment: BodyEnvironment) -> BodyFrameResult {
        var contacts: [Contact] = []
        for id in bodies.keys.sorted() {
            guard var body = bodies[id], let definition = definitions[id] else { continue }
            syncAttachedSurface(&body, environment: environment, definition: definition)
            if definition.simulationEnabled {
                integrate(&body, definition: definition, environment: environment, contacts: &contacts)
            }
            bodies[id] = body
        }
        resolvePushboxes(environment: environment)
        let result = BodyFrameResult(frame: frame, contacts: contacts)
        frame += 1
        return result
    }

    public func beginDrag(entityID: EntityID, position: Vec2) {
        update(entityID) { body in
            body.locomotion = .dragged
            body.currentSurfaceID = nil
            body.surfaceFraction = nil
            body.velocity = Vec2()
            body.position = position
        }
        dragLast[entityID.raw] = position
    }

    public func drag(entityID: EntityID, position: Vec2, elapsedSeconds: Double) {
        guard var body = bodies[entityID.raw], body.locomotion == .dragged else { return }
        let previous = dragLast[entityID.raw] ?? body.position
        let dt = max(1.0 / 240.0, elapsedSeconds)
        let sampleVX = (position.x - previous.x) / dt / 60.0
        let sampleVY = (position.y - previous.y) / dt / 60.0
        body.velocity.x += (sampleVX - body.velocity.x) * 0.35
        body.velocity.y += (sampleVY - body.velocity.y) * 0.35
        body.position = position
        dragLast[entityID.raw] = position
        bodies[entityID.raw] = body
    }

    public func endDrag(entityID: EntityID, wasClick: Bool) {
        guard var body = bodies[entityID.raw], body.locomotion == .dragged else { return }
        dragLast[entityID.raw] = nil
        if wasClick {
            body.locomotion = .airborne
            body.velocity.y = min(body.velocity.y, -4)
        } else {
            body.locomotion = .tossed
            body.velocity.x = min(43, max(-43, body.velocity.x))
            body.velocity.y = min(43, max(-43, body.velocity.y))
        }
        bodies[entityID.raw] = body
    }

    private func syncAttachedSurface(
        _ body: inout BodyState,
        environment: BodyEnvironment,
        definition: BodyDefinition
    ) {
        guard body.locomotion == .grounded, let id = body.currentSurfaceID else { return }
        guard let surface = environment.surface(id: id) else {
            body.currentSurfaceID = nil
            body.surfaceFraction = nil
            body.locomotion = .airborne
            return
        }
        body.position.y = surface.y
        if surface.kind != .floor, let fraction = body.surfaceFraction {
            let margin = supportMargin(for: definition)
            let usable = max(1, surface.right - surface.left - margin * 2)
            body.position.x = surface.left + margin + min(1, max(0, fraction)) * usable
        }
    }

    private func integrate(
        _ body: inout BodyState,
        definition: BodyDefinition,
        environment: BodyEnvironment,
        contacts: inout [Contact]
    ) {
        guard body.locomotion != .dragged && body.locomotion != .sleeping else { return }
        let previousY = body.position.y

        if body.locomotion == .grounded && body.currentSurfaceID == nil {
            if let support = environment.surfaces.first(where: {
                $0.contains(x: body.position.x) && abs($0.y - body.position.y) <= 2
            }) {
                attach(&body, to: support, definition: definition)
            } else {
                body.locomotion = .airborne
            }
        }

        if body.locomotion == .grounded {
            body.position.x += body.velocity.x
            if let surface = environment.surface(id: body.currentSurfaceID) {
                let margin = supportMargin(for: definition)
                if !surface.contains(x: body.position.x, margin: margin) {
                    body.currentSurfaceID = nil
                    body.surfaceFraction = nil
                    body.locomotion = .airborne
                    body.position.y += 0.01
                } else if surface.right - surface.left > margin * 2 {
                    body.surfaceFraction = (body.position.x - surface.left - margin) /
                        max(1, surface.right - surface.left - margin * 2)
                }
            }
        }

        if body.locomotion == .airborne || body.locomotion == .tossed {
            body.velocity.y += Self.gravityPerFrame
            body.position.x += body.velocity.x
            body.position.y += body.velocity.y
            if body.velocity.y >= 0,
               let landing = environment.landingSurface(
                    x: body.position.x, previousFeetY: previousY, nextFeetY: body.position.y) {
                let wasTossed = body.locomotion == .tossed
                let impactVelocityY = body.velocity.y
                attach(&body, to: landing, definition: definition)
                contacts.append(Contact(entityID: body.entityID, surfaceID: landing.id))
                if wasTossed && abs(impactVelocityY) > 4.5 {
                    body.locomotion = .tossed
                    body.velocity.y = -abs(impactVelocityY) * 0.28
                    body.velocity.x *= 0.72
                } else {
                    body.locomotion = .grounded
                    body.velocity.y = 0
                    body.velocity.x *= body.landingHorizontalVelocityRetention
                }
            }
        }

        if body.velocity.y >= 0,
           body.position.y >= environment.bounds.maxY,
           body.locomotion != .grounded,
           let floor = environment.surfaces.filter({ $0.kind == .floor }).min(by: {
               Self.distanceToSpan(body.position.x, $0.left, $0.right) <
                   Self.distanceToSpan(body.position.x, $1.left, $1.right)
           }) {
            let margin = supportMargin(for: definition)
            body.position.x = min(floor.right - margin, max(floor.left + margin, body.position.x))
            attach(&body, to: floor, definition: definition)
            body.surfaceFraction = nil
            body.velocity = Vec2()
            contacts.append(Contact(entityID: body.entityID, surfaceID: floor.id))
        }

        body.position.x = min(environment.bounds.maxX, max(environment.bounds.minX, body.position.x))
        body.position.y = min(environment.bounds.maxY, max(environment.bounds.minY, body.position.y))
    }

    private func attach(_ body: inout BodyState, to surface: Surface, definition: BodyDefinition) {
        body.position.y = surface.y
        body.currentSurfaceID = surface.id
        body.locomotion = .grounded
        let margin = supportMargin(for: definition)
        let usable = max(1, surface.right - surface.left - margin * 2)
        body.surfaceFraction = min(1, max(0,
            (body.position.x - surface.left - margin) / usable))
    }

    private func resolvePushboxes(environment: BodyEnvironment) {
        let ids = bodies.keys.sorted()
        guard ids.count > 1 else { return }
        for i in 0..<(ids.count - 1) {
            for j in (i + 1)..<ids.count {
                guard var a = bodies[ids[i]], var b = bodies[ids[j]],
                      let ad = definitions[ids[i]], let bd = definitions[ids[j]],
                      ad.pushEnabled, bd.pushEnabled,
                      ad.simulationEnabled, bd.simulationEnabled,
                      ad.collisionMask.contains(.body), bd.collisionMask.contains(.body),
                      a.locomotion == .grounded, b.locomotion == .grounded,
                      abs(a.position.y - b.position.y) < 8 else { continue }
                let overlap = ad.pushRadius + bd.pushRadius - abs(b.position.x - a.position.x)
                guard overlap > 0 else { continue }
                let sign = b.position.x - a.position.x >= 0 ? 1.0 : -1.0
                a.position.x -= sign * overlap * 0.5
                b.position.x += sign * overlap * 0.5
                refreshSurfaceFraction(&a, definition: ad, environment: environment)
                refreshSurfaceFraction(&b, definition: bd, environment: environment)
                bodies[ids[i]] = a
                bodies[ids[j]] = b
            }
        }
    }

    private func refreshSurfaceFraction(
        _ body: inout BodyState,
        definition: BodyDefinition,
        environment: BodyEnvironment
    ) {
        guard body.locomotion == .grounded,
              let surface = environment.surface(id: body.currentSurfaceID),
              surface.kind != .floor else {
            if let id = body.currentSurfaceID, environment.surface(id: id)?.kind == .floor {
                body.surfaceFraction = nil
            }
            return
        }
        let margin = supportMargin(for: definition)
        let usable = max(1, surface.right - surface.left - margin * 2)
        body.surfaceFraction = min(1, max(0,
            (body.position.x - surface.left - margin) / usable))
    }

    private func supportMargin(for definition: BodyDefinition) -> Double {
        definition.pushRadius * 0.6
    }

    private static func distanceToSpan(_ x: Double, _ left: Double, _ right: Double) -> Double {
        if x < left { return left - x }
        if x > right { return x - right }
        return 0
    }
}
