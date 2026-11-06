import Foundation
import SwiftData
import Testing
@testable import Moonee

/// The whole money workflow (spec §3, §4, §7): onboarding → salary → split into jars → spend → Budget numbers → assistant.
@MainActor struct MoneyFlowTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func at(_ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }
    func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d))! }

    func seeded() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        Seed.ifNeeded(context)
        return context
    }

    func facts(_ context: ModelContext, now: Date) throws -> BudgetFacts {
        BudgetFacts(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: try context.fetch(FetchDescriptor<Wallet>()),
                    jars: try context.fetch(FetchDescriptor<Jar>()), recurrings: try context.fetch(FetchDescriptor<Recurring>()),
                    now: now, calendar: cal)
    }

    func jars(_ context: ModelContext) throws -> [Jar] { try context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)])) }

    func category(_ key: String, _ context: ModelContext) throws -> Moonee.Category {
        try #require(try context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == key })
    }

    /// The owner's case: 15tr salary on the 25th, a bank account with 38tr. Onboarding on 6 Nov.
    func onboarded() throws -> (ModelContext, Recurring) {
        let context = try seeded()
        let salary = try #require(OnboardingBook.saveSalary(15_000_000, payday: 25, regular: true, now: at(11, 6), calendar: cal, in: context))
        OnboardingBook.saveWallets([.init(type: .bank, name: "ACB", amount: 38_000_000)], in: context)
        let jars = try jars(context)
        OnboardingBook.applyJars(jars.map(\.percent), to: jars, now: at(11, 6), in: context)
        return (context, salary)
    }

    @Test func onboardingSalarySplitExpense() throws {
        let (context, salary) = try onboarded()
        let jars = try jars(context)

        // Opening money is all in the jars: nothing unallocated, the month's budget is what the wallets hold.
        var f = try facts(context, now: at(11, 6))
        #expect(f.unallocated == 0)
        #expect(f.budget == 38_000_000)
        #expect(f.jars.first?.balance == 20_900_000) // Essentials 55%
        #expect(f.left == 38_000_000)

        // The salary is an expected income on payday, not yet received.
        #expect(salary.isIncome && salary.category?.key == "category.salary")
        #expect(salary.nextDue == day(11, 25))
        #expect(f.expectedIncome.map(\.amount) == [15_000_000])
        #expect(f.income == 0)
        #expect(BudgetActions.dueIncome([salary], txns: [], now: at(11, 6), calendar: cal).isEmpty)
        #expect(BudgetActions.dueIncome([salary], txns: [], now: at(11, 25), calendar: cal) == [salary])

        // Payday: "Received" records income into the bank and splits it into the jars.
        let pay = BudgetActions.markPaid(salary, date: at(11, 25), jars: jars, in: context, calendar: cal)
        #expect(pay.kind == .income && pay.wallet?.name == "ACB")
        #expect((pay.splits ?? []).reduce(0) { $0 + $1.amount } == 15_000_000)
        #expect(salary.nextDue == day(12, 25))

        // Spend: food comes out of Essentials.
        let lunch = Txn(amount: 113_000, kind: .expense, date: at(11, 26), category: try category("category.food", context), wallet: pay.wallet)
        context.insert(lunch)
        lunch.allocate(jars: jars, in: context)

        f = try facts(context, now: at(11, 26))
        #expect(f.unallocated == 0)
        #expect(f.income == 15_000_000)
        #expect(f.budget == 53_000_000)
        #expect(f.spent == 113_000)
        #expect(f.left == 52_887_000)
        #expect(f.jars.first?.balance == 20_900_000 + 8_250_000 - 113_000)
        #expect(f.jars.reduce(0) { $0 + $1.balance } == 52_887_000) // the jars hold exactly what the wallets hold
    }

    @Test func walletAddedLaterIsUnallocatedThenSplit() throws {
        let (context, _) = try onboarded()
        context.insert(Wallet(name: "MoMo", type: .ewallet, initialBalance: 2_000_000))

        var f = try facts(context, now: at(11, 10))
        #expect(f.unallocated == 2_000_000)
        #expect(f.budget == 38_000_000) // not in a jar yet

        BudgetActions.splitUnallocated(f.unallocated, jars: try jars(context), date: at(11, 10), in: context)
        f = try facts(context, now: at(11, 10))
        #expect(f.unallocated == 0)
        #expect(f.budget == 40_000_000)
        #expect(f.jars.map(\.added) == [22_000_000, 4_000_000, 4_000_000, 4_000_000, 4_000_000, 2_000_000])
        #expect(BudgetActions.splitUnallocated(0, jars: try jars(context), in: context) == nil)
    }

    @Test func salaryLoggedInChatIsNotAskedAgain() throws {
        let (context, salary) = try onboarded()
        let t = Txn(amount: 15_500_000, kind: .income, date: at(11, 24), category: salary.category, wallet: BudgetActions.defaultWallet(in: context))
        context.insert(t)
        t.allocate(jars: try jars(context), in: context)
        let txns = try context.fetch(FetchDescriptor<Txn>())

        #expect(BudgetActions.isReceived(salary, txns: txns, calendar: cal))
        #expect(BudgetActions.dueIncome([salary], txns: txns, now: at(11, 25), calendar: cal).isEmpty)
        #expect(try facts(context, now: at(11, 25)).expectedIncome.first?.date == day(12, 25))
        BudgetActions.catchUpIncome(in: context, calendar: cal)
        #expect(salary.nextDue == day(12, 25))
        #expect(!BudgetActions.isReceived(salary, txns: txns, calendar: cal))
    }

    @Test func debtsAndTransfersDoNotChangeUnallocated() {
        let l = Ledger<String>(entries: [
            .init(kind: .lend, amount: 1_000, date: .now, wallet: "cash", debt: "nam"),
            .init(kind: .borrow, amount: 5_000, date: .now, wallet: "cash", debt: "mom"),
            .init(kind: .transfer, amount: 300, date: .now, wallet: "cash", toWallet: "bank"),
        ], walletOpening: ["cash": 10_000], jarOpening: ["a": 10_000], debtDirections: ["nam": .lent, "mom": .borrowed])
        #expect(l.unallocated == 0)
    }

    @Test func assistantReadsTheBudgetTabNumbers() async throws {
        let (context, salary) = try onboarded()
        let lunch = Txn(amount: 113_000, kind: .expense, date: at(11, 6, 13), category: try category("category.food", context),
                        wallet: BudgetActions.defaultWallet(in: context))
        context.insert(lunch)
        lunch.allocate(jars: try jars(context), in: context)
        let rent = Recurring(name: "Rent", amount: 5_000_000, nextDue: at(11, 28))
        context.insert(rent)
        rent.category = try category("category.housing", context)

        let now = at(11, 7)
        let f = try facts(context, now: now)
        let locale = Locale(identifier: "en_US")
        let tools = MooneeTools(ledger: StoreLedger(context, currency: "VND", now: now, calendar: cal), now: { now }, calendar: cal, locale: locale)
        let money = { (m: Int) in Money(m, "VND").formatted(locale: locale) }
        let json = try await tools.monthBudget.run(Data("{}".utf8))
        let o = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(o["left"] as? String == money(f.left))
        #expect(o["left"] as? String == money(37_887_000))
        #expect(o["totalBudget"] as? String == money(38_000_000))
        #expect(o["spent"] as? String == money(113_000))
        #expect(o["unallocated"] as? String == money(0))
        #expect(o["leftAfterBills"] as? String == money(32_887_000))
        let pay = try #require((o["expectedIncome"] as? [[String: Any]])?.first)
        #expect(pay["amount"] as? String == money(15_000_000))
        #expect(pay["name"] as? String == salary.name)
        #expect(pay["date"] as? String == "2026-11-25")
        #expect((o["billsDueThisMonth"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Rent"])
        // No model: the chat states the same number.
        #expect(ChatBook.factsText([.init(tool: "monthBudget", json: json)])?.contains(money(37_887_000)) == true)
    }
}
