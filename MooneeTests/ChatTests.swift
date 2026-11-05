import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor struct ChatTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        Seed.ifNeeded(container.mainContext)
    }

    func parser() -> ParserContext {
        var c = ParserContext(context)
        c.currency = "VND"
        return c
    }

    func say(_ text: String) -> [Txn] {
        ChatBook.save(QuickParser.parse(text, context: parser()), source: .text, rawInput: text, in: context)
    }

    func category(_ key: String) throws -> Moonee.Category { try #require(context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == key }) }

    @Test func multiTransactionMessageSavesEachWithItsJar() throws {
        let saved = say("ăn trưa 65k, mua sách 120k hôm nay")
        #expect(saved.map(\.amount) == [65_000, 120_000])
        #expect(saved.map(\.currencyCode) == ["VND", "VND"])
        #expect(saved.map { $0.category?.key } == ["category.food", "category.education"])
        #expect(saved.map { $0.jar?.key } == ["jar.essentials", "jar.growth"]) // pinned by allocate
        #expect(saved.allSatisfy { $0.wallet != nil && $0.source == .text && Calendar.current.isDateInToday($0.date) })
        #expect(try context.fetchCount(FetchDescriptor<Txn>()) == 2)
    }

    @Test func incomeIsSplitIntoJarsOnce() throws {
        let income = try #require(say("lương 10tr").first)
        #expect(income.kind == .income)
        #expect((income.splits ?? []).map(\.amount).reduce(0, +) == 10_000_000)
        #expect((income.splits ?? []).count == 6)
    }

    @Test func missingAmountIsNotSaved() {
        let t = ParsedTxn(amount: nil, currency: "VND", kind: .expense, categoryKey: "category.food", date: .now, note: "ăn trưa")
        #expect(ChatBook.save([t], source: .text, rawInput: "ăn trưa", in: context).isEmpty)
    }

    @Test func lendingReusesThePersonsDebt() throws {
        let a = try #require(say("cho Nam mượn 2tr").first)
        let b = try #require(say("cho Nam mượn 1tr").first)
        #expect(a.kind == .lend)
        #expect(a.debt != nil && a.debt === b.debt)
        #expect(a.debt?.direction == .lent)
    }

    @Test func undoRemovesTransactionsAndKeepsTheCard() throws {
        let m = ChatMessage(fromUser: false, text: "")
        context.insert(m)
        m.txns = say("ăn trưa 65k, mua sách 120k")
        ChatBook.undo(m, in: context)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Txn>()) == 0)
        #expect(m.undone)
        #expect(ChatBook.undoneLines(m).map(\.amount) == [65_000, 120_000])
        #expect(ChatBook.undoneLines(m).first?.title == "Ăn trưa")
    }

    @Test func categoryEditTeachesTheNextParse() throws {
        let first = try #require(say("highlands 55k").first)
        let fun = try category("category.entertainment")
        TxnEdit.setCategory(fun, of: first, in: context)
        #expect(first.jar?.key == "jar.play") // re-pinned
        TxnEdit.setCategory(try category("category.shopping"), of: first, in: context)
        TxnEdit.setCategory(fun, of: first, in: context)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<MerchantRule>()) == 1) // one rule per merchant, updated

        let next = try #require(say("Highlands 60k").first)
        #expect(next.category?.key == "category.entertainment")
    }

    @Test func storeLedgerAdaptsTheStore() async throws {
        _ = say("lương 10tr")
        _ = say("ăn trưa 65k")
        try context.save()
        let ledger = StoreLedger(context, currency: "VND")
        let jars = try await ledger.jars()
        #expect(jars.map(\.key) == ["jar.essentials", "jar.investing", "jar.savings", "jar.growth", "jar.play", "jar.giving"])
        #expect(jars.first?.balance == 5_500_000 - 65_000)
        let today = Calendar.current.dateInterval(of: .day, for: .now)!
        let txns = try await ledger.transactions(in: today)
        #expect(txns.count == 2)
        let lunch = try #require(txns.first { $0.kind == .expense })
        #expect(lunch.categoryKey == "category.food" && lunch.jarKey == "jar.essentials" && lunch.amount == 65_000)
        #expect(txns.first { $0.kind == .income }?.splits["jar.giving"] == 500_000)

        // The AI tools run on it.
        let json = try await MooneeTools(ledger: ledger).spendingSummary.run(Data(#"{"period":"today"}"#.utf8))
        #expect(ChatBook.factsText([.init(tool: "spendingSummary", json: json)])?.contains("65") == true)
    }

    @Test func parserContextKnowsTheStore() {
        let c = ParserContext(context)
        #expect(c.wallets.count == 1)
        #expect(c.jars.values.contains("jar.play"))
        #expect(c.categories.values.contains("category.food"))
    }

    @Test func receiptTakesTheTotalLine() {
        var c = ParserContext()
        c.currency = "VND"
        let t = ChatBook.receipt(["HIGHLANDS COFFEE", "Phin sữa đá  29.000", "Bánh mì  29.000", "Tổng cộng  58.000", "Tiền khách đưa  100.000"], context: c)
        #expect(t.amount == 58_000)
        #expect(t.note == "HIGHLANDS COFFEE")
        #expect(t.missing.isEmpty)
    }

    // MARK: Ask back instead of saving half a transaction

    @Test func transferWithoutDestinationAsksForTheWallet() throws {
        context.insert(Wallet(name: "Vietcombank", type: .bank, order: 1))
        let cash = try #require(ChatBook.Lookup(context).wallets.first)
        var p = ParsedTxn(amount: 500_000, currency: "VND", kind: .transfer, date: .now, note: "")
        let book = ChatBook.Lookup(context)
        #expect(book.unresolved(p) == .toWallet)
        #expect(ChatBook.save([p], source: .text, rawInput: "", in: context).isEmpty) // money never goes nowhere
        #expect(book.choices(.toWallet, for: p) == ["Vietcombank"])

        p.toWallet = cash.name
        #expect(book.unresolved(p) == .toWallet) // to itself is no transfer

        #expect(ChatBook.fill(&p, .toWallet, from: "vietcombank nhé", context: parser()))
        let t = try #require(ChatBook.save([p], source: .text, rawInput: "", in: context).first)
        #expect(t.wallet == cash && t.toWallet?.name == "Vietcombank")
    }

    @Test func jarTransferAsksForTheMissingJar() throws {
        var p = ParsedTxn(amount: 300_000, currency: "VND", kind: .jarTransfer, jar: "jar.savings", date: .now, note: "")
        let book = ChatBook.Lookup(context)
        #expect(book.unresolved(p) == .toJar)
        #expect(ChatBook.save([p], source: .text, rawInput: "", in: context).isEmpty)
        #expect(book.choices(.toJar, for: p).count == 5) // every jar but the source

        #expect(!ChatBook.fill(&p, .toJar, from: "ừm", context: parser()))
        #expect(ChatBook.fill(&p, .toJar, from: "hưởng thụ", context: parser()))
        let t = try #require(ChatBook.save([p], source: .text, rawInput: "", in: context).first)
        #expect(t.jar?.key == "jar.savings" && t.toJar?.key == "jar.play")

        var noSource = ParsedTxn(amount: 1, currency: "VND", kind: .jarTransfer, date: .now, note: "")
        #expect(book.unresolved(noSource) == .jar)
        #expect(ChatBook.fill(&noSource, .jar, from: "tiết kiệm", context: parser()) && noSource.jar == "jar.savings")
    }

    @Test func amountAnswerFillsTheWaitingTransaction() {
        var p = ParsedTxn(amount: nil, currency: "VND", kind: .expense, categoryKey: "category.food", date: .now, note: "ăn trưa")
        #expect(ChatBook.Lookup(context).unresolved(p) == .amount)
        #expect(ChatBook.fill(&p, .amount, from: "65k", context: parser()))
        #expect(p.amount == 65_000 && p.missing.isEmpty)
    }

    // MARK: Undo and debts

    @Test func undoDeletesTheDebtItsLendCreated() throws {
        let m = ChatMessage(fromUser: false, text: "")
        context.insert(m)
        m.txns = say("cho Nam mượn 2tr")
        #expect(try context.fetchCount(FetchDescriptor<Debt>()) == 1)
        ChatBook.undo(m, in: context)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Debt>()) == 0)
    }

    @Test func undoKeepsADebtThatHasOtherTransactions() throws {
        let earlier = try #require(say("cho Nam mượn 1tr").first)
        let m = ChatMessage(fromUser: false, text: "")
        context.insert(m)
        m.txns = say("cho Nam mượn 2tr")
        ChatBook.undo(m, in: context)
        try context.save()
        let debts = try context.fetch(FetchDescriptor<Debt>())
        #expect(debts.count == 1 && debts.first === earlier.debt)
        #expect(debts.first?.txns?.count == 1)
    }

    // MARK: The shared editor

    @Test func editorRescalesAnIncomesSplits() throws {
        let income = try #require(say("lương 10tr").first)
        TxnEdit.apply(to: income, amount: 20_000_000, date: income.date, note: income.note, category: income.category,
                      wallet: income.wallet, toWallet: nil, in: context)
        let splits = income.splits ?? []
        #expect(splits.map(\.amount).reduce(0, +) == 20_000_000)
        #expect(splits.first { $0.jar?.key == "jar.giving" }?.amount == 1_000_000) // 5% kept
    }

    @Test func editorCategoryChangeRepinsAndLearns() throws {
        let t = try #require(say("highlands 55k").first)
        TxnEdit.apply(to: t, amount: t.amount, date: t.date, note: "  Highlands ", category: try category("category.entertainment"),
                      wallet: t.wallet, toWallet: nil, in: context)
        try context.save()
        #expect(t.note == "Highlands" && t.jar?.key == "jar.play")
        #expect(try context.fetch(FetchDescriptor<MerchantRule>()).map(\.pattern) == ["highlands"])
        #expect(say("highlands 40k").first?.category?.key == "category.entertainment")
    }

    // MARK: Threads

    static let hcm: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.hcm.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func aNewDayStartsANewThread() {
        let cal = Self.hcm
        let late = ChatThreads.forNewMessage(open: nil, resumed: false, now: at(5, 23, 58), calendar: cal, in: context)
        #expect(ChatThreads.forNewMessage(open: late, resumed: false, now: at(5, 23, 59), calendar: cal, in: context) === late)

        let next = ChatThreads.forNewMessage(open: late, resumed: false, now: at(6, 0, 1), calendar: cal, in: context)
        #expect(next !== late)
        #expect(next.day == at(6, 0))
        // Reopened from history, the old thread keeps going.
        #expect(ChatThreads.forNewMessage(open: late, resumed: true, now: at(6, 9), calendar: cal, in: context) === late)
        // With nothing open, today's newest thread is reused.
        #expect(ChatThreads.forNewMessage(open: nil, resumed: false, now: at(6, 10), calendar: cal, in: context) === next)
    }

    @Test func newChatAddsASecondThreadToday() {
        let cal = Self.hcm
        let first = ChatThreads.forNewMessage(open: nil, resumed: false, now: at(6, 9), calendar: cal, in: context)
        let second = ChatThreads.start(now: at(6, 10), calendar: cal, in: context)
        #expect(second !== first && second.day == first.day)
        #expect(ChatThreads.todays(now: at(6, 11), calendar: cal, in: context) === second)
    }

    @Test func oldMessagesMoveIntoOneThreadPerDay() throws {
        for (day, hour, user, text) in [(4, 8, true, "phở 45k"), (4, 8, false, "ok"), (5, 9, false, "hi"), (5, 9, true, "cafe 29k\nsáng")] {
            context.insert(ChatMessage(fromUser: user, text: text, date: at(day, hour, user ? 0 : 1)))
        }
        ChatThreads.migrate(calendar: Self.hcm, in: context)
        let threads = try context.fetch(FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.day)]))
        #expect(threads.map(\.day) == [at(4, 0), at(5, 0)])
        #expect(threads.map { $0.messages?.count } == [2, 2])
        #expect(threads.map(\.title) == ["phở 45k", "cafe 29k"]) // first user message, first line
        ChatThreads.migrate(calendar: Self.hcm, in: context) // runs once
        #expect(try context.fetchCount(FetchDescriptor<ChatThread>()) == 2)
    }

    @Test func deletingAThreadKeepsItsTransactions() throws {
        let t = ChatThreads.start(in: context)
        let m = ChatMessage(fromUser: false, text: "")
        context.insert(m)
        ChatThreads.add(m, to: t)
        m.txns = say("ăn trưa 65k, mua sách 120k")
        try context.save()

        context.delete(t)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ChatThread>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChatMessage>()) == 0)
        let txns = try context.fetch(FetchDescriptor<Txn>())
        #expect(txns.count == 2 && txns.allSatisfy { $0.chatMessage == nil })
    }

    @Test func historyListsPinnedFirstThenByDay() {
        let cal = Self.hcm
        func thread(_ day: Int, _ title: String, hour: Int = 9, pinned: Bool = false) -> ChatThread {
            let t = ChatThreads.start(now: at(day, hour), calendar: cal, in: context)
            let m = ChatMessage(fromUser: true, text: title, date: at(day, hour))
            context.insert(m)
            ChatThreads.add(m, to: t)
            t.isPinned = pinned
            return t
        }
        let a = thread(3, "lương tháng 11"), b = thread(4, "phở 45k", pinned: true), c = thread(5, "cafe 29k"), d = thread(5, "grab 32k", hour: 10)
        _ = ChatThreads.start(now: at(5, 12), calendar: cal, in: context) // empty: not listed

        let sections = ChatThreads.sections([a, b, c, d], calendar: cal)
        #expect(sections.map(\.kind) == [.pinned, .day(at(5, 0)), .day(at(3, 0))])
        #expect(sections.map { $0.threads.map(\.title) } == [["phở 45k"], ["grab 32k", "cafe 29k"], ["lương tháng 11"]])
        #expect(ChatThreads.sections([a, b, c, d], query: "PHO", calendar: cal).flatMap(\.threads).map(\.title) == ["phở 45k"])
    }

    @Test func titlesAreShortAndCutOnAWord() {
        #expect(ChatThreads.title(from: "  phở 45k  ") == "phở 45k")
        let long = ChatThreads.title(from: "tháng này mình đã chi bao nhiêu cho ăn uống và cafe vậy Moonee")
        #expect(long.count <= 41 && long.hasSuffix("…") && !long.dropLast().hasSuffix(" "))
    }

    // MARK: Web answers without a model

    @Test func webSearchFactsBecomeTextAndSourceChips() throws {
        let found = SearchResult(configured: true, source: "Tavily", searchedAt: "2026-11-06T09:00:00Z",
                                 results: [.init(title: "Giá vàng SJC hôm nay", url: "https://www.vnexpress.net/gia-vang", text: "…", date: "2 hours ago"),
                                           .init(title: "SJC", url: "https://sjc.com.vn", text: "…")])
        let facts = [Assistant.ToolResult(tool: "webSearch", json: String(decoding: try JSONEncoder().encode(found), as: UTF8.self))]
        #expect(ChatBook.factsText(facts)?.contains("**Giá vàng SJC hôm nay**") == true)
        #expect(ChatBook.sources(facts).map(\.url) == ["https://www.vnexpress.net/gia-vang", "https://sjc.com.vn"])
        #expect(SourceChips.site(ChatBook.sources(facts)[0]) == "vnexpress.net")

        let off = SearchResult(configured: false, searchedAt: "2026-11-06T09:00:00Z", message: "Web search is not set up.")
        let offFacts = [Assistant.ToolResult(tool: "webSearch", json: String(decoding: try JSONEncoder().encode(off), as: UTF8.self))]
        #expect(ChatBook.factsText(offFacts)?.contains("Tavily") == true)
        #expect(ChatBook.sources(offFacts).isEmpty)
    }

    @Test func marketPriceFactsShowEveryPrice() throws {
        let q = MarketPrices.Quote(symbol: "btc", coin: "bitcoin", prices: [.init(currency: "VND", price: "2.500.000.000 ₫"), .init(currency: "USD", price: "$98,000")])
        let text = ChatBook.factsText([.init(tool: "marketPrice", json: String(decoding: try JSONEncoder().encode(q), as: UTF8.self))])
        #expect(text?.hasPrefix("**Bitcoin (BTC)**: 2.500.000.000 ₫ · $98,000") == true)
        #expect(text?.contains("CoinGecko") == true)
    }

    @Test func messagesKeepTheirSources() {
        let m = ChatMessage(fromUser: false, text: "")
        #expect(m.sourcesData == nil)
        m.sources = [.init(title: "A", url: "https://a.vn", text: "")]
        #expect(m.sources.map(\.url) == ["https://a.vn"])
        m.sources = []
        #expect(m.sourcesData == nil)
    }
}
