import Foundation
import Testing
@testable import Moonee

/// A small model that fails with the given errors first, then answers. Records requests.
final class FlakyLLM: LLM, @unchecked Sendable {
    var isSmall: Bool { true }
    var errors: [any Error]
    var replies: [String]
    var requests: [LLMRequest] = []

    init(errors: [any Error], replies: [String] = []) { (self.errors, self.replies) = (errors, replies) }

    func respond(_ r: LLMRequest) async throws -> String {
        requests.append(r)
        if !errors.isEmpty { throw errors.removeFirst() }
        guard !replies.isEmpty else { throw LLMError("offline") }
        return replies.removeFirst()
    }
}

/// Small on-device (local) models: compact prompt, notices, fallbacks, and keyless gold / exchange-rate prices.
/// No network.
struct SmallModelTests {
    let ctx = Books.context

    static let pnj: [String: Any] = ["updateDate": "06/11/2026 08:39:51", "data": [
        ["masp": "SJC", "tensp": "Vàng miếng SJC 999.9", "giaban": 14100, "giamua": 13800],
        ["masp": "N24K", "tensp": "Nhẫn Trơn PNJ 999.9", "giaban": 14030, "giamua": 13630],
    ]]
    static let vcb: [String: Any] = ["UpdatedDate": "2026-11-06T08:01:46+07:00", "Data": [
        ["currencyCode": "USD", "cash": "25400.00", "transfer": "25430.00", "sell": "25810.00"],
        ["currencyCode": "DKK", "cash": "-", "transfer": "3776.16", "sell": "3920.71"],
    ]]

    @Test func noticeFromErrors() {
        #expect(AINotice(LLMError("x")) == .failed)
        #expect(AINotice(AINotice.tooLong) == .tooLong)
    }

    @Test func localModeWithoutAModelUsesTheRulesQuietly() async {
        let a = Assistant(router: AIRouter(mode: .local), tools: Books.tools, language: "vi")
        let parsed = await a.reply("phở 45k", context: ctx)
        #expect(parsed.output == .transactions(QuickParser.parse("phở 45k", context: ctx), usedModel: false))
        #expect(parsed.notice == nil)
        guard case .facts = await a.reply("tháng này mình tiêu bao nhiêu?", context: ctx).output else { Issue.record("expected facts"); return }
    }

    @Test func hybridCloudStandsInForABrokenLocalModel() async {
        let local = FlakyLLM(errors: [LLMError("boom")])
        let cloud = ScriptedLLM(replies: ["Tháng này bạn tiêu 3.400.000 ₫ nè."])
        let r = await Assistant(router: AIRouter(mode: .hybrid, local: local, cloud: cloud), tools: Books.tools, language: "vi")
            .reply("tháng này mình tiêu bao nhiêu?", context: ctx)
        #expect(r.output == .answer("Tháng này bạn tiêu 3.400.000 ₫ nè.", skill: "spending-coach"))
        #expect(r.noticeText == AINotice.failed.text(answeredByModel: true))
    }

    @Test func overflowRetriesTightThenFallsBack() async {
        let history = (1...8).map { LLMMessage(role: $0 % 2 == 0 ? .assistant : .user, text: String(repeating: "chi tiêu ", count: 80)) }
        let local = FlakyLLM(errors: [AINotice.tooLong], replies: ["Tháng này bạn tiêu 3.400.000 ₫."])
        let a = Assistant(router: AIRouter(mode: .local, local: local), tools: Books.tools, language: "vi")
        let r = await a.reply("tháng này mình tiêu bao nhiêu?", history: history, context: ctx)
        #expect(r.output == .answer("Tháng này bạn tiêu 3.400.000 ₫.", skill: "spending-coach"))
        #expect(r.notice == .tooLong)
        #expect(local.requests.map(\.messages.count) == [5, 1]) // 4 clipped turns + the question, then the question alone
        #expect(local.requests[0].messages.dropLast().allSatisfy { $0.text.count <= CompactPrompt.turnChars + 1 })

        // Any other failure: no retry, the numbers answer, and the chat is told.
        let broken = FlakyLLM(errors: [LLMError("boom")])
        let b = await Assistant(router: AIRouter(mode: .local, local: broken), tools: Books.tools, language: "vi")
            .reply("tháng này mình tiêu bao nhiêu?", context: ctx)
        guard case .facts = b.output else { Issue.record("expected facts"); return }
        #expect(broken.requests.count == 1)
        #expect(b.noticeText == AINotice.failed.text(answeredByModel: false))
    }

