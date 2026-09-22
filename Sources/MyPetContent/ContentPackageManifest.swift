import Foundation

public enum ContentPackageKind: String, Codable, Sendable {
    case role
    case group
    case story
}

public struct ContentPackageFile: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

/// package.json at the root of a .mypetpack ZIP. Hashes prove integrity of
/// bytes inside the archive, not author identity or trustworthiness.
public struct ContentPackageManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var kind: ContentPackageKind
    public var id: String
    public var revision: Int
    public var name: String
    public var content: String
    public var targetGroupID: String?
    public var files: [ContentPackageFile]

    public init(formatVersion: Int, kind: ContentPackageKind, id: String,
                revision: Int, name: String, content: String,
                targetGroupID: String? = nil, files: [ContentPackageFile]) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.id = id
        self.revision = revision
        self.name = name
        self.content = content
        self.targetGroupID = targetGroupID
        self.files = files
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw ContentPackageError.invalidManifest("unsupported format") }
        guard Self.validID(id), revision > 0 else {
            throw ContentPackageError.invalidManifest("invalid package ID or revision")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 160 else {
            throw ContentPackageError.invalidManifest("invalid display name")
        }
        guard Self.validPath(content), content.hasPrefix("content/"), content.hasSuffix(".json") else {
            throw ContentPackageError.invalidManifest("invalid primary content path")
        }
        let requiredContent: String
        switch kind {
        case .role: requiredContent = "content/role.json"
        case .group: requiredContent = "content/group.json"
        case .story: requiredContent = "content/story.json"
        }
        guard content == requiredContent else {
            throw ContentPackageError.invalidManifest("wrong primary content for \(kind.rawValue)")
        }
        switch kind {
        case .story:
            guard let targetGroupID, Self.validID(targetGroupID) else {
                throw ContentPackageError.invalidManifest("story target group is required")
            }
        case .role, .group:
            guard targetGroupID == nil else {
                throw ContentPackageError.invalidManifest("only a story has a target group")
            }
        }
        guard !files.isEmpty, files.count <= 20_000 else {
            throw ContentPackageError.invalidManifest("invalid file count")
        }
        var seen = Set<String>()
        for file in files {
            guard Self.validPath(file.path), file.path != "package.json" else {
                throw ContentPackageError.invalidManifest("unsafe file path \(file.path)")
            }
            guard seen.insert(file.path.lowercased()).inserted else {
                throw ContentPackageError.invalidManifest("duplicate file path \(file.path)")
            }
            guard file.sha256.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ContentPackageError.invalidManifest("invalid SHA-256 for \(file.path)")
            }
            let suffix = URL(fileURLWithPath: file.path).pathExtension.lowercased()
            guard ["json", "webp", "png", "mp3"].contains(suffix) else {
                throw ContentPackageError.invalidManifest("unsupported content type: \(file.path)")
            }
            if suffix == "mp3" {
                let parts = file.path.split(separator: "/")
                guard kind != .story, parts.count == 5,
                      parts[0] == "petpack", parts[2] == "actions",
                      parts[4] == "voice.mp3" else {
                    throw ContentPackageError.invalidManifest("audio must belong to one action clip")
                }
            }
            switch kind {
            case .story:
                guard file.path == content else {
                    throw ContentPackageError.invalidManifest("story package cannot carry roles or assets")
                }
            case .role, .group:
                guard file.path == content || file.path.hasPrefix("petpack/") ||
                        (kind == .group && file.path.hasPrefix("props/")) else {
                    throw ContentPackageError.invalidManifest("unexpected content path: \(file.path)")
                }
            }
        }
        guard seen.contains(content.lowercased()) else {
            throw ContentPackageError.invalidManifest("primary content is not declared")
        }
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }

    /// ASCII-only archive paths avoid Unicode/case normalization ambiguity on
    /// default macOS volumes. No absolute, hidden, empty or traversal segments.
    public static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\\"), !path.contains(":") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            guard !segment.isEmpty, segment != ".", segment != "..", !segment.hasPrefix(".") else {
                return false
            }
            return segment.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
            }
        }
    }
}

public enum ContentPackageError: Error, Equatable {
    case invalidManifest(String)
    case invalidArchive(String)
    case invalidContent(String)
}
