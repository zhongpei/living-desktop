import XCTest
@testable import MyPet

/// 模型下载组件：续传决策矩阵与「已齐即跳过、不发请求」（离线可测，不联网）。
final class ModelDownloaderTests: XCTestCase {

    func testResumePlanMatrix() {
        // 200：服务端不理会 Range，从头重写。
        XCTAssertEqual(ModelDownloader.resumePlan(status: 200, partBytes: 100, expected: 1000)?
            .truncateFirst, true)
        // 206：从 part 已有字节处接着写。
        let resumed = ModelDownloader.resumePlan(status: 206, partBytes: 100, expected: 1000)
        XCTAssertEqual(resumed?.appendFrom, 100)
        XCTAssertEqual(resumed?.truncateFirst, false)
        // 416：part 已齐 = 直接落位；part 坏了 = 从头重写。
        XCTAssertEqual(ModelDownloader.resumePlan(status: 416, partBytes: 1000, expected: 1000)?
            .alreadyDone, true)
        XCTAssertEqual(ModelDownloader.resumePlan(status: 416, partBytes: 5, expected: 1000)?
            .truncateFirst, true)
        // 其他状态一律报错。
        XCTAssertNil(ModelDownloader.resumePlan(status: 500, partBytes: 0, expected: 1000))
        XCTAssertNil(ModelDownloader.resumePlan(status: 404, partBytes: 0, expected: 1000))
    }

    func testInstallSkipsCompleteFilesWithoutNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloader-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 文件与清单字节数一致 → 不发任何请求（base 指向必然失败的主机）直接返回 false。
        try Data(repeating: 0, count: 8).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 3).write(to: dir.appendingPathComponent("b.bin"))
        let downloader = ModelDownloader()
        let did = try await downloader.install(
            files: [
                LocalBrainModel.File(path: "a.bin", bytes: 8, required: true),
                LocalBrainModel.File(path: "b.bin", bytes: 3, required: true),
            ],
            from: URL(string: "https://invalid.invalid")!,
            into: dir)
        XCTAssertFalse(did)

        // 缺一个 → 需要下载（用必然失败的 base，验证它真的尝试了并报错）。
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.bin"))
        do {
            _ = try await downloader.install(
                files: [
                    LocalBrainModel.File(path: "a.bin", bytes: 8, required: true),
                    LocalBrainModel.File(path: "b.bin", bytes: 3, required: true),
                ],
                from: URL(string: "https://invalid.invalid")!,
                into: dir)
            XCTFail("缺文件时应当发起下载并失败")
        } catch {
            // 期望路径：域名解析失败抛错。
        }
    }

    func testNoFileLeftAfterFailedInstall() async throws {
        // base 不可达 → install 抛传输错误，且不落任何最终文件 / 暂存文件。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloader-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            _ = try await ModelDownloader().install(
                files: [LocalBrainModel.File(path: "a.bin", bytes: 8, required: true)],
                from: URL(string: "https://invalid.invalid")!,
                into: dir)
            XCTFail("不可达的 base 应当抛错")
        } catch {
            // 期望路径：域名解析 / TLS 失败。
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("a.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("a.bin.part").path))
    }
}
