import Foundation
import Testing
@testable import Moonee

/// Effort levels per provider/model and how each API receives them. Unsupported levels are never sent.
struct EffortTests {
    let all = ReasoningEffort.allCases
    let openAIStyle: [ReasoningEffort] = [.low, .medium, .high]
    let noCache = ModelCache(directory: URL.temporaryDirectory.appending(path: "no-cache-\(UUID())"))

    @Test func supportedPerProvider() {
        #expect(supportedEfforts(provider: .openAI, model: "gpt-5-mini") == openAIStyle)
        #expect(supportedEfforts(provider: .openAI, model: "o4-mini") == openAIStyle)
        #expect(supportedEfforts(provider: .openAI, model: "gpt-4o") == [])
        #expect(supportedEfforts(provider: .openAI, model: "gpt-5-chat-latest") == [])
        #expect(supportedEfforts(provider: .anthropic, model: "claude-sonnet-5-5") == all)
        #expect(supportedEfforts(provider: .anthropic, model: "claude-3-7-sonnet-latest") == all)
        #expect(supportedEfforts(provider: .anthropic, model: "claude-3-5-haiku-latest") == [])
        #expect(supportedEfforts(provider: .gemini, model: "gemini-3.5-flash") == all)
        #expect(supportedEfforts(provider: .gemini, model: "gemini-2.0-flash") == [])
        #expect(supportedEfforts(provider: .deepSeek, model: "deepseek-reasoner") == [])
        #expect(supportedEfforts(provider: .custom, model: "gpt-5") == [])
        #expect(supportedEfforts(provider: .openRouter, model: "anthropic/claude-sonnet-4.5", cache: noCache) == openAIStyle)
        #expect(supportedEfforts(provider: .openRouter, model: "meta-llama/llama-3.3-70b", cache: noCache) == [])
    }

    @Test func openRouterTrustsItsModelList() throws {
        let cache = ModelCache(directory: URL.temporaryDirectory.appending(path: "effort-\(UUID())"))
        try cache.save([CloudModel(id: "openai/gpt-5", reasoning: false), CloudModel(id: "acme/thinker", reasoning: true)],
                       for: .openRouter, baseURL: LLMSettings.defaultBaseURL)
        #expect(supportedEfforts(provider: .openRouter, model: "openai/gpt-5", cache: cache) == [])
        #expect(supportedEfforts(provider: .openRouter, model: "acme/thinker", cache: cache) == openAIStyle)
        #expect(CloudModel.decodeOpenAI(["data": [["id": "x", "supported_parameters": ["tools", "reasoning"]]]]).first?.reasoning == true)
    }

    func sent(_ llm: (@escaping HTTPTransport) -> any LLM, effort: ReasoningEffort?, reply: [String: Any]) async throws -> [String: Any] {
        let stub = StubTransport([reply])
        _ = try await llm(stub.send).respond(LLMRequest(system: "s", messages: [.init(role: .user, text: "hi")], effort: effort))
        return stub.bodies[0]
    }

    let openAIReply: [String: Any] = ["choices": [["message": ["content": "ok"]]]]

    @Test func openAIAndOpenRouterMapping() async throws {
        let openAI = { (s: @escaping HTTPTransport) -> any LLM in
            OpenAICompatibleLLM(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "gpt-5-mini", provider: .openAI, send: s)
        }
        let high = try await sent(openAI, effort: .high, reply: openAIReply)
        #expect(high["reasoning_effort"] as? String == "high")
        #expect(high["temperature"] == nil) // reasoning models only take the default temperature
        #expect(try await sent(openAI, effort: .max, reply: openAIReply)["reasoning_effort"] == nil) // not an OpenAI level

        let router = { (s: @escaping HTTPTransport) -> any LLM in
            OpenAICompatibleLLM(baseURL: "https://openrouter.ai/api/v1", apiKey: "k", model: "deepseek/deepseek-r1", provider: .openRouter, send: s)
        }
        #expect(try await sent(router, effort: .low, reply: openAIReply)["reasoning"] as? [String: String] == ["effort": "low"])

        let deepSeek = { (s: @escaping HTTPTransport) -> any LLM in
            OpenAICompatibleLLM(baseURL: "https://api.deepseek.com", apiKey: "k", model: "deepseek-chat", provider: .deepSeek, send: s)
        }
        let ds = try await sent(deepSeek, effort: .high, reply: openAIReply)
        #expect(ds["reasoning_effort"] == nil && ds["reasoning"] == nil)
        #expect(ds["temperature"] as? Double == 0.2)
    }

    @Test func anthropicThinkingBudget() async throws {
        let reply: [String: Any] = ["content": [["type": "thinking", "thinking": "…", "signature": "s"], ["type": "text", "text": "ok"]]]
        let claude = { (s: @escaping HTTPTransport) -> any LLM in AnthropicLLM(apiKey: "k", model: "claude-sonnet-5-5", send: s) }
        let body = try await sent(claude, effort: .higher, reply: reply)
        let thinking = body["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "enabled")
        #expect(thinking?["budget_tokens"] as? Int == 20_000)
        #expect(body["max_tokens"] as? Int == 24_096)
        #expect(try await sent(claude, effort: nil, reply: reply)["thinking"] == nil)
        let old = { (s: @escaping HTTPTransport) -> any LLM in AnthropicLLM(apiKey: "k", model: "claude-3-5-haiku-latest", send: s) }
        #expect(try await sent(old, effort: .max, reply: reply)["thinking"] == nil)
    }

    @Test func geminiThinkingBudget() async throws {
        let reply: [String: Any] = ["candidates": [["content": ["role": "model", "parts": [["text": "plan…", "thought": true], ["text": "ok"]]]]]]
        let stub = StubTransport([reply])
        let text = try await GeminiLLM(apiKey: "k", model: "gemini-3.5-flash", send: stub.send)
            .respond(LLMRequest(system: "s", messages: [.init(role: .user, text: "hi")], effort: .max))
        #expect(text == "ok") // thought parts are not the answer
        let config = stub.bodies[0]["generationConfig"] as? [String: Any]
        #expect(config?["thinkingConfig"] as? [String: Int] == ["thinkingBudget": 24_576])
    }

    @Test func storedPerProviderAndModel() throws {
        let d = try #require(UserDefaults(suiteName: "effort-\(UUID())"))
        #expect(LLMSettings.effort(provider: .anthropic, model: "a", defaults: d) == .medium)
        LLMSettings.setEffort(.max, provider: .anthropic, model: "a", defaults: d)
        #expect(LLMSettings.effort(provider: .anthropic, model: "a", defaults: d) == .max)
        #expect(LLMSettings.effort(provider: .anthropic, model: "b", defaults: d) == .medium)
        #expect(LLMSettings.effort(provider: .gemini, model: "a", defaults: d) == .medium)
    }

    @Test func answersThinkParsingDoesNot() async {
        let model = ScriptedLLM(replies: [#"{"transactions":[{"amountText":"45k","kind":"expense","note":"Phở"}]}"#, "Chào bạn!"])
        var a = Assistant(router: AIRouter(mode: .byok, onDevice: nil, local: nil, cloud: model), tools: Books.tools, language: "vi")
        a.effort = .high
        _ = await a.handle("phở 45k", context: Books.context)
        _ = await a.handle("cảm ơn Moonee", context: Books.context)
        #expect(model.requests.map(\.effort) == [nil, .high])
    }
}
