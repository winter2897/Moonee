import Foundation
import SwiftData
import Testing
@testable import Moonee

/// P1-2 (S28): "Update balance" records the difference, and "Don't count in reports" keeps a txn out of every total
/// while it still moves its wallet.
@MainActor struct AdjustExcludeTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func at(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }

    /// Seeded store (6 jars, categories, cash wallet 1tr), salary 10tr split by percent, food 200k, both in October.
    func store() throws -> (context: ModelContext, cash: Wallet) {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        Seed.ifNeeded(context)
        let cash = try #require(try context.fetch(FetchDescriptor<Wallet>()).first)
        cash.initialBalance = 1_000_000
        let jars = try context.fetch(FetchDescriptor<Jar>())
        let categories = try context.fetch(FetchDescriptor<Moonee.Category>())
        for (amount, kind, key) in [(10_000_000, TxKind.income, "category.salary"), (200_000, .expense, "category.food")] {
            let t = Txn(amount: amount, kind: kind, currencyCode: "VND", date: at(10, 3), category: categories.first { $0.key == key }, wallet: cash)
            context.insert(t)
            t.allocate(jars: jars, in: context)
        }
        try context.save()
        return (context, cash)
    }

    func ledger(_ context: ModelContext) throws -> Ledger<PersistentIdentifier> {
        Ledger(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: try context.fetch(FetchDescriptor<Wallet>()),
               jars: try context.fetch(FetchDescriptor<Jar>()))
    }

    func report(_ context: ModelContext) throws -> MonthReport {
        MonthReport(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: try context.fetch(FetchDescriptor<Wallet>()),
                    jars: try context.fetch(FetchDescriptor<Jar>()), month: at(10, 15), calendar: cal)
    }

    @Test func excludedEntriesMoveWalletsOnly() {
        let l = Ledger<String>(entries: [
            .init(kind: .income, amount: 1_000, date: .now, wallet: "cash", splits: ["needs": 1_000]),
            .init(kind: .expense, amount: 300, date: .now, wallet: "cash", jar: "needs"),
            .init(kind: .expense, amount: 200, date: .now, wallet: "cash", jar: "needs", excluded: true),
            .init(kind: .income, amount: 500, date: .now, wallet: "cash", splits: ["needs": 500], excluded: true),
        ])
        #expect(l.walletBalance("cash") == 1_000)
        #expect(l.jarBalance("needs") == 700) // neither excluded entry touches the jar
        #expect(l.unallocated == 300) // +500 found, −200 paid for someone else
        #expect(l.income(in: DateInterval(start: .distantPast, end: .distantFuture)) == 1_000)
    }

    @Test func adjustmentChangesUnallocatedByTheDifferenceOnly() throws {
        let (context, cash) = try store()
        let before = try ledger(context), reportBefore = try report(context)
        #expect(before.walletBalance(cash.persistentModelID) == 10_800_000)

        let up = try #require(BudgetActions.adjustBalance(cash, to: 11_500_000, date: at(10, 10), level: .suggest, in: context))
        #expect(up.kind == .income && up.amount == 700_000 && up.excludedFromReport && up.category?.key == Seed.adjustmentKey)
        let after = try ledger(context)
        #expect(after.walletBalance(cash.persistentModelID) == 11_500_000)
        #expect(after.unallocated - before.unallocated == 700_000)
        #expect(after.jarBalances == before.jarBalances)

        let down = try #require(BudgetActions.adjustBalance(cash, to: 11_000_000, date: at(10, 11), level: .suggest, in: context))
        #expect(down.kind == .expense && down.amount == 500_000 && down.jar == nil)
        let last = try ledger(context)
        #expect(last.unallocated - after.unallocated == -500_000)
        #expect(last.jarBalances == before.jarBalances)
        #expect(BudgetActions.adjustBalance(cash, to: 11_000_000, in: context) == nil) // nothing to fix

        // The report is unchanged, and shows what it kept out.
        let r = try report(context)
        #expect(r.income == reportBefore.income && r.spent == reportBefore.spent)
        #expect(r.excludedIn == 700_000 && r.excludedOut == 500_000)
        // One fixed category, made once, never in a picker (kind .transfer) or a jar.
        let adjustments = try context.fetch(FetchDescriptor<Moonee.Category>()).filter { $0.key == Seed.adjustmentKey }
        #expect(adjustments.count == 1 && adjustments[0].kind == .transfer && adjustments[0].jar == nil)
    }

    @Test func ledgerOverviewAndReportAgreeWithExcludedTxns() throws {
        let (context, cash) = try store()
        let food = try #require(try context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == "category.food" })
        let boss = Txn(amount: 500_000, kind: .expense, currencyCode: "VND", date: at(10, 5), note: "chi hộ sếp", category: food, wallet: cash)
        context.insert(boss)
        boss.allocate(jars: try context.fetch(FetchDescriptor<Jar>()), in: context)
        TxnEdit.apply(to: boss, amount: boss.amount, date: boss.date, note: boss.note, category: food, wallet: cash, toWallet: nil,
                      excluded: true, in: context)
        #expect(boss.excludedFromReport && boss.jar == nil)
        try context.save()

        let txns = try context.fetch(FetchDescriptor<Txn>()), wallets = try context.fetch(FetchDescriptor<Wallet>())
        let jars = try context.fetch(FetchDescriptor<Jar>())
        let now = at(10, 15)
        let flow = CashFlow(txns, in: TxnPeriod.current(.month, now: now, calendar: cal).interval)
        let overview = DashboardStats(txns: txns, wallets: wallets, jars: jars, assets: [], period: .month, now: now, calendar: cal)
        let report = MonthReport(txns: txns, wallets: wallets, jars: jars, month: now, calendar: cal)
        #expect(flow.expense == 200_000 && flow.excludedOut == 500_000)
        #expect(overview.expense == flow.expense && report.spent == flow.expense)
        #expect(overview.income == flow.income && report.income == flow.income)
        #expect(report.byCategory.reduce(0) { $0 + $1.total } == 200_000 && report.top.allSatisfy { !$0.excludedFromReport })
        #expect(TxnPeriod.groups(txns, by: .category).first { $0.name == food.name }?.total == 200_000)
        #expect(SpendingSummary(txns: txns, period: .month, anchor: now, calendar: cal).total == 200_000)
        // Still out of the wallet.
        #expect(try ledger(context).walletBalance(cash.persistentModelID) == 10_300_000)

        // Counted again: back into its category's jar.
        TxnEdit.apply(to: boss, amount: boss.amount, date: boss.date, note: boss.note, category: food, wallet: cash, toWallet: nil,
                      excluded: false, in: context)
        #expect(!boss.excludedFromReport && boss.jar == food.jar)
    }

    @Test func chatAsksWhetherAWorkSpendIsPaidBack() throws {
        let (context, _) = try store()
        let parser = ParserContext(context)
        for text in ["chi hộ sếp 500k", "công tác phí 2tr"] {
            let parsed = QuickParser.parse(text, context: parser)
            let saved = ChatBook.save(parsed, source: .text, rawInput: text, level: .suggest, in: context)
            var ask = try #require(ChatBook.reimburseQuestion(saved), "\(text): \(saved.map(\.note))")
            #expect(ChatBook.Lookup(context).asking(ask) == .reimbursed)
            #expect(ChatBook.Lookup(context).choices(.reimbursed, for: ask) == [ChatBook.reimbursedYes, ChatBook.reimbursedNo])
            #expect(!ChatBook.fill(&ask, .reimbursed, from: "45k", context: parser)) // not an answer
            #expect(ChatBook.fill(&ask, .reimbursed, from: ChatBook.reimbursedYes, context: parser))
            ChatBook.setReimbursed(ask, in: context)
            #expect(saved[0].excludedFromReport && saved[0].jar == nil)
        }
        #expect(ChatBook.reimburseQuestion(ChatBook.save(QuickParser.parse("phở 45k", context: parser), source: .text, rawInput: "phở 45k",
                                                         level: .suggest, in: context)) == nil)
        #expect(ChatBook.reimbursedAnswer("không") == false && ChatBook.reimbursedAnswer("có nha") == true)
        #expect(ChatBook.reimbursedAnswer("ไม่ได้") == false && ChatBook.reimbursedAnswer("ใช่") == true && ChatBook.reimbursedAnswer("No") == false)
    }
}
