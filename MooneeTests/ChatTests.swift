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
        ChatBook.setCategory(fun, of: first, in: context)
        #expect(first.jar?.key == "jar.play") // re-pinned
        ChatBook.setCategory(try category("category.shopping"), of: first, in: context)
        ChatBook.setCategory(fun, of: first, in: context)
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
}
