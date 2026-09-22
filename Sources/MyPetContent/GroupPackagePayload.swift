import Foundation
import MyPetCore

/// A group package carries its own group definition and member profiles.
/// Stories are deliberately absent and arrive from independent StoryPacks.
public struct GroupPackagePayload: Codable, Equatable, Sendable {
    public var group: CharacterGroup
    public var cast: CastPack
    public var characters: [CharacterDefinition]

    public init(group: CharacterGroup, cast: CastPack,
                characters: [CharacterDefinition]) {
        self.group = group
        self.cast = cast
        self.characters = characters
    }
}
