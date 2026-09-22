import Foundation

/// Authored narrative content for one cast group. The group remains playable
/// without this data; execution stays in the existing StoryDirector.
public struct StoryPack: Codable, Equatable, Sendable {
    public var id: String
    public var groupID: String
    public var episodes: [StoryEpisode]

    public init(id: String, groupID: String, episodes: [StoryEpisode]) {
        self.id = id
        self.groupID = groupID
        self.episodes = episodes
    }

    /// Runtime identity is package-scoped; authored IDs remain unchanged on
    /// disk. Internal completion/interruption prerequisites follow the same
    /// namespace, while unrelated world facts retain their original meaning.
    public var runtimeEpisodes: [StoryEpisode] {
        let localIDs = Set(episodes.map(\.id))
        func namespace(_ facts: [StoryPrerequisite]) -> [StoryPrerequisite] {
            facts.map { prerequisite in
                var result = prerequisite
                if let fact = result.requiredFact, fact.hasPrefix("episode/") {
                    let pieces = fact.split(separator: "/", omittingEmptySubsequences: false)
                    if pieces.count == 3, localIDs.contains(String(pieces[1])),
                       pieces[2] == "completed" || pieces[2] == "interrupted" {
                        result.requiredFact = "episode/\(id)::\(pieces[1])/\(pieces[2])"
                    }
                }
                return result
            }
        }
        return episodes.map { original in
            var episode = original
            episode.id = "\(id)::\(original.id)"
            episode.prerequisites = namespace(original.prerequisites)
            episode.branches = original.branches.map { branch in
                var result = branch
                result.prerequisites = namespace(branch.prerequisites)
                return result
            }
            return episode
        }
    }
}
