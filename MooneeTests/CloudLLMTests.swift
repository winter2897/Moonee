import Foundation
import FoundationModels
import Testing
@testable import Moonee

/// BYOK clients against canned provider replies: request shape and the tool-calling loop.
struct CloudLLMTests {
    final class Calls: @unchecked Sendable { var args: [String] = [] }

    func lookup(_ calls: Calls) -> AITool {
        AITool(name: "lookup", description: "Spending for a period",
               parameters: .object([.init("period", .string(oneOf: ["thisMonth", "lastMonth"]), required: true)])) { data in
            calls.args.append(String(decoding: data, as: UTF8.self))
            return #"{"spent":"₫1,000"}"#
        }
    }

    func request(_ tools: [AITool], json: Bool = false) -> LLMRequest {
        LLMRequest(system: "be nice", messages: [.init(role: .user, text: "how much?")], tools: tools, json: json)
    }

    @Test func openAIToolLoop() async throws {
        let stub = StubTransport([
            ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "c1", "type": "function", "function": ["name": "lookup", "arguments": #"{"period":"thisMonth"}"#]],
            ]]]]],
            ["choices": [["message": ["role": "assistant", "content": "You spent ₫1,000"]]]],
        ])
        let calls = Calls()
        let llm = OpenAICompatibleLLM(baseURL: "https://openrouter.ai/api/v1/", apiKey: "sk-test", model: "m", send: stub.send)
        #expect(try await llm.respond(request([lookup(calls)])) == "You spent ₫1,000")
        #expect(calls.args == [#"{"period":"thisMonth"}"#])
        #expect(stub.requests[0].url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let first = stub.bodies[0], second = stub.bodies[1]
        #expect((first["messages"] as? [[String: Any]])?.first?["role"] as? String == "system")
        let fn = ((first["tools"] as? [[String: Any]])?.first?["function"]) as? [String: Any]
        #expect(fn?["name"] as? String == "lookup")
        #expect(((fn?["parameters"] as? [String: Any])?["required"]) as? [String] == ["period"])
        let last = (second["messages"] as? [[String: Any]])?.last
        #expect(last?["role"] as? String == "tool")
        #expect(last?["tool_call_id"] as? String == "c1")
        #expect(last?["content"] as? String == #"{"spent":"₫1,000"}"#)
    }

    @Test func openAIJSONModeAndDefaultExtraction() async throws {
        let content = "```json\n" + #"{"transactions":[{"amountText":"45k","kind":"expense","note":"phở"}]}"# + "\n```"
        let stub = StubTransport([["choices": [["message": ["content": content]]]]])
        let llm = OpenAICompatibleLLM(baseURL: "https://x/v1", apiKey: "k", model: "m", send: stub.send)
        let items = try await llm.extractTransactions(instructions: "parse", text: "phở 45k")
        #expect(items == [AIParsedTxn(amountText: "45k", kind: "expense", note: "phở")])
        #expect((stub.bodies[0]["response_format"] as? [String: String]) == ["type": "json_object"])
    }

    @Test func anthropicToolLoop() async throws {
        let stub = StubTransport([
            ["content": [["type": "text", "text": "Let me check."],
                         ["type": "tool_use", "id": "t1", "name": "lookup", "input": ["period": "lastMonth"]]],
             "stop_reason": "tool_use"],
            ["content": [["type": "text", "text": "Done"]], "stop_reason": "end_turn"],
        ])
        let calls = Calls()
        let llm = AnthropicLLM(apiKey: "ak", model: "claude-sonnet-5-5", send: stub.send)
        #expect(try await llm.respond(request([lookup(calls)])) == "Done")
        #expect(calls.args == [#"{"period":"lastMonth"}"#])
        #expect(stub.requests[0].url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(stub.requests[0].value(forHTTPHeaderField: "x-api-key") == "ak")
        #expect(stub.requests[0].value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let first = stub.bodies[0]
        #expect(first["system"] as? String == "be nice")
        #expect(((first["tools"] as? [[String: Any]])?.first?["input_schema"] as? [String: Any])?["type"] as? String == "object")
        let msgs = stub.bodies[1]["messages"] as? [[String: Any]] ?? []
        #expect(msgs.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let result = (msgs.last?["content"] as? [[String: Any]])?.first
        #expect(result?["type"] as? String == "tool_result")
        #expect(result?["tool_use_id"] as? String == "t1")
    }

    @Test func geminiToolLoop() async throws {
        let stub = StubTransport([
            ["candidates": [["content": ["role": "model", "parts": [
                ["functionCall": ["name": "lookup", "args": ["period": "thisMonth"]], "thoughtSignature": "sig"],
            ]]]]],
            ["candidates": [["content": ["role": "model", "parts": [["text": "Xong"]]]]]],
        ])
        let calls = Calls()
        let llm = GeminiLLM(apiKey: "gk", model: "gemini-3.5-flash", send: stub.send)
        #expect(try await llm.respond(request([lookup(calls)], json: true)) == "Xong")
        #expect(calls.args == [#"{"period":"thisMonth"}"#])
        #expect(stub.requests[0].url?.absoluteString.hasSuffix("/models/gemini-3.5-flash:generateContent") == true)
        #expect(stub.requests[0].value(forHTTPHeaderField: "x-goog-api-key") == "gk")
        #expect(((stub.bodies[0]["generationConfig"] as? [String: Any])?["responseMimeType"]) as? String == "application/json")
        let contents = stub.bodies[1]["contents"] as? [[String: Any]] ?? []
        #expect(contents.count == 3)
        let echoed = (contents[1]["parts"] as? [[String: Any]])?.first
        #expect(echoed?["thoughtSignature"] as? String == "sig") // model turn echoed untouched
        let response = ((contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"]) as? [String: Any]
        #expect(response?["name"] as? String == "lookup")
        #expect(((response?["response"] as? [String: Any])?["result"] as? [String: String]) == ["spent": "₫1,000"])
    }

    @Test func httpErrorsSurface() async {
        let stub = StubTransport(status: 401, body: ["error": ["message": "invalid x-api-key"]])
        let llm = AnthropicLLM(apiKey: "bad", model: "m", send: stub.send)
        await #expect(throws: LLMError("HTTP 401: invalid x-api-key")) { try await llm.respond(request([])) }
    }

    @Test func schemaFormats() throws {
        let s = ToolSchema.object([.init("n", .integer("count"), required: true), .init("tags", .array(.string()))], "args")
        let json = s.json
        #expect(json["type"] as? String == "object")
        #expect(json["required"] as? [String] == ["n"])
        #expect(json["description"] as? String == "args")
        #expect(((json["properties"] as? [String: Any])?["tags"] as? [String: Any])?["type"] as? String == "array")
        _ = try GenerationSchema(root: s.dynamic(name: "args"), dependencies: [])
    }

    @Test func cloudJSONShapeMatchesGenerableSchema() throws {
        // The @Generable type (Foundation Models) and the JSON example (cloud models) must name the same fields.
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AIParsedTxnList.generationSchema)) as? [String: Any]
        let defs = schema?["$defs"] as? [String: Any]
        let txn = defs?.values.compactMap { $0 as? [String: Any] }.first { ($0["properties"] as? [String: Any])?["amountText"] != nil }
        let generable = Set(((txn?["properties"]) as? [String: Any])?.keys.map { $0 } ?? [])
        let example = AIParsedTxn.jsonInstructions.split(separator: "\n").last.map(String.init) ?? ""
        let list = try JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any]
        let shown = Set(((list?["transactions"] as? [[String: Any]])?.first ?? [:]).keys)
        #expect(!generable.isEmpty)
        #expect(generable == shown)
    }
}
