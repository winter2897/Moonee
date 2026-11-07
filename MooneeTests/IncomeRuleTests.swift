import Foundation
import SwiftData
import Testing
@testable import Moonee

/// P0-1 (one rule for money coming in) and P0-2 (no orphan spending), spec §4.1 / §4.3.
@MainActor struct IncomeRuleTests {
    func seeded() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        Seed.ifNeeded(context)
        for w in try context.fetch(FetchDescriptor<Wallet>()) { w.currencyCode = "VND" } // CI is en_US
        return context
    }

    func jars(_ context: ModelContext) throws -> [Jar] { try context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)])) }
    func category(_ key: String, _ context: ModelContext) throws -> Moonee.Category {
        try #require(try context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == key })
    }

    func say(_ text: String, level: AdvisorLevel, _ context: ModelContext) -> [Txn] {
        var p = ParserContext(context)
        p.currency = "VND"
        return ChatBook.save(QuickParser.parse(text, context: p), source: .text, rawInput: text, level: level, in: context)
    }

    /// What the books look like after: each jar's balance (jar order) and Unallocated.
    func books(_ context: ModelContext) throws -> [Int] {
        let l = Ledger(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: try context.fetch(FetchDescriptor<Wallet>()), jars: try jars(context))
        return try jars(context).map { l.jarBalance($0.persistentModelID) } + [l.unallocated]
    }

    /// A 20tr salary due in 12 days, empty jars; then 10tr comes in through `path`.
    func scenario(_ level: AdvisorLevel, _ path: (ModelContext) throws -> Void) throws -> [Int] {
        let context = try seeded()
        let salary = Recurring(name: "Lương", amount: 20_000_000, currencyCode: "VND",
                               nextDue: Calendar.current.date(byAdding: .day, value: 12, to: .now)!)
        context.insert(salary)
        salary.category = try category("category.salary", context)
        let bank = Wallet(name: "Bank", type: .bank, currencyCode: "VND", order: 1)
        context.insert(bank)
        context.insert(Wallet(name: "Tiết kiệm", type: .savings, currencyCode: "VND", initialBalance: 10_000_000, order: 2))
        let defaults = UserDefaults.standard
        let saved = (defaults.string(forKey: Prefs.advisorLevel), defaults.data(forKey: Prefs.advisorAuto))
        defer { // Automatic leaves an Undo record; never leak it into the app on this simulator
            defaults.set(saved.0, forKey: Prefs.advisorLevel)
            defaults.set(saved.1, forKey: Prefs.advisorAuto)
        }
        defaults.set(level.rawValue, forKey: Prefs.advisorLevel) // the UI paths read the help level from Prefs
        try path(context)
        return try books(context)
    }

    func bank(_ context: ModelContext) throws -> Wallet { try #require(try context.fetch(FetchDescriptor<Wallet>()).first { $0.name == "Bank" }) }

    @Test(arguments: [AdvisorLevel.automatic, .suggest, .manual])
    func everyInflowGivesTheSameResult(level: AdvisorLevel) throws {
        let paths: [String: (ModelContext) throws -> Void] = [
            "chat income": { c in _ = self.say("thưởng 10tr", level: level, c) },
            "opening balance": { c in
                try self.bank(c).initialBalance = 10_000_000
                OnboardingBook.chooseLevel(level, in: c)
            },
            "new wallet": { c in
                c.insert(Wallet(name: "MoMo", type: .ewallet, currencyCode: "VND", initialBalance: 10_000_000))
                BudgetActions.receive(10_000_000, level: level, in: c)
            },
            "sell an asset": { c in
                let gold = Asset(symbol: "SJC", kind: .gold, quantity: 1, unitPrice: 10_000_000, currencyCode: "VND")
                c.insert(gold)
                BudgetActions.bringBack(10_000_000, into: try self.bank(c), asset: gold, quantity: 1, in: c)
                BudgetActions.receive(10_000_000, level: level, in: c)
            },
            "withdraw savings": { c in
                let savings = try #require(try c.fetch(FetchDescriptor<Wallet>()).first { $0.type == .savings })
                BudgetActions.bringBack(10_000_000, into: try self.bank(c), from: savings, in: c)
                BudgetActions.receive(10_000_000, level: level, in: c)
            },
        ]
        let results = try paths.mapValues { try scenario(level, $0) }
        let expected = try #require(results["chat income"])
        for (name, r) in results { #expect(r == expected, "\(name) at \(level)") }

        #expect(expected.reduce(0, +) == 10_000_000) // jars + Unallocated hold exactly the new money
        switch level {
        case .suggest: #expect(expected.last == 10_000_000) // all of it waits in Unallocated
        case .manual: #expect(expected == [5_500_000, 1_000_000, 1_000_000, 1_000_000, 1_000_000, 500_000, 0]) // by percent
        case .automatic:
            #expect(expected.last == 0)
            #expect(expected[2] > 1_000_000) // the a–d plan: Savings builds the emergency fund first
        }
    }

    /// "Received" on the salary line and "nhận lương 20tr" in chat land the same, at every level, and the chat one still
    /// counts as received.
    @Test(arguments: [AdvisorLevel.automatic, .suggest, .manual])
    func salaryReceivedEqualsSalaryInChat(level: AdvisorLevel) throws {
        func run(_ path: (ModelContext, Recurring) throws -> Void) throws -> [Int] {
            try scenario(level) { c in
                let r = try #require(try c.fetch(FetchDescriptor<Recurring>()).first)
                r.nextDue = Calendar.current.startOfDay(for: .now)
                try path(c, r)
                #expect(BudgetActions.dueIncome([r], txns: try c.fetch(FetchDescriptor<Txn>())).isEmpty)
            }
        }
        let button = try run { c, r in BudgetActions.receive(r, level: level, in: c) }
        let chat = try run { c, _ in _ = self.say("lương 20tr", level: level, c) }
        #expect(button == chat)
    }

    /// Suggest's chat card buttons: "Split as Moonee suggests" = the Automatic result, "By %" = Do it myself.
    @Test func chatCardButtonsMatchTheLevels() throws {
        let auto = try scenario(.automatic) { c in _ = self.say("thưởng 10tr", level: .automatic, c) }
        let byPercent = try scenario(.manual) { c in _ = self.say("thưởng 10tr", level: .manual, c) }
        let tapped = { (level: AdvisorLevel) in
            try self.scenario(.suggest) { c in
                let t = try #require(self.say("thưởng 10tr", level: .suggest, c).first)
                #expect((t.splits ?? []).isEmpty)
                BudgetActions.receive(income: t, level: level, in: c)
                BudgetActions.receive(income: t, level: level, in: c) // a second tap moves nothing more
            }
        }
        #expect(try tapped(.automatic) == auto)
        #expect(try tapped(.manual) == byPercent)
    }

    /// Automatic money in Unallocated (a new wallet) shows on the Budget card with Undo.
    @Test func automaticInflowCanBeUndone() throws {
        let defaults = UserDefaults.standard, saved = defaults.data(forKey: Prefs.advisorAuto)
        defer { defaults.set(saved, forKey: Prefs.advisorAuto) }
        let context = try seeded()
        context.insert(Wallet(name: "MoMo", type: .ewallet, currencyCode: "VND", initialBalance: 3_000_000))
        let t = try #require(BudgetActions.receive(3_000_000, level: .automatic, in: context))
        let record = try #require(AdvisorMemory.autoRecords.last)
        #expect(t.externalID == record.tag)
        #expect(try books(context).last == 0)
        Autopilot.undo(record, in: context)
        #expect(try books(context).last == 3_000_000)
    }

    @Test func editorSetsAnIncomesSplit() throws {
        let context = try seeded()
        let t = try #require(say("thưởng 10tr", level: .manual, context).first)
        let needs = try #require(try jars(context).first)
        TxnEdit.apply(to: t, amount: t.amount, date: t.date, note: t.note, category: t.category, wallet: t.wallet, toWallet: nil,
                      splits: [needs: 3_000_000], in: context)
        #expect((t.splits ?? []).map(\.amount) == [3_000_000])
        #expect(try books(context) == [3_000_000, 0, 0, 0, 0, 0, 7_000_000])
    }

    // MARK: P0-2

    /// Budget's "Spent" (jars) equals Overview's "Chi" (every expense) for the month.
    @Test func spentFromJarsEqualsAllSpending() throws {
        let context = try seeded()
        _ = say("ăn trưa 65k, abc xyz 120k, grab 50k, quà sinh nhật 300k", level: .manual, context) // "abc xyz": Other
        let rent = try #require(OnboardingBook.saveBills([.init(name: "Tiền điện", amount: 800_000, day: 1, categoryKey: "category.other")],
                                                         in: context).first)
        BudgetActions.markPaid(rent, jars: try jars(context), in: context)
        let txns = try context.fetch(FetchDescriptor<Txn>())
        #expect(txns.filter { $0.kind == .expense }.allSatisfy { $0.jar != nil })
        let facts = BudgetFacts(context)
        let overview = DashboardStats(txns: txns, wallets: try context.fetch(FetchDescriptor<Wallet>()), jars: try jars(context), assets: [],
                                      period: .month)
        #expect(overview.expense == 1_335_000)
        #expect(facts.spent == overview.expense)
    }

    @Test func orphanCategoriesGetAJarOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "IncomeRuleTests.\(UUID())"))
        let context = try seeded()
        let other = try category("category.other", context)
        other.jar = nil // an install from before P0-2
        let old = Txn(amount: 50_000, kind: .expense, category: other)
        context.insert(old)
        old.allocate(jars: try jars(context), in: context)
        #expect(old.jar == nil)

        Seed.assignOrphanCategories(context, defaults: defaults)
        #expect(other.jar?.key == "jar.essentials")
        #expect(old.jar == nil) // history keeps its pinned jar
        other.jar = nil // later made "Not in any jar" on purpose (Advanced)
        Seed.assignOrphanCategories(context, defaults: defaults)
        #expect(other.jar == nil)
        #expect(try category("category.food", context).jar?.key == "jar.essentials") // assigned ones untouched
    }

    @Test func billsGuessTheirCategory() {
        #expect(OnboardingBook.billCategory("Tiền điện") == "category.housing")
        #expect(OnboardingBook.billCategory("Điện") == "category.housing")
        #expect(OnboardingBook.billCategory("Nước") == "category.housing") // a bill, not a drink
        #expect(OnboardingBook.billCategory("Internet FPT") == "category.housing")
        #expect(OnboardingBook.billCategory("Học phí con") == "category.education")
        #expect(OnboardingBook.billCategory("Netflix") == "category.entertainment")
        #expect(OnboardingBook.billCategory("Electricity") == "category.housing")
        #expect(OnboardingBook.billCategory("Lương") == "category.other") // never an income category
        #expect(OnboardingBook.billCategory("zzz") == "category.other")
    }
}
