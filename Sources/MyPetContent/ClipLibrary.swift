import CoreGraphics
import Foundation
import ImageIO

/// petpack-v2 manifest（desktop/scripts/sync_assets.py 产出）。
/// 目录名即语义：base/* 是身体线的规范槽位，actions/* 是名字自由的表演素材。
public struct PetPackManifest: Decodable {
    public struct Sprite: Decodable {
        public let cellWidth: Double
        public let cellHeight: Double

        enum CodingKeys: String, CodingKey {
            case cellWidth = "cell_width"
            case cellHeight = "cell_height"
        }
    }

    public struct ClipMeta: Decodable {
        public let frames: Int
        public let fps: Double
        /// 素材的**真实像素朝向**（sync-assets 从动作表写入）。
        /// 声明可能与生成实况不符（rei_chibi 步态实为朝左），运行时据此镜像。
        public let facing: String?
        /// loop = 循环播放；once = 播完停末帧（onFinish）。
        public let playback: String?
        public let voice: VoiceMeta?

        enum CodingKeys: String, CodingKey {
            case frames, fps, facing, playback, voice
        }
    }

    public struct VoiceMeta: Decodable {
        public let path: String
        public let language: String
        public let durationSeconds: Double

        enum CodingKeys: String, CodingKey {
            case path, language
            case durationSeconds = "duration_seconds"
        }
    }

    /// 道具元信息（manifest "props" 段，可选——旧包无此段照常工作）。
    public struct PropMeta: Decodable {
        /// 世界尺寸覆盖：宠物显示高度 × scale（缺省用 PropCatalog.def.scale）。
        let scale: Double?
        let frames: Int?
        let fps: Double?
    }

    let id: String
    let format: String
    let sprite: Sprite
    /// clip 键（"base/walk" / "actions/wave"）→ 元信息。
    let clips: [String: ClipMeta]
    /// 道具元信息（可选段）。
    var props: [String: PropMeta]?
}

/// 一套可播放的角色素材（clip 库）。
///
/// v2 契约：base/{idle,idle_2..,walk,run,airborne,drag} 是身体线规范槽位，
/// actions/<name> 是表演素材。帧**懒解码**——首次播放才 decode，LRU 上限缓存，
/// 100+ 动作的包不再要求启动时全量驻留内存。
/// 源 cell 统一 192×208，脚底共享基线（cell 高 × 0.88）。
public final class ClipLibrary: SpriteClipSource {

    /// 脚底基线在 cell 内的位置比例（素材工厂 `_cell_pack` 的共享基线约定）。
    public static let baselineRatio: CGFloat = 0.88

    /// 身体线槽位。idle 有变体池（idle, idle_2, ...），其余每槽一个 clip。
    public enum BaseMotion: String, CaseIterable, Sendable {
        case idle, walk, run, airborne, drag
    }

    /// 素材像素实况朝向。down（正面）按 right 处理（正面镜像近似无损）。
    public enum AuthoredFacing: String {
        case right, left, down
    }

    /// 是否需要水平镜像：素材实况朝左，或（向左移动时的）默认右向素材。
    /// movingRight = 宠物正朝右移动。
    public static func mirrorNeeded(authored: AuthoredFacing, movingRight: Bool) -> Bool {
        switch authored {
        case .right, .down: return !movingRight
        case .left:         return movingRight
        }
    }

    public enum Playback: String {
        case loop, once
    }

    public struct Clip {
        let key: String           // "base/walk" | "actions/wave"
        let meta: PetPackManifest.ClipMeta
        let directory: URL
    }

    public let characterID: String
    public let cellSize: CGSize
    /// petpack 根目录（道具 sprites 等扩展素材的查找基准；测试手工构造时可为 nil）。
    public private(set) var packURL: URL?

    /// 道具世界尺寸覆盖（manifest props 段；nil = 用 PropCatalog 默认 scale）。
    public func propScaleOverride(for id: String) -> Double? {
        manifestProps?[id]?.scale
    }
    private var manifestProps: [String: PetPackManifest.PropMeta]? = nil
    /// 解码缓存上限（clip 个数）。按 192×208×4B/帧 ≈ 160KB、8 帧/clip 计，
    /// 24 个 ≈ 30MB，足以容纳当前活跃的工作集。
    private let cacheLimit: Int

