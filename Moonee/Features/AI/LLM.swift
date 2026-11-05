import Foundation
import FoundationModels
import Security

/// A chat model Moonee can use: Apple on-device, a local open model (later) or a BYOK cloud model.
/// Models never compute money (spec §9.3): they call `AITool`s (Swift) for numbers, then explain.
protocol LLM: Sendable {
    /// Small on-device models get the short skill text and pre-computed tool results instead of tool calls.
    var isSmall: Bool { get }
    /// Runs the tool loop (the model may call `request.tools` several times) and returns the final text.
    func respond(_ request: LLMRequest) async throws -> String
    /// Structured read of a chat message. Default: JSON through `respond`; Foundation Models uses `@Generable`.
    func extractTransactions(instructions: String, text: String) async throws -> [AIParsedTxn]
}

struct LLMMessage: Sendable, Equatable {
    enum Role: String, Sendable { case user, assistant }
    var role: Role
    var text: String
}

struct LLMRequest: Sendable {
    var system: String
    var messages: [LLMMessage]
    var tools: [AITool] = []
    /// Ask for one JSON object and nothing else.
    var json = false

    static let maxToolRounds = 6
}

struct LLMError: LocalizedError, Equatable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension LLM {
    var isSmall: Bool { false }

    func complete(system: String, user: String) async throws -> String {
        try await respond(LLMRequest(system: system, messages: [.init(role: .user, text: user)]))
    }

    func extractTransactions(instructions: String, text: String) async throws -> [AIParsedTxn] {
        let reply = try await respond(LLMRequest(
            system: instructions + "\n\n" + AIParsedTxn.jsonInstructions, messages: [.init(role: .user, text: text)], json: true))
        return try AIParsedTxn.decodeList(reply)
    }
}

// MARK: - Tools

/// A tiny JSON Schema subset. Becomes JSON Schema for cloud models and `DynamicGenerationSchema` for Foundation Models.
indirect enum Schema: Sendable {
    case string(String? = nil, oneOf: [String]? = nil)
    case integer(String? = nil)
    case number(String? = nil)
    case boolean(String? = nil)
    case array(Schema, String? = nil)
    case object([Property], String? = nil)

    struct Property: Sendable {
        var name: String
        var schema: Schema
        var required = false
        init(_ name: String, _ schema: Schema, required: Bool = false) { (self.name, self.schema, self.required) = (name, schema, required) }
    }

    var summary: String? {
        switch self {
        case .string(let d, _), .integer(let d), .number(let d), .boolean(let d), .array(_, let d), .object(_, let d): d
        }
    }

    var json: [String: Any] {
        var out: [String: Any]
        switch self {
        case .string(_, let oneOf):
            out = ["type": "string"]
            if let oneOf { out["enum"] = oneOf }
        case .integer: out = ["type": "integer"]
        case .number: out = ["type": "number"]
        case .boolean: out = ["type": "boolean"]
        case .array(let item, _): out = ["type": "array", "items": item.json]
        case .object(let props, _):
            out = ["type": "object", "properties": Dictionary(uniqueKeysWithValues: props.map { ($0.name, $0.schema.json) })]
            let required = props.filter(\.required).map(\.name)
            if !required.isEmpty { out["required"] = required }
        }
        if let summary { out["description"] = summary }
        return out
    }

    func dynamic(name: String) -> DynamicGenerationSchema {
        switch self {
        case .string(_, let oneOf?): .init(name: name, description: summary, anyOf: oneOf)
        case .string: .init(type: String.self)
        case .integer: .init(type: Int.self)
        case .number: .init(type: Double.self)
        case .boolean: .init(type: Bool.self)
        case .array(let item, _): .init(arrayOf: item.dynamic(name: name + "Item"))
        case .object(let props, let d):
            .init(name: name, description: d, properties: props.map {
                .init(name: $0.name, description: $0.schema.summary, schema: $0.schema.dynamic(name: name + "_" + $0.name), isOptional: !$0.required)
            })
        }
    }
}

/// A Swift function a model may call (spec §9.3): name, argument schema, closure. JSON in, JSON out.
struct AITool: Sendable {
    let name: String
    let description: String
    /// Always an `.object`.
    let parameters: Schema
    let run: @Sendable (Data) async throws -> String

    init(name: String, description: String, parameters: Schema, run: @escaping @Sendable (Data) async throws -> String) {
        (self.name, self.description, self.parameters, self.run) = (name, description, parameters, run)
    }

    /// Typed convenience: decodes `Args` from the model's JSON, encodes the result as JSON.
    init<Args: Decodable, Out: Encodable>(name: String, description: String, parameters: Schema,
                                          typed: @escaping @Sendable (Args) async throws -> Out) {
        self.init(name: name, description: description, parameters: parameters) { data in
            let args = try JSONDecoder().decode(Args.self, from: data.isEmpty ? Data("{}".utf8) : data)
            return try AITool.encode(try await typed(args))
        }
    }

