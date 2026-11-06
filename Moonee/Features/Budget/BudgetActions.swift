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

    /// Spec §4.3 "Paid": records the expense (pinned to its category's jar) and moves the bill one period on.
    @discardableResult
    static func markPaid(_ bill: Recurring, amount: Int? = nil, date: Date = .now, jars: [Jar], in context: ModelContext,
                         calendar: Calendar = .current) -> Txn {
        let t = Txn(amount: amount ?? bill.amount, kind: .expense, currencyCode: bill.currencyCode, date: date, note: bill.name,
                    category: bill.category, wallet: bill.wallet)
        context.insert(t)
        t.allocate(jars: jars, in: context)
        bill.lastPaid = date
        let anchor = bill.dueDay ?? calendar.component(.day, from: bill.nextDue)
        bill.dueDay = anchor
        bill.nextDue = nextDue(after: bill.nextDue, bill.frequency, day: anchor, calendar: calendar)
        return t
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

extension Ledger.JarMonth {
    /// Balance at the end of the month shown (equals the live balance for the current month).
    var endBalance: Int { start + added - spent }
}
