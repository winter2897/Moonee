import Foundation
import SwiftData
import Testing
@testable import Moonee

/// The ledger v2 math (spec §2): period totals, wallet opening → closing, grouping, upcoming, and that the ledger,
/// Overview and the monthly report show the same money in / out.
@MainActor struct TxnPeriodTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        c.firstWeekday = 2
        return c
    }()

    func at(_ m: Int, _ d: Int, _ y: Int = 2026) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }

    struct Book {
        let context: ModelContext
        let txns: [Txn]
        let cash: Wallet
        let bank: Wallet
        let wallets: [Wallet]
        let jars: [Jar]
        let food: Moonee.Category
    }

    /// Cash 1tr opening, bank 5tr. Sep: food 200k. Oct: salary 10tr (bank), food 300k + 1tr, fun 2tr (cash),
    /// bank → cash 3tr, jar transfer 500k, lend 400k, borrow 600k, repay 100k. Nov: food 50k.
    func book() throws -> Book {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let needs = Jar(key: "jar.essentials", icon: "house", colorHex: 0, percent: 80, order: 0)
        let play = Jar(key: "jar.play", icon: "sparkles", colorHex: 0, percent: 20, order: 1)
        let food = Category(key: "category.food", icon: "fork.knife", colorHex: 0, jar: needs)
        let fun = Category(key: "category.entertainment", icon: "gamecontroller", colorHex: 0, jar: play)
        let salary = Category(key: "category.salary", icon: "banknote", colorHex: 0, kind: .income)
        let cash = Wallet(name: "Cash", type: .cash, initialBalance: 1_000_000)
        let bank = Wallet(name: "Bank", type: .bank, initialBalance: 5_000_000)
        [needs, play].forEach(context.insert)
        [food, fun, salary].forEach(context.insert)
        [cash, bank].forEach(context.insert)
        let jars = [needs, play]
        @discardableResult
        func add(_ amount: Int, _ kind: TxKind, _ date: Date, _ c: Moonee.Category? = nil, _ w: Wallet? = nil) -> Txn {
            let t = Txn(amount: amount, kind: kind, currencyCode: "VND", date: date, category: c, wallet: w ?? cash)
            context.insert(t)
            t.allocate(jars: jars, in: context)
            return t
        }
        add(200_000, .expense, at(9, 10), food)
        add(10_000_000, .income, at(10, 1), salary, bank)
        add(300_000, .expense, at(10, 3), food)
        add(1_000_000, .expense, at(10, 20), food)
        add(2_000_000, .expense, at(10, 12), fun)
        add(3_000_000, .transfer, at(10, 5), nil, bank).toWallet = cash
        let move = add(500_000, .jarTransfer, at(10, 6))
        move.wallet = nil
        move.jar = needs
        move.toJar = play
        let nam = Debt(person: "Nam", direction: .lent)
        context.insert(nam)
        add(400_000, .lend, at(10, 7)).debt = nam
        let lan = Debt(person: "Lan", direction: .borrowed)
        context.insert(lan)
        add(600_000, .borrow, at(10, 8)).debt = lan
        add(100_000, .repay, at(10, 9)).debt = nam
        add(50_000, .expense, at(11, 2), food)
        try context.save()
        return Book(context: context, txns: try context.fetch(FetchDescriptor<Txn>()), cash: cash, bank: bank, wallets: [cash, bank], jars: jars, food: food)
    }

    @Test func periodTotalsLeaveTransfersAndDebtsOut() throws {
        let b = try book()
        let october = TxnPeriod.current(.month, now: at(10, 15), calendar: cal)
        let flow = CashFlow(b.txns, in: october.interval)
        #expect(flow.income == 10_000_000)
        #expect(flow.expense == 3_300_000)
        #expect(flow.net == 6_700_000)
        #expect(CashFlow(b.txns).expense == 3_550_000) // all time
        #expect(!CashFlow.counts(.transfer) && !CashFlow.counts(.jarTransfer) && !CashFlow.counts(.lend) && !CashFlow.counts(.repay))
    }

    @Test func ledgerOverviewAndReportAgree() throws {
        let b = try book()
        let now = at(10, 15)
        let ledger = CashFlow(b.txns, in: TxnPeriod.current(.month, now: now, calendar: cal).interval)
        let overview = DashboardStats(txns: b.txns, wallets: b.wallets, jars: b.jars, assets: [], period: .month, now: now, calendar: cal)
        let report = MonthReport(txns: b.txns, wallets: b.wallets, jars: b.jars, month: now, calendar: cal)
        #expect(overview.income == ledger.income && report.income == ledger.income)
        #expect(overview.expense == ledger.expense && report.spent == ledger.expense)
        #expect(overview.net == ledger.net && report.saved == ledger.net)
        #expect(overview.previousExpense == report.previousSpent)
    }

    @Test func walletOpeningAndClosing() throws {
        let b = try book()
        let october = TxnPeriod.current(.month, now: at(10, 15), calendar: cal)
        // Cash: 1tr − 200k (Sep) = 800k; Oct: −3.3tr spent +3tr from bank −400k lent +600k borrowed +100k repaid = 0.
        let cash = october.walletSpan(b.cash, txns: b.txns, wallets: b.wallets, jars: b.jars)
        #expect(cash == .init(opening: 800_000, closing: 800_000))
        #expect(cash.change == 0)
        // Bank: 5tr; Oct: +10tr −3tr = 12tr.
        #expect(october.walletSpan(b.bank, txns: b.txns, wallets: b.wallets, jars: b.jars) == .init(opening: 5_000_000, closing: 12_000_000))
        // All time: opening balance → balance now (Nov food 50k too).
        let all = TxnPeriod.current(.all).walletSpan(b.cash, txns: b.txns, wallets: b.wallets, jars: b.jars)
        #expect(all == .init(opening: 1_000_000, closing: 750_000))
    }

    @Test func groupsByCategoryAndJar() throws {
        let b = try book()
        let october = TxnPeriod.current(.month, now: at(10, 15), calendar: cal)
        let shown = b.txns.filter { october.contains($0.date) }
        let groups = TxnPeriod.groups(shown, by: .category)
        // Cash-flow groups first, biggest first: salary 10tr (100% of income), fun 2tr (61%), food 1.3tr (39%).
        #expect(groups.prefix(3).map(\.total) == [10_000_000, 2_000_000, 1_300_000])
        #expect(groups.prefix(3).map(\.percent) == [100, 61, 39])
        #expect(groups.first { $0.total == 1_300_000 }?.txns.count == 2)
        // Transfers and debts follow, with no percent.
        #expect(groups.dropFirst(3).allSatisfy { $0.percent == nil })
        #expect(groups.reduce(0) { $0 + $1.txns.count } == shown.count)

        let byJar = TxnPeriod.groups(shown.filter { $0.kind == .expense }, by: .jar)
        #expect(byJar.map(\.total) == [2_000_000, 1_300_000]) // play, needs
        #expect(byJar.map(\.percent) == [61, 39])
    }

    @Test func periodsStepAndCustomRanges() {
        let oct = TxnPeriod.current(.month, now: at(10, 15), calendar: cal)
        #expect(oct.interval == DateInterval(start: cal.startOfDay(for: at(10, 1)), end: cal.startOfDay(for: at(11, 1))))
        #expect(oct.moved(-1, calendar: cal).interval?.start == cal.startOfDay(for: at(9, 1)))
        #expect(oct.moved(3, calendar: cal).interval?.start == cal.startOfDay(for: at(1, 1, 2027)))
        let week = TxnPeriod.current(.week, now: at(10, 15), calendar: cal) // Thu → Mon 12 … Sun 18
        #expect(week.interval?.start == cal.startOfDay(for: at(10, 12)))
        #expect(week.moved(1, calendar: cal).interval?.start == cal.startOfDay(for: at(10, 19)))
        let custom = TxnPeriod.custom(from: at(10, 10), to: at(10, 5), calendar: cal) // either order, both days in
        #expect(custom.contains(at(10, 5)) && custom.contains(at(10, 10)) && !custom.contains(at(10, 11)))
        #expect(custom.moved(-1, calendar: cal).interval?.start == cal.startOfDay(for: at(9, 29)))
        let all = TxnPeriod.current(.all)
        #expect(all.interval == nil && all.contains(.distantPast) && all.moved(1) == all)
    }

    @Test func upcomingBillsAndSalary() throws {
        let b = try book()
        let rent = Recurring(name: "Rent", amount: 4_000_000, nextDue: at(10, 25))
        let salary = Recurring(name: "Salary", amount: 10_000_000, nextDue: at(10, 1))
        salary.category = try b.context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.kind == .income }
        let yearly = Recurring(name: "Insurance", amount: 2_000_000, frequency: .yearly, nextDue: at(3, 1, 2027))
        [rent, salary, yearly].forEach(b.context.insert)
        let one = TxnPeriod.upcoming([rent, salary, yearly], txns: b.txns, months: 1, now: at(10, 15), calendar: cal)
        // Oct salary was received on Oct 1, so the next one is Nov 1.
        #expect(one.map(\.bill.name) == ["Rent", "Salary"])
        #expect(one.map(\.date) == [at(10, 25), cal.date(byAdding: .month, value: 1, to: at(10, 1))!])
        let year = TxnPeriod.upcoming([rent, salary, yearly], txns: b.txns, months: 12, now: at(10, 15), calendar: cal)
        #expect(year.filter { $0.bill === rent }.count == 12)
        #expect(year.filter { $0.bill === yearly }.count == 1)
    }

    @Test func typeAndAmountFilters() throws {
        let b = try book()
        func count(_ f: TxnFilter) -> Int { b.txns.filter { f.matches($0) }.count }
        #expect(count(TxnFilter(kind: .transfer)) == 2)
        #expect(count(TxnFilter(kind: .debt)) == 3)
        #expect(count(TxnFilter(kind: .income)) == 1)
        #expect(count(TxnFilter(minAmount: 1_000_000)) == 4) // 10tr, 1tr, 2tr, 3tr
        #expect(count(TxnFilter(minAmount: 300_000, maxAmount: 600_000)) == 4) // 300k, 500k, 400k, 600k
        #expect(count(TxnFilter(category: b.food, kind: .expense, maxAmount: 250_000)) == 2) // 200k, 50k
        #expect(TxnFilter(maxAmount: 1).isActive && !TxnFilter(text: "x").isActive)
    }
}
