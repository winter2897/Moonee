import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor struct ChatTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
}
