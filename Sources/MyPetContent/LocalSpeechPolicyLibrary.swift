import Foundation
import MyPetCore

public enum LocalSpeechPolicyLibrary {
    public static func load(resourcesRoot: URL) throws -> LocalSpeechPolicy {
        let url = resourcesRoot.appendingPathComponent("brain/local-speech.json")
        let policy = try JSONDecoder().decode(LocalSpeechPolicy.self, from: Data(contentsOf: url))
        guard policy.configurationErrors.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return policy
    }

    public static func loadAvailable(roots: [URL] = ContentResourceLocator.roots()) -> LocalSpeechPolicy? {
        roots.lazy.compactMap { try? load(resourcesRoot: $0) }.first
    }
}
