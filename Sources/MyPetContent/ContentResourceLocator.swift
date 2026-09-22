import Foundation
import MyPetCore

/// Locates read-only application resources. Content owns disk discovery;
/// Core's gameplay values remain independent of the bundle layout.
public enum ContentResourceLocator {
    public static func roots(
        bundle: Bundle = .main,
        executablePath: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var candidates: [URL] = []
        if let override = environment["MYPET_RESOURCES"] {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resourceURL = bundle.resourceURL { candidates.append(resourceURL) }
        var directory = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent("Resources", isDirectory: true))
            directory = directory.deletingLastPathComponent()
        }
        var seen = Set<String>()
        return candidates.filter { url in
            let root = url.standardizedFileURL
            let fm = FileManager.default
            let isResourceRoot = fm.fileExists(atPath: root.appendingPathComponent("characters/catalog.json").path)
                || fm.fileExists(atPath: root.appendingPathComponent("packages").path)
                || fm.fileExists(atPath: root.appendingPathComponent("gameplay/catalog.json").path)
            return isResourceRoot && seen.insert(root.path).inserted
        }
    }

    public static func gameplayCatalog(roots: [URL] = roots()) -> GameplayCatalog? {
        struct GroupFile: Decodable { let groups: [GameplayGroup] }
        let decoder = JSONDecoder()
        for root in roots {
            let gameplay = root.appendingPathComponent("gameplay", isDirectory: true)
            do {
                let groupFile = try decoder.decode(GroupFile.self,
                    from: Data(contentsOf: gameplay.appendingPathComponent("catalog.json")))
                let pluginDirectory = gameplay.appendingPathComponent("plugins", isDirectory: true)
                let URLs = try FileManager.default.contentsOfDirectory(at: pluginDirectory,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let plugins = try URLs.map {
                    try decoder.decode(GameplayPlugin.self, from: Data(contentsOf: $0))
                }
                let catalog = GameplayCatalog(groups: groupFile.groups, plugins: plugins)
                if catalog.configurationErrors.isEmpty { return catalog }
            } catch { continue }
        }
        return nil
    }
}
