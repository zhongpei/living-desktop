import Foundation
import MyPetCombat

public struct PetPackCombatFile: Codable, Equatable, Sendable {
    public var version: Int
    public var profile: CombatProfile

    public init(version: Int = 1, profile: CombatProfile) {
        self.version = version
        self.profile = profile
    }
}

public enum CombatProfileLoader {
    public static func load(from packURL: URL?) -> CombatProfile? {
        guard let packURL else { return nil }
        let url = packURL.appendingPathComponent("combat.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PetPackCombatFile.self, from: data),
              file.version == 1 else { return nil }
        return file.profile
    }
}