    // MARK: Compact prompt

    @Test func compactPromptStaysSmall() async {
        let local = ScriptedLLM(small: true, replies: ["ok"])
        let a = Assistant(router: AIRouter(mode: .local, local: local), tools: Books.tools, language: "vi")
        _ = await a.handle("tháng này mình tiêu bao nhiêu?", history: [.init(role: .user, text: "chào")], context: ctx)
        let r = local.requests[0]
        #expect(r.tools.isEmpty)
        #expect(r.system.hasPrefix(Skill.persona(language: "vi", short: true)))
        #expect(r.system.contains(Skill.spendingCoach.instructions(language: "vi", short: true)))
        #expect(!r.system.contains("spendingSummary: {")) // stable system prompt: the facts ride in the user turn
        #expect(r.messages.last?.text.hasPrefix("FACTS") == true)
        #expect(r.messages.last?.text.hasSuffix("tháng này mình tiêu bao nhiêu?") == true)
        // ~3 characters a Vietnamese token: well inside a small model's 4096-token window with room for the answer.
        #expect(r.system.count + r.messages.map(\.text.count).reduce(0, +) < 3_600)
        #expect(Skill.persona(language: "vi", short: true).count < 450) // 400 + the no-investment-advice rule (docs/TERMS.md)
        #expect(!Skill.persona(language: "vi").contains("<!-- short -->"))

        let hits = (1...5).map { SearchHit(title: "t\($0)", url: "https://a\($0).vn", text: String(repeating: "x", count: 500)) }
        let search = try! AITool.encode(SearchResult(configured: true, source: "Tavily", searchedAt: "now", results: hits, summary: "s"))
        let facts = CompactPrompt.facts([.init(tool: "webSearch", json: search)])
        #expect(facts.count < CompactPrompt.factsChars + 20)
        #expect(facts.contains("https://a3.vn") && !facts.contains("https://a4.vn"))
    }

    @Test func systemPromptIsStableAndPartialsArePassedOn() async {
        let local = ScriptedLLM(small: true, replies: ["a", "b"])
        var a = Assistant(router: AIRouter(mode: .local, local: local), tools: Books.tools, language: "vi")
        a.onPartial = { _ in }
        _ = await a.handle("tháng này mình tiêu bao nhiêu?", context: ctx)
        _ = await a.handle("tuần trước mình tiêu bao nhiêu?", context: ctx)
        #expect(local.requests[0].system == local.requests[1].system) // same prefix: a local model reuses its KV cache
        #expect(local.requests.allSatisfy { $0.onPartial != nil })
    }

    @Test func rulesThatReadEverythingSkipTheSmallModel() async {
        let local = ScriptedLLM(small: true, replies: [])
        let a = Assistant(router: AIRouter(mode: .local, local: local), tools: Books.tools, language: "vi")
        let r = await a.parse("phở 45k", context: ctx)
        #expect(!r.usedModel && r.txns.first?.amount == 45_000 && local.requests.isEmpty)
        #expect(!Assistant.rulesComplete(QuickParser.parse("ăn trưa với team", context: ctx)))
    }

    // MARK: Keyless prices

    @Test func goldPricesNameNoBrand() async throws {
        let stub = StubTransport([Self.pnj])
        let prices = MarketPrices(send: stub.send, cache: QuoteCache(), now: { Books.now })
        let q = try await prices.quote("SJC", currency: "VND", locale: Locale(identifier: "en_US"))
        #expect(q.source == MarketPrices.sourceName && q.url?.contains("pnj.com.vn") == true)
        #expect(q.prices.map(\.price) == ["₫138,000,000", "₫141,000,000"]) // thousands per chỉ × 10 chỉ per lượng
        #expect(q.prices[1].label == String(localized: "\(String(localized: "Gold bars 999.9", table: "AI")), \(String(localized: "sell", table: "AI")), 1 tael", table: "AI"))
        #expect(!q.prices.contains { $0.label?.contains("SJC") == true || $0.label?.contains("PNJ") == true })
        #expect(q.updatedAt == "2026-11-06T01:39:51Z")
        #expect(stub.requests[0].timeoutInterval == MarketPrices.timeout)

        let both = try await MarketPrices(send: StubTransport([Self.pnj]).send, cache: QuoteCache()).quote("GOLD", currency: "VND", locale: .init(identifier: "en_US"))
        #expect(both.prices.count == 4)
    }

