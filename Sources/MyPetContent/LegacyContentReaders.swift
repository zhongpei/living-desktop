import Foundation
import MyPetCore

/// Read-only JSON compatibility for old loose-resource fixtures and Harness
/// inputs. New production sessions use ContentRegistry packages instead.
public enum CastPackLibrary {
    public static func files(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func loadJSON(at url: URL) throws -> CastPack {
        try JSONDecoder().decode(CastPack.self, from: Data(contentsOf: url))
    }

    public static func loadDirectory(_ directory: URL) throws -> [CastPack] {
        try files(in: directory).map(loadJSON(at:))
    }

    public static func roots(
        bundle: Bundle = .main,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var result: [URL] = []
        if let override = environment["MYPET_CASTPACKS"] {
            result.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        result += ContentResourceLocator.roots(bundle: bundle,
            executablePath: executablePath, environment: environment)
            .map { $0.appendingPathComponent("castpacks", isDirectory: true) }
        var seen = Set<String>()
        return result.filter {
            FileManager.default.fileExists(atPath: $0.path) &&
                seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    public static func loadAvailable(
        bundle: Bundle = .main,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [CastPack] {
        var seen = Set<String>()
        return roots(bundle: bundle, executablePath: executablePath, environment: environment)
            .flatMap { (try? loadDirectory($0)) ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }
}

public enum CastContentLibrary {
    public static func load(resourcesRoot: URL) throws -> CastContentCatalog {
        let decoder = JSONDecoder()
        let characters = try decoder.decode(CharacterCatalog.self,
            from: Data(contentsOf: resourcesRoot.appendingPathComponent("characters/catalog.json"))).characters
        let relationshipKinds = try decoder.decode(RelationshipKindCatalog.self,
            from: Data(contentsOf: resourcesRoot.appendingPathComponent("relationships/catalog.json")))
        let groups = try CastPackLibrary.files(in: resourcesRoot.appendingPathComponent("castgroups"))
            .map { try decoder.decode(CharacterGroup.self, from: Data(contentsOf: $0)) }
        let categoryURL = resourcesRoot.appendingPathComponent("categories/catalog.json")
        let categories = FileManager.default.fileExists(atPath: categoryURL.path)
            ? try decoder.decode(CharacterCategoryCatalog.self,
                from: Data(contentsOf: categoryURL)).categories : []
        return CastContentCatalog(categories: categories, characters: characters,
                                  groups: groups, relationshipKinds: relationshipKinds)
    }

    public static func roots(
        bundle: Bundle = .main,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        ContentResourceLocator.roots(bundle: bundle,
            executablePath: executablePath, environment: environment)
            .filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("characters/catalog.json").path) }
    }

    public static func loadAvailable(
        bundle: Bundle = .main,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CastContentCatalog? {
        roots(bundle: bundle, executablePath: executablePath, environment: environment)
            .lazy.compactMap { try? load(resourcesRoot: $0) }.first
    }
}

public enum StoryPackLibrary {
    public static func loadJSON(at url: URL) throws -> StoryPack {
        try JSONDecoder().decode(StoryPack.self, from: Data(contentsOf: url))
    }

    public static func loadDirectory(_ directory: URL) throws -> [StoryPack] {
        try CastPackLibrary.files(in: directory).map(loadJSON(at:))
    }

    public static func loadAvailable(
        bundle: Bundle = .main,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [StoryPack] {
        var seen = Set<String>()
        return CastPackLibrary.roots(bundle: bundle,
            executablePath: executablePath, environment: environment)
            .map { $0.deletingLastPathComponent().appendingPathComponent("stories", isDirectory: true) }
            .flatMap { (try? loadDirectory($0)) ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }
    }
}

public enum GameplayCatalogLibrary {
    public static func load(resourcesRoot: URL) throws -> GameplayCatalog {
        struct GroupFile: Decodable { let groups: [GameplayGroup] }
        let decoder = JSONDecoder()
        let root = resourcesRoot.appendingPathComponent("gameplay", isDirectory: true)
        let groups = try decoder.decode(GroupFile.self,
            from: Data(contentsOf: root.appendingPathComponent("catalog.json"))).groups
        let plugins = try CastPackLibrary.files(in: root.appendingPathComponent("plugins"))
            .map { try decoder.decode(GameplayPlugin.self, from: Data(contentsOf: $0)) }
        return GameplayCatalog(groups: groups, plugins: plugins)
    }

    public static func roots(
        bundle: Bundle = .main,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        ContentResourceLocator.roots(bundle: bundle,
            executablePath: executablePath, environment: environment)
            .filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("gameplay/catalog.json").path) }
    }

    public static func loadAvailable() -> GameplayCatalog? {
        ContentResourceLocator.gameplayCatalog()
    }
}
