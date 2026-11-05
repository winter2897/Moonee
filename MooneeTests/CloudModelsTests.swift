import Foundation
import Testing
@testable import Moonee

/// BYOK providers: model lists per provider, the old-provider migration, the list cache, and DeepSeek
/// through the parse and tool paths. Canned replies only; nothing touches the network.
struct CloudModelsTests {
    static let openRouterModels: [String: Any] = ["data": [
        ["id": "deepseek/deepseek-chat", "name": "DeepSeek V3", "context_length": 163_840,
         "pricing": ["prompt": "0.00000027", "completion": "0.0000011"],
         "supported_parameters": ["tools", "tool_choice", "response_format", "temperature"]],
        ["id": "meta/llama-free:free", "name": "Llama (free)", "context_length": 8192,
         "pricing": ["prompt": "0", "completion": "0"], "supported_parameters": ["temperature"]],
        ["id": "openrouter/auto", "name": "Auto Router", "pricing": ["prompt": "-1", "completion": "-1"]],
        ["id": "anthropic/claude-sonnet", "name": "Claude Sonnet", "context_length": 200_000,
         "pricing": ["prompt": "0.000003", "completion": "0.000015"],
         "supported_parameters": ["tools", "structured_outputs"]],
    ]]

    // MARK: - Decoding

    @Test func openRouterListHasPricesCapabilitiesAndSortsMooneeReadyFirst() {
        let models = CloudModel.sorted(CloudModel.decodeOpenAI(Self.openRouterModels))
        #expect(models.map(\.id) == ["anthropic/claude-sonnet", "deepseek/deepseek-chat", "openrouter/auto", "meta/llama-free:free"])
        let deepseek = models[1]
        #expect(deepseek.contextLength == 163_840)
        #expect(deepseek.promptPrice == 0.27 && deepseek.completionPrice == 1.1)
        #expect(deepseek.tools == true && deepseek.structuredOutputs == true && !deepseek.isFree)
        #expect(models[3].isFree && models[3].tools == false)
        #expect(models[2].promptPrice == nil && !models[2].isFree) // -1 = unknown, not free
    }

    @Test func plainOpenAIListHasIdsOnly() {
        let models = CloudModel.decodeOpenAI(["object": "list", "data": [
            ["id": "deepseek-chat", "object": "model", "owned_by": "deepseek"],
            ["id": "deepseek-reasoner", "object": "model", "owned_by": "deepseek"], ["object": "model"],
        ]])
        #expect(models == [CloudModel(id: "deepseek-chat"), CloudModel(id: "deepseek-reasoner")])
        #expect(models[0].tools == nil && !models[0].fitsMoonee)
    }

    @Test func anthropicList() {
        let models = CloudModel.decodeAnthropic(["data": [
            ["type": "model", "id": "claude-sonnet-5-5", "display_name": "Claude Sonnet 5.5", "created_at": "2026-09-01T00:00:00Z"],
            ["type": "model", "id": "claude-haiku-5-5", "display_name": "Claude Haiku 5.5"],
        ], "has_more": false])
        #expect(models == [CloudModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"), CloudModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5")])
    }

    @Test func geminiListKeepsOnlyGenerateContentModels() {
        let models = CloudModel.decodeGemini(["models": [
            ["name": "models/gemini-3.5-flash", "displayName": "Gemini 3.5 Flash", "inputTokenLimit": 1_048_576,
             "supportedGenerationMethods": ["generateContent", "countTokens"]],
            ["name": "models/text-embedding-004", "displayName": "Text Embedding", "supportedGenerationMethods": ["embedContent"]],
        ]])
        #expect(models == [CloudModel(id: "gemini-3.5-flash", name: "Gemini 3.5 Flash", contextLength: 1_048_576)])
    }

    // MARK: - Requests

    @Test func deepSeekListsFromItsOwnEndpoint() async throws {
        let stub = StubTransport([["data": [["id": "deepseek-chat"]]]])
        let llm = LLMSettings.client(.deepSeek, key: "sk-ds", model: "", send: stub.send)
        #expect(try await llm.listModels().map(\.id) == ["deepseek-chat"])
        #expect(stub.requests[0].url?.absoluteString == "https://api.deepseek.com/models")
        #expect(stub.requests[0].httpMethod == "GET")
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer sk-ds")
    }