    @Test func ratesFromVietcombankAreCached() async throws {
        let stub = StubTransport([Self.vcb])
        let prices = MarketPrices(send: stub.send, cache: QuoteCache(), now: { Books.now })
        let usd = try await prices.quote("usd", currency: "VND", locale: Locale(identifier: "en_US"))
        #expect(usd.source == MarketPrices.sourceName)
        #expect(usd.prices.map(\.price) == ["₫25,400", "₫25,430", "₫25,810"])
        #expect(stub.requests[0].url?.query() == "date=2026-11-20")
        let dkk = try await prices.quote("DKK", currency: "VND", locale: Locale(identifier: "en_US")) // same URL: from the cache
        #expect(dkk.prices.count == 2) // no cash rate ("-")
        #expect(stub.requests.count == 1)
    }

    @Test(arguments: [
        ("Giá vàng sjc nay là bao nhiêu thế", "SJC"), ("giá vàng hôm nay", "GOLD"), ("vàng pnj", "PNJ"),
        ("tỷ giá đô hôm nay", "USD"), ("1 EUR bằng bao nhiêu", "EUR"), ("giá btc", "bitcoin"), ("vâng, cảm ơn", nil),
    ] as [(String, String?)])
    func symbols(text: String, symbol: String?) {
        #expect(MarketPrices.symbol(in: text) == symbol)
    }

    /// The owner's example: a local model, no search key, still gets the real price; no provider name in the UI.
    @Test func goldQuestionOnDeviceWithoutKey() async throws {
        var tools = Books.tools
        tools.prices = MarketPrices(send: StubTransport([Self.pnj]).send, cache: QuoteCache())
        let local = ScriptedLLM(small: true, replies: ["Giá tham khảo trên internet lúc 8:39 sáng nay: vàng miếng bán ra ₫141,000,000 một lượng nè."])
        let a = Assistant(router: AIRouter(mode: .local, local: local), tools: tools, language: "vi")
        let r = await a.reply("Giá vàng sjc nay là bao nhiêu thế", context: ctx)
        guard case .answer(_, "market-lookup", let sources) = r.output else { Issue.record("expected an answer"); return }
        #expect(sources.map(\.site) == ["Internet"])
        let question = try #require(local.requests.first?.messages.last?.text)
        #expect(question.contains("₫141,000,000"))
        #expect(!question.contains("webSearch:")) // the price answered it: no search
        #expect(r.notice == nil)

        // No model at all: the plain numbers, labelled.
        var none = tools
        none.prices = MarketPrices(send: StubTransport([Self.pnj]).send, cache: QuoteCache())
        let facts = await Assistant(router: AIRouter(mode: .local), tools: none, language: "vi").handle("giá vàng sjc", context: ctx)
        guard case .facts(let f, _) = facts else { Issue.record("expected facts"); return }
        let text = try #require(ChatBook.factsText(f))
        #expect(text.contains("**₫141,000,000**") && text.contains(MarketPrices.sourceName))
        #expect(!["PNJ", "SJC", "Vietcombank", "CoinGecko"].contains { text.contains($0) })
    }

    @Test func searchRouteFollowsTheModel() {
        let keys: (SearchKeyProvider) -> String? = { _ in "k" }
        #expect(SearchSettings.backend(mode: .hybrid, provider: .gemini, cloud: GeminiLLM(apiKey: "k", model: "m"), keyProvider: .tavily, key: keys)?.sourceName
            == "Google Search (Gemini)")
        #expect(SearchSettings.backend(mode: .byok, provider: .custom, cloud: nil, keyProvider: .brave, key: keys)?.sourceName == "Brave Search")
        #expect(SearchSettings.backend(mode: .local, provider: .openRouter, cloud: nil, keyProvider: nil, key: keys) == nil)
        #expect(Skill.marketLookup.job == .advice) // hybrid: the cloud model with search answers first
        #expect(Skill.marketLookup.tools.first == "marketPrice")
    }
}
