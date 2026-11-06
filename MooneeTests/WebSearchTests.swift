import Foundation
import Testing
@testable import Moonee

/// Every search backend against canned replies: request shape and the snippets it returns. No network.
struct WebSearchTests {
    @Test func tavily() async throws {
        let stub = StubTransport([["answer": "SJC 152tr", "results": [
            ["title": "Giá vàng hôm nay", "url": "https://a.vn/vang", "content": "SJC mua 150, bán 152 triệu/lượng", "published_date": "2026-11-06"],
        ]]])
        let r = try await TavilySearch(apiKey: "tvly-test", send: stub.send).search("giá vàng SJC")
        #expect(r.hits == [SearchHit(title: "Giá vàng hôm nay", url: "https://a.vn/vang", text: "SJC mua 150, bán 152 triệu/lượng", date: "2026-11-06")])
        #expect(r.summary == "SJC 152tr")
        #expect(stub.requests[0].url?.absoluteString == "https://api.tavily.com/search")
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tvly-test")
        #expect(stub.bodies[0]["query"] as? String == "giá vàng SJC")
    }

    @Test func brave() async throws {
        let stub = StubTransport([["web": ["results": [
            ["title": "USD/VND", "url": "https://b.com/fx", "description": "1 USD = 26,300 VND", "page_age": "2026-11-06T02:00:00"],
        ]]]])
        let r = try await BraveSearch(apiKey: "BSA-key", send: stub.send).search("tỷ giá đô")
        #expect(r.hits.first?.text == "1 USD = 26,300 VND")
        #expect(r.hits.first?.date == "2026-11-06T02:00:00")
        let url = try #require(stub.requests[0].url)
        #expect(url.host() == "api.search.brave.com")
        #expect(url.query()?.contains("count=5") == true)
        #expect(stub.requests[0].value(forHTTPHeaderField: "X-Subscription-Token") == "BSA-key")
    }

    @Test func openRouterWebPlugin() async throws {
        let stub = StubTransport([["choices": [["message": [
            "content": "Gold is up today.",
            "annotations": [["type": "url_citation", "url_citation": ["url": "https://c.com/gold", "title": "Gold", "content": "Gold rose 1%"]]],
        ]]]]])
        let llm = OpenAICompatibleLLM(baseURL: "https://openrouter.ai/api/v1", apiKey: "k", model: "m", provider: .openRouter, send: stub.send)
        let r = try await llm.search("gold price")
        #expect(r.hits == [SearchHit(title: "Gold", url: "https://c.com/gold", text: "Gold rose 1%")])
        #expect(r.summary == "Gold is up today.")
        #expect((stub.bodies[0]["plugins"] as? [[String: Any]])?.first?["id"] as? String == "web")
    }

    @Test func openAIResponsesWebSearch() async throws {
        let text = "Rates are 4.8% at VCB."
        let stub = StubTransport([["output": [
            ["type": "web_search_call", "status": "completed"],
            ["type": "message", "content": [["type": "output_text", "text": text, "annotations": [
                ["type": "url_citation", "url": "https://vcb.vn/rates", "title": "VCB", "start_index": 0, "end_index": 14],
            ]]]],
        ]]])
        let llm = OpenAICompatibleLLM(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "gpt-5-mini", provider: .openAI, send: stub.send)
        let r = try await llm.search("VCB savings rate")
        #expect(stub.requests[0].url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect((stub.bodies[0]["tools"] as? [[String: String]]) == [["type": "web_search"]])
        #expect(r.hits == [SearchHit(title: "VCB", url: "https://vcb.vn/rates", text: "Rates are 4.8%")])
    }

    @Test func anthropicServerTool() async throws {
        let stub = StubTransport([["content": [
            ["type": "server_tool_use", "id": "s1", "name": "web_search", "input": ["query": "btc"]],
            ["type": "web_search_tool_result", "tool_use_id": "s1", "content": [
                ["type": "web_search_result", "url": "https://d.com/btc", "title": "BTC", "page_age": "November 6, 2026", "encrypted_content": "x"],
            ]],
            ["type": "text", "text": "Bitcoin trades near $68k.", "citations": [
                ["type": "web_search_result_location", "url": "https://d.com/btc", "title": "BTC", "cited_text": "BTC at $68,000"],
            ]],
        ]]])
        let r = try await AnthropicLLM(apiKey: "k", model: "claude-sonnet-5-5", send: stub.send).search("bitcoin price")
        #expect(r.hits == [SearchHit(title: "BTC", url: "https://d.com/btc", text: "BTC at $68,000", date: "November 6, 2026")])
        #expect(((stub.bodies[0]["tools"] as? [[String: Any]])?.first?["type"]) as? String == "web_search_20250305")
    }

