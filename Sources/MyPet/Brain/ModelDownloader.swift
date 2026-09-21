import Foundation

/// 本地模型下载器（brain-local.md §6 的「专门下载组件」）。
///
/// 按 `LocalBrainModel` 写死的清单逐文件下载：Range 断点续传（`.part` 暂存）、
/// 完成后按清单字节数校验再落位，全部 required 就位才算装好。
/// 取消 / 崩溃 / 断网后重跑即从半截继续，不重下已齐的文件。
/// 手动安装走 `modelscope download` CLI；本组件给设置窗与 MLXBrainProbe 用。
actor ModelDownloader {

    struct Progress: Sendable {
        /// 当前文件相对路径。
        let path: String
        let bytesDone: Int64
        let bytesTotal: Int64
        /// 整包进度（按本次 install 的文件总字节）。
        let overallFraction: Double
    }

    enum DownloadError: LocalizedError, Equatable {
        case badStatus(path: String, status: Int)
        case sizeMismatch(path: String, expected: Int, got: Int)
        case verificationFailed(paths: [String])

        var errorDescription: String? {
            switch self {
            case let .badStatus(path, status):
                return "下载失败 \(path)：HTTP \(status)"
            case let .sizeMismatch(path, expected, got):
                return "下载不完整 \(path)：期望 \(expected) 字节，实际 \(got)"
            case let .verificationFailed(paths):
                return "模型清单验证失败：\(paths.joined(separator: ", "))"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = ModelDownloader.defaultSession()) {
        self.session = session
    }

    private static func defaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60          // 两次数据到达之间的空窗
        cfg.timeoutIntervalForResource = 24 * 3600  // 大文件 + 慢链路的总时长上限
        return URLSession(configuration: cfg)
    }

    // MARK: 对外入口

    /// 把 files 下载 / 补齐到 dir；已齐的跳过，半截的续传。
    /// 返回是否发生了实际下载（全部已就位则为 false，不发任何请求）。
    @discardableResult
    func install(
        files: [LocalBrainModel.File] = LocalBrainModel.files.filter(\.required),
        from base: URL = LocalBrainModel.rawBaseURL,
        into dir: URL = LocalBrainModel.installDirectory,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Bool {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = max(1, files.map(\.bytes).reduce(0, +))
        var completedBytes: Int64 = 0
        var didDownload = false

        for file in files {
            if Self.size(of: file.path, in: dir) == file.bytes {
                completedBytes += Int64(file.bytes)
                continue
            }
            didDownload = true
            let baseBytes = completedBytes  // 值捕获，@Sendable 闭包里只读不变量
            try await downloadOne(file, from: base, into: dir) { bytesDone in
                progress?(Progress(
                    path: file.path,
                    bytesDone: bytesDone,
                    bytesTotal: Int64(file.bytes),
                    overallFraction: Double(baseBytes + bytesDone) / Double(total)))
            }
            completedBytes += Int64(file.bytes)
        }
        return didDownload
    }

    /// 便捷入口：就位本地大脑（LocalBrainModel 的 required 集）。
    @discardableResult
    func installLocalBrain(
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Bool {
        let didDownload = try await install(
            files: LocalBrainModel.files.filter(\.required),
            from: LocalBrainModel.rawBaseURL,
            into: LocalBrainModel.installDirectory,
            progress: progress)
        let missing = LocalBrainModel.missingFiles(in: LocalBrainModel.installDirectory)
        guard missing.isEmpty else {
            throw DownloadError.verificationFailed(paths: missing.map(\.path))
        }
        LocalBrainModel.writeProcessorShim(into: LocalBrainModel.installDirectory)
        return didDownload
    }

    // MARK: 单文件

    private func downloadOne(
        _ file: LocalBrainModel.File,
        from base: URL,
        into dir: URL,
        report: @Sendable (Int64) -> Void
    ) async throws {
        let final = dir.appendingPathComponent(file.path)
        let part = final.appendingPathExtension("part")
        let offset = Self.size(of: file.path + ".part", in: dir) ?? 0

        var request = URLRequest(url: base.appendingPathComponent(file.path))
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let plan = Self.resumePlan(
            status: status, partBytes: offset, expected: file.bytes)
        else { throw DownloadError.badStatus(path: file.path, status: status) }

        if !plan.alreadyDone {
            let handle = try Self.openForAppend(part)
            defer { try? handle.close() }
            if plan.truncateFirst {
                try handle.truncate(atOffset: 0)  // 服务端不支持续传，从头来
            } else {
                try handle.seek(toOffset: UInt64(plan.appendFrom))
            }

            var written = Int64(plan.appendFrom)
            var buffer = [UInt8]()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    report(written)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            try handle.close()
        }

        let got = Self.size(of: file.path + ".part", in: dir) ?? 0
        guard got == file.bytes else {
            throw DownloadError.sizeMismatch(path: file.path, expected: file.bytes, got: got)
        }
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: part, to: final)
    }

    /// Range 响应 → 对 `.part` 的续写方案。返回 nil = 状态异常，应当报错。
    /// - 200：服务端不理会 Range，从头重写；
    /// - 206：从 `partBytes` 处接着写；
    /// - 416：Range 起点越界——part 已齐则直接落位，否则视为坏暂存从头重写。
    static func resumePlan(
        status: Int, partBytes: Int, expected: Int
    ) -> (appendFrom: Int, truncateFirst: Bool, alreadyDone: Bool)? {
        switch status {
        case 200: return (0, true, false)
        case 206: return (partBytes, false, false)
        case 416: return partBytes == expected ? (0, false, true) : (0, true, false)
        default: return nil
        }
    }

    private static func openForAppend(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return try FileHandle(forWritingTo: url)
    }

    private static func size(of path: String, in dir: URL) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(path).path)
        return attrs?[.size] as? Int
    }
}
