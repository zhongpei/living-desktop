import Foundation
import MyPetCore

public struct PackagedRole {
    public let id: String
    public let visualURL: URL
    public let definition: CharacterDefinition
}

/// Immutable snapshot assembled from one registry projection. A session may
/// retain it until the App performs a safe switch; the registry never mutates
/// an already-running world.
public struct PackagedContentCatalog {
    public let roles: [PackagedRole]
    public let groups: [ResolvedCastPack]
    public let stories: [StoryPack]
    public let visualsByActor: [String: URL]
    public let diagnostics: [String]
}

public enum ContentCatalogLoader {
    public static func load(registry: ContentRegistry,
                            relationshipCatalogURL: URL) -> PackagedContentCatalog {
        let decoder = JSONDecoder()
        var roles: [PackagedRole] = []
        var groups: [ResolvedCastPack] = []
        var storyCandidates: [StoryPack] = []
        var visualsByActor: [String: URL] = [:]
        var diagnostics: [String] = []
        let kinds: RelationshipKindCatalog
        do {
            kinds = try decoder.decode(RelationshipKindCatalog.self,
                from: Data(contentsOf: relationshipCatalogURL))
        } catch {
            kinds = RelationshipKindCatalog(kinds: [])
            diagnostics.append("relationship catalog: \(error)")
        }

        for record in registry.list() where record.status == .enabled {
            guard let manifest = record.manifest else { continue }
            do {
                let root = try registry.resolve(kind: manifest.kind, id: manifest.id)
                let content = try Data(contentsOf: root.appendingPathComponent(manifest.content))
                switch manifest.kind {
                case .role:
                    let role = try decoder.decode(CharacterDefinition.self, from: content)
                    roles.append(PackagedRole(id: manifest.id,
                        visualURL: root.appendingPathComponent("petpack/\(manifest.id)"),
                        definition: role))
                case .group:
                    let payload = try decoder.decode(GroupPackagePayload.self, from: content)
                    let catalog = CastContentCatalog(characters: payload.characters,
                        groups: [payload.group], relationshipKinds: kinds)
                    let resolved = try catalog.resolve([payload.cast])[0]
                    var groupVisuals: [String: URL] = [:]
                    for member in resolved.pack.members {
                        guard let visualID = member.visualPackID else { continue }
                        guard visualsByActor[member.id] == nil,
                              groupVisuals[member.id] == nil else {
                            throw ContentPackageError.invalidContent(
                                "duplicate actor ID across enabled groups: \(member.id)")
                        }
                        groupVisuals[member.id] = root.appendingPathComponent("petpack/\(visualID)")
                    }
                    visualsByActor.merge(groupVisuals) { first, _ in first }
                    groups.append(resolved)
                case .story:
                    storyCandidates.append(try decoder.decode(StoryPack.self, from: content))
                }
            } catch {
                diagnostics.append("\(manifest.kind.rawValue)/\(manifest.id): \(error)")
            }
        }

        let checker = CastContentCatalog(characters: [], groups: [], relationshipKinds: kinds)
        var stories: [StoryPack] = []
        for story in storyCandidates.sorted(by: { $0.id < $1.id }) {
            do {
                stories += try checker.resolveStories([story], for: groups)
            } catch {
                diagnostics.append("story/\(story.id): \(error)")
            }
        }
        return PackagedContentCatalog(
            roles: roles.sorted { $0.id < $1.id },
            groups: groups.sorted { $0.pack.id < $1.pack.id },
            stories: stories, visualsByActor: visualsByActor,
            diagnostics: diagnostics.sorted())
    }
}
