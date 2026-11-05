import Foundation

// BYOK clients (spec §9.1). Each runs its provider's tool-calling loop with the same `AITool`s.
// `send` is injectable so tests replay canned provider replies.

/// OpenAI `/chat/completions` and everything that speaks it (OpenRouter, Groq, local servers…).
struct OpenAICompatibleLLM: LLM {
    var baseURL: String
    var apiKey: String
    var model: String
    /// Which service this is: decides effort and web-search support.
    var provider: CloudProvider = .custom
    var send: HTTPTransport = HTTP.live

    func respond(_ r: LLMRequest) async throws -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/ ")) + "/chat/completions") else {
            throw LLMError("Invalid base URL")
        }
        var messages: [[String: Any]] = [["role": "system", "content": r.system]]
            + r.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        for _ in 0..<LLMRequest.maxToolRounds {
            var body: [String: Any] = ["model": model, "messages": messages]
            // OpenAI's reasoning models (o-series, gpt-5) reject any temperature but the default.
            if !(provider == .openAI && EffortModels.openAIReasoning(model.lowercased())) { body["temperature"] = 0.2 }
            if let e = r.effort, supportedEfforts(provider: provider, model: model).contains(e), let value = e.openAIValue {
                if provider == .openRouter { body["reasoning"] = ["effort": value] } else { body["reasoning_effort"] = value }
            }
            if !r.tools.isEmpty {
                body["tools"] = r.tools.map {
                    ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters.json]]
                }
            }
            if r.json { body["response_format"] = ["type": "json_object"] }
            let reply = try await HTTP.postJSON(url, headers: ["Authorization": "Bearer \(apiKey)", "X-Title": "Moonee"], body: body, send: send)
            guard let message = (reply["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
                throw LLMError("Unexpected reply")
            }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty { return message["content"] as? String ?? "" }
            messages.append(message)
            for call in calls {
                let fn = call["function"] as? [String: Any] ?? [:]
                let result = await r.tools.call(fn["name"] as? String ?? "", arguments: Data((fn["arguments"] as? String ?? "{}").utf8))
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": result])
            }
        }
        throw LLMError("Too many tool calls")
    }
}

/// Anthropic Messages API.
struct AnthropicLLM: LLM {
    var apiKey: String
    var model: String
    var baseURL = "https://api.anthropic.com"
    var send: HTTPTransport = HTTP.live

    func respond(_ r: LLMRequest) async throws -> String {
        guard let url = URL(string: baseURL + "/v1/messages") else { throw LLMError("Invalid base URL") }
        var messages: [[String: Any]] = r.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let system = r.json ? r.system + "\n\nReply with one JSON object and nothing else." : r.system
        for _ in 0..<LLMRequest.maxToolRounds {
            var body: [String: Any] = ["model": model, "max_tokens": 2048, "system": system, "messages": messages]
            if let e = r.effort, supportedEfforts(provider: .anthropic, model: model).contains(e) {
                body["thinking"] = ["type": "enabled", "budget_tokens": e.anthropicBudget]
                body["max_tokens"] = e.anthropicBudget + 4096 // must exceed the thinking budget
            }
            if !r.tools.isEmpty {
                body["tools"] = r.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.json] }
            }
            let reply = try await HTTP.postJSON(url, headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"], body: body, send: send)
            guard let content = reply["content"] as? [[String: Any]] else { throw LLMError("Unexpected reply") }
            let uses = content.filter { $0["type"] as? String == "tool_use" }
            if uses.isEmpty { return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined() }
            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for use in uses {
                let input = try JSONSerialization.data(withJSONObject: use["input"] ?? [String: Any]())
                let out = await r.tools.call(use["name"] as? String ?? "", arguments: input)
                results.append(["type": "tool_result", "tool_use_id": use["id"] as? String ?? "", "content": out])
            }
            messages.append(["role": "user", "content": results])
        }
        throw LLMError("Too many tool calls")
    }
}

/// Google Gemini `generateContent`.
struct GeminiLLM: LLM {
    var apiKey: String
    var model: String
    var baseURL = "https://generativelanguage.googleapis.com/v1beta"
    var send: HTTPTransport = HTTP.live

    func respond(_ r: LLMRequest) async throws -> String {
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent") else { throw LLMError("Invalid model name") }
        var contents: [[String: Any]] = r.messages.map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] }
        for _ in 0..<LLMRequest.maxToolRounds {
            var config: [String: Any] = ["temperature": 0.2]
            if r.json { config["responseMimeType"] = "application/json" }
            if let e = r.effort, supportedEfforts(provider: .gemini, model: model).contains(e) {
                config["thinkingConfig"] = ["thinkingBudget": e.geminiBudget]
            }
            var body: [String: Any] = ["systemInstruction": ["parts": [["text": r.system]]], "contents": contents, "generationConfig": config]
            if !r.tools.isEmpty {
                body["tools"] = [["functionDeclarations": r.tools.map { tool -> [String: Any] in
                    var d: [String: Any] = ["name": tool.name, "description": tool.description]
                    if case .object(let props, _) = tool.parameters, !props.isEmpty { d["parameters"] = tool.parameters.json }
                    return d
                }]]
            }
            let reply = try await HTTP.postJSON(url, headers: ["x-goog-api-key": apiKey], body: body, send: send)
            guard let content = (reply["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw LLMError("Unexpected reply") }
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            if calls.isEmpty { return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined() }
            contents.append(content) // echoed as-is: keeps Gemini's thought signatures
            var responses: [[String: Any]] = []
            for call in calls {
                let name = call["name"] as? String ?? ""
                let out = await r.tools.call(name, arguments: try JSONSerialization.data(withJSONObject: call["args"] ?? [String: Any]()))
                let value = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) ?? out
                responses.append(["functionResponse": ["name": name, "response": ["result": value]]])
            }
            contents.append(["role": "user", "parts": responses])
        }
        throw LLMError("Too many tool calls")
    }
}
