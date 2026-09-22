import XCTest
@testable import MyPetApp

/// 本地 Student Brain 模型目录：下载源写死与清单完整性（离线可测，不联网）。
final class LocalBrainModelTests: XCTestCase {

    func testDownloadSourceIsPinnedToModelScope() {
        XCTAssertEqual(LocalBrainModel.repoID, "mlx-community/Qwen3.5-0.8B-OptiQ-4bit")
        XCTAssertEqual(
            LocalBrainModel.rawBaseURL.absoluteString,
            "https://modelscope.cn/models/mlx-community/Qwen3.5-0.8B-OptiQ-4bit/resolve/master")
        XCTAssertEqual(
            LocalBrainModel.pageURL.absoluteString,
            "https://modelscope.cn/models/mlx-community/Qwen3.5-0.8B-OptiQ-4bit")
    }

    func testFileURLKeepsSubdirectoryPaths() {
        XCTAssertEqual(
            LocalBrainModel.url(for: "optiq/mtp.safetensors").absoluteString,
            LocalBrainModel.rawBaseURL.appendingPathComponent("optiq/mtp.safetensors").absoluteString)
        XCTAssertTrue(LocalBrainModel.url(for: "config.json").absoluteString.hasSuffix("/config.json"))
    }

    func testManifestIntegrity() {
        let files = LocalBrainModel.files
        XCTAssertEqual(Set(files.map(\.path)).count, files.count, "路径不得重复")
        XCTAssertTrue(files.allSatisfy { $0.bytes > 0 })
        // 权重主体必须在场且是 required（漏下它 = 装完也跑不起来）。
        let weights = files.first { $0.path == "model.safetensors" }
        XCTAssertEqual(weights?.bytes, 650_257_188)
        XCTAssertEqual(weights?.required, true)
        // 手改清单时这里先炸：required 集约 872MB（含 vision 半区），全仓库约 886MB。
        XCTAssertEqual(LocalBrainModel.requiredBytes, 871_590_512)
        XCTAssertEqual(LocalBrainModel.totalBytes, 886_126_193)
    }

    func testReadinessCheckByByteSize() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localbrain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func makeSparseFile(_ path: String, bytes: Int) throws {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            try fh.seek(toOffset: UInt64(bytes - 1))
            try fh.write(Data([0]))
        }

        // 空目录：所有 required 都缺。
        let requiredCount = LocalBrainModel.files.filter(\.required).count
        XCTAssertEqual(LocalBrainModel.missingFiles(in: dir).count, requiredCount)

        // 字节数不符 = 缺（防下载半截）。
        try Data(repeating: 0, count: 10).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertTrue(LocalBrainModel.missingFiles(in: dir).contains { $0.path == "config.json" })

        // 逐个补齐正确大小后清零；可选边车缺席不算缺。
        for file in LocalBrainModel.files where file.required {
            try makeSparseFile(file.path, bytes: file.bytes)
        }
        XCTAssertTrue(LocalBrainModel.missingFiles(in: dir).isEmpty)
    }

    func testProcessorShimIsIdempotentAndMinimal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localbrain-shim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        LocalBrainModel.writeProcessorShim(into: dir)
        let url = dir.appendingPathComponent("processor_config.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["processor_class"] as? String, "Qwen3VLProcessor")
        XCTAssertEqual((json?["image_mean"] as? [Double])?.count, 3)

        // 幂等：已存在不覆盖（后续版本/用户的改动不被冲掉）。
        try "custom".data(using: .utf8)!.write(to: url)
        LocalBrainModel.writeProcessorShim(into: dir)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "custom")
    }
}