    static func encode(_ value: some Encodable) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }
}

extension Array where Element == AITool {
    /// Never throws: an unknown tool or a failure becomes `{"error": …}` so the model can recover.
    func call(_ name: String, arguments: Data) async -> String {
        guard let tool = first(where: { $0.name == name }) else { return #"{"error":"unknown tool \#(name)"}"# }
        do { return try await tool.run(arguments) } catch {
            return (try? AITool.encode(["error": String(describing: error)])) ?? #"{"error":"failed"}"#
        }
    }
}

// MARK: - HTTP

typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum HTTP {
    static let live: HTTPTransport = { try await URLSession.shared.data(for: $0) }

    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any], send: HTTPTransport) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code), let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw LLMError("HTTP \(code): \(message)")
        }
        return json
    }
}

// MARK: - Settings

enum LLMProvider: String, CaseIterable {
    case remote, apple
    var title: String { self == .remote ? "OpenRouter" : "Trên máy" }
}

/// AI mode of spec §9.1.
enum AIMode: String, CaseIterable, Sendable {
    case onDevice, local, byok, hybrid
}

/// BYOK providers. OpenRouter and any OpenAI-style server use `openAICompatible`.
enum CloudProvider: String, CaseIterable, Sendable {
    case openAICompatible, anthropic, gemini

    var keychainAccount: String { self == .openAICompatible ? "openrouter" : rawValue }
    var modelKey: String { self == .openAICompatible ? LLMSettings.modelKey : "ai.model.\(rawValue)" }
    var defaultModel: String {
        switch self {
        case .openAICompatible: LLMSettings.defaultModel
        case .anthropic: "claude-sonnet-5-5"
        case .gemini: "gemini-3.5-flash"
        }
    }
}

/// Provider choice + remote config. Model/base URL in AppStorage, API keys in Keychain.
enum LLMSettings {
    static let providerKey = "ai.provider"
    static let modelKey = "ai.model"
    static let baseURLKey = "ai.baseURL"
    static let modeKey = "ai.mode"
    static let cloudKey = "ai.cloud"
    static let defaultModel = "google/gemini-3.5-flash-lite"
    static let defaultBaseURL = "https://openrouter.ai/api/v1"

    static var provider: LLMProvider {
        LLMProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .remote
    }

    /// Stored mode; until the user picks one it follows the older provider switch.
    static var mode: AIMode {
        AIMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? (provider == .apple ? .onDevice : .byok)
    }

    static var cloudProvider: CloudProvider {
        CloudProvider(rawValue: UserDefaults.standard.string(forKey: cloudKey) ?? "") ?? .openAICompatible
    }

    /// The models the current settings allow, for `Assistant`.
    static func router() -> AIRouter {
        AIRouter(mode: mode, onDevice: AppleLLM.isAvailable ? AppleLLM() : nil, local: nil, cloud: cloud(cloudProvider))
    }

    /// A configured BYOK model, or nil when it has no key.
    static func cloud(_ p: CloudProvider) -> (any LLM)? {
        guard let key = apiKey(for: p), !key.isEmpty else { return nil }
        let model = UserDefaults.standard.string(forKey: p.modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel
        switch p {
        case .openAICompatible:
            let base = UserDefaults.standard.string(forKey: baseURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
            return OpenAICompatibleLLM(baseURL: base, apiKey: key, model: model)
        case .anthropic: return AnthropicLLM(apiKey: key, model: model)
        case .gemini: return GeminiLLM(apiKey: key, model: model)
        }
    }

    /// The model the older two-way switch picks, or an error saying what to set up (used by the settings test button).
    static func current() throws -> any LLM {
        switch provider {
        case .remote:
            guard let llm = cloud(.openAICompatible) else { throw LLMError("Chưa nhập API key OpenRouter") }
            return llm
        case .apple:
            guard AppleLLM.isAvailable else { throw LLMError(appleStatus) }
            return AppleLLM()
        }
    }

    static var appleStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Sẵn sàng (Apple Intelligence, model do hệ thống quản lý)"
        case .unavailable(.deviceNotEligible): "Thiết bị không hỗ trợ Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): "Hãy bật Apple Intelligence trong Cài đặt"
        case .unavailable(.modelNotReady): "Hệ thống đang tải model, thử lại sau"
        case .unavailable: "Model trên máy chưa sẵn sàng"
        }
    }

    /// OpenRouter / OpenAI-compatible key (older settings screen).
    static var apiKey: String? {
        get { apiKey(for: .openAICompatible) }
        set { setAPIKey(newValue, for: .openAICompatible) }
    }

    static func apiKey(for p: CloudProvider) -> String? { Keychain.get(p.keychainAccount) }
    static func setAPIKey(_ key: String?, for p: CloudProvider) { Keychain.set(key, account: p.keychainAccount) }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "moonee.ai", kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock // readable by background refresh
        SecItemAdd(q as CFDictionary, nil)
    }
}
