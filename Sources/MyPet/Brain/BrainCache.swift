import Foundation
import MyPetAI

struct BrainMemoryLRU<Value> {
    private(set) var values: [String: Value] = [:]
    private(set) var order: [String] = []

    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    mutating func insert(_ value: Value, for key: String, capacity: Int) {
        values[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        trim(capacity: capacity)
    }

    mutating func trim(capacity: Int) {
        while order.count > max(0, capacity), let oldest = order.first {
            order.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }
}

/// App-side cache identity policy. MLX cache objects and persistence live in
/// MyPetAI; this value builder only describes when a prompt cache is stale.
enum BrainCacheManager {
    struct Key: Equatable {
        var model: String
        var tokenizer: String
        var chatTemplate: String
        var brainPrompt: Int
        var actionSchema: Int
        var fewshot: Int
        var personality: String
        var adapter: String
        var profileHash: String
        var promptKind: String

        var composite: String {
            [model, tokenizer, chatTemplate, "brain-v\(brainPrompt)",
             "actions-v\(actionSchema)", "fewshot-v\(fewshot)", personality,
             "lora-\(adapter)", "profile-\(profileHash)", "prompt-\(promptKind)"]
                .joined(separator: "/")
        }

        var hash8: String { MLXPromptCacheIdentity.hash8(composite) }
    }

    static var cacheDirectory: URL {
        MLXPromptCacheIdentity.cacheDirectory
    }

    static func fileURL(petID: String, key: Key) -> URL {
        MLXPromptCacheIdentity.fileURL(
            petID: petID, cacheKey: key.composite, promptVersion: key.brainPrompt)
    }

    static func makeKey(
        petID: String, personality: Personality, profile: BrainProfile,
        modelDir: URL, promptKind: String = "goal", promptVersion: Int? = nil,
        contentHash: String = "-"
    ) -> Key {
        let templateURL = modelDir.appendingPathComponent("chat_template.jinja")
        let templateHash = (try? Data(contentsOf: templateURL)).map {
            BrainProfile.sha8(String(data: $0.prefix(64 * 1024), encoding: .utf8) ?? "-")
        } ?? "none"
        return Key(
            model: modelDir.lastPathComponent, tokenizer: templateHash,
            chatTemplate: "jinja", brainPrompt: promptVersion ?? BrainPrefixBuilder.brainPromptVersion,
            actionSchema: BrainPrefixBuilder.actionSchemaVersion,
            fewshot: BrainPrefixBuilder.fewshotVersion,
            personality: "\(petID)-\(BrainProfile.sha8(personality.promptSection))",
            adapter: "none", profileHash: BrainProfile.sha8(profile.prefixHash + "/" + contentHash),
            promptKind: promptKind)
    }

    static func pruneDiskCache(maxEntries: Int, directory: URL = cacheDirectory) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let caches = files.filter { $0.pathExtension == "safetensors" }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        for url in caches.dropFirst(max(0, maxEntries)) { try? FileManager.default.removeItem(at: url) }
    }

    static func sendableMessages(_ messages: [[String: String]]) -> [[String: any Sendable]] {
        messages.map { $0.mapValues { $0 as any Sendable } }
    }
}
