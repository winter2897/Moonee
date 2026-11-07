import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor struct OverviewTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()
    let context = ModelContext(try! ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))

    func day(_ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }

    @discardableResult
    func txn(_ amount: Int, _ kind: TxKind, _ date: Date, category: Moonee.Category? = nil, wallet: Wallet? = nil, jars: [Jar] = [], note: String = "") -> Txn {
        let t = Txn(amount: amount, kind: kind, date: date, note: note, category: category, wallet: wallet)
        context.insert(t)
        t.allocate(jars: jars, in: context)
        return t
    }

    @Test func dashboardComparesPeriods() throws {
        let needs = Jar(key: "jar.essentials", icon: "house", colorHex: 0, percent: 50, order: 0)
        let savings = Jar(key: "jar.savings", icon: "banknote", colorHex: 0, percent: 50, order: 1)
        let food = Category(key: "category.food", icon: "fork.knife", colorHex: 0, jar: needs)
        let wallet = Wallet(name: "Cash", type: .cash, initialBalance: 1_000)
        [needs, savings].forEach(context.insert); context.insert(food); context.insert(wallet)
        let jars = [needs, savings]

        txn(2_000, .income, day(10, 5), wallet: wallet, jars: jars)                    // last month
        txn(400, .expense, day(10, 20), category: food, wallet: wallet, jars: jars)
        txn(4_000, .income, day(11, 1), wallet: wallet, jars: jars)                    // this month
        txn(300, .expense, day(11, 9), category: food, wallet: wallet, jars: jars)
        txn(150, .expense, day(11, 10, 8), category: food, wallet: wallet, jars: jars)
        txn(999, .expense, day(11, 10, 23), wallet: wallet)                            // no category → "Other"
        context.insert(Asset(symbol: "SJC", kind: .gold, quantity: 2, unitPrice: 500))
        let all = try context.fetch(FetchDescriptor<Txn>()), assets = try context.fetch(FetchDescriptor<Asset>())
        func stats(_ p: Period) -> DashboardStats {
            DashboardStats(txns: all, wallets: [wallet], jars: jars, assets: assets, period: p, now: day(11, 10, 23), calendar: cal)
        }

        let m = stats(.month)
        #expect((m.income, m.expense, m.previousIncome, m.previousExpense) == (4_000, 1_449, 2_000, 400))
        #expect(DashboardStats.change(m.net, from: m.previousNet) == 59) // 1600 → 2551
        #expect(m.walletTotal == 5_151)
        #expect(m.netWorth == 6_151)
        #expect(m.jars.map(\.month.balance) == [2_150, 3_000])
        // Cumulative by day: 31 points (October is longer); this month stops today (day 10).
        #expect(m.cumulative.count == 31)
        #expect(m.cumulative[8].current == 300)
        #expect(m.cumulative[9].current == 1_449)
        #expect(m.cumulative[10].current == nil)
        #expect(m.cumulative[19].previous == 400)
        #expect(m.cumulative[30].previous == 400 && m.cumulative[30].current == nil)
        #expect(m.perBucket[8].current == 300 && m.perBucket[9].current == 1_149 && m.perBucket[10].current == nil)
        #expect(m.perBucket[19].previous == 400 && m.perBucket[20].previous == 0)
        #expect(m.previousAverage == 400 / 31)
        #expect(m.categories.map(\.id) == ["category.food", "other"])
        #expect(m.categories.map(\.amount) == [450, 999])

        let y = stats(.year)
        #expect(y.cumulative.count == 12)
        #expect(y.cumulative[9].current == 400 && y.cumulative[10].current == 1_849 && y.cumulative[11].current == nil)
        #expect(y.cumulative[11].previous == 0)

        let w = stats(.week) // Sun 8 – Sat 14 Nov
        #expect(w.expense == 1_449 && w.previousExpense == 0 && w.cumulative.count == 7)
    }

    @Test func categoriesAreTopFiveThenOther() {
        let cats = (0..<7).map { Category(key: "c\($0)", icon: "tag", colorHex: 0) }
        cats.forEach(context.insert)
        let txns = cats.enumerated().map { i, c in txn(70 - i * 10, .expense, day(11, 3), category: c) }
        let s = DashboardStats(txns: txns, wallets: [], jars: [], assets: [], period: .month, now: day(11, 10), calendar: cal)
        #expect(s.categories.map(\.id) == ["c0", "c1", "c2", "c3", "c4", "other"])
        #expect(s.categories.last?.amount == 30)
    }

    @Test func billsDueWithinAWeekIncludeOverdue() {
        let now = day(11, 10, 9)
        let bills = [Recurring(name: "late", amount: 1, nextDue: day(11, 8)), Recurring(name: "edge", amount: 1, nextDue: day(11, 17, 22)),
                     Recurring(name: "far", amount: 1, nextDue: day(11, 18, 1)), Recurring(name: "soon", amount: 1, nextDue: day(11, 11))]
        #expect(DashboardStats.billsDue(bills, now: now, calendar: cal).map(\.name) == ["late", "soon", "edge"])
    }

    @Test func noteFollowsUrgencyAndReminderLevel() {
        let now = day(11, 10, 20)
        let ok = MooneeNote.JarState(name: "Play", balance: 100, progress: 0.5)
        let hot = MooneeNote.JarState(name: "Needs", balance: 100, progress: 0.85)
        let over = MooneeNote.JarState(name: "Fun", balance: 0, progress: 1.2)
        let red = MooneeNote.JarState(name: "Red", balance: -5, progress: 0.5)
        func note(_ level: MooneeNote.Level, _ jars: [MooneeNote.JarState], bills: [(name: String, due: Date)] = [], spent: Int = 10) -> MooneeNote {
            .make(level: level, jars: jars, bills: bills, spentToday: spent, now: now, calendar: cal)
        }

        #expect(note(.low, [ok, over, red]).text.contains("Red"))
        #expect(note(.low, [ok, over]).text.contains("Fun"))
        #expect(note(.low, [hot], bills: [("Internet", day(11, 10, 8))]).text.contains("Internet"))
        #expect(note(.low, [hot]).symbol == "sparkles")    // ≥80% is medium+
        #expect(note(.medium, [hot]).text.contains("85%"))
        #expect(note(.medium, [ok], spent: 0).symbol == "sparkles")
        #expect(note(.high, [ok], spent: 0).symbol == "moon.zzz.fill") // evening nudge only on "high"
    }

    @Test func filterByWalletJarCategoryDateAndText() {
        let needs = Jar(key: "jar.essentials", icon: "house", colorHex: 0, percent: 100, order: 0)
        let food = Category(key: "category.food", icon: "fork.knife", colorHex: 0, jar: needs)
        let cash = Wallet(name: "Cash", type: .cash), bank = Wallet(name: "Bank", type: .bank)
        context.insert(needs); context.insert(food); [cash, bank].forEach(context.insert)
        let lunch = txn(50, .expense, day(11, 3), category: food, wallet: cash, jars: [needs], note: "Phở bò")
        let salary = txn(1_000, .income, day(11, 1), wallet: bank, jars: [needs])
        let move = txn(200, .transfer, day(11, 5), wallet: bank)
        move.toWallet = cash
        let all = [lunch, salary, move]
        func run(_ f: TxnFilter) -> [Txn] { all.filter { f.matches($0) } }
        func run(_ p: TxnPeriod) -> [Txn] { all.filter { p.contains($0.date) } }

        #expect(run(TxnFilter(wallet: cash)) == [lunch, move])
        #expect(run(TxnFilter(jar: needs)) == [lunch, salary]) // expense jar + income split
        #expect(run(TxnFilter(category: food)) == [lunch])
        #expect(run(TxnPeriod.current(.month, now: day(11, 20), calendar: cal)) == [lunch, salary, move])
        #expect(run(TxnPeriod.current(.month, now: day(12, 2), calendar: cal).moved(-1, calendar: cal)) == [lunch, salary, move])
        #expect(run(TxnPeriod.current(.week, now: day(11, 4), calendar: cal)).isEmpty == false) // Sun 1 – Sat 7 Nov
        #expect(run(TxnPeriod.current(.week, now: day(11, 10), calendar: cal)).isEmpty)
        #expect(run(TxnFilter(text: "pho")) == [lunch])        // diacritic-insensitive
        #expect(run(TxnFilter(text: "bank")) == [salary, move])
        #expect(!TxnFilter(text: "x").isActive)
    }

    @Test func deletingIncomeRemovesItsSplits() throws {
        let jars = [Jar(icon: "a", colorHex: 0, percent: 60, order: 0), Jar(icon: "b", colorHex: 0, percent: 40, order: 1)]
        jars.forEach(context.insert)
        let t = txn(1_000, .income, day(11, 1), jars: jars)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<IncomeSplit>()) == 2)
        context.delete(t)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<IncomeSplit>()) == 0)
    }

    @Test func rescaleKeepsProportionsAndTotal() {
        #expect(rescaleSplits([550, 100, 100, 100, 100, 50], to: 2_000) == [1_100, 200, 200, 200, 200, 100])
        #expect(rescaleSplits([1, 1, 1], to: 10).reduce(0, +) == 10)
        #expect(rescaleSplits([], to: 10) == [])
    }
}
