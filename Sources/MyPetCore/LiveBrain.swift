import Foundation

/// Harness 的 live brain 配置。桌面端的 MLX 本地脑仍由 MyPet 目标负责；
/// 这里提供一个无 AppKit 依赖的 OpenAI-compatible 通道，便于在 CMD 中调用
/// 已配置的 Qwen/llama.cpp 服务，并把响应交回同一个 GameKernel。
public struct LiveBrainConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var maxTokens: Int
    public var intervalTicks: Int64
    public var timeoutSeconds: Double

    public init(
        baseURL: String,
        model: String,
        apiKey: String = "",
        maxTokens: Int = 160,
        intervalTicks: Int64 = 20,
        timeoutSeconds: Double = 20
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey
        self.maxTokens = max(1, maxTokens)
        self.intervalTicks = max(1, intervalTicks)
        self.timeoutSeconds = max(0.1, timeoutSeconds)
    }

    public var isComplete: Bool { !baseURL.isEmpty && !model.isEmpty }

    public static func fromEnvironment(
        mode: BrainMode,
        baseURL: String? = nil,
        model: String? = nil,
        apiKey: String? = nil
    ) -> LiveBrainConfiguration {
        let env = ProcessInfo.processInfo.environment
        let prefix = mode == .teacher ? "MYPET_TEACHER" : "MYPET_LOCAL_BRAIN"
        return LiveBrainConfiguration(
            baseURL: baseURL ?? env["\(prefix)_BASE_URL"] ?? "",
            model: model ?? env["\(prefix)_MODEL"] ?? "",
            apiKey: apiKey ?? env["\(prefix)_KEY"] ?? "",
            maxTokens: Int(env["\(prefix)_MAX_TOKENS"] ?? "160") ?? 160,
            intervalTicks: Int64(env["\(prefix)_INTERVAL_TICKS"] ?? "20") ?? 20,
            timeoutSeconds: Double(env["\(prefix)_TIMEOUT_SECONDS"] ?? "20") ?? 20)
    }

    public var chatCompletionsURL: URL? {
        guard let url = URL(string: baseURL) else { return nil }
        if url.path.hasSuffix("/chat/completions") { return url }
        return url.appendingPathComponent("chat/completions")
    }
}

public struct LiveBrainResult: Codable, Equatable, Sendable {
    public let tick: Int64
    public let requested: Bool
    public let enqueued: Bool
    public let reason: String
    public let latencyMilliseconds: Int
    /// Raw local model output. The harness is a local training recorder and
    /// intentionally does not redact or summarize this field.
    public let rawOutput: String?
    public let trajectoryID: String?
    public let actor: String?
    public let modelInput: String?
    public let orderedOptions: [String]?
    public let chosen: String?
    public let providerID: String?

    public init(
        tick: Int64,
        requested: Bool,
        enqueued: Bool,
        reason: String,
        latencyMilliseconds: Int = 0,
        rawOutput: String? = nil,
        trajectoryID: String? = nil,
        actor: String? = nil,
        modelInput: String? = nil,
        orderedOptions: [String]? = nil,
        chosen: String? = nil,
        providerID: String? = nil
    ) {
        self.tick = tick
        self.requested = requested
        self.enqueued = enqueued
        self.reason = reason
        self.latencyMilliseconds = latencyMilliseconds
        self.rawOutput = rawOutput
        self.trajectoryID = trajectoryID
        self.actor = actor
        self.modelInput = modelInput
        self.orderedOptions = orderedOptions
        self.chosen = chosen
        self.providerID = providerID
    }
}

/// 一次同步 live 调用。Harness 是命令行工具，阻塞该命令直到网络调用结束是
/// 可观察且可记录的；桌面端则使用自己的异步 TeacherBrain/LocalBrain。
public final class LiveBrainAdapter {
    public let mode: BrainMode
    public let configuration: LiveBrainConfiguration
    public let status: BrainBackendStatus

    private let session: URLSession
    private var nextRequestTick: Int64 = 0

