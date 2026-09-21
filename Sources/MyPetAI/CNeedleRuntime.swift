import CNeedle
import Foundation

/// A cheap cancellation gate for queued CNeedle work. The C function has no
/// interruption API, so an already-running call finishes and its answer is
/// discarded; queued calls do not enter the model at all.
public final class CNeedleRequestToken {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Sole process-local owner of Needle's non-thread-safe C session.
/// It returns model text only and cannot write runtime state or construct a
/// behavior request.
public final class CNeedleRuntime {
    public static let shared = CNeedleRuntime()

    private let queue = DispatchQueue(label: "mypet.ai.cneedle")
    private var loadedModelPath: String?
    private var initializedSystemPrompt: String?
    private var initializedSchema: String?
    private var buffer = [UInt8](repeating: 0, count: 65_536)

    private init() {}

    public func complete(
        modelPath: String,
        systemPrompt: String,
        schema: String,
        snapshot: String,
        maxNewTokens: Int,
        requestToken: CNeedleRequestToken? = nil,
        completion: @escaping (String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { completion(nil); return }
            let output = Self.runUnlessCancelled(requestToken) {
                self.runOnce(
                    modelPath: modelPath, systemPrompt: systemPrompt, schema: schema,
                    snapshot: snapshot, maxNewTokens: maxNewTokens)
            }
            // The caller may still record a completed raw answer locally, but
            // must gate its adoption against the token and plan generation.
            completion(output)
        }
    }

    static func runUnlessCancelled(
        _ token: CNeedleRequestToken?, work: () -> String?
    ) -> String? {
        guard token?.isCancelled != true else { return nil }
        return work()
    }

    /// Synchronous harness seam. It still executes on the same process-wide
    /// serial queue, so production and integration adapters cannot race the C
    /// session even when they use different calling styles.
    public func completeSync(
        modelPath: String,
        systemPrompt: String,
        schema: String,
        snapshot: String,
        maxNewTokens: Int
    ) -> String? {
        queue.sync {
            runOnce(
                modelPath: modelPath, systemPrompt: systemPrompt, schema: schema,
                snapshot: snapshot, maxNewTokens: maxNewTokens)
        }
    }

    private func runOnce(
        modelPath: String,
        systemPrompt: String,
        schema: String,
        snapshot: String,
        maxNewTokens: Int
    ) -> String? {
        if loadedModelPath != modelPath {
            guard loadModel(at: modelPath) else { return nil }
            loadedModelPath = modelPath
            initializedSystemPrompt = nil
            initializedSchema = nil
        }
        if systemPrompt != initializedSystemPrompt || schema != initializedSchema {
            guard needle_init(systemPrompt, schema, nil) >= 0 else { return nil }
            initializedSystemPrompt = systemPrompt
            initializedSchema = schema
        } else {
            needle_reset()
        }
        buffer.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        let result = needle_complete(
            snapshot, Int32(max(1, maxNewTokens)), &buffer, Int32(buffer.count))
        guard result >= 0 else { return nil }
        return String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8)
    }

    private func loadModel(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return data.withUnsafeBytes { raw in
            needle_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt64(raw.count)) >= 0
        }
    }
}
