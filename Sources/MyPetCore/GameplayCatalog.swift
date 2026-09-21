import Foundation

public enum GameplayImplementationID: String, Codable, CaseIterable, Sendable {
    case speech
    case scenes
    case props
    case perching
    case foregroundFollow = "foreground-follow"
    case windowPull = "window-pull"
}

public struct GameplayGroup: Codable, Equatable, Sendable {
    public var id: String
    public var displayNames: LocalizedLabel
    public var order: Int

    public init(id: String, displayNames: LocalizedLabel, order: Int) {
        self.id = id
        self.displayNames = displayNames
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayNames = "displayName", order
    }
}

public struct GameplayPlugin: Codable, Equatable, Sendable {
    public var id: String
    public var groupID: String
    public var displayNames: LocalizedLabel
    public var order: Int
    public var implementationID: String
    public var sceneIDs: [String]
    public var actionFamilies: [String]
    public var propIDs: [String]
    public var inputSources: [String]
    public var enabledByDefault: Bool
    public var surfaces: [String]
    public var fallback: String

    public init(
        id: String, groupID: String, displayNames: LocalizedLabel, order: Int,
        implementationID: String, sceneIDs: [String] = [], actionFamilies: [String] = [],
        propIDs: [String] = [], inputSources: [String] = [], enabledByDefault: Bool = true,
        surfaces: [String] = ["tray", "settings"], fallback: String = "disable"
    ) {
        self.id = id
        self.groupID = groupID
        self.displayNames = displayNames
        self.order = order
        self.implementationID = implementationID
        self.sceneIDs = sceneIDs
        self.actionFamilies = actionFamilies
        self.propIDs = propIDs
        self.inputSources = inputSources
        self.enabledByDefault = enabledByDefault
        self.surfaces = surfaces
        self.fallback = fallback
    }

    private enum CodingKeys: String, CodingKey {
        case id, groupID, displayNames = "displayName", order, implementationID
        case sceneIDs, actionFamilies, propIDs, inputSources, enabledByDefault, surfaces, fallback
    }
}

public struct GameplayCatalog: Codable, Equatable, Sendable {
    public var groups: [GameplayGroup]
    public var plugins: [GameplayPlugin]

    public init(groups: [GameplayGroup], plugins: [GameplayPlugin]) {
        self.groups = groups.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        self.plugins = plugins.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    public var configurationErrors: [String] {
        let groupIDs = Set(groups.map(\.id))
        var errors: [String] = []
        for plugin in plugins {
            if !groupIDs.contains(plugin.groupID) {
                errors.append("gameplay plugin \(plugin.id) references unknown group \(plugin.groupID)")
            }
            if GameplayImplementationID(rawValue: plugin.implementationID) == nil {
                errors.append("gameplay plugin \(plugin.id) uses unknown implementation \(plugin.implementationID)")
            }
        }
        return errors.sorted()
    }
}

public enum GameplayCatalogLibrary {
    private struct GroupFile: Codable { var groups: [GameplayGroup] }

    public static func load(resourcesRoot: URL) throws -> GameplayCatalog {
        let decoder = JSONDecoder()
        let gameplayRoot = resourcesRoot.appendingPathComponent("gameplay", isDirectory: true)
        let groups = try decoder.decode(
            GroupFile.self,
            from: Data(contentsOf: gameplayRoot.appendingPathComponent("catalog.json"))).groups
        let plugins = try CastPackLibrary.files(
            in: gameplayRoot.appendingPathComponent("plugins", isDirectory: true))
            .map { try decoder.decode(GameplayPlugin.self, from: Data(contentsOf: $0)) }
        return GameplayCatalog(groups: groups, plugins: plugins)
    }

    public static func roots(
        bundle: Bundle = .main,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var roots: [URL] = []
        if let raw = environment["MYPET_RESOURCES"] {
            roots.append(URL(fileURLWithPath: raw, isDirectory: true))
        }
        if let resourceURL = bundle.resourceURL { roots.append(resourceURL) }
        var directory = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            roots.append(directory.appendingPathComponent("Resources", isDirectory: true))
            directory = directory.deletingLastPathComponent()
        }
        var seen = Set<String>()
        return roots.filter {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("gameplay/catalog.json").path) &&
                seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    public static func loadAvailable() -> GameplayCatalog? {
        roots().lazy.compactMap { try? load(resourcesRoot: $0) }
            .first { $0.configurationErrors.isEmpty }
    }
}
