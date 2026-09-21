import MyPetCore

/// AppKit presentation boundary. Render consumes immutable Core values and
/// never receives a mutable runtime or world reference.
@MainActor
public protocol PresentationRenderer: AnyObject {
    func apply(snapshot: PresentationSnapshot)
    func consume(_ effects: [PresentationEffect])
    func close(entityID: String)
}
