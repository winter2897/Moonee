import Foundation
import PDFKit
import SwiftData
import UIKit
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

    @Test func newLoanAsksWhenItIsDueBackAndSavesTheAnswer() throws {
        let lent = say("cho Nam mượn 500k")
        var ask = try #require(ChatBook.dueQuestion(lent))
        #expect(ask.person == "Nam" && ask.kind == .lend)
        let book = ChatBook.Lookup(context)
        #expect(book.unresolved(ask) == nil && book.asking(ask) == .dueDate) // already saved: only the date is asked
        #expect(book.choices(.dueDate, for: ask).count == 4)
        #expect(ChatLines.question(.dueDate, ask, variant: 0) == "When will Nam pay you back?")

        // A new transaction is not an answer; a chip or a date is.
        var other = ask
        #expect(!ChatBook.fill(&other, .dueDate, from: "ăn trưa hôm qua 50k", context: parser()))
        #expect(ChatBook.fill(&ask, .dueDate, from: "Cuối tháng", context: parser()))
        let endOfMonth = Calendar.current.dateInterval(of: .month, for: .now)!.end.addingTimeInterval(-1)
        #expect(ask.dueDate.map { Calendar.current.isDate($0, inSameDayAs: endOfMonth) || $0 > endOfMonth } == true)
        ChatBook.setDue(ask, in: context)
        #expect(lent.first?.debt?.dueDate == ask.dueDate)

        // "Không thời hạn" saves none; a second loan to Nam is not asked again.
        var none = try #require(ChatBook.dueQuestion(say("Lan cho mình vay 2tr")))
        #expect(none.kind == .borrow && none.person == "Lan")
        #expect(ChatBook.fill(&none, .dueDate, from: "Không thời hạn", context: parser()) && none.dueDate == nil)
        #expect(ChatBook.dueQuestion(say("cho Nam mượn 100k")) == nil)
    }

    @Test func repaymentInChatReducesTheDebt() throws {
        let debt = try #require(say("cho Nam mượn 500k").first?.debt)
        let paid = say("Nam trả 200k")
        #expect(paid.first?.kind == .repay && paid.first?.debt === debt)
        #expect(ChatBook.debtLeft(paid, in: context) == "Nam still owes you **\(Money(300_000, "VND").formatted())**.")
        #expect(ChatBook.debtLeft(say("Nam trả nợ 300k"), in: context) == "All settled with Nam!")
        #expect(DebtBook.line(debt, in: context).remaining == 0)
        // A shop before "trả" is still spending; so is a person with no debt.
        #expect(say("cafe trả bằng momo 30k").first?.kind == .expense)
    }

    @Test func closingADebtByHandDropsItEverywhere() async throws {
        let debt = try #require(say("cho Hùng mượn 1tr").first?.debt)
        #expect(try await StoreLedger(context, currency: "VND").debts().map(\.person) == ["Hùng"])
        DebtBook.close(debt, in: context)
        #expect(DebtBook.line(debt, in: context).remaining == 0)
        #expect(try await StoreLedger(context, currency: "VND").debts().isEmpty)
        // Lending to Hùng again starts a new debt.
        #expect(say("cho Hùng mượn 200k").first?.debt !== debt)
    }

    @Test func debtBookFactsAnswerWhoOwesMe() async throws {
        _ = say("cho Nam mượn 500k")
        _ = say("Lan cho mình vay 2tr")
        let json = try await MooneeTools(ledger: StoreLedger(context, currency: "VND")).debtBook.run(Data("{}".utf8))
        let text = try #require(ChatBook.factsText([.init(tool: "debtBook", json: json)]))
        #expect(text.contains("Nam") && text.contains("Lan") && text.contains(Money(500_000, "VND").formatted()))
        #expect(Skill.route("ai đang nợ mình?", context: parser()).id == "debt-tracking")
        #expect(Skill.route("who owes me money?", context: parser()).id == "debt-tracking")
        #expect(Skill.route("cho Nam mượn 2tr", context: parser()).id == "transaction-parser")
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

    @Test func receiptTakesTheTotalLine() throws {
        var c = ParserContext()
        c.currency = "VND"
        let t = try #require(ChatBook.receipt(OCRLine.plain(["HIGHLANDS COFFEE", "Phin sữa đá  29.000", "Bánh mì  29.000", "Tổng cộng  58.000",
                                                             "Tiền khách đưa  100.000"]), context: c).first)
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

    @Test func theChatRollsOverToTodayWhenTheDayChanges() {
        let cal = Self.hcm
        let late = ChatThreads.forNewMessage(open: nil, resumed: false, now: at(5, 23, 58), calendar: cal, in: context)
        // Same day: whatever is open stays, a thread reopened from history too.
        let same = ChatThreads.onScreen(open: late, resumed: true, lastCheck: at(5, 23, 58), now: at(5, 23, 59), calendar: cal, in: context)
        #expect(same.thread === late && same.resumed)
        // Past midnight (or back the next morning): today's thread, none yet, so the first message starts it.
        let next = ChatThreads.onScreen(open: late, resumed: true, lastCheck: at(5, 23, 59), now: at(6, 0, 1), calendar: cal, in: context)
        #expect(next.thread == nil && !next.resumed)
        // A "New chat" yesterday doesn't swallow today's messages; today's existing thread is shown.
        let manual = ChatThreads.start(now: at(5, 22), calendar: cal, in: context)
        let today = ChatThreads.forNewMessage(open: nil, resumed: false, now: at(6, 8), calendar: cal, in: context)
        let shown = ChatThreads.onScreen(open: manual, resumed: true, lastCheck: at(5, 22), now: at(6, 9), calendar: cal, in: context)
        #expect(shown.thread === today && !shown.resumed)
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
        #expect(ChatBook.sources(facts).map(\.url.absoluteString) == ["https://www.vnexpress.net/gia-vang", "https://sjc.com.vn"])
        #expect(ChatBook.sources(facts).map(\.site) == ["vnexpress.net", "sjc.com.vn"])

        let off = SearchResult(configured: false, searchedAt: "2026-11-06T09:00:00Z", message: "Web search is not set up.")
        let offFacts = [Assistant.ToolResult(tool: "webSearch", json: String(decoding: try JSONEncoder().encode(off), as: UTF8.self))]
        #expect(ChatBook.factsText(offFacts)?.contains("Tavily") == true)
        #expect(ChatBook.sources(offFacts).isEmpty)
    }

    @Test func marketPriceFactsShowEveryPrice() throws {
        let q = MarketPrices.Quote(symbol: "btc", coin: "bitcoin", prices: [.init(currency: "VND", price: "2.500.000.000 ₫"), .init(currency: "USD", price: "$98,000")])
        let text = ChatBook.factsText([.init(tool: "marketPrice", json: String(decoding: try JSONEncoder().encode(q), as: UTF8.self))])
        #expect(text?.hasPrefix("**Bitcoin (BTC)**: 2.500.000.000 ₫ · $98,000") == true)
        #expect(text?.contains(MarketPrices.sourceName) == true && text?.contains("CoinGecko") == false)
    }

    @Test func messagesKeepTheirSources() {
        let m = ChatMessage(fromUser: false, text: "")
        #expect(m.sourcesData == nil)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        m.sources = [WebSource(title: "A", url: URL(string: "https://a.vn/x")!, site: "a.vn", date: when)]
        #expect(m.sources == [WebSource(title: "A", url: URL(string: "https://a.vn/x")!, site: "a.vn", date: when)])
        m.sources = []
        #expect(m.sourcesData == nil)
    }

    // MARK: Model chip

    @Test func chipNamesTheEngineThatReallyAnswers() {
        let model = ScriptedLLM(replies: [])
        #expect(ChatEngine.current(AIRouter(mode: .byok), provider: .openRouter) == .needsKey(.openRouter)) // BYOK, no key
        #expect(ChatEngine.current(AIRouter(mode: .local), provider: .openRouter) == .offline) // nothing downloaded
        #expect(ChatEngine.current(AIRouter(mode: .byok, cloud: model), provider: .deepSeek, model: "deepseek-chat")
                == .cloud(.deepSeek, model: "deepseek-chat"))
        #expect(ChatEngine.current(AIRouter(mode: .hybrid), provider: .gemini) == .needsKey(.gemini))
    }

    @Test func chipLabelsAreShort() {
        #expect(ChatEngine.cloud(.openRouter, model: "google/gemini-3.5-flash-lite").label(effort: nil) == "gemini-3.5-flash-lite")
        #expect(ChatEngine.cloud(.custom, model: "llama-4").label(effort: nil) == "llama-4")
        #expect(ChatEngine.local("Qwen3 1.7B").label(effort: nil) == "Qwen3 1.7B")
        #expect(ChatEngine.cloud(.anthropic, model: "claude-sonnet-5-5").label(effort: .high)
                == "claude-sonnet-5-5 · " + ModelChip.title(.high))
    }

    // MARK: Feedback round 3

    @Test func dailyThreadIsNamedAfterItsDayAndANewChatAfterItsFirstSentence() {
        let cal = Self.hcm
        let daily = ChatThreads.forNewMessage(open: nil, resumed: false, now: at(6, 9), calendar: cal, in: context)
        #expect(!daily.isManual)
        #expect(ChatThreads.dailyTitle(daily.day, calendar: cal).hasSuffix("06/11/26"))
        let manual = ChatThreads.start(now: at(6, 10), calendar: cal, in: context)
        let m = ChatMessage(fromUser: true, text: "Lập kế hoạch tiết kiệm mua xe. Mỗi tháng nên để bao nhiêu?")
        context.insert(m)
        ChatThreads.add(m, to: manual)
        #expect(manual.isManual && manual.displayTitle == "Lập kế hoạch tiết kiệm mua xe")
        #expect(ChatThreads.title(from: "giá 45.000 hôm nay") == "giá 45.000 hôm nay") // a decimal point is not a sentence end
    }

    @Test func modelTitleIsCleanedUp() async {
        let llm = ScriptedLLM(replies: ["\"Tiết kiệm mua xe.\"\nextra"])
        #expect(await ChatThreads.modelTitle(for: "Lập kế hoạch tiết kiệm mua xe", using: llm) == "Tiết kiệm mua xe")
        #expect(await ChatThreads.modelTitle(for: "x", using: nil) == nil)
    }

    @Test func savedLineSaysWhatWhereAndHowMuch() {
        let one = say("ăn sáng ở GS25 40k")
        let line = ChatLines.saved(one, variant: 0)
        #expect(line.contains(Money(40_000, "VND").formatted()) && line.contains("GS25"))
        #expect(!line.contains("1 transaction"))
        let many = say("ăn trưa 65k, cafe 35k")
        #expect(ChatLines.saved(many, variant: 0).contains(Money(100_000, "VND").formatted()))
        #expect(ChatLines.saved(say("ăn trưa 65k, lương 10tr"), variant: 0).contains("2")) // mixed kinds: no total
    }

    @Test func notesReadNaturallyMidSentence() {
        #expect(ChatLines.midSentence("Ăn sáng ở GS25") == "ăn sáng ở GS25")
        #expect(ChatLines.midSentence("GS25 cafe") == "GS25 cafe")
        #expect(ChatLines.midSentence("iPhone case") == "iPhone case")
    }

    @Test func everyExpenseGetsACategoryAndJar() {
        let t = say("zxqw 40k").first
        #expect(t?.category?.key == "category.other")
        let card = t.map { ChatCardLine($0).item() }
        #expect(card?.category.isEmpty == false && card?.when == nil) // today's card shows category · jar, no date
    }

    @Test func voiceUsesTheAppLanguage() {
        let supported: Set<Locale> = [Locale(identifier: "vi-VN"), Locale(identifier: "en-US"), Locale(identifier: "en-GB")]
        #expect(SpeechInput.recognizerLocale(app: "vi", region: "VN", supported: supported)?.identifier == "vi-VN")
        #expect(SpeechInput.recognizerLocale(app: "en", region: "GB", supported: supported)?.identifier == "en-GB")
        #expect(SpeechInput.recognizerLocale(app: "en", region: "VN", supported: supported)?.identifier == "en-US")
        #expect(SpeechInput.recognizerLocale(app: "vi", region: "VN", supported: []) == nil)
        let thai: Set<Locale> = supported.union([Locale(identifier: "th-TH")])
        #expect(SpeechInput.recognizerLocale(app: "th", region: "TH", supported: thai)?.identifier == "th-TH")
        #expect(SpeechInput.recognizerLocale(app: "lo", region: "LA", supported: thai)?.identifier == "th-TH") // no Lao: Thai
        #expect(SpeechInput.recognizerLocale(app: "lo", region: "LA", supported: thai.union([Locale(identifier: "lo-LA")]))?.identifier == "lo-LA")
    }

    @Test func pdfReceiptIsReadFromItsText() async throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { ctx in
            ctx.beginPage()
            for (i, line) in ["Highlands Coffee", "Bạc xỉu  39.000", "Tổng cộng  58.000"].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 20, y: 20 + i * 30), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
        let pdf = try #require(PDFDocument(data: data))
        let lines = await ReceiptScanner.lines(in: pdf)
        #expect(lines.contains { $0.text.contains("Tổng cộng") })
        #expect(lines.map(\.y) == lines.map(\.y).sorted() && lines.allSatisfy { $0.height > 0 }) // with its layout
        let t = try #require(ChatBook.receipt(lines, context: parser()).first)
        #expect(t.amount == 58_000 && t.note == "Highlands Coffee")
    }
}