    @Test func openRouterChecksTheKeyBeforeListing() async throws {
        let stub = StubTransport([["data": ["label": "sk-or-…"]], Self.openRouterModels])
        let models = try await LLMSettings.client(.openRouter, key: "sk-or", model: "", send: stub.send).listModels()
        #expect(models.count == 4)
        #expect(stub.requests.map { $0.url!.absoluteString } == ["https://openrouter.ai/api/v1/key", "https://openrouter.ai/api/v1/models"])

        let bad = StubTransport(status: 401, body: ["error": ["message": "No auth credentials found", "code": 401]])
        await #expect(throws: LLMError("HTTP 401: No auth credentials found", status: 401)) {
            try await LLMSettings.client(.openRouter, key: "nope", model: "", send: bad.send).listModels()
        }
    }

    @Test func anthropicAndGeminiSendKeysInHeaders() async throws {
        let a = StubTransport([["data": [["id": "claude-sonnet-5-5"]]]])
        _ = try await LLMSettings.client(.anthropic, key: "sk-ant", model: "", send: a.send).listModels()
        #expect(a.requests[0].url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(a.requests[0].value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(a.requests[0].value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let g = StubTransport([["models": []]])
        _ = try await LLMSettings.client(.gemini, key: "AIza-secret", model: "", send: g.send).listModels()
        #expect(g.requests[0].url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
        #expect(g.requests[0].value(forHTTPHeaderField: "x-goog-api-key") == "AIza-secret")
    }

    @Test func listErrorsSayWhatToDo() {
        // Compared with the catalogue (not English text) so the test passes in every UI language.
        #expect(ModelPickerView.message(for: LLMError("HTTP 401: x", status: 401))
                == String(localized: "The provider rejected this key. Check it and try again.", table: "Account"))
        #expect(ModelPickerView.message(for: LLMError("HTTP 404: x", status: 404))
                == String(localized: "This server has no model list. Type a model ID instead.", table: "Account"))
        #expect(ModelPickerView.message(for: URLError(.notConnectedToInternet))
                == String(localized: "Can't reach the provider. Check your internet connection.", table: "Account"))
        #expect(ModelPickerView.message(for: LLMError("HTTP 500: boom", status: 500)) == "HTTP 500: boom")
    }

    // MARK: - Migration

    private func defaults() -> UserDefaults {
        let name = "CloudModelsTests.\(UUID())"
        return UserDefaults(suiteName: name)!
    }

    @Test(arguments: [nil, "", "https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1/"])
    func oldProviderWithOpenRouterURLBecomesOpenRouter(url: String?) {
        let d = defaults()
        d.set("openAICompatible", forKey: LLMSettings.cloudKey)
        d.set(url, forKey: LLMSettings.baseURLKey)
        d.set("google/gemini-3.5-flash-lite", forKey: LLMSettings.modelKey)
        var moves: [String] = []
        LLMSettings.migrate(d) { moves.append("\($0)→\($1)") }
        #expect(d.string(forKey: LLMSettings.cloudKey) == "openRouter")
        #expect(moves.isEmpty) // the key already lives under "openrouter"
        #expect(LLMSettings.model(.openRouter, defaults: d) == "google/gemini-3.5-flash-lite")
    }

    @Test func oldProviderWithAnotherURLBecomesCustom() {
        let d = defaults()
        d.set("openAICompatible", forKey: LLMSettings.cloudKey)
        d.set("http://192.168.1.5:1234/v1", forKey: LLMSettings.baseURLKey)
        d.set("qwen3-8b", forKey: LLMSettings.modelKey)
        var moves: [String] = []
        LLMSettings.migrate(d) { moves.append("\($0)→\($1)") }
        #expect(d.string(forKey: LLMSettings.cloudKey) == "custom")
        #expect(moves == ["openrouter→custom"])
        #expect(LLMSettings.model(.custom, defaults: d) == "qwen3-8b")
        #expect(LLMSettings.model(.openRouter, defaults: d) == LLMSettings.defaultModel)
        #expect(LLMSettings.baseURL(.custom, defaults: d) == "http://192.168.1.5:1234/v1")
    }

    @Test func migrationRunsOnlyOnTheOldValue() {
        let d = defaults()
        d.set("anthropic", forKey: LLMSettings.cloudKey)
        LLMSettings.migrate(d) { _, _ in Issue.record("moved a key") }
        #expect(d.string(forKey: LLMSettings.cloudKey) == "anthropic")
        #expect(Set(CloudProvider.allCases.map(\.keychainAccount)).count == CloudProvider.allCases.count)
        #expect(CloudProvider.openRouter.keychainAccount == "openrouter")
    }

    // MARK: - Cache

    @Test func cacheIsPerProviderAndPerBaseURL() throws {
        let cache = ModelCache(directory: URL.temporaryDirectory.appending(path: "ModelCache-\(UUID())"))
        defer { cache.clear() }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(cache.load(.deepSeek, baseURL: "https://api.deepseek.com") == nil)

        try cache.save([CloudModel(id: "deepseek-chat")], for: .deepSeek, baseURL: "https://api.deepseek.com", now: when)
        try cache.save([CloudModel(id: "qwen3")], for: .custom, baseURL: "http://a/v1", now: when)
        #expect(cache.load(.deepSeek, baseURL: "https://api.deepseek.com") == .init(baseURL: "https://api.deepseek.com", fetched: when, models: [CloudModel(id: "deepseek-chat")]))
        #expect(cache.load(.custom, baseURL: "http://a/v1")?.models.map(\.id) == ["qwen3"])
        #expect(cache.load(.custom, baseURL: "http://b/v1") == nil) // another server, another list
        #expect(cache.load(.openAI, baseURL: CloudProvider.openAI.defaultBaseURL) == nil)

        try cache.save([CloudModel(id: "deepseek-reasoner")], for: .deepSeek, baseURL: "https://api.deepseek.com", now: when)
        #expect(cache.load(.deepSeek, baseURL: "https://api.deepseek.com")?.models.map(\.id) == ["deepseek-reasoner"]) // refresh replaces
        cache.clear()
        #expect(cache.load(.custom, baseURL: "http://a/v1") == nil)
    }

    // MARK: - DeepSeek through the parse and tool paths

    private func assistant(_ cloud: any LLM) -> Assistant {
        Assistant(router: AIRouter(mode: .byok, onDevice: nil, local: nil, cloud: cloud), tools: Books.tools, language: "vi")
    }

    @Test func deepSeekParsesWithJSONMode() async {
        let reply = #"{"transactions":[{"amountText":"45k","kind":"expense","category":"category.food","note":"phở"}]}"#
        let stub = StubTransport([["id": "x", "model": "deepseek-chat",
                                   "choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": reply]]]]])
        let r = await assistant(LLMSettings.client(.deepSeek, key: "sk-ds", model: "deepseek-chat", send: stub.send)).parse("phở 45k", context: Books.context)
        #expect(r.usedModel)
        #expect(r.txns.map(\.amount) == [45_000])
        #expect(r.txns.first?.categoryKey == "category.food")
        #expect(stub.requests[0].url?.absoluteString == "https://api.deepseek.com/chat/completions")
        let body = stub.bodies[0]
        #expect(body["model"] as? String == "deepseek-chat")
        #expect((body["response_format"] as? [String: String]) == ["type": "json_object"])
        // DeepSeek's JSON mode requires the word "json" in the prompt.
        #expect(((body["messages"] as? [[String: Any]])?.first?["content"] as? String)?.localizedCaseInsensitiveContains("json") == true)
    }

    enum DeepSeekFailure: CaseIterable { case emptyJSON, prose, outOfCredit }

    @Test(arguments: DeepSeekFailure.allCases)
    func deepSeekFailuresFallBackToTheRuleParser(_ failure: DeepSeekFailure) async {
        let stub = switch failure {
        case .emptyJSON: StubTransport([["choices": [["message": ["role": "assistant", "content": ""]]]]])
        case .prose: StubTransport([["choices": [["message": ["role": "assistant", "content": "Sure! You spent 45k on phở."]]]]])
        case .outOfCredit: StubTransport(status: 402, body: ["error": ["message": "Insufficient Balance"]])
        }
        let r = await assistant(LLMSettings.client(.deepSeek, key: "sk-ds", model: "deepseek-chat", send: stub.send)).parse("phở 45k, cafe 29k", context: Books.context)
        #expect(!r.usedModel)
        #expect(r.txns == QuickParser.parse("phở 45k, cafe 29k", context: Books.context))
    }

    @Test func deepSeekCallsToolsTheOpenAIWay() async throws {
        let stub = StubTransport([
            ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": "", "tool_calls": [
                ["index": 0, "id": "call_0_ab", "type": "function", "function": ["name": "spendingSummary", "arguments": #"{"period":"thisMonth"}"#]],
            ]]]]],
            ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Tháng này bạn tiêu ít hơn tháng trước."]]]],
        ])
        let llm = LLMSettings.client(.deepSeek, key: "sk-ds", model: "deepseek-chat", send: stub.send)
        let out = await assistant(llm).answer("tháng này tiêu bao nhiêu?", skill: .spendingCoach, context: Books.context)
        #expect(out == .answer("Tháng này bạn tiêu ít hơn tháng trước.", skill: Skill.spendingCoach.id))
        let toolMessage = (stub.bodies[1]["messages"] as? [[String: Any]])?.last
        #expect(toolMessage?["role"] as? String == "tool")
        #expect(toolMessage?["tool_call_id"] as? String == "call_0_ab")
        #expect((toolMessage?["content"] as? String)?.contains("error") == false) // the Swift tool really ran
    }
}
