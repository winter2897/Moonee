import Foundation
import Security
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol LLM {
    func complete(system: String, user: String) async throws -> String
}

struct LLMError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum LLMProvider: String, CaseIterable {
    case remote, apple
    var title: String { self == .remote ? "OpenRouter" : "Trên máy" }
}

/// Provider choice + remote config. Model/base URL in AppStorage, API key in Keychain.
enum LLMSettings {
    static let providerKey = "ai.provider"
    static let modelKey = "ai.model"
    static let baseURLKey = "ai.baseURL"
    static let defaultModel = "google/gemini-3.5-flash-lite"
    static let defaultBaseURL = "https://openrouter.ai/api/v1"

    static var provider: LLMProvider {
        LLMProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .remote
    }

    /// The configured provider, or an error saying what to set up.
    static func current() throws -> LLM {
        switch provider {
        case .remote:
            guard let key = apiKey, !key.isEmpty else { throw LLMError("Chưa nhập API key OpenRouter") }
            let d = UserDefaults.standard
            return OpenRouterLLM(
                baseURL: d.string(forKey: baseURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL,
                apiKey: key,
                model: d.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel)
        case .apple:
            #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                guard SystemLanguageModel.default.isAvailable else { throw LLMError(appleStatus) }
                return AppleLLM()
            }
            #endif
            throw LLMError(appleStatus)
        }
    }

    static var appleStatus: String {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Sẵn sàng (Apple Intelligence, model do hệ thống quản lý)"
            case .unavailable(.deviceNotEligible): return "Thiết bị không hỗ trợ Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled): return "Hãy bật Apple Intelligence trong Cài đặt"
            case .unavailable(.modelNotReady): return "Hệ thống đang tải model, thử lại sau"
            case .unavailable: return "Model trên máy chưa sẵn sàng"
            }
        }
        #endif
        return "Cần iOS 26 trở lên"
    }

    // MARK: Keychain

    private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "moonee.ai",
        kSecAttrAccount as String: "openrouter",
    ]

    static var apiKey: String? {
        get {
            var q = keychainQuery
            q[kSecReturnData as String] = true
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(keychainQuery as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var q = keychainQuery
            q[kSecValueData as String] = Data(newValue.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock // readable by background refresh
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

/// OpenAI/OpenRouter-compatible `/chat/completions`.
struct OpenRouterLLM: LLM {
    let baseURL: String
    let apiKey: String
    let model: String

    func complete(system: String, user: String) async throws -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/ ")) + "/chat/completions") else {
            throw LLMError("Base URL không hợp lệ")
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("Moonee", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        struct Reply: Decodable {
            struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
            struct Err: Decodable { let message: String }
            let choices: [Choice]?
            let error: Err?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if let content = reply?.choices?.first?.message.content { return content }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        throw LLMError("Lỗi \(code): \(reply?.error?.message ?? String(decoding: data.prefix(200), as: UTF8.self))")
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
struct AppleLLM: LLM {
    func complete(system: String, user: String) async throws -> String {
        try await LanguageModelSession(instructions: system).respond(to: user).content
    }
}
#endif
