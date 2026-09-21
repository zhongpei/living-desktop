import MyPetCore

/// Read-only render inputs; Core has already decided which entities exist and where they belong.
public struct CastPropVisual {
    public let id: String
    public let visualID: String
    public let emoji: String
    public let frame: LayoutRect

    public init(id: String, visualID: String, emoji: String, frame: LayoutRect) {
        self.id = id
        self.visualID = visualID
        self.emoji = emoji
        self.frame = frame
    }
}

public struct CastMechVisual {
    public let id: String
    public let title: String
    public let frame: LayoutRect
    public let pilotName: String?

    public init(id: String, title: String, frame: LayoutRect, pilotName: String?) {
        self.id = id
        self.title = title
        self.frame = frame
        self.pilotName = pilotName
    }
}

/// Owns all non-actor Cast AppKit surfaces; disappearance is driven only by the next projection.
@MainActor
public final class CastOverlayPresentation {
    private let coordinateSpace: any RenderCoordinateSpace
    private var props: [String: CastPropOverlay] = [:]
    private var mechs: [String: CastMechOverlay] = [:]

    public init(coordinateSpace: (any RenderCoordinateSpace)? = nil) {
        self.coordinateSpace = coordinateSpace ?? AppKitRenderCoordinateSpace()
    }

    var visiblePropIDs: [String] { props.keys.sorted() }
    var visibleMechIDs: [String] { mechs.keys.sorted() }

    public func apply(props projectedProps: [CastPropVisual],
                      mechs projectedMechs: [CastMechVisual], now: Double) {
        let propIDs = Set(projectedProps.map(\.id))
        for id in props.keys.filter({ !propIDs.contains($0) }) {
            props.removeValue(forKey: id)?.close()
        }
        for visual in projectedProps {
            if props[visual.id] == nil {
                props[visual.id] = CastPropOverlay(visual: visual, coordinateSpace: coordinateSpace)
            }
            props[visual.id]?.update(frame: visual.frame, now: now)
        }

        let mechIDs = Set(projectedMechs.map(\.id))
        for id in mechs.keys.filter({ !mechIDs.contains($0) }) {
            mechs.removeValue(forKey: id)?.close()
        }
        for visual in projectedMechs {
            if mechs[visual.id] == nil {
                mechs[visual.id] = CastMechOverlay(visual: visual, coordinateSpace: coordinateSpace)
            }
            mechs[visual.id]?.update(frame: visual.frame, pilotName: visual.pilotName)
        }
    }

    public func beginHandoff(
        propID: String, from: LayoutRect, toActorFrame: LayoutRect,
        now: Double, durationTicks: Int64, stepMilliseconds: Int64
    ) {
        props[propID]?.beginHandoff(
            from: from, toActorFrame: toActorFrame, now: now,
            durationTicks: durationTicks, stepMilliseconds: stepMilliseconds)
    }

    public func close() {
        for overlay in props.values { overlay.close() }
        for overlay in mechs.values { overlay.close() }
        props.removeAll()
        mechs.removeAll()
    }
}
