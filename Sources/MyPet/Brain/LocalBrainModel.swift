import Foundation

/// 本地 Student Brain 的模型目录（brain-local.md §6：默认不打包，启用时才下载）。
///
/// 下载源写死为 ModelScope（国内直连，与 fetch_needle.sh 同一直链形式）：
///     https://modelscope.cn/models/mlx-community/Qwen3.5-0.8B-OptiQ-4bit
/// 文件清单与字节数实测自该仓库 master（2026-09-20），下载后按字节数校验；
/// 换模型 / 加 2B 候选 = 改本文件（或新增一份目录），不散落到设置里。
struct LocalBrainModel {

    // MARK: 写死的下载源

    /// ModelScope 仓库 ID（namespace/name）。
    static let repoID = "mlx-community/Qwen3.5-0.8B-OptiQ-4bit"
    /// 仓库网页（设置窗展示用）。
    static let pageURL = URL(string: "https://modelscope.cn/models/\(repoID)")!
    /// 原始文件直链前缀：`resolve/master/<path>`。小文件 200 直出，LFS 大文件
    /// 302 跳 CDN（URLSession/curl -L 默认跟随），支持 Range 断点续传。
    static let rawBaseURL = URL(string: "https://modelscope.cn/models/\(repoID)/resolve/master")!

    // MARK: 文件清单（字节数为仓库实测，下载后照此校验）

    struct File {
        /// 仓库内相对路径（含 optiq/ 子目录）。
        let path: String
        let bytes: Int
        /// false = 可选边车（MTP 投机解码 / bf16 视觉塔），第一版不下载。
        let required: Bool
    }

    /// required = 能加载推理的最小集。注意：本 checkpoint 是 Qwen3.5 原生 VL 复合结构，
    /// 必须走 MLXVLM 的 qwen3_5 加载，vision 权重的另一半在 optiq/optiq_vision.safetensors
    /// 里（G0 实测缺它会 keyNotFound）→ 该文件是必需的；mtp.safetensors 才是可选项。
    static let files: [File] = [
        File(path: "config.json",                    bytes: 42_307,      required: true),
        File(path: "model.safetensors",              bytes: 650_257_188, required: true),
        File(path: "model.safetensors.index.json",   bytes: 70_097,      required: true),
        File(path: "optiq_metadata.json",            bytes: 19_711,      required: true),
        File(path: "kv_config.json",                 bytes: 396,         required: true),
        File(path: "generation_config.json",         bytes: 148,         required: true),
        File(path: "chat_template.jinja",            bytes: 7_755,       required: true),
        File(path: "tokenizer.json",                 bytes: 19_989_343,  required: true),
        File(path: "tokenizer_config.json",          bytes: 1_135,       required: true),
        File(path: "optiq/optiq_vision.safetensors", bytes: 201_202_432, required: true),
        // 可选边车：MTP 投机解码，v1 不碰（brain-local.md §5.4）。
        // 且不能落在安装目录里——加载器递归扫 *.safetensors，mtp 键会撑爆权重校验。
        File(path: "optiq/mtp.safetensors",          bytes: 14_530_491,  required: false),
        File(path: "README.md",                      bytes: 5_117,       required: false),
        File(path: "configuration.json",             bytes: 73,          required: false),
    ]

    /// 需下载字节数（required 集，约 872MB；按十进制字节显示）。
    static var requiredBytes: Int { files.filter(\.required).map(\.bytes).reduce(0, +) }
    /// 全仓库字节数（约 886MB）。
    static var totalBytes: Int { files.map(\.bytes).reduce(0, +) }

    /// 单文件直链。
    static func url(for path: String) -> URL {
        rawBaseURL.appendingPathComponent(path)
    }

    // MARK: 安装位置与就绪检查

    /// 安装目录：~/Library/Application Support/MyPet/Models/brain/<模型名>/。
    /// 版本独立目录，换模型 / 加 LoRA adapter 不动旧版（brain-local.md §6）。
    static var installDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPet", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
        return base.appendingPathComponent("qwen3.5-0.8b-optiq-4bit", isDirectory: true)
    }

    static var isInstalled: Bool { missingFiles(in: installDirectory).isEmpty }

    /// ModelScope 仓库不带 processor_config.json，但 VLM 加载器必需（G0 实测）。
    /// 落一份最小 shim：processor 指到注册表现成的 Qwen3VLProcessor（纯文本决策够用），
    /// 视觉字段取自 checkpoint 的 vision_config。幂等；已存在不覆盖。
    static func writeProcessorShim(into dir: URL) {
        let url = dir.appendingPathComponent("processor_config.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let shim: [String: Any] = [
            "processor_class": "Qwen3VLProcessor",
            "image_processor_type": "Qwen2VLImageProcessor",
            "patch_size": 16,
            "merge_size": 2,
            "temporal_patch_size": 2,
            "image_mean": [0.48145466, 0.4578275, 0.40821073],
            "image_std": [0.26862954, 0.26130258, 0.27577711],
            "min_pixels": 3_136,
            "max_pixels": 12_845_056,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: shim, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    /// dir 里缺失或字节数不符（下载半截）的 required 文件。
    static func missingFiles(in dir: URL) -> [File] {
        files.filter { $0.required && size(of: $0.path, in: dir) != $0.bytes }
    }

    private static func size(of path: String, in dir: URL) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(path).path)
        return attrs?[.size] as? Int
    }
}