    @Test func geminiGrounding() async throws {
        let stub = StubTransport([["candidates": [[
            "content": ["role": "model", "parts": [["text": "SJC sells at 152m."]]],
            "groundingMetadata": [
                "groundingChunks": [["web": ["uri": "https://e.vn/sjc", "title": "e.vn"]]],
                "groundingSupports": [["segment": ["text": "SJC sells at 152m."], "groundingChunkIndices": [0]]],
            ],
        ]]]])
        let r = try await GeminiLLM(apiKey: "k", model: "gemini-3.5-flash", send: stub.send).search("giá vàng")
        #expect(r.hits == [SearchHit(title: "e.vn", url: "https://e.vn/sjc", text: "SJC sells at 152m.")])
        #expect((stub.bodies[0]["tools"] as? [[String: Any]])?.first?["google_search"] != nil)
    }

    @Test func bigModelAnswersCarryTheSourcesItSearched() async throws {
        var tools = Books.tools
        tools.search = WebSearch(backend: TavilySearch(apiKey: "k", send: StubTransport([["results": [
            ["title": "Giá vàng", "url": "https://www.sjc.com.vn/gia", "content": "Bán 152.000.000", "published_date": "2026-11-06"],
            ["title": "Dup", "url": "https://www.sjc.com.vn/gia", "content": "x"],
        ]]]).send))
        let stub = StubTransport([
            ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "c1", "type": "function", "function": ["name": "webSearch", "arguments": #"{"query":"giá vàng SJC"}"#]],
            ]]]]],
            ["choices": [["message": ["content": "Theo sjc.com.vn, 152 triệu."]]]],
        ])
        let cloud = OpenAICompatibleLLM(baseURL: "https://x/v1", apiKey: "k", model: "m", send: stub.send)
        let a = Assistant(router: AIRouter(mode: .byok, onDevice: nil, local: nil, cloud: cloud), tools: tools, language: "vi")
        guard case .answer(_, "market-lookup", let sources) = await a.handle("giá vàng SJC hôm nay?", context: Books.context) else {
            Issue.record("expected an answer")
            return
        }
        #expect(sources.map(\.site) == ["sjc.com.vn"])
        #expect(sources.first?.date == (try? Date("2026-11-06", strategy: .iso8601.year().month().day())))
        #expect(WebSource.date(from: "November 6, 2026") != nil)
        #expect(WebSource.date(from: "2 hours ago") == nil)
    }

    @Test func switchedOff() async {
        let off = await WebSearch(backend: TavilySearch(apiKey: "k"), enabled: false).run("gold")
        #expect(off.configured == false)
        #expect(off.message?.contains("turned web search off") == true)
    }

    @Test func notSetUpAndFailures() async {
        let none = await WebSearch(backend: nil).run("giá vàng")
        #expect(none.configured == false)
        #expect(none.message?.contains("Web search") == true)

        let failing = WebSearch(backend: TavilySearch(apiKey: "bad", send: StubTransport(status: 401, body: ["error": ["message": "bad key"]]).send))
        let r = await failing.run("gold")
        #expect(r.configured)
        #expect(r.results.isEmpty)
        #expect(r.message?.contains("bad key") == true)
    }

    @Test func backendOrder() {
        let anthropic = AnthropicLLM(apiKey: "k", model: "m")
        let keys: (SearchKeyProvider) -> String? = { $0 == .tavily ? "tvly-1" : "brave-1" }
        // (a) the BYOK provider's own search, when answers already go there
        #expect(SearchSettings.backend(mode: .byok, provider: .anthropic, cloud: anthropic, keyProvider: .tavily, key: keys)?.sourceName == "Anthropic")
        // (b) the user's key: provider has no search (DeepSeek) or answers stay on the phone
        #expect(SearchSettings.backend(mode: .byok, provider: .deepSeek, cloud: OpenAICompatibleLLM(baseURL: "x", apiKey: "k", model: "m", provider: .deepSeek),
                                       keyProvider: .brave, key: keys)?.sourceName == "Brave Search")
        #expect(SearchSettings.backend(mode: .onDevice, provider: .anthropic, cloud: anthropic, keyProvider: .tavily, key: keys)?.sourceName == "Tavily")
        // (c) nothing
        #expect(SearchSettings.backend(mode: .onDevice, provider: .anthropic, cloud: anthropic, keyProvider: nil, key: keys) == nil)
        #expect(SearchSettings.backend(mode: .local, provider: .openAI, cloud: nil, keyProvider: .tavily, key: { _ in nil }) == nil)
    }

    @Test func toolsGoThroughSwift() async throws {
        var tools = Books.tools
        let coingecko = StubTransport([["bitcoin": ["usd": 68000.5, "vnd": 1_790_000_000, "last_updated_at": 1_762_400_000]]])
        tools.prices = MarketPrices(send: coingecko.send, cache: QuoteCache())
        tools.search = WebSearch(backend: nil, now: { Books.now })

        let quote = try #require(await tools.json("marketPrice", #"{"symbol":"btc"}"#) as? [String: Any])
        #expect(quote["coin"] as? String == "bitcoin")
        #expect((quote["prices"] as? [[String: String]]) == [["currency": "USD", "price": "$68,000.50"], ["currency": "VND", "price": "₫1,790,000,000"]])
        #expect(quote["source"] as? String == "CoinGecko")
        #expect(coingecko.requests[0].url?.query()?.contains("vs_currencies=usd,vnd") == true)

        let stock = try #require(await tools.json("marketPrice", #"{"symbol":"VNM"}"#) as? [String: Any])
        #expect((stock["error"] as? String)?.contains("webSearch") == true) // stocks go through web search

        let search = try #require(await tools.json("webSearch", #"{"query":"giá vàng"}"#) as? [String: Any])
        #expect(search["configured"] as? Bool == false)
        #expect(search["searchedAt"] as? String == Books.now.formatted(.iso8601))

        #expect(MarketPrices.symbol(in: "giá bitcoin hôm nay") == "bitcoin")
        #expect(MarketPrices.symbol(in: "ETH bao nhiêu") == "ethereum")
        #expect(MarketPrices.symbol(in: "giá vàng") == "GOLD")
        #expect(MooneeTools.allNames == tools.all.map(\.name))
    }

    @Test(arguments: [
        ("giá vàng SJC hôm nay bao nhiêu?", "market-lookup"), ("tỷ giá đô hôm nay", "market-lookup"),
        ("What's the bitcoin price?", "market-lookup"), ("giá bitcoin", "market-lookup"),
        ("mua vàng 2tr", "transaction-parser"), ("mua bitcoin 5tr", "transaction-parser"),
    ])
    func marketRouting(text: String, skill: String) {
        #expect(Skill.route(text, context: Books.context).id == skill)
    }

    @Test func smallModelGetsSearchResultsAsFacts() async throws {
        var tools = Books.tools
        tools.search = WebSearch(backend: TavilySearch(apiKey: "k", send: StubTransport([["results": [
            ["title": "SJC", "url": "https://sjc.vn", "content": "Bán 152.000.000"],
        ]]]).send))
        let apple = ScriptedLLM(small: true, replies: ["Theo SJC, giá bán 152 triệu."])
        let a = Assistant(router: AIRouter(mode: .onDevice, onDevice: apple, local: nil, cloud: nil), tools: tools, language: "vi")
        let out = await a.handle("giá vàng SJC hôm nay bao nhiêu?", context: Books.context)
        #expect(out == .answer("Theo SJC, giá bán 152 triệu.", skill: "market-lookup",
                               sources: [WebSource(title: "SJC", url: URL(string: "https://sjc.vn")!, site: "sjc.vn")]))
        let system = try #require(apple.requests.first?.system)
        #expect(system.contains("https://sjc.vn"))
        #expect(system.contains(Skill.marketLookup.instructions(language: "vi", short: true)))
    }
}