    public init(
        mode: BrainMode,
        configuration: LiveBrainConfiguration,
        session: URLSession = .shared
    ) {
        self.mode = mode
        self.configuration = configuration
        self.session = session
        if configuration.isComplete, configuration.chatCompletionsURL != nil {
            status = BrainBackendStatus(mode: mode, available: true, reason: "live_http_configured")
        } else {
            status = BrainBackendStatus(mode: mode, available: false, reason: "live_http_config_missing")
        }
    }

    /// 在有角色且到达请求边界时调用模型。返回行为请求后仍由 GameKernel
    /// 做 plan epoch、占槽、抢占和实体生存性校验。
    @discardableResult
    public func maybeEnqueue(in kernel: GameKernel) -> LiveBrainResult {
        let tick = kernel.clock.tick
        guard status.available else {
            return LiveBrainResult(tick: tick, requested: false, enqueued: false, reason: status.reason)
        }
        guard tick >= nextRequestTick else {
            return LiveBrainResult(tick: tick, requested: false, enqueued: false, reason: "interval")
        }
        guard kernel.runningBehaviorStates.isEmpty else {
            return LiveBrainResult(tick: tick, requested: false, enqueued: false, reason: "behavior_running")
        }
        let started = Date()
        nextRequestTick = tick + configuration.intervalTicks
        do {
            let data = try requestData(world: kernel.world, tick: tick)
            guard let content = Self.responseContent(data),
                  let request = Self.parseBehavior(content, world: kernel.world, tick: tick) else {
                return LiveBrainResult(
                    tick: tick, requested: true, enqueued: false, reason: "invalid_model_json",
                    latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
            }
            kernel.enqueue(GameEvent(kind: .behaviorRequest, request: request), atTick: tick)
            return LiveBrainResult(
                tick: tick, requested: true, enqueued: true, reason: "behavior_enqueued",
                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return LiveBrainResult(
                tick: tick, requested: true, enqueued: false,
                reason: "http_error:\(Self.safeReason(error))",
                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
        }
    }

    public static func behaviorSystemPrompt() -> String {
        """
        You are a desktop-pet game brain. Return ONLY one JSON object with this shape:
        {"actor_id":"alive actor id","intent":"short semantic intent","priority":"ambient|brainReactive|urgentReactive|story|userDirect","duration_ticks":1,"slot":"optional slot key","target":"optional entity id"}
        Never emit coordinates, UI commands, relation values, or effects. Choose only an alive actor and an intent useful for the current world.
        """
    }

    public static func worldPrompt(world: WorldState, tick: Int64) -> String {
        let entities = world.entities.values.sorted { $0.id.raw < $1.id.raw }.map {
            ["id": $0.id.raw, "kind": $0.kind.rawValue, "alive": $0.alive, "revision": $0.revision] as [String: Any]
        }
        let slots = world.slots.values.sorted { $0.key < $1.key }.map {
            ["key": $0.key, "status": $0.status.rawValue, "capacity": $0.capacity,
             "occupants": $0.occupants.map { $0.actorID.raw }] as [String: Any]
        }
        let object: [String: Any] = [
            "tick": tick,
            "entities": entities,
            "slots": slots,
            "running_behaviors": world.behaviors.values.filter { $0.status == .running }.map {
                ["id": $0.request.id, "actor_id": $0.request.actorID.raw,
                 "intent": $0.request.intent, "remaining_ticks": $0.remainingTicks]
            },
            "facts": world.facts.keys.sorted(),
            "relations": world.relationValues,
            "input_observations": world.inputObservations.values.map { observation -> [String: Any] in
                let bundleID: Any = observation.bundleID.map { $0 as Any } ?? NSNull()
                let expiresAtTick: Any = observation.expiresAtTick.map { $0 as Any } ?? NSNull()
                return ["plugin": observation.pluginID, "channel": observation.channel.rawValue,
                        "app": observation.appName, "bundle_id": bundleID,
                        "window_title": observation.windowTitle, "text": observation.text,
                        "captured_at_tick": observation.capturedAtTick,
                        "expires_at_tick": expiresAtTick]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 允许模型输出裸 JSON 或 markdown code fence；其余格式一律拒绝。
    public static func parseBehavior(_ text: String, world: WorldState, tick: Int64) -> BehaviorRequest? {
        let candidates = jsonObjects(in: text)
        guard !candidates.isEmpty else { return nil }
        let alive = world.entities.values
            .filter { $0.alive && $0.kind == .actor }
            .sorted { $0.id.raw < $1.id.raw }
        guard let defaultActor = alive.first else { return nil }
        for raw in candidates.reversed() {
            let object = (raw["behavior"] as? [String: Any]) ?? raw
            let actorID = EntityID(rawString(object, keys: ["actor_id", "actorID"]) ?? defaultActor.id.raw)
            guard world.isAlive(actorID), world.entity(actorID)?.kind == .actor,
                  let intent = rawString(object, keys: ["intent"]), !intent.isEmpty else { continue }
            let priority = parsePriority(object["priority"]) ?? .ambient
            let duration = max(1, (object["duration_ticks"] as? NSNumber)?.int64Value ?? 1)
            let target = (object["target"] as? String).flatMap { id -> EntityRef? in
                world.entity(EntityID(id))?.ref
            }
            let slot = (object["slot"] as? String).flatMap { world.slots[$0]?.ref }
            let claims = (object["claims"] as? [String]) ?? ["body"]
            let requestID = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "live-\(tick)-\(actorID.raw)-\(intent)"
            return BehaviorRequest(
                id: requestID,
                actorID: actorID,
                intent: intent,
                priority: priority,
                planEpoch: world.planEpochs[actorID.raw, default: 0],
                target: target,
                slot: slot,
                claims: claims,
                durationTicks: duration,
                occupySlotOnSuccess: object["occupy_slot"] as? Bool ?? false)
        }
        return nil
    }

    private static func rawString(_ object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { object[$0] as? String }.first
    }

    /// Extract balanced JSON objects from plain text, fences, or a model's
    /// reasoning transcript without accepting arbitrary non-JSON text.
    private static func jsonObjects(in text: String) -> [[String: Any]] {
        var candidates: [[String: Any]] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if let objectStart = start {
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(text[objectStart...index])
                        if let data = candidate.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            candidates.append(object)
                        }
                        start = nil
                    }
                }
            } else if character == "{" {
                start = index
                depth = 1
                inString = false
                escaped = false
            }
        }
        return candidates
    }

    private func requestData(world: WorldState, tick: Int64) throws -> Data {
        guard let url = configuration.chatCompletionsURL else { throw URLError(.badURL) }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": Self.behaviorSystemPrompt()],
                ["role": "user", "content": Self.worldPrompt(world: world, tick: tick)],
            ],
            "temperature": 0,
            "max_tokens": configuration.maxTokens,
            "response_format": ["type": "json_object"],
        ]
        if configuration.model.localizedCaseInsensitiveContains("qwen") {
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        let requestData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = requestData
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>!
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = .failure(NSError(domain: "LiveBrain", code: status,
                                           userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]))
                return
            }
            result = .success(data)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + configuration.timeoutSeconds + 1)
        if case .some(.success(let data)) = result { return data }
        if case .some(.failure(let error)) = result { throw error }
        task.cancel()
        throw URLError(.timedOut)
    }

    private static func responseContent(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return message["reasoning_content"] as? String
    }

    private static func parsePriority(_ value: Any?) -> PriorityBand? {
        if let number = value as? NSNumber { return PriorityBand(rawValue: number.intValue) }
        if let text = value as? String {
            if let raw = Int(text), let priority = PriorityBand(rawValue: raw) { return priority }
            switch text {
            case "userDirect": return .userDirect
            case "urgentReactive": return .urgentReactive
            case "brainReactive": return .brainReactive
            case "story": return .story
            case "ambient": return .ambient
            default: return nil
            }
        }
        return nil
    }

    private static func safeReason(_ error: Error) -> String {
        error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            .prefix(160).description
    }
}
