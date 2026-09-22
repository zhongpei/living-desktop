import Foundation

/// The filesystem is the catalog. This module does not own the active game
/// session; callers must retire an active package before removing its files.
public final class ContentRegistry {
    public enum Source: Equatable, Sendable { case builtIn, user }
    public enum Status: Equatable, Sendable { case enabled, disabled, corrupt }

    public struct Record: Sendable {
        public let manifest: ContentPackageManifest?
        public let source: Source
        public let status: Status
        public let url: URL
        public let reason: String?
    }

    public enum RegistryError: Error, Equatable {
        case duplicateOrOlder
        case updateNeedsConfirmation
        case unavailable
    }

    private let builtInDirectory: URL
    private let packageDirectory: URL
    private let cacheDirectory: URL
    private let stateURL: URL
    private var disabled: Set<String>
    private var records: [Record] = []
    private let fm = FileManager.default

    public init(builtInDirectory: URL, appSupportDirectory: URL) throws {
        self.builtInDirectory = builtInDirectory
        packageDirectory = appSupportDirectory.appendingPathComponent("packages", isDirectory: true)
        cacheDirectory = appSupportDirectory.appendingPathComponent("cache", isDirectory: true)
        stateURL = appSupportDirectory.appendingPathComponent("disabled-packages.json")
        try fm.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: stateURL.path) {
            disabled = Set(try JSONDecoder().decode([String].self,
                from: Data(contentsOf: stateURL)))
        } else {
            disabled = []
        }
        refresh()
    }

    public func list() -> [Record] { records }

    public func refresh() {
        var candidates: [String: Record] = [:]
        var broken: [Record] = []
        for (source, directory) in [(Source.builtIn, builtInDirectory), (.user, packageDirectory)] {
            let URLs = ((try? fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "mypetpack" }
            for url in URLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let manifest = try ContentPackageReader.inspect(at: url)
                    let key = Self.key(manifest.kind, manifest.id)
                    let status: Status = disabled.contains(key) ? .disabled : .enabled
                    let record = Record(manifest: manifest, source: source, status: status,
                                        url: url, reason: nil)
                    if let previous = candidates[key], let old = previous.manifest {
                        if source == .user && previous.source == .builtIn &&
                            manifest.revision > old.revision ||
                            source == previous.source && manifest.revision > old.revision {
                            candidates[key] = record
                        }
                    } else {
                        candidates[key] = record
                    }
                } catch {
                    broken.append(Record(manifest: nil, source: source, status: .corrupt,
                                         url: url, reason: String(describing: error)))
                }
            }
        }
        records = candidates.values.sorted {
            Self.key($0.manifest!.kind, $0.manifest!.id) <
                Self.key($1.manifest!.kind, $1.manifest!.id)
        } + broken.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    @discardableResult
    public func importPackage(at sourceURL: URL, confirmUpdate: Bool = false) throws -> ContentPackageManifest {
        let candidate = try ContentPackageReader.inspect(at: sourceURL)
        let existing = records.first { $0.manifest?.kind == candidate.kind && $0.manifest?.id == candidate.id }
        if let existing = existing?.manifest {
            guard candidate.revision > existing.revision else { throw RegistryError.duplicateOrOlder }
            guard confirmUpdate else { throw RegistryError.updateNeedsConfirmation }
        }
        let target = packageDirectory.appendingPathComponent(
            "\(candidate.kind.rawValue)-\(candidate.id)-r\(candidate.revision).mypetpack")
        guard !fm.fileExists(atPath: target.path) else { throw RegistryError.duplicateOrOlder }
        let staged = packageDirectory.appendingPathComponent(".pending-\(UUID().uuidString).mypetpack")
        do {
            try fm.copyItem(at: sourceURL, to: staged)
            guard try ContentPackageReader.inspect(at: staged) == candidate else {
                throw ContentPackageError.invalidArchive("package changed while staging")
            }
            try fm.moveItem(at: staged, to: target)
            refresh()
            return candidate
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    public func setEnabled(_ enabled: Bool, kind: ContentPackageKind, id: String) throws {
        let key = Self.key(kind, id)
        guard records.contains(where: { $0.manifest?.kind == kind && $0.manifest?.id == id }) else {
            throw RegistryError.unavailable
        }
        var next = disabled
        if enabled { next.remove(key) } else { next.insert(key) }
        let data = try JSONEncoder().encode(next.sorted())
        try data.write(to: stateURL, options: .atomic)
        disabled = next
        refresh()
    }

    public func resolve(kind: ContentPackageKind, id: String) throws -> URL {
        guard let record = records.first(where: { $0.manifest?.kind == kind && $0.manifest?.id == id }),
              let manifest = record.manifest, record.status == .enabled else {
            throw RegistryError.unavailable
        }
        let cache = cacheDirectory.appendingPathComponent(
            "\(kind.rawValue)-\(id)-r\(manifest.revision)-\(record.source == .user ? "user" : "builtin")")
        if fm.fileExists(atPath: cache.path) {
            if (try? ContentPackageReader.validateExtracted(at: cache, matching: manifest)) != nil {
                return cache
            }
            try fm.removeItem(at: cache)
        }
        let extracted = try ContentPackageReader.extract(at: record.url, to: cache)
        guard extracted == manifest else {
            try? fm.removeItem(at: cache)
            throw ContentPackageError.invalidArchive("package changed after catalog refresh")
        }
        return cache
    }

    /// Logically retire all user revisions before the App's session barrier.
    /// Physical deletion must wait until the active session has released them.
    @discardableResult
    public func removeUserPackage(kind: ContentPackageKind, id: String) throws -> URL {
        let matching = ((try? fm.contentsOfDirectory(at: packageDirectory,
            includingPropertiesForKeys: nil)) ?? []).filter { url in
                guard url.pathExtension == "mypetpack",
                      let manifest = try? ContentPackageReader.inspect(at: url) else { return false }
                return manifest.kind == kind && manifest.id == id
            }
        guard !matching.isEmpty else { throw RegistryError.unavailable }
        let retired = packageDirectory.appendingPathComponent(".retired-\(UUID().uuidString)")
        try fm.createDirectory(at: retired, withIntermediateDirectories: false)
        var moved: [URL] = []
        do {
            for url in matching {
                try fm.moveItem(at: url, to: retired.appendingPathComponent(url.lastPathComponent))
                moved.append(url)
            }
        } catch {
            for url in moved.reversed() {
                try? fm.moveItem(at: retired.appendingPathComponent(url.lastPathComponent), to: url)
            }
            try? fm.removeItem(at: retired)
            throw error
        }
        refresh()
        return retired
    }

    /// A broken user archive has no trustworthy kind/ID, so retire only the
    /// exact file already observed in this registry projection.
    @discardableResult
    public func removeCorruptUserPackage(at url: URL) throws -> URL {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path ==
                packageDirectory.resolvingSymlinksInPath().path,
              records.contains(where: {
                  $0.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path &&
                      $0.source == .user && $0.status == .corrupt
              }) else {
            throw RegistryError.unavailable
        }
        let retired = packageDirectory.appendingPathComponent(".retired-\(UUID().uuidString)")
        try fm.createDirectory(at: retired, withIntermediateDirectories: false)
        do {
            try fm.moveItem(at: url, to: retired.appendingPathComponent(url.lastPathComponent))
        } catch {
            try? fm.removeItem(at: retired)
            throw error
        }
        refresh()
        return retired
    }

    public func finalizeRemoval(at retiredDirectory: URL) throws {
        guard retiredDirectory.deletingLastPathComponent() == packageDirectory,
              retiredDirectory.lastPathComponent.hasPrefix(".retired-") else {
            throw RegistryError.unavailable
        }
        try fm.removeItem(at: retiredDirectory)
    }

    /// Cache files are disposable only after the caller retires all sessions
    /// that can still hold image or audio references into this package.
    public func purgeCache(kind: ContentPackageKind, id: String, source: Source? = nil) throws {
        let prefix = "\(kind.rawValue)-\(id)-r"
        let URLs = try fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for url in URLs where url.lastPathComponent.hasPrefix(prefix) &&
            (source == nil || url.lastPathComponent.hasSuffix(source == .user ? "-user" : "-builtin")) {
            try fm.removeItem(at: url)
        }
    }

    private static func key(_ kind: ContentPackageKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }
}
