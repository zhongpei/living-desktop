import CoreGraphics
import Foundation
import ImageIO

/// Resolves prop art once; the caller decides whether missing art uses an emoji.
public enum PropSpriteLibrary {
    public static func frameURLs(for id: String, packURL: URL?) -> [URL] {
        let fm = FileManager.default
        var singleCandidates: [URL] = []
        var frameDirs: [URL] = []
        if let packURL {
            frameDirs.append(packURL.appendingPathComponent("props/\(id)", isDirectory: true))
            singleCandidates.append(packURL.appendingPathComponent("props/\(id).webp"))
        }
        for shared in sharedRoots() {
            frameDirs.append(shared.appendingPathComponent(id, isDirectory: true))
            singleCandidates.append(shared.appendingPathComponent("\(id).webp"))
        }
        for dir in frameDirs {
            let frames = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "webp" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let frames, !frames.isEmpty { return frames }
        }
        return singleCandidates.first { fm.fileExists(atPath: $0.path) }.map { [$0] } ?? []
    }

    public static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func sharedRoots() -> [URL] {
        var roots: [URL] = []
        if let resource = Bundle.main.resourceURL {
            roots.append(resource.appendingPathComponent("props", isDirectory: true))
        }
        if let exe = CommandLine.arguments.first, FileManager.default.fileExists(atPath: exe) {
            var dir = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("Resources/props", isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.path) { roots.append(candidate) }
                dir = dir.deletingLastPathComponent()
            }
        }
        return roots
    }
}
