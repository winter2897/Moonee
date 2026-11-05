import Foundation

/// A model a BYOK key can use, from the provider's own models endpoint. The metadata fields are filled
/// only where the provider says (OpenRouter: context, price, supported parameters).
struct CloudModel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String?
    var contextLength: Int?
    /// USD per million tokens.
    var promptPrice: Double?
    var completionPrice: Double?
    /// From OpenRouter's `supported_parameters`; nil = the provider doesn't say.
    var tools: Bool?
    var structuredOutputs: Bool?
    /// Accepts a reasoning effort (OpenRouter `reasoning`); nil = the provider doesn't say.
    var reasoning: Bool?

    var isFree: Bool { id.hasSuffix(":free") || (promptPrice == 0 && completionPrice == 0) }
    /// Moonee calls tools and asks for JSON; models known to do both sort first.
    var fitsMoonee: Bool { tools == true && structuredOutputs == true }
}

/// A BYOK client that can also list its models.
protocol CloudLLM: LLM {
    func listModels() async throws -> [CloudModel]
}

extension CloudModel {
    /// OpenAI-style `{"data":[{"id":…}]}`; OpenRouter adds name, context_length, pricing (USD per token, as strings)
    /// and supported_parameters.
    static func decodeOpenAI(_ json: [String: Any]) -> [CloudModel] {
        (json["data"] as? [[String: Any]] ?? []).compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            let pricing = m["pricing"] as? [String: Any]
            func perMillion(_ key: String) -> Double? {
                // OpenRouter's routers ("openrouter/auto") report -1: unknown, not a price.
                (pricing?[key] as? String).flatMap(Double.init).flatMap { $0 < 0 ? nil : ($0 * 1_000_000 * 1000).rounded() / 1000 }
            }
            let params = m["supported_parameters"] as? [String]
            return CloudModel(id: id, name: m["name"] as? String, contextLength: m["context_length"] as? Int,
                              promptPrice: perMillion("prompt"), completionPrice: perMillion("completion"),
                              tools: params.map { $0.contains("tools") },
                              structuredOutputs: params.map { $0.contains("structured_outputs") || $0.contains("response_format") },
                              reasoning: params.map { $0.contains("reasoning") })
        }
    }

    /// Anthropic `{"data":[{"id","display_name"}]}`.
    static func decodeAnthropic(_ json: [String: Any]) -> [CloudModel] {
        (json["data"] as? [[String: Any]] ?? []).compactMap { m in
            (m["id"] as? String).map { CloudModel(id: $0, name: m["display_name"] as? String) }
        }
    }

    /// Gemini `{"models":[{"name":"models/…","displayName","inputTokenLimit","supportedGenerationMethods"}]}`;
    /// only models that can `generateContent` (no embedding/TTS-only models).
    static func decodeGemini(_ json: [String: Any]) -> [CloudModel] {
        (json["models"] as? [[String: Any]] ?? []).compactMap { m in
            guard let name = m["name"] as? String,
                  (m["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            return CloudModel(id: id, name: m["displayName"] as? String, contextLength: m["inputTokenLimit"] as? Int)
        }
    }

    /// Moonee-ready first (tools + structured output), then by name.
    static func sorted(_ models: [CloudModel]) -> [CloudModel] {
        models.sorted { a, b in
            a.fitsMoonee != b.fitsMoonee ? a.fitsMoonee : (a.name ?? a.id).localizedStandardCompare(b.name ?? b.id) == .orderedAscending
        }
    }
}

extension OpenAICompatibleLLM: CloudLLM {
    func listModels() async throws -> [CloudModel] {
        let base = baseURL.trimmingCharacters(in: .init(charactersIn: "/ "))
        guard let url = URL(string: base + "/models"), url.scheme != nil else { throw LLMError("Invalid base URL") }
        // OpenRouter lists models without a key, so check the key itself first (401 when it is wrong).
        if url.host() == "openrouter.ai", let keyURL = URL(string: base + "/key") {
            _ = try await HTTP.getJSON(keyURL, headers: ["Authorization": "Bearer \(apiKey)"], send: send)
        }
        return CloudModel.sorted(CloudModel.decodeOpenAI(try await HTTP.getJSON(url, headers: ["Authorization": "Bearer \(apiKey)"], send: send)))
    }
}

extension AnthropicLLM: CloudLLM {
    func listModels() async throws -> [CloudModel] {
        guard let url = URL(string: baseURL + "/v1/models?limit=1000") else { throw LLMError("Invalid base URL") }
        let json = try await HTTP.getJSON(url, headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"], send: send)
        return CloudModel.decodeAnthropic(json) // already newest first
    }
}

extension GeminiLLM: CloudLLM {
    func listModels() async throws -> [CloudModel] {
        // The key goes in a header, never in the URL (URLs end up in logs).
        guard let url = URL(string: baseURL + "/models?pageSize=1000") else { throw LLMError("Invalid base URL") }
        return CloudModel.sorted(CloudModel.decodeGemini(try await HTTP.getJSON(url, headers: ["x-goog-api-key": apiKey], send: send)))
    }
}

/// Last model list per provider, in Caches. Custom's list belongs to its base URL: a new URL means no list.
struct ModelCache {
    struct Entry: Codable, Equatable {
        var baseURL: String
        var fetched: Date
        var models: [CloudModel]
    }

    var directory = URL.cachesDirectory.appending(path: "CloudModels")

    private func file(_ p: CloudProvider) -> URL { directory.appending(path: "\(p.rawValue).json") }

    func load(_ p: CloudProvider, baseURL: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(p)), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.baseURL == baseURL else { return nil }
        return entry
    }

    func save(_ models: [CloudModel], for p: CloudProvider, baseURL: String, now: Date = .now) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(baseURL: baseURL, fetched: now, models: models)).write(to: file(p), options: .atomic)
    }

    func clear() { try? FileManager.default.removeItem(at: directory) }
}
