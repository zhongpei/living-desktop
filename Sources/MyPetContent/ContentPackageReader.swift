import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import MyPetCore
import ZIPFoundation

/// Inspects untrusted ZIP bytes before any file is created. Extraction is only
/// allowed into a new, empty directory and repeats inspection to avoid using
/// a stale verdict after the source file has changed.
public enum ContentPackageReader {
    public static let maximumUncompressedBytes: UInt64 = 1_073_741_824
    public static let maximumEntries = 20_000
    public static let maximumJSONBytes: UInt64 = 16_777_216

    public static func inspect(at url: URL) throws -> ContentPackageManifest {
        guard url.pathExtension.lowercased() == "mypetpack" else {
            throw ContentPackageError.invalidArchive("expected .mypetpack")
        }
        let centralEntryCount = try validateCentralDirectoryTypes(at: url)
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [String: Entry] = [:]
        var seen = Set<String>()
        var total: UInt64 = 0
        for entry in archive {
            guard entries.count < maximumEntries else {
                throw ContentPackageError.invalidArchive("too many ZIP entries")
            }
            let isDirectory = entry.type == .directory
            let path = isDirectory && entry.path.hasSuffix("/")
                ? String(entry.path.dropLast()) : entry.path
            guard ContentPackageManifest.validPath(path) else {
                throw ContentPackageError.invalidArchive("unsafe ZIP path \(entry.path)")
            }
            guard seen.insert(path.lowercased()).inserted else {
                throw ContentPackageError.invalidArchive("duplicate normalized ZIP path \(path)")
            }
            guard entry.type != .symlink else {
                throw ContentPackageError.invalidArchive("symbolic links are forbidden: \(path)")
            }
            guard entry.type == .file || isDirectory else {
                throw ContentPackageError.invalidArchive("unsupported ZIP entry: \(path)")
            }
            let (next, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, next <= maximumUncompressedBytes else {
                throw ContentPackageError.invalidArchive("uncompressed package exceeds 1 GiB")
            }
            total = next
            if path.hasSuffix(".json") && entry.uncompressedSize > maximumJSONBytes {
                throw ContentPackageError.invalidArchive("JSON exceeds 16 MiB: \(path)")
            }
            if path.hasSuffix(".mp3") && entry.uncompressedSize > 33_554_432 {
                throw ContentPackageError.invalidArchive("MP3 exceeds 32 MiB: \(path)")
            }
            entries[path] = entry
        }
        guard entries.count == centralEntryCount else {
            throw ContentPackageError.invalidArchive("ZIP directory entry count differs")
        }
        guard let manifestEntry = entries["package.json"], manifestEntry.type == .file else {
            throw ContentPackageError.invalidArchive("missing root package.json")
        }
        let manifest = try JSONDecoder().decode(ContentPackageManifest.self,
            from: read(manifestEntry, from: archive))
        try manifest.validate()
        let declared = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.sha256) })
        let allowedDirectories = Set(manifest.files.flatMap { file -> [String] in
            let parts = file.path.split(separator: "/")
            return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        })
        for (path, entry) in entries {
            if entry.type == .directory {
                guard allowedDirectories.contains(path) else {
                    throw ContentPackageError.invalidArchive("undeclared directory \(path)")
                }
            } else if path != "package.json" {
                guard let expectedHash = declared[path] else {
                    throw ContentPackageError.invalidArchive("undeclared file \(path)")
                }
                var hash = SHA256()
                _ = try archive.extract(entry, skipCRC32: false) { hash.update(data: $0) }
                let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual == expectedHash else {
                    throw ContentPackageError.invalidArchive("SHA-256 mismatch: \(path)")
                }
            }
        }
        for file in manifest.files where entries[file.path]?.type != .file {
            throw ContentPackageError.invalidArchive("missing declared file \(file.path)")
        }
        let allFiles = Set(manifest.files.map(\.path)).union(["package.json"])
        for path in allFiles {
            let parts = path.split(separator: "/")
            for count in 1..<parts.count where allFiles.contains(parts.prefix(count).joined(separator: "/")) {
                throw ContentPackageError.invalidArchive("file/directory conflict: \(path)")
            }
        }
        guard let primary = entries[manifest.content] else {
            throw ContentPackageError.invalidArchive("missing primary content")
        }
        let payload = try read(primary, from: archive)
        switch manifest.kind {
        case .role:
            let role = try JSONDecoder().decode(CharacterDefinition.self, from: payload)
            guard role.id == manifest.id else {
                throw ContentPackageError.invalidContent("role ID differs from package ID")
            }
            try validatePetPack(id: role.id, entries: entries, archive: archive)
        case .group:
            let payload = try JSONDecoder().decode(GroupPackagePayload.self, from: payload)
            let group = payload.cast
            guard group.id == manifest.id, payload.group.id == group.groupID,
                  group.episodes.isEmpty else {
                throw ContentPackageError.invalidContent("group ID differs or contains embedded story")
            }
            let profiles = Set(payload.characters.map(\.id))
            guard profiles.count == payload.characters.count,
                  profiles == Set(payload.group.memberIDs),
                  group.members.allSatisfy({ member in
                      member.kind == .mech || profiles.contains(member.profileID ?? member.id)
                  }) else {
                throw ContentPackageError.invalidContent("group member profiles are not self-contained")
            }
            for visualID in Set(group.members.compactMap(\.visualPackID)) {
                try validatePetPack(id: visualID, entries: entries, archive: archive)
            }
        case .story:
            let story = try JSONDecoder().decode(StoryPack.self, from: payload)
            guard story.id == manifest.id, story.groupID == manifest.targetGroupID else {
                throw ContentPackageError.invalidContent("story ID or target group differs")
            }
        }
        return manifest
    }

    public static func extract(at archiveURL: URL, to newDirectory: URL) throws -> ContentPackageManifest {
        let manifest = try inspect(at: archiveURL)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newDirectory.path) else {
            throw ContentPackageError.invalidArchive("extraction destination already exists")
        }
        let archive = try Archive(url: archiveURL, accessMode: .read)
        try fm.createDirectory(at: newDirectory, withIntermediateDirectories: false)
        do {
            for file in ["package.json"] + manifest.files.map(\.path) {
                guard let entry = archive[file] else {
                    throw ContentPackageError.invalidArchive("missing file during extraction: \(file)")
                }
                let target = newDirectory.appendingPathComponent(file)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: target, skipCRC32: false,
                                    allowUncontainedSymlinks: false)
            }
            try validateExtracted(at: newDirectory, matching: manifest)
            return manifest
        } catch {
            try? fm.removeItem(at: newDirectory)
            throw error
        }
    }

    /// Read one declared idle frame for the manager thumbnail without unpacking a whole role/group.
    public static func previewFrameData(at archiveURL: URL,
                                        manifest: ContentPackageManifest) throws -> Data? {
        guard manifest.kind != .story else { return nil }
        try manifest.validate()
        guard let file = manifest.files.sorted(by: { $0.path < $1.path }).first(where: {
            $0.path.hasPrefix("petpack/") &&
            ($0.path.hasSuffix("/base/idle/frame_00.webp") ||
             $0.path.hasSuffix("/base/idle/frame_00.png"))
        }) else { return nil }
        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard let entry = archive[file.path], entry.type == .file,
              entry.uncompressedSize <= 8_388_608 else {
            throw ContentPackageError.invalidContent("missing or oversized preview frame")
        }
        let data = try readMedia(entry, from: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            throw ContentPackageError.invalidArchive("preview frame hash differs")
        }
        return data
    }

    /// Cached extractions are disposable. Verify them again before reuse: a
    /// previous crash or local modification must not bypass the ZIP preflight.
    static func validateExtracted(at root: URL, matching manifest: ContentPackageManifest) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        func checkedFile(_ relative: String) throws -> URL {
            var url = root
            let rootValues = try url.resourceValues(forKeys: keys)
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                throw ContentPackageError.invalidArchive("cached package root is not a directory")
            }
            let parts = relative.split(separator: "/")
            for (index, part) in parts.enumerated() {
                url.appendPathComponent(String(part))
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true,
                      (index == parts.count - 1 ? values.isRegularFile == true
                          : values.isDirectory == true) else {
                    throw ContentPackageError.invalidArchive("invalid cached path: \(relative)")
                }
            }
            return url
        }
        let manifestURL = try checkedFile("package.json")
        let installed = try JSONDecoder().decode(ContentPackageManifest.self,
            from: Data(contentsOf: manifestURL))
        guard installed == manifest else {
            throw ContentPackageError.invalidArchive("cached manifest differs")
        }
        for file in manifest.files {
            let digest = try hashFile(checkedFile(file.path))
            guard digest == file.sha256 else {
                throw ContentPackageError.invalidArchive("cached file differs: \(file.path)")
            }
        }
    }

    private static func read(_ entry: Entry, from archive: Archive) throws -> Data {
        guard entry.uncompressedSize <= maximumJSONBytes else {
            throw ContentPackageError.invalidArchive("JSON exceeds 16 MiB: \(entry.path)")
        }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: false) { chunk in
            guard data.count <= Int(maximumJSONBytes) - chunk.count else {
                throw ContentPackageError.invalidArchive("JSON expanded beyond limit")
            }
            data.append(chunk)
        }
        return data
    }

    private static func readMedia(_ entry: Entry, from archive: Archive) throws -> Data {
        let limit = 33_554_432
        guard entry.uncompressedSize <= limit else {
            throw ContentPackageError.invalidContent("media exceeds 32 MiB: \(entry.path)")
        }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: false) { chunk in
            guard data.count <= limit - chunk.count else {
                throw ContentPackageError.invalidContent("media expanded beyond limit")
            }
            data.append(chunk)
        }
        return data
    }

    private static func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// ZIPFoundation maps unknown Unix mode bits to `.file`. Check the raw
    /// central-directory attributes first so FIFO/device/socket entries cannot
    /// masquerade as ordinary content. ZIP64 and multi-disk archives are not
    /// needed for the 1 GiB/20k-entry package contract and are rejected.
    private static func validateCentralDirectoryTypes(at url: URL) throws -> Int {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        let tailSize = Int(min(length, 65_557))
        guard tailSize >= 22 else { throw ContentPackageError.invalidArchive("truncated ZIP") }
        try file.seek(toOffset: length - UInt64(tailSize))
        let tail = try file.read(upToCount: tailSize) ?? Data()
        func number(_ data: Data, _ index: Int, _ bytes: Int) -> UInt64? {
            guard index >= 0, bytes > 0, index <= data.count - bytes else { return nil }
            return (0..<bytes).reduce(UInt64(0)) { value, offset in
                value | (UInt64(data[index + offset]) << (offset * 8))
            }
        }
        let eocd = stride(from: tail.count - 22, through: 0, by: -1).first { index in
            number(tail, index, 4) == 0x06054b50 &&
                index + 22 + Int(number(tail, index + 20, 2) ?? 0) == tail.count
        }
        guard let eocd,
              number(tail, eocd + 4, 2) == 0,
              number(tail, eocd + 6, 2) == 0,
              let count = number(tail, eocd + 10, 2),
              count == number(tail, eocd + 8, 2), count <= UInt64(maximumEntries),
              let size = number(tail, eocd + 12, 4), size <= 67_108_864,
              let offset = number(tail, eocd + 16, 4),
              count < 0xffff, size < 0xffff_ffff, offset < 0xffff_ffff,
              offset <= length, size <= length - offset,
              offset + size <= length - UInt64(tailSize) + UInt64(eocd) else {
            throw ContentPackageError.invalidArchive("unsupported or malformed ZIP directory")
        }
        try file.seek(toOffset: offset)
        let central = try file.read(upToCount: Int(size)) ?? Data()
        guard central.count == Int(size) else {
            throw ContentPackageError.invalidArchive("truncated ZIP directory")
        }
        var cursor = 0
        for _ in 0..<Int(count) {
            guard number(central, cursor, 4) == 0x02014b50,
                  let madeBy = number(central, cursor + 4, 2),
                  let nameLength = number(central, cursor + 28, 2),
                  let extraLength = number(central, cursor + 30, 2),
                  let commentLength = number(central, cursor + 32, 2),
                  let attributes = number(central, cursor + 38, 4),
                  cursor + 46 + Int(nameLength + extraLength + commentLength) <= central.count else {
                throw ContentPackageError.invalidArchive("malformed ZIP entry header")
            }
            let host = madeBy >> 8
            if host == 3 || host == 19 {
                let fileType = (attributes >> 16) & 0xf000
                guard fileType == 0x8000 || fileType == 0x4000 || fileType == 0xa000 else {
                    throw ContentPackageError.invalidArchive("unsupported Unix ZIP entry type")
                }
            } else if host != 0 {
                throw ContentPackageError.invalidArchive("unsupported ZIP host type")
            }
            cursor += 46 + Int(nameLength + extraLength + commentLength)
        }
        guard cursor == central.count else {
            throw ContentPackageError.invalidArchive("extra ZIP directory records")
        }
        return Int(count)
    }

    private static func validatePetPack(id: String, entries: [String: Entry], archive: Archive) throws {
        let root = "petpack/\(id)/"
        guard let entry = entries[root + "manifest.json"], entry.type == .file else {
            throw ContentPackageError.invalidContent("missing petpack manifest for \(id)")
        }
        let visual = try JSONDecoder().decode(PetPackManifest.self, from: read(entry, from: archive))
        guard visual.id == id, visual.format == "petpack-v2",
              visual.sprite.cellWidth.isFinite, visual.sprite.cellHeight.isFinite,
              (1...4096).contains(visual.sprite.cellWidth),
              (1...4096).contains(visual.sprite.cellHeight) else {
            throw ContentPackageError.invalidContent("invalid petpack identity or sprite size")
        }
        for required in ["base/idle", "base/walk"] where visual.clips[required] == nil {
            throw ContentPackageError.invalidContent("missing required \(required) clip")
        }
        for (key, clip) in visual.clips {
            guard ContentPackageManifest.validPath(key), clip.frames > 0,
                  clip.frames <= 10_000, clip.fps.isFinite, (1...120).contains(clip.fps) else {
                throw ContentPackageError.invalidContent("invalid clip parameters: \(key)")
            }
            let framePrefix = root + key + "/frame_"
            let actual = entries.keys.filter {
                $0.hasPrefix(framePrefix) && ($0.hasSuffix(".webp") || $0.hasSuffix(".png"))
            }.count
            guard actual == clip.frames else {
                throw ContentPackageError.invalidContent("missing frames for \(key)")
            }
            for index in 0..<clip.frames {
                let stem = root + key + "/" + String(format: "frame_%02d", index)
                let frame = [stem + ".webp", stem + ".png"].compactMap { entries[$0] }
                guard frame.count == 1, frame[0].type == .file else {
                    throw ContentPackageError.invalidContent("missing numbered frame: \(stem)")
                }
                let data = try readMedia(frame[0], from: archive)
                let headerMatches = frame[0].path.hasSuffix(".png")
                    ? data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
                    : data.count >= 12 && data.starts(with: Data("RIFF".utf8))
                        && data[8..<12] == Data("WEBP".utf8)
                guard headerMatches else {
                    throw ContentPackageError.invalidContent("frame format differs: \(frame[0].path)")
                }
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      (1...4096).contains(image.width), (1...4096).contains(image.height) else {
                    throw ContentPackageError.invalidContent("unreadable frame: \(frame[0].path)")
                }
            }
            if let voice = clip.voice {
                let path = root + key + "/voice.mp3"
                guard key.hasPrefix("actions/"), voice.path == key + "/voice.mp3",
                      voice.language == "zh-Hans" || voice.language == "en",
                      voice.durationSeconds.isFinite, (0.1...30).contains(voice.durationSeconds),
                      entries[path]?.type == .file else {
                    throw ContentPackageError.invalidContent("invalid voice asset for \(key)")
                }
                let data = try readMedia(entries[path]!, from: archive)
                guard let player = try? AVAudioPlayer(data: data), player.duration > 0 else {
                    throw ContentPackageError.invalidContent("unreadable MP3 voice for \(key)")
                }
            }
        }
        let declaredVoicePaths = Set(visual.clips.compactMap { key, clip in
            clip.voice == nil ? nil : root + key + "/voice.mp3"
        })
        for path in entries.keys where path.hasPrefix(root) && path.hasSuffix(".mp3") {
            guard declaredVoicePaths.contains(path) else {
                throw ContentPackageError.invalidContent("undeclared clip voice: \(path)")
            }
        }
    }
}
