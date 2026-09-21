import Foundation

public struct OpenAIEndpointConfiguration: Sendable, Equatable {
    public var baseURL: String
    public var apiKey: String

    public init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

/// Stateless OpenAI-compatible transport. It owns HTTP construction and wire
/// decoding but knows nothing about goals, speech, actors or runtime state.
public enum OpenAIHTTPClient {
    public static func endpoint(_ configuration: OpenAIEndpointConfiguration, path: String) -> URL? {
        URL(string: configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
    }

    @discardableResult
    public static func complete(
        configuration: OpenAIEndpointConfiguration,
        request: [String: Any],
        session: URLSession = .shared,
        completion: @escaping (String?) -> Void
    ) -> URLSessionTask? {
        guard let url = endpoint(configuration, path: "/chat/completions") else {
            completion(nil)
            return nil
        }
        var requestValue = URLRequest(url: url, timeoutInterval: 30)
        requestValue.httpMethod = "POST"
        requestValue.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            requestValue.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        requestValue.httpBody = try? JSONSerialization.data(withJSONObject: request)
        let task = session.dataTask(with: requestValue) { data, _, _ in
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                completion(nil)
                return
            }
            if let content = message["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completion(content)
            } else {
                completion(message["reasoning_content"] as? String)
            }
        }
        task.resume()
        return task
    }

    public static func probeModels(
        configuration: OpenAIEndpointConfiguration,
        session: URLSession = .shared,
        completion: @escaping ([String], Error?) -> Void
    ) {
        guard let url = endpoint(configuration, path: "/models") else {
            completion([], URLError(.badURL))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        session.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion([], error ?? URLError(.cannotParseResponse))
                return
            }
            let ids: [String]
            if let list = object["data"] as? [[String: Any]] {
                ids = list.compactMap { $0["id"] as? String }
            } else if let list = object["models"] as? [[String: Any]] {
                ids = list.compactMap { $0["name"] as? String }
            } else {
                ids = []
            }
            completion(ids, nil)
        }.resume()
    }
}
