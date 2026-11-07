import Foundation
import SwiftData

/// Budget strings live in `Budget.xcstrings` (table "Budget").
func loc(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Budget") }

/// Every write the Budget tab makes. Each new txn goes through `allocate` (CLAUDE.md conventions).
@MainActor enum BudgetActions {
    /// Spec §4.1: jar percents must add up to exactly 100. Returns what is left (negative = over).
    nonisolated static func percentRemainder(_ percents: [Int]) -> Int { 100 - percents.reduce(0, +) }

    nonisolated static func percentsValid(_ percents: [Int]) -> Bool {
        !percents.isEmpty && percents.allSatisfy { (0...100).contains($0) } && percentRemainder(percents) == 0
    }

    /// Moves envelope money; wallets do not change.
    @discardableResult
    static func moveBetweenJars(_ amount: Int, from: Jar, to: Jar, note: String = "", date: Date = .now, jars: [Jar], in context: ModelContext) -> Txn {
        let t = Txn(amount: amount, kind: .jarTransfer, date: date, note: note)
        context.insert(t)
        t.jar = from
        t.toJar = to
        t.allocate(jars: jars, in: context)
        return t
    }

    /// Spec §4.2: paying a credit card is a wallet transfer into the card, never a second expense.
    @discardableResult
    static func payCard(_ card: Wallet, amount: Int, from: Wallet, date: Date = .now, jars: [Jar], in context: ModelContext) -> Txn {
        let t = Txn(amount: amount, kind: .transfer, currencyCode: card.currencyCode, date: date,
                    note: String(localized: "Card payment: \(card.name)", table: "Budget"), wallet: from)
        context.insert(t)
        t.toWallet = card
        t.allocate(jars: jars, in: context)
        return t
    }

    /// Budget-wallet money no jar holds yet (`Ledger.unallocated`), from the store.
    static func unallocated(in context: ModelContext) -> Int {
        Ledger(txns: (try? context.fetch(FetchDescriptor<Txn>())) ?? [], wallets: (try? context.fetch(FetchDescriptor<Wallet>())) ?? [],
               jars: (try? context.fetch(FetchDescriptor<Jar>())) ?? []).unallocated
    }

    /// "Split into jars": puts unallocated money into the jars by their percents, as one dated jarTransfer with no
    /// source jar and a split per jar (written by `allocate`). Nothing to split or no percents → nil.
    @discardableResult
    static func splitUnallocated(_ amount: Int, jars: [Jar], date: Date = .now, in context: ModelContext) -> Txn? {
        guard amount > 0, jars.contains(where: { $0.percent > 0 }) else { return nil }
        let t = Txn(amount: amount, kind: .jarTransfer, date: date, note: loc("Split into jars"))
        context.insert(t)
        t.allocate(jars: jars, in: context)
        return t
    }

    /// Where a bill is paid from / an income lands when it names no wallet: the first budget wallet that is not a credit
    /// card (a salary goes to the first bank account).
    static func defaultWallet(income: Bool = false, in context: ModelContext) -> Wallet? {
        let all = (try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let wallets = all.filter(\.inBudget).isEmpty ? all : all.filter(\.inBudget)
        return (income ? wallets.first { $0.type == .bank } : nil) ?? wallets.first { $0.type != .credit } ?? wallets.first
    }

    /// Spec §4.3 "Paid": records the expense (pinned to its category's jar) and moves the bill one period on.
    /// An income recurring (salary) is "Received" the same way: an income that `receive` splits by the help level
    /// (spec §4.1, P0-1). Received early, the next payday still moves on.
    @discardableResult
    static func markPaid(_ bill: Recurring, amount: Int? = nil, date: Date = .now, jars: [Jar], level: AdvisorLevel = .current,
                         in context: ModelContext, calendar: Calendar = .current) -> Txn {
        let t = Txn(amount: amount ?? bill.amount, kind: bill.isIncome ? .income : .expense, currencyCode: bill.currencyCode,
                    date: date, note: bill.name, category: bill.category, wallet: bill.wallet ?? defaultWallet(income: bill.isIncome, in: context))
        context.insert(t)
        if !bill.isIncome { t.allocate(jars: jars, in: context) }
        bill.lastPaid = date
        let anchor = bill.dueDay ?? calendar.component(.day, from: bill.nextDue)
        bill.dueDay = anchor
        bill.nextDue = nextDue(after: bill.nextDue, bill.frequency, day: anchor, calendar: calendar)
        if bill.isIncome { receive(income: t, level: level, date: date, in: context, calendar: calendar) } // after: plans to the next payday
        return t
    }

    /// An income recurring counts as received for its current payday once an income of its category is logged
    /// from a week before payday on (chat "nhận lương 15tr" or "Received"), so it is never asked for or counted twice.
    static func isReceived(_ income: Recurring, txns: [Txn], calendar: Calendar = .current) -> Bool {
        guard income.isIncome, let category = income.category,
              let from = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: income.nextDue)) else { return false }
        return txns.contains { $0.kind == .income && $0.category == category && $0.date >= from }
    }

    /// Income recurrings due by the end of today and not received yet: the Budget tab asks "Received?".
    static func dueIncome(_ recurrings: [Recurring], txns: [Txn], now: Date = .now, calendar: Calendar = .current) -> [Recurring] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return recurrings.filter { $0.isIncome && $0.nextDue < end && !isReceived($0, txns: txns, calendar: calendar) }
            .sorted { $0.nextDue < $1.nextDue }
    }

    /// Moves a salary that was already logged (e.g. through chat) on to its next payday.
    static func catchUpIncome(in context: ModelContext, calendar: Calendar = .current) {
        let txns = (try? context.fetch(FetchDescriptor<Txn>())) ?? []
        for r in (try? context.fetch(FetchDescriptor<Recurring>())) ?? [] where isReceived(r, txns: txns, calendar: calendar) {
            let anchor = r.dueDay ?? calendar.component(.day, from: r.nextDue)
            r.dueDay = anchor
            r.lastPaid = txns.filter { $0.kind == .income && $0.category == r.category }.map(\.date).max()
            r.nextDue = nextDue(after: r.nextDue, r.frequency, day: anchor, calendar: calendar)
        }
    }

    /// One period after `due`. Monthly/yearly bills land on `day` (a 31st bill is due Feb 28, then Mar 31 again).
    nonisolated static func nextDue(after due: Date, _ frequency: Frequency, day: Int? = nil, calendar: Calendar = .current) -> Date {
        guard let next = calendar.date(byAdding: frequency.component, value: 1, to: due) else { return due }
        guard let day, frequency == .monthly || frequency == .yearly,
              let days = calendar.range(of: .day, in: .month, for: next) else { return next }
        var c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: next)
        c.day = min(day, days.count)
        return calendar.date(from: c) ?? next
    }

    /// The next date on `day` of the month (clamped to the month's length) on or after today. Credit-card due/statement days.
    nonisolated static func nextDate(day: Int, from now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        for offset in 0...1 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: today),
                  let range = calendar.range(of: .day, in: .month, for: month) else { continue }
            var c = calendar.dateComponents([.year, .month], from: month)
            c.day = min(day, range.count)
            if let d = calendar.date(from: c), d >= today { return d }
        }
        return today
    }
}

extension Recurring {
    /// A salary or other expected income (its category is an income one), not a bill.
    var isIncome: Bool { category?.kind == .income }
}

extension Ledger.JarMonth {
    /// Balance at the end of the month shown (equals the live balance for the current month).
    var endBalance: Int { start + added - spent }
}
