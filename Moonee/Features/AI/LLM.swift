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
    /// HTTP status when the provider answered with an error (401/403 = bad key).
    var status: Int?
    init(_ message: String, status: Int? = nil) { (errorDescription, self.status) = (message, status) }
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
indirect enum ToolSchema: Sendable {
    case string(String? = nil, oneOf: [String]? = nil)
    case integer(String? = nil)
    case number(String? = nil)
    case boolean(String? = nil)
    case array(ToolSchema, String? = nil)
    case object([Property], String? = nil)

    struct Property: Sendable {
        var name: String
        var schema: ToolSchema
        var required = false
        init(_ name: String, _ schema: ToolSchema, required: Bool = false) { (self.name, self.schema, self.required) = (name, schema, required) }
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
    let parameters: ToolSchema
    let run: @Sendable (Data) async throws -> String

    init(name: String, description: String, parameters: ToolSchema, run: @escaping @Sendable (Data) async throws -> String) {
        (self.name, self.description, self.parameters, self.run) = (name, description, parameters, run)
    }

    /// Typed convenience: decodes `Args` from the model's JSON, encodes the result as JSON.
    init<Args: Decodable, Out: Encodable>(name: String, description: String, parameters: ToolSchema,
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
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await json(req, headers: headers, send: send)
    }

    static func getJSON(_ url: URL, headers: [String: String], send: HTTPTransport) async throws -> [String: Any] {
        try await json(URLRequest(url: url, timeoutInterval: 30), headers: headers, send: send)
    }

    private static func json(_ request: URLRequest, headers: [String: String], send: HTTPTransport) async throws -> [String: Any] {
        var req = request
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await send(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code), let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw LLMError("HTTP \(code): \(message)", status: code)
        }
        return json
    }
}

// MARK: - Settings

/// The first settings screen's two-way switch; only read now to pick the default `AIMode`.
enum LLMProvider: String, CaseIterable {
    case remote, apple
}

/// AI mode of spec §9.1.
enum AIMode: String, CaseIterable, Sendable {
    case onDevice, local, byok, hybrid
}

/// BYOK providers (spec §6.2). Each has its own Keychain account, stored model and base URL;
/// all but Anthropic and Gemini speak OpenAI's `/chat/completions`.
enum CloudProvider: String, CaseIterable, Sendable {
    case openRouter, deepSeek, openAI, anthropic, gemini, custom

    var keychainAccount: String { rawValue.lowercased() } // "openrouter" is where the first screen kept its key
    var modelKey: String { self == .openRouter ? LLMSettings.modelKey : "ai.model.\(rawValue)" }
    var isOpenAICompatible: Bool { self != .anthropic && self != .gemini }

    var defaultModel: String {
        switch self {
        case .openRouter: LLMSettings.defaultModel
        case .deepSeek: "deepseek-chat"
        case .openAI: "gpt-5-mini"
        case .anthropic: "claude-sonnet-5-5"
        case .gemini: "gemini-3.5-flash"
        case .custom: ""
        }
    }

    /// Fixed for every provider but Custom, whose URL the user types (`LLMSettings.baseURLKey`).
    var defaultBaseURL: String {
        switch self {
        case .openRouter: LLMSettings.defaultBaseURL
        case .deepSeek: "https://api.deepseek.com"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .custom: ""
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
    static let skillsOffKey = "ai.skillsOff"
    static let customPromptKey = "ai.customPrompt"
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
        CloudProvider(rawValue: UserDefaults.standard.string(forKey: cloudKey) ?? "") ?? .openRouter
    }

    static func baseURL(_ p: CloudProvider, defaults: UserDefaults = .standard) -> String {
        p == .custom ? (defaults.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespaces) : p.defaultBaseURL
    }

    static func model(_ p: CloudProvider, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: p.modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel
    }

    /// Before DeepSeek & co. there was one `openAICompatible` provider: with OpenRouter's URL (or none) it is
    /// OpenRouter; with another URL it becomes Custom, taking the key (Keychain) and model along. Runs once at launch.
    static func migrate(_ d: UserDefaults = .standard, moveKey: (_ from: String, _ to: String) -> Void = Keychain.move) {
        guard d.string(forKey: cloudKey) == "openAICompatible" else { return }
        let url = (d.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, url.trimmingCharacters(in: .init(charactersIn: "/")) != defaultBaseURL else {
            d.set(CloudProvider.openRouter.rawValue, forKey: cloudKey)
            return
        }
        moveKey(CloudProvider.openRouter.keychainAccount, CloudProvider.custom.keychainAccount)
        if let model = d.string(forKey: modelKey) {
            d.set(model, forKey: CloudProvider.custom.modelKey)
            d.removeObject(forKey: modelKey)
        }
        d.set(CloudProvider.custom.rawValue, forKey: cloudKey)
    }

    /// The models the current settings allow, for `Assistant`.
    static func router() -> AIRouter {
        AIRouter(mode: mode, onDevice: AppleLLM.isAvailable ? AppleLLM() : nil, local: LocalLLM.current, cloud: cloud(cloudProvider))
    }

    /// A configured BYOK model, or nil when it has no key.
    static func cloud(_ p: CloudProvider) -> (any LLM)? {
        guard let key = apiKey(for: p), !key.isEmpty, !model(p).isEmpty, !baseURL(p).isEmpty else { return nil }
        return client(p, key: key, model: model(p))
    }

    /// The BYOK client for a provider. `send` is injectable for tests.
    static func client(_ p: CloudProvider, key: String, model: String, baseURL url: String? = nil, send: @escaping HTTPTransport = HTTP.live) -> any CloudLLM {
        let base = url ?? baseURL(p)
        switch p {
        case .anthropic: return AnthropicLLM(apiKey: key, model: model, baseURL: base, send: send)
        case .gemini: return GeminiLLM(apiKey: key, model: model, baseURL: base, send: send)
        default: return OpenAICompatibleLLM(baseURL: base, apiKey: key, model: model, send: send)
        }
    }

    static var skillsOff: Set<String> { Set(UserDefaults.standard.stringArray(forKey: skillsOffKey) ?? []) }
    static var customPrompt: String {
        (UserDefaults.standard.string(forKey: customPromptKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var appleStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: String(localized: "Ready (Apple Intelligence, managed by iOS)", table: "Account")
        case .unavailable(.deviceNotEligible): String(localized: "This iPhone does not support Apple Intelligence", table: "Account")
        case .unavailable(.appleIntelligenceNotEnabled): String(localized: "Turn on Apple Intelligence in Settings", table: "Account")
        case .unavailable(.modelNotReady): String(localized: "iOS is still downloading the model, try again later", table: "Account")
        case .unavailable: String(localized: "The on-device model is not ready", table: "Account")
        }
    }

    /// OpenRouter key (filled from `.env` by DevSecrets).
    static var apiKey: String? {
        get { apiKey(for: .openRouter) }
        set { setAPIKey(newValue, for: .openRouter) }
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

    static func move(_ from: String, to: String) {
        guard let value = get(from) else { return }
        set(value, account: to)
        set(nil, account: from)
    }
}
