import SwiftData
import SwiftUI

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Report") }

/// Every number of the monthly report (spec §3.5), computed once from the stored data. Pure, so it is unit-tested.
/// Jar balances (carry-over) come from `Ledger`; amounts are summed as stored (no FX, see CLAUDE.md known gaps).
struct MonthReport {
    struct Slice: Identifiable {
        let id: String
        let name: String
        let icon: String
        let color: Color
        let total: Int
        var previous = 0
    }

    struct JarRow: Identifiable {
        let jar: Jar
        let month: Ledger<PersistentIdentifier>.JarMonth
        var id: PersistentIdentifier { jar.persistentModelID }
    }

    struct MonthTotal: Identifiable {
        let month: Date
        let spent: Int
        var id: Date { month }
    }

    let month: DateInterval
    let income: Int
    let spent: Int
    let previousSpent: Int
    /// Spending by the jar each expense was pinned to; expenses with no jar are one "No jar" slice. Biggest first.
    let byJar: [Slice]
    /// Spending by category with the previous month's total, biggest first.
    let byCategory: [Slice]
    /// The 5 biggest expenses of the month.
    let top: [Txn]
    /// Spending of the 6 months ending with this one, oldest first.
    let trend: [MonthTotal]
    /// Each jar's month: start (carried in), added, spent, end balance (carried over to next month).
    let jars: [JarRow]

    var saved: Int { income - spent }
    var isEmpty: Bool { income == 0 && spent == 0 }
    /// Percent change of spending vs the previous month; nil when that month had none.
    var change: Int? { previousSpent > 0 ? Int((Double(spent - previousSpent) * 100 / Double(previousSpent)).rounded()) : nil }
    var savingsRate: Int? { income > 0 ? Int((Double(saved) * 100 / Double(income)).rounded()) : nil }

    init(txns: [Txn], wallets: [Wallet], jars: [Jar], month anchor: Date, calendar: Calendar = .current) {
        let m = calendar.dateInterval(of: .month, for: anchor)!
        let prev = calendar.dateInterval(of: .month, for: m.start.addingTimeInterval(-1))!
        month = m
        func expenses(_ i: DateInterval) -> [Txn] { txns.filter { $0.kind == .expense && $0.date >= i.start && $0.date < i.end } }
        let now = expenses(m), before = expenses(prev)
        spent = now.reduce(0) { $0 + $1.amount }
        previousSpent = before.reduce(0) { $0 + $1.amount }
        income = txns.filter { $0.kind == .income && $0.date >= m.start && $0.date < m.end }.reduce(0) { $0 + $1.amount }

        byJar = Dictionary(grouping: now) { $0.jar?.persistentModelID }.map { id, list in
            let jar = list.first?.jar
            return Slice(id: id.map { "\($0.hashValue)" } ?? "none", name: jar?.name ?? L("No jar"), icon: jar?.icon ?? "questionmark",
                         color: jar?.color ?? Color.inkSecondary.opacity(0.35), total: list.reduce(0) { $0 + $1.amount })
        }
        .sorted { $0.total > $1.total }

        let previousByCategory = Dictionary(grouping: before) { $0.category?.persistentModelID }.mapValues { $0.reduce(0) { $0 + $1.amount } }
        byCategory = Dictionary(grouping: now) { $0.category?.persistentModelID }.map { id, list in
            let c = list.first?.category
            return Slice(id: id.map { "\($0.hashValue)" } ?? "none", name: c?.name ?? L("Uncategorized"), icon: c?.icon ?? "tag",
                         color: c?.color ?? Color.inkSecondary, total: list.reduce(0) { $0 + $1.amount },
                         previous: previousByCategory[id] ?? 0)
        }
        .sorted { $0.total > $1.total }

        top = Array(now.sorted { $0.amount > $1.amount }.prefix(5))

        trend = (0..<6).reversed().map { back in
            let start = calendar.date(byAdding: .month, value: -back, to: m.start)!
            let i = calendar.dateInterval(of: .month, for: start)!
            return MonthTotal(month: i.start, spent: expenses(i).reduce(0) { $0 + $1.amount })
        }

        // Entries up to the month's end only, so `balance` is the balance carried over at that point.
        let ledger = Ledger(txns: txns.filter { $0.date < m.end }, wallets: wallets, jars: jars)
        self.jars = jars.sorted { $0.order < $1.order }.map { JarRow(jar: $0, month: ledger.jarMonth($0.persistentModelID, in: m)) }
    }

    /// Moonee's comment without a model (spec §9.1 fallback): two or three sentences from the numbers above.
    func ruleComment(currency: String) -> String {
        guard !isEmpty else { return L("Nothing logged this month yet. Tell Moonee your first spend and the report fills itself in.") }
        let money = { (v: Int) in AmountFormat.string(v, currency) }
        var out: [String] = []
        switch change {
        case let c? where c < 0: out.append(L("You spent \(money(spent)), \(-c)% less than the month before. Nice work!"))
        case let c? where c > 0: out.append(L("You spent \(money(spent)), \(c)% more than the month before."))
        default: out.append(L("You spent \(money(spent))."))
        }
        if income > 0 {
            out.append(saved >= 0 ? L("You kept \(money(saved)), \(savingsRate ?? 0)% of your income.")
                                  : L("Spending was \(money(-saved)) more than your income."))
        }
        if let first = byCategory.first, spent > 0 {
            out.append(L("Most of it went to \(first.name) (\(money(first.total)))."))
        }
        let ends = jars.map { ($0.jar.name, $0.month.balance) }
        if let neg = ends.min(by: { $0.1 < $1.1 }), neg.1 < 0, let rich = ends.max(by: { $0.1 < $1.1 }), rich.1 > 0 {
            out.append(L("\(neg.0) ended in the red: move \(money(min(-neg.1, rich.1))) from \(rich.0) to cover it."))
        } else {
            out.append(L("Every jar's balance carries over to next month."))
        }
        return out.joined(separator: " ")
    }
}
