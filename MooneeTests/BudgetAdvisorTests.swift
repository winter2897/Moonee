import Foundation
import SwiftData
import Testing
@testable import Moonee

/// Moonee's advice (spec §4.6) and budget workflow v2 (§4.1–4.2 rules A.1–A.6).
@MainActor struct BudgetAdvisorTests {
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

    func facts(_ context: ModelContext, now: Date, level: AdvisorLevel = .suggest) throws -> BudgetFacts {
        // The suite's budgets are VND whatever the runner's region (CI is en_US: USD steps would round differently).
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        for w in wallets { w.currencyCode = "VND" }
        return BudgetFacts(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: wallets,
                    jars: try context.fetch(FetchDescriptor<Jar>()), recurrings: try context.fetch(FetchDescriptor<Recurring>()),
                    now: now, calendar: cal, level: level, muted: [])
    }

    func jars(_ context: ModelContext) throws -> [Jar] { try context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)])) }
    func jar(_ key: String, _ context: ModelContext) throws -> Jar { try #require(try jars(context).first { $0.key == key }) }
    func balance(_ key: String, _ context: ModelContext) throws -> Int {
        Ledger(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: [], jars: try jars(context)).jarBalance(try jar(key, context).persistentModelID)
    }

    func category(_ key: String, _ context: ModelContext) throws -> Moonee.Category {
        try #require(try context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == key })
    }

    /// The owner's phone (build 3): cash −113k after lunch, bank `bank`, salary 40tr on the 10th, bills 5.14tr.
    func owner(bank: Int) throws -> (ModelContext, Recurring) {
        let context = try seeded()
        let salary = try #require(OnboardingBook.saveSalary(40_000_000, payday: 10, regular: true, now: at(11, 6), calendar: cal, in: context))
        let wallets = OnboardingBook.saveWallets([.init(type: .cash, name: "", amount: 0), .init(type: .bank, name: "Ngân hàng", amount: bank)], in: context)
        OnboardingBook.applyJars(try jars(context).map(\.percent), to: try jars(context), in: context)
        let lunch = Txn(amount: 113_000, kind: .expense, date: at(11, 6, 11), category: try category("category.food", context), wallet: wallets[0])
        context.insert(lunch)
        lunch.allocate(jars: try jars(context), in: context)
        for (name, amount, d) in [("Tiền nhà", 4_000_000, 15), ("Điện nước", 1_140_000, 20)] {
            let bill = Recurring(name: name, amount: amount, nextDue: day(11, d))
            context.insert(bill)
            bill.category = try category("category.housing", context)
        }
        return (context, salary)
    }

    @Test func ownerWithEmptyWalletsIsToldToUpdateBalancesNotToMoveJars() throws {
        let (context, salary) = try owner(bank: 0)
        let f = try facts(context, now: at(11, 6))
        #expect(f.advisor.input.budgetBalance == -113_000)
        #expect(f.unallocated == 0)
        let first = try #require(f.advice.first)
        #expect(first.kind == .noMoney)
        #expect(first.title == loc("Your wallets have no money yet"))
        #expect(first.ref == salary.ref) // "Record salary early" is offered
        #expect(first.moves.isEmpty)
        #expect(!f.advice.contains { $0.kind == .negativeJar }) // never "move from another jar"

        // Payday: "Salary 40tr in yet?" comes first, the plan pays the bills before the next payday.
        let pay = try facts(context, now: at(11, 10, 9))
        let card = try #require(pay.advice.first)
        #expect(card.kind == .payday && card.amount == 40_000_000)
        #expect(card.moves.reduce(0) { $0 + $1.amount } == 40_000_000)
        let plan = pay.advisor.plan(40_000_000, until: day(12, 10))
        #expect(plan.bills == 5_140_000)
        #expect(plan.shares["jar.essentials", default: 0] >= 5_140_000 + 113_000)
        #expect(plan.emergency > 0)
        let shares = plan.shares.filter { $0.key != "jar.savings" }
        #expect(shares.allSatisfy { $0.value % pay.advisor.step($0.value) == 0 }) // clean steps
        #expect(plan.shares.values.reduce(0, +) == 40_000_000)

        // One tap records it into the bank and splits it by that plan.
        let t = try #require(BudgetActions.apply(card, date: at(11, 10, 9), in: context, calendar: cal).first)
        #expect(t.kind == .income && t.wallet?.name == "Ngân hàng")
        #expect((t.splits ?? []).reduce(0) { $0 + $1.amount } == 40_000_000)
        #expect(salary.nextDue == day(12, 10))
        let after = try facts(context, now: at(11, 10, 9))
        #expect(after.unallocated == 0)
        #expect(after.advice.first?.kind != .payday)
    }

    @Test func ownerWithMoneyInTheBankGetsPlanAtoD() throws {
        let (context, _) = try owner(bank: 20_000_000)
        let f = try facts(context, now: at(11, 6))
        #expect(f.unallocated == 20_000_000)
        let card = try #require(f.advice.first)
        #expect(card.kind == .unallocated) // Essentials −113k is refilled by the plan, no second card
        #expect(!f.advice.contains { $0.kind == .negativeJar })

        let p = f.advisor.plan(20_000_000, until: day(11, 10))
        #expect(p.bills == 0) // rent and power are due after payday
        #expect(p.spending == 2_248_000) // (22tr essentials − 5.14tr bills) × 4 days / 30
        #expect(p.emergencyTarget == 66_000_000) // 3 × 22tr
        #expect(p.emergency == 8_819_500) // half of what is left after a–b
        #expect(p.byPercent == 8_819_500)
        // Clean amounts (50k steps from 1tr, 10k below), rounded up; Savings takes the difference so it adds up.
        #expect(p.shares["jar.essentials"] == 7_250_000) // 2,361,000 + 55% of the rest = 7,211,725
        #expect(p.shares["jar.investing"] == 890_000 && p.shares["jar.play"] == 890_000 && p.shares["jar.giving"] == 450_000)
        #expect(p.shares["jar.savings"] == 9_630_000) // 8,819,500 + 881,950 − 71,450 rounding
        #expect(p.shares.values.reduce(0, +) == 20_000_000)
        #expect(card.text.contains(try jar("jar.essentials", context).name))

        BudgetActions.apply(card, date: at(11, 6, 13), in: context, calendar: cal)
        let after = try facts(context, now: at(11, 6, 13))
        #expect(after.unallocated == 0)
        #expect(try balance("jar.essentials", context) == 7_250_000 - 113_000)
        #expect(!card.text.contains(",95") && !card.text.contains(".95")) // no calculator amounts
        #expect(card.why?.contains(String(localized: "\(try jar("jar.essentials", context).name) covers \("0") of bills", table: "Budget")) == false)
    }

    @Test func offBudgetWalletsAreNetWorthOnly() throws {
        let context = try seeded()
        let savings = Wallet(name: "Tiết kiệm VCB", type: .savings, initialBalance: 50_000_000)
        context.insert(savings)
        context.insert(Wallet(name: "Bank", type: .bank, initialBalance: 3_000_000))
        #expect(!savings.inBudget && WalletType.bank.countsInBudgetByDefault)
        let ledger = Ledger(txns: [], wallets: try context.fetch(FetchDescriptor<Wallet>()), jars: try jars(context))
        #expect(ledger.unallocated == 3_000_000)
        #expect(ledger.budgetBalance == 3_000_000)
        #expect(ledger.netWorth() == 53_000_000)
    }

    @Test func buyingAnAssetTakesMoneyFromAJar() throws {
        let context = try seeded()
        let bank = Wallet(name: "Bank", type: .bank, initialBalance: 20_000_000)
        let deposit = Wallet(name: "Tiết kiệm", type: .savings)
        [bank, deposit].forEach(context.insert)
        BudgetActions.splitUnallocated(20_000_000, jars: try jars(context), in: context)
        #expect(try balance("jar.investing", context) == 2_000_000)

        let gold = Asset(symbol: "SJC", kind: .gold, quantity: 0, unitPrice: 0)
        context.insert(gold)
        BudgetActions.setAside(1_500_000, from: bank, jar: try jar("jar.investing", context), asset: gold, quantity: 0.2, in: context)
        BudgetActions.setAside(1_000_000, from: bank, jar: try jar("jar.savings", context), into: deposit, in: context)
        var ledger = Ledger(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: try context.fetch(FetchDescriptor<Wallet>()), jars: try jars(context))
        #expect(try balance("jar.investing", context) == 500_000)
        #expect(try balance("jar.savings", context) == 1_000_000)
        #expect(ledger.walletBalance(bank.persistentModelID) == 17_500_000)
        #expect(ledger.unallocated == 0) // the jars still match the budget wallets
        #expect(gold.quantity == 0.2 && gold.unitPrice == 7_500_000 && gold.costBasis == 1_500_000)
        #expect(ledger.netWorth(assets: gold.value) == 20_000_000)

        // Selling comes back as Unallocated money (rule A.4).
        BudgetActions.bringBack(1_800_000, into: bank, asset: gold, quantity: 0.2, in: context)
        ledger = Ledger(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: try context.fetch(FetchDescriptor<Wallet>()), jars: try jars(context))
        #expect(ledger.unallocated == 1_800_000)
        #expect(gold.quantity == 0)
    }

    @Test func automaticRecordsSalaryOnPaydayWithUndo() throws {
        let defaults = UserDefaults.standard
        let saved = (defaults.string(forKey: Prefs.advisorLevel), defaults.stringArray(forKey: Prefs.advisorHandled), defaults.data(forKey: Prefs.advisorAuto))
        defer {
            defaults.set(saved.0, forKey: Prefs.advisorLevel)
            defaults.set(saved.1, forKey: Prefs.advisorHandled)
            defaults.set(saved.2, forKey: Prefs.advisorAuto)
        }
        defaults.set(AdvisorLevel.automatic.rawValue, forKey: Prefs.advisorLevel)
        defaults.removeObject(forKey: Prefs.advisorHandled)

        let context = try seeded()
        let salary = try #require(OnboardingBook.saveSalary(40_000_000, payday: 10, regular: true, now: at(11, 6), calendar: cal, in: context))
        _ = OnboardingBook.saveWallets([.init(type: .bank, name: "Bank", amount: 0)], in: context)
        #expect(Autopilot.run(context, now: at(11, 6), calendar: cal, notify: false) == nil) // not payday yet

        let record = try #require(Autopilot.run(context, now: at(11, 10, 9), calendar: cal, notify: false))
        #expect(record.kind == "payday")
        let income = try context.fetch(FetchDescriptor<Txn>()).filter { $0.kind == .income }
        #expect(income.count == 1 && income.first?.externalID == record.tag && income.first?.amount == 40_000_000)
        #expect(salary.nextDue == day(12, 10))
        #expect(try facts(context, now: at(11, 10, 9)).income == 40_000_000)
        #expect(Autopilot.run(context, now: at(11, 10, 10), calendar: cal, notify: false) == nil) // once

        Autopilot.undo(record, in: context)
        #expect(try context.fetch(FetchDescriptor<Txn>()).isEmpty)
        #expect(salary.nextDue == day(11, 10))
        #expect(!AdvisorMemory.autoRecords.contains(record))
    }

    // MARK: Pure advisor

    func input(_ jars: [BudgetAdvisor.Jar], budget: Int, unallocated: Int = 0, now: Date) -> BudgetAdvisor.Input {
        .init(jars: jars, budgetBalance: budget, unallocated: unallocated, now: now, currency: "VND", calendar: cal, locale: Locale(identifier: "en_US"))
    }

    func j(_ id: String, _ role: BudgetAdvisor.Role, _ balance: Int, percent: Int = 10, spent: Int = 0, budget: Int = 0) -> BudgetAdvisor.Jar {
        .init(id: id, name: id, role: role, percent: percent, balance: balance, spent: spent, budget: budget)
    }

    @Test func negativeJarIsCoveredPlayFirstSavingsLast() {
        let a = BudgetAdvisor(input([j("ess", .essentials, -500, percent: 55), j("play", .play, 100), j("growth", .growth, 200),
                                     j("giving", .giving, 0), j("sav", .savings, 1_000)], budget: 800, now: at(11, 6)))
        let card = a.advice.first { $0.kind == .negativeJar }
        #expect(card?.moves == [.init(from: "play", to: "ess", amount: 100), .init(from: "growth", to: "ess", amount: 200),
                                .init(from: "sav", to: "ess", amount: 200)])
        #expect(card?.why == loc("Savings and Investing come last: the other jars are empty."))

        var manual = a.input
        manual.level = .manual
        let warning = BudgetAdvisor(manual).advice.first { $0.kind == .negativeJar }
        #expect(warning?.moves.isEmpty == true)
        manual.muted = [.negativeJar]
        #expect(BudgetAdvisor(manual).advice.isEmpty)

        // Real amounts: the move is a clean 120k when Play has it (Essentials ends slightly above zero).
        let big = BudgetAdvisor(input([j("ess", .essentials, -113_000, percent: 55), j("play", .play, 500_000)], budget: 387_000, now: at(11, 6)))
        #expect(big.advice.first { $0.kind == .negativeJar }?.moves == [.init(from: "play", to: "ess", amount: 120_000)])
        #expect(big.step(881_950) == 10_000 && big.step(7_211_725) == 50_000 && big.step(40_000_000) == 100_000)
        var usd = big.input
        usd.currency = "USD"
        #expect(BudgetAdvisor(usd).step(88_195) == 1_000) // $881.95 → $10 steps
    }

    @Test func paceMonthEndAndRebalance() {
        // 10 Nov: a third of the month gone, Play 80% spent → about 200k / 21 days.
        let pace = BudgetAdvisor(input([j("play", .play, 210_000, spent: 800_000, budget: 1_010_000)], budget: 210_000, now: at(11, 10))).advice
        #expect(pace.first?.kind == .pace && pace.first?.amount == 10_000)

        let end = BudgetAdvisor(input([j("play", .play, 300_000), j("sav", .savings, 0)], budget: 300_000, now: at(11, 29))).advice
        #expect(end.first { $0.kind == .monthEnd }?.moves == [.init(from: "play", to: "sav", amount: 300_000)])

        var i = input([j("ess", .essentials, 0, percent: 55), j("play", .play, 0), j("growth", .growth, 0)], budget: 0, now: at(11, 6))
        i.history = [.init(income: 10_000_000, spent: ["ess": 6_800_000]), .init(income: 10_000_000, spent: ["ess": 6_800_000])]
        let r = BudgetAdvisor(i).rebalance()
        #expect(r?.percents == ["ess": 70, "play": 0, "growth": 5])
        i.history.removeLast()
        #expect(BudgetAdvisor(i).rebalance() == nil) // needs 2 months
    }

    /// P1-3: "about X a day" = left ÷ days left (today included), rounded down to a clean step.
    @Test func dailyAllowance() {
        let a = BudgetAdvisor(input([], budget: 0, now: at(11, 10)))
        #expect(a.daysLeft == 21)
        #expect(a.perDay(1_000_000) == 40_000)   // 47.619 → 40k
        #expect(a.perDay(5_000_000) == 230_000)  // 238.095 → 230k
        #expect(a.perDay(150_000) == 7_000)      // under one step: a finer one
        #expect(a.perDay(0) == 0 && a.perDay(-113_000) == 0)
        #expect(BudgetAdvisor(input([], budget: 0, now: at(11, 30, 22))).daysLeft == 1)
    }

    /// P1-3: "at this pace, about Y by month end" = spent ÷ days gone × days in the month; nothing in the first week.
    @Test func monthEndForecast() {
        let a = BudgetAdvisor(input([], budget: 0, now: at(11, 10)))  // 10 of 30 days gone
        #expect(a.monthEndForecast(spent: 1_000_000) == 3_000_000)
        #expect(a.monthEndForecast(spent: 1_234_567) == 3_700_000)
        #expect(a.monthEndForecast(spent: 0) == nil)
        #expect(BudgetAdvisor(input([], budget: 0, now: at(11, 6))).monthEndForecast(spent: 1_000_000) == nil)
        #expect(BudgetAdvisor(input([], budget: 0, now: at(11, 6))).monthEndForecast(spent: 1_000_000, minDays: 1) == 5_000_000)
    }

    /// P0-3: jars below zero are covered from Unallocated, worst first, while the money lasts.
    @Test func coverFromUnallocated() {
        let a = BudgetAdvisor(input([j("ess", .essentials, -113_000), j("play", .play, -50_000), j("sav", .savings, 0)],
                                    budget: 0, unallocated: 140_000, now: at(11, 6)))
        let c = a.unallocatedCover
        #expect(c?.moves == [.init(from: nil, to: "ess", amount: 113_000), .init(from: nil, to: "play", amount: 27_000)])
        #expect(c?.amount == 140_000)
        #expect(BudgetAdvisor(input([j("ess", .essentials, -113_000)], budget: 0, unallocated: 0, now: at(11, 6))).unallocatedCover == nil)
        #expect(BudgetAdvisor(input([j("ess", .essentials, 0)], budget: 0, unallocated: 500, now: at(11, 6))).unallocatedCover == nil)
    }

    /// The owner's phone: 20tr unsplit and lunch −113k. The header shows money to split (never a red total), offers to cover
    /// Essentials; Automatic covers it by itself, says so, and Undo puts it back.
    @Test func ownerUnsplitMoneyCoversTheLunch() throws {
        let (context, _) = try owner(bank: 20_000_000)
        let f = try facts(context, now: at(11, 6, 13))
        #expect(f.unallocated == 20_000_000) // wallets 19,887tr, jars −113k
        #expect(f.left == -113_000)
        let cover = try #require(f.advisor.unallocatedCover)
        #expect(cover.moves == [.init(from: nil, to: "jar.essentials", amount: 113_000)])

        let defaults = UserDefaults.standard
        let saved = (defaults.string(forKey: Prefs.advisorLevel), defaults.stringArray(forKey: Prefs.advisorHandled), defaults.data(forKey: Prefs.advisorAuto))
        defer {
            defaults.set(saved.0, forKey: Prefs.advisorLevel)
            defaults.set(saved.1, forKey: Prefs.advisorHandled)
            defaults.set(saved.2, forKey: Prefs.advisorAuto)
        }
        defaults.set(AdvisorLevel.automatic.rawValue, forKey: Prefs.advisorLevel)
        defaults.removeObject(forKey: Prefs.advisorHandled)
        let record = try #require(Autopilot.run(context, now: at(11, 6, 13), calendar: cal, notify: false))
        #expect(record.title == loc("Moonee covered a jar below zero"))
        #expect(try balance("jar.essentials", context) == 0)
        Autopilot.undo(record, in: context)
        #expect(try balance("jar.essentials", context) == -113_000)
    }

    @Test func emergencyCheckBeforeBuying() {
        var i = input([j("ess", .essentials, 0, percent: 50), j("sav", .savings, 10_000_000)], budget: 10_000_000, now: at(11, 6))
        i.income = .init(name: "Salary", amount: 20_000_000, due: day(11, 25), next: day(12, 25))
        let a = BudgetAdvisor(i)
        #expect(a.emergencyTarget == 30_000_000)
        #expect(a.emergencyNote(spending: 5_000_000, from: "sav") != nil)
        i.jars[1].balance = 40_000_000
        #expect(BudgetAdvisor(i).emergencyNote(spending: 5_000_000, from: "sav") == nil)
    }
}
