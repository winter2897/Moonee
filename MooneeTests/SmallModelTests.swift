import Foundation
import FoundationModels
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

/// Apple Intelligence on the owner's iPhone (feedback 3): status, compact prompt, notices, fallbacks,
/// and keyless gold / exchange-rate prices. No network.
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

    // MARK: Apple status

    @Test func appleStatusFromTheSystem() {
        #expect(AppleStatus(.available, supportsLanguage: true) == .ready)
        #expect(AppleStatus(.available, supportsLanguage: false) == .languageUnsupported)
        #expect(AppleStatus(.unavailable(.deviceNotEligible), supportsLanguage: true) == .notEligible)
        #expect(AppleStatus(.unavailable(.appleIntelligenceNotEnabled), supportsLanguage: true) == .notEnabled)
        #expect(AppleStatus(.unavailable(.modelNotReady), supportsLanguage: true) == .downloading)
        #expect(AppleStatus.languageUnsupported.canRun && !AppleStatus.notEnabled.canRun)
        #expect(AINotice(LLMError("x")) == .failed)
        #expect(AINotice(AINotice.tooLong) == .tooLong)
    }

    @Test func onDeviceWithoutAppleSaysWhyAndStillWorks() async {
        let a = Assistant(router: AIRouter(mode: .onDevice, appleStatus: .notEnabled), tools: Books.tools, language: "vi")
        let parsed = await a.reply("phở 45k", context: ctx)
        #expect(parsed.output == .transactions(QuickParser.parse("phở 45k", context: ctx), usedModel: false))
        #expect(parsed.notice == .appleUnavailable(.notEnabled))
        #expect(parsed.noticeText?.contains(AppleStatus.notEnabled.text) == true)

        let answered = await a.reply("tháng này mình tiêu bao nhiêu?", context: ctx)
        guard case .facts = answered.output else { Issue.record("expected facts"); return }
        #expect(answered.notice == .appleUnavailable(.notEnabled))
        // Apple is there, or the user picked another mode: nothing to say.
        #expect(await Assistant(router: AIRouter(mode: .byok, appleStatus: .notEnabled), tools: Books.tools).reply("phở 45k", context: ctx).notice == nil)
    }

    @Test func theOtherOnDeviceModelStandsIn() async {
        let local = ScriptedLLM(small: true, replies: ["Tháng này bạn tiêu 3.400.000 ₫ nè."])
        let a = Assistant(router: AIRouter(mode: .onDevice, local: local, appleStatus: .notEligible), tools: Books.tools, language: "vi")
        let r = await a.reply("tháng này mình tiêu bao nhiêu?", context: ctx)
        #expect(r.output == .answer("Tháng này bạn tiêu 3.400.000 ₫ nè.", skill: "spending-coach"))
        #expect(r.noticeText?.hasSuffix(String(localized: "Moonee asked your other on-device model instead.", table: "AI")) == true)
        #expect(AIRouter(mode: .local, onDevice: local).candidates(for: .quickAnswer).count == 1)
    }

    @Test func overflowRetriesTightThenFallsBack() async {
        let history = (1...8).map { LLMMessage(role: $0 % 2 == 0 ? .assistant : .user, text: String(repeating: "chi tiêu ", count: 80)) }
        let apple = FlakyLLM(errors: [AINotice.tooLong], replies: ["Tháng này bạn tiêu 3.400.000 ₫."])
        let a = Assistant(router: AIRouter(mode: .onDevice, onDevice: apple), tools: Books.tools, language: "vi")
        let r = await a.reply("tháng này mình tiêu bao nhiêu?", history: history, context: ctx)
        #expect(r.output == .answer("Tháng này bạn tiêu 3.400.000 ₫.", skill: "spending-coach"))
        #expect(r.notice == .tooLong)
        #expect(apple.requests.map(\.messages.count) == [5, 1]) // 4 clipped turns + the question, then the question alone
        #expect(apple.requests[0].messages.allSatisfy { $0.text.count <= CompactPrompt.turnChars + 1 })

        // Guardrails: no retry, the numbers answer, and the chat is told.
        let blocked = FlakyLLM(errors: [AINotice.blocked])
        let b = await Assistant(router: AIRouter(mode: .onDevice, onDevice: blocked), tools: Books.tools, language: "vi")
            .reply("tháng này mình tiêu bao nhiêu?", context: ctx)
        guard case .facts = b.output else { Issue.record("expected facts"); return }
        #expect(blocked.requests.count == 1)
        #expect(b.noticeText == AINotice.blocked.text(answeredByModel: false))
    }

    @Test func englishWhenAppleCantSpeakVietnamese() async {
        let apple = ScriptedLLM(small: true, replies: ["You spent ₫3,400,000 this month."])
        var a = Assistant(router: AIRouter(mode: .onDevice, onDevice: apple), tools: Books.tools, language: "vi")
        a.router.onDevice = AppleStandIn(apple, replyLanguage: "en")
        let r = await a.reply("tháng này mình tiêu bao nhiêu?", context: ctx)
        #expect(r.notice == .answeredInEnglish)
        #expect(apple.requests[0].system.hasPrefix(Skill.persona(language: "en", short: true)))
    }

    // MARK: Compact prompt

    @Test func compactPromptStaysSmall() async {
        let apple = ScriptedLLM(small: true, replies: ["ok"])
        let a = Assistant(router: AIRouter(mode: .onDevice, onDevice: apple), tools: Books.tools, language: "vi")
        _ = await a.handle("tháng này mình tiêu bao nhiêu?", history: [.init(role: .user, text: "chào")], context: ctx)
        let r = apple.requests[0]
        #expect(r.tools.isEmpty)
        #expect(r.system.hasPrefix(Skill.persona(language: "vi", short: true)))
        #expect(r.system.contains(Skill.spendingCoach.instructions(language: "vi", short: true)))
        #expect(r.system.contains("FACTS"))
        // ~3 characters a Vietnamese token: well inside Apple's 4096-token window with room for the answer.
        #expect(r.system.count + r.messages.map(\.text.count).reduce(0, +) < 3_600)
        #expect(Skill.persona(language: "vi", short: true).count < 400)
        #expect(!Skill.persona(language: "vi").contains("<!-- short -->"))

        let hits = (1...5).map { SearchHit(title: "t\($0)", url: "https://a\($0).vn", text: String(repeating: "x", count: 500)) }
        let search = try! AITool.encode(SearchResult(configured: true, source: "Tavily", searchedAt: "now", results: hits, summary: "s"))
        let facts = CompactPrompt.facts([.init(tool: "webSearch", json: search)])
        #expect(facts.count < CompactPrompt.factsChars + 20)
        #expect(facts.contains("https://a3.vn") && !facts.contains("https://a4.vn"))
    }

    @Test func rulesThatReadEverythingSkipTheSmallModel() async {
        let apple = ScriptedLLM(small: true, replies: [])
        let a = Assistant(router: AIRouter(mode: .onDevice, onDevice: apple), tools: Books.tools, language: "vi")
        let r = await a.parse("phở 45k", context: ctx)
        #expect(!r.usedModel && r.txns.first?.amount == 45_000 && apple.requests.isEmpty)
        #expect(!Assistant.rulesComplete(QuickParser.parse("ăn trưa với team", context: ctx)))
    }

    @Test func appleReadingIsMappedAndPrefixed() {
        let item = AppleParsedTxn(amountText: "59k", kind: "expense", category: "food", wallet: nil, toWallet: nil, jar: nil,
                                  toJar: nil, person: nil, dateText: "", note: "Highlands").parsed
        #expect(item.amountText == "59k" && item.dateText == nil && item.category == "food")
        let txns = TransactionExtractor.validate([item], text: "highlands 59k", rules: QuickParser.parse("highlands 59k", context: ctx), context: ctx)
        #expect(txns?.first?.categoryKey == "category.food")
    }

    // MARK: Keyless prices

    @Test func goldFromPNJ() async throws {
        let stub = StubTransport([Self.pnj])
        let prices = MarketPrices(send: stub.send, cache: QuoteCache(), now: { Books.now })
        let q = try await prices.quote("SJC", currency: "VND", locale: Locale(identifier: "en_US"))
        #expect(q.source == "PNJ" && q.url?.contains("pnj.com.vn") == true)
        #expect(q.prices.map(\.price) == ["₫138,000,000", "₫141,000,000"]) // thousands per chỉ × 10 chỉ per lượng
        #expect(q.prices[1].label?.contains("Vàng miếng SJC 999.9") == true)
        #expect(q.updatedAt == "2026-11-06T01:39:51Z")
        #expect(stub.requests[0].timeoutInterval == MarketPrices.timeout)

        let both = try await MarketPrices(send: StubTransport([Self.pnj]).send, cache: QuoteCache()).quote("GOLD", currency: "VND", locale: .init(identifier: "en_US"))
        #expect(both.prices.count == 4)
    }

    @Test func ratesFromVietcombankAreCached() async throws {
        let stub = StubTransport([Self.vcb])
        let prices = MarketPrices(send: stub.send, cache: QuoteCache(), now: { Books.now })
        let usd = try await prices.quote("usd", currency: "VND", locale: Locale(identifier: "en_US"))
        #expect(usd.source == "Vietcombank")
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

    /// The owner's example: Apple (or a local model), no search key, still gets the real price, with its source.
    @Test func goldQuestionOnDeviceWithoutKey() async throws {
        var tools = Books.tools
        tools.prices = MarketPrices(send: StubTransport([Self.pnj]).send, cache: QuoteCache())
        let apple = ScriptedLLM(small: true, replies: ["Theo PNJ lúc 8:39 sáng nay, vàng miếng SJC bán ra ₫141,000,000 một lượng nè."])
        let a = Assistant(router: AIRouter(mode: .onDevice, onDevice: apple), tools: tools, language: "vi")
        let r = await a.reply("Giá vàng sjc nay là bao nhiêu thế", context: ctx)
        guard case .answer(_, "market-lookup", let sources) = r.output else { Issue.record("expected an answer"); return }
        #expect(sources.map(\.site) == ["pnj.com.vn"])
        let system = try #require(apple.requests.first?.system)
        #expect(system.contains("₫141,000,000"))
        #expect(!system.contains("webSearch:")) // the price answered it: no search
        #expect(r.notice == nil)

        // No model at all: the plain numbers, labelled.
        var none = tools
        none.prices = MarketPrices(send: StubTransport([Self.pnj]).send, cache: QuoteCache())
        let facts = await Assistant(router: AIRouter(mode: .onDevice), tools: none, language: "vi").handle("giá vàng sjc", context: ctx)
        guard case .facts(let f, _) = facts else { Issue.record("expected facts"); return }
        #expect(ChatBook.factsText(f)?.contains("**₫141,000,000**") == true)
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

/// Wraps a scripted model as Apple would be set up for an unsupported language.
struct AppleStandIn: LLM {
    let inner: ScriptedLLM
    let replyLanguage: String?
    var isSmall: Bool { true }
    init(_ inner: ScriptedLLM, replyLanguage: String) { (self.inner, self.replyLanguage) = (inner, replyLanguage) }
    func respond(_ r: LLMRequest) async throws -> String { try await inner.respond(r) }
}