    private var clips: [String: Clip] = [:]
    private var decodedCache: [String: [CGImage]] = [:]
    /// LRU 序（队首 = 最久未用）。
    private var lru: [String] = []
    /// 加载时的诊断信息，仅日志用。
    public private(set) var warnings: [String] = []

    public var baselinePixels: CGFloat {
        cellSize.height * Self.baselineRatio
    }

    /// clip 总数（base + actions）。
    public var clipCount: Int { clips.count }

    public init(characterID: String, cellSize: CGSize, cacheLimit: Int = 24) {
        self.characterID = characterID
        self.cellSize = cellSize
        self.cacheLimit = max(cacheLimit, 2)
    }

    // ============ 加载 ============

    /// 从 petpack 目录加载。只读 manifest 和目录结构，不解码帧。
    /// base/idle 与 base/walk 缺失 = 契约错误（身体线无法运转），直接抛错指名。
    public static func load(from dir: URL, cacheLimit: Int = 24) throws -> ClipLibrary {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PetPackManifest.self, from: data)
        guard manifest.format == "petpack-v2" else {
            throw PetPackError.staleFormat(dir: dir, format: manifest.format)
        }

        let library = ClipLibrary(
            characterID: manifest.id,
            cellSize: CGSize(width: manifest.sprite.cellWidth, height: manifest.sprite.cellHeight),
            cacheLimit: cacheLimit
        )
        library.packURL = dir
        library.manifestProps = manifest.props

        for (key, meta) in manifest.clips {
            let clipDir = dir.appendingPathComponent(key, isDirectory: true)
            let urls = frameURLs(in: clipDir)
            if urls.isEmpty {
                library.warnings.append("clip \(key): 目录无帧文件，跳过")
                continue
            }
            if urls.count != meta.frames {
                library.warnings.append("clip \(key): 声明 \(meta.frames) 帧，实存 \(urls.count)")
            }
            library.clips[key] = Clip(key: key, meta: meta, directory: clipDir)
        }

        for motion in [BaseMotion.idle, .walk] where library.base(motion) == nil {
            throw PetPackError.missingBase(dir: dir, motion: motion)
        }
        guard !library.clips.isEmpty else {
            throw PetPackError.empty(dir: dir)
        }
        return library
    }

    private static func frameURLs(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ))?
            .filter { ["webp", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    public static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // ============ 查询（名字零猜测：调用方只问语义） ============

    public func clip(_ key: String) -> Clip? { clips[key] }
    public func meta(for key: String) -> PetPackManifest.ClipMeta? { clips[key]?.meta }

    /// Optional recorded line belonging to one authored action, never inferred for base clips.
    public func voiceURL(for key: String) -> URL? {
        guard key.hasPrefix("actions/"),
              let voice = clips[key]?.meta.voice,
              voice.path == "\(key)/voice.mp3",
              let packURL else { return nil }
        let url = packURL.appendingPathComponent(voice.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func facing(for key: String) -> AuthoredFacing {
        clips[key]?.meta.facing.flatMap(AuthoredFacing.init(rawValue:)) ?? .right
    }

    public func playback(for key: String) -> Playback {
        clips[key]?.meta.playback.flatMap(Playback.init(rawValue:)) ?? .loop
    }

    /// 规范槽位的 clip 键（"base/walk"），无则 nil。
    public func base(_ motion: BaseMotion) -> String? {
        clips["base/\(motion.rawValue)"] != nil ? "base/\(motion.rawValue)" : nil
    }

    /// 规范槽位 + 回退链：run 缺 → walk；airborne/drag 缺 → idle。保证身体线永远有帧。
    public func baseOrFallback(_ motion: BaseMotion) -> String {
        if let direct = base(motion) { return direct }
        switch motion {
        case .idle: return base(.idle)!
        case .run: return base(.walk) ?? base(.idle)!
        case .walk: return base(.idle)!
        case .airborne, .drag: return base(.idle)!
        }
    }

    /// 站立姿态池（"base/idle", "base/idle_2", ...），按键名字典序。
    public var idlePool: [String] {
        clips.keys.filter { $0 == "base/idle" || $0.hasPrefix("base/idle_") }.sorted()
    }

    /// 表演素材名（不带 "actions/" 前缀），字母序。
    public var actionNames: [String] {
        clips.keys.filter { $0.hasPrefix("actions/") }
            .map { String($0.dropFirst("actions/".count)) }
            .sorted()
    }

    /// 表演名 → clip 键（"wave" → "actions/wave"）。
    public func action(named name: String) -> String? {
        clips["actions/\(name)"] != nil ? "actions/\(name)" : nil
    }

    /// 睡眠姿态 clip（actions/sleep*，如 sleep_loop / sleep），无则 nil（调用方回退 idle）。
    public func sleepActionKey() -> String? {
        actionNames.first { $0.hasPrefix("sleep") }.flatMap { action(named: $0) }
    }

    // ============ 懒解码 + LRU ============

    /// 取 clip 的帧（首次访问解码并缓存，LRU 淘汰）。
    public func frames(for key: String) -> [CGImage]? {
        if let hit = decodedCache[key] {
            touch(key)
            return hit
        }
        guard let clip = clips[key] else { return nil }
        let urls = Self.frameURLs(in: clip.directory)
        let frames = urls.compactMap { Self.loadCGImage($0) }
        if frames.isEmpty { return nil }
        if frames.count != urls.count {
            warnings.append("clip \(key): \(urls.count - frames.count) 帧解码失败")
        }
        decodedCache[key] = frames
        touch(key)
        while lru.count > cacheLimit, let oldest = lru.first {
            lru.removeFirst()
            decodedCache[oldest] = nil
        }
        return frames
    }

    public func spriteClip(for name: String) -> SpriteClip? {
        guard let meta = meta(for: name), let frames = frames(for: name) else { return nil }
        return SpriteClip(frames: frames, fps: meta.fps, looping: playback(for: name) == .loop)
    }

    /// 当前缓存中的 clip 数（测试/诊断用）。
    public var debugCachedClipCount: Int { decodedCache.count }

    private func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }
}

public enum PetPackError: LocalizedError {
    case empty(dir: URL)
    case staleFormat(dir: URL, format: String)
    case missingBase(dir: URL, motion: ClipLibrary.BaseMotion)

    public var errorDescription: String? {
        switch self {
        case .empty(let dir):
            return "petpack 里没有任何可用 clip：\(dir.path)。先运行 desktop/scripts/sync_assets.py。"
        case .staleFormat(let dir, let format):
            return "petpack 格式过旧（\(format)）：\(dir.path)。先运行 desktop/scripts/sync_assets.py 重新编译。"
        case .missingBase(let dir, let motion):
            return "petpack 缺身体线必需槽位 base/\(motion.rawValue)：\(dir.path)。"
                + "先运行 desktop/scripts/sync_assets.py；若素材缺失请补生成该动作。"
        }
    }
}

/// 素材库：枚举所有可切换的宠物、决定加载哪个。
/// 分辨率/路径零写死 —— 库根实时探测，子目录含 manifest.json 即为一只宠物。
public enum PetPackLibrary {

    /// `-pet <id>` 启动参数：直接以指定宠物启动（调试 / 测试用）。
    public static func requestedPet(from arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: "-pet"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// 枚举库根下的宠物包（子目录含 manifest.json），按 id 字母序。
    public static func availablePacks(in root: URL) -> [(id: String, url: URL)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ))?.filter {
            $0.hasDirectoryPath
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        } ?? []
        return dirs
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, $0) }
    }

    /// 库根查找顺序：MYPET_PETPACK 环境变量 → .app 内置 Resources → 仓库 desktop/Resources（swift run）。
    /// 环境变量指向单个包目录时自动上跳一层当库根。
    public static func roots(bundle: Bundle = .main,
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default
        if let env = environment["MYPET_PETPACK"] {
            let url = URL(fileURLWithPath: env)
            roots.append(
                fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
                    ? url.deletingLastPathComponent()
                    : url
            )
        }
        if let resourceURL = bundle.resourceURL {
            roots.append(resourceURL.appendingPathComponent("petpack"))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            roots.append(dir.appendingPathComponent("Resources/petpack"))
            dir = dir.deletingLastPathComponent()
        }
        return roots
    }
}
