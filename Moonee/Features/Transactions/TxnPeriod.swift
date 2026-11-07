import SwiftData
import SwiftUI

/// Money in and money out (spec §2): income and expense txns only. Wallet transfers, jar transfers and
/// lend / borrow / repay move money you already have, so they are not counted. The ledger's totals card,
/// the Overview and the monthly report all use this one function, so the three always show the same numbers.
struct CashFlow: Equatable {
    var income = 0
    var expense = 0
    var net: Int { income - expense }

    init(income: Int = 0, expense: Int = 0) {
        self.income = income
        self.expense = expense
    }

    /// `interval` nil = every txn given.
    init(_ txns: [Txn], in interval: DateInterval? = nil) {
        for t in txns where interval.map({ $0.start <= t.date && t.date < $0.end }) ?? true {
            switch t.kind {
            case .income: income += t.amount
            case .expense: expense += t.amount
            default: break
            }
        }
    }

    /// Whether a kind counts as income or spending (transfers and debts don't).
    static func counts(_ kind: TxKind) -> Bool { kind == .income || kind == .expense }
}

/// The span the ledger shows (spec §2): this month by default, ‹ › or a swipe steps by its unit.
/// Pure, with the period's aggregations (wallet opening → closing, groups, upcoming bills), so it is unit-tested.
struct TxnPeriod: Equatable {
    enum Unit: String, CaseIterable, Identifiable {
        case week, month, year, all, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: String(localized: "Week", table: "Transactions")
            case .month: String(localized: "Month", table: "Transactions")
            case .year: String(localized: "Year", table: "Transactions")
            case .all: String(localized: "All time", table: "Transactions")
            case .custom: String(localized: "Custom range…", table: "Transactions")
            }
        }

        var component: Calendar.Component? {
            switch self {
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            case .all, .custom: nil
            }
        }
    }

    let unit: Unit
    /// nil = all time.
    let interval: DateInterval?

    /// The week / month / year holding `now` (all time for `.all`; `.custom` falls back to the month).
    static func current(_ unit: Unit, now: Date = .now, calendar: Calendar = .current) -> TxnPeriod {
        if unit == .all { return TxnPeriod(unit: .all, interval: nil) }
        let c = unit.component ?? .month
        return TxnPeriod(unit: unit.component == nil ? .month : unit, interval: calendar.dateInterval(of: c, for: now)!)
    }

    /// Whole days `from` … `to` (either order).
    static func custom(from: Date, to: Date, calendar: Calendar = .current) -> TxnPeriod {
        let a = calendar.startOfDay(for: min(from, to))
        let b = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))!
        return TxnPeriod(unit: .custom, interval: DateInterval(start: a, end: b))
    }

    /// The period `step` units before (−) or after (+). A custom range moves by its own length; all time stays.
    func moved(_ step: Int, calendar: Calendar = .current) -> TxnPeriod {
        guard let interval else { return self }
        if let c = unit.component, let d = calendar.date(byAdding: c, value: step, to: interval.start) {
            return TxnPeriod(unit: unit, interval: calendar.dateInterval(of: c, for: d))
        }
        let days = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1
        let start = calendar.date(byAdding: .day, value: step * days, to: interval.start)!
        return TxnPeriod(unit: .custom, interval: DateInterval(start: start, end: calendar.date(byAdding: .day, value: days, to: start)!))
    }

    func contains(_ date: Date) -> Bool { interval.map { $0.start <= date && date < $0.end } ?? true }

    var title: String {
        guard let interval else { return Unit.all.title }
        switch unit {
        case .month: return interval.start.formatted(.dateTime.month(.wide).year())
        case .year: return interval.start.formatted(.dateTime.year())
        default: return (interval.start..<interval.end.addingTimeInterval(-1)).formatted(.interval.day().month(.abbreviated).year())
        }
    }

    // MARK: - Aggregations

    /// A wallet's balance at the start and end of the period, from `Ledger` (all time: opening balance → now).
    struct WalletSpan: Equatable {
        let opening: Int
        let closing: Int
        var change: Int { closing - opening }
    }

    func walletSpan(_ wallet: Wallet, txns: [Txn], wallets: [Wallet], jars: [Jar]) -> WalletSpan {
        func balance(before date: Date?) -> Int {
            Ledger(txns: date.map { d in txns.filter { $0.date < d } } ?? txns, wallets: wallets, jars: jars)
                .walletBalance(wallet.persistentModelID)
        }
        return WalletSpan(opening: interval.map { balance(before: $0.start) } ?? wallet.initialBalance,
                          closing: balance(before: interval?.end))
    }

    /// One section of the by-category / by-jar view.
    struct Group: Identifiable {
        let id: String
        let name: String
        let icon: String
        let color: Color
        /// Spent (or received, for an income group; moved, for transfers).
        let total: Int
        /// Share of the period's spending (income for an income group); nil for transfers and debts.
        let percent: Int?
        let txns: [Txn]
    }

    enum Grouping { case category, jar }

    /// Txns grouped by category (no category: by kind) or by jar (expense jar, else the jar money moved to);
    /// groups that count as income or spending first, biggest first.
    static func groups(_ txns: [Txn], by grouping: Grouping) -> [Group] {
        let flow = CashFlow(txns)
        func key(_ t: Txn) -> String {
            switch grouping {
            case .category: t.category.map { "c\($0.persistentModelID.hashValue)" } ?? "k\(t.kind.rawValue)"
            case .jar: (t.jar ?? t.toJar).map { "j\($0.persistentModelID.hashValue)" } ?? "none"
            }
        }
        return Dictionary(grouping: txns, by: key).map { id, list in
            let first = list[0]
            let spent = list.reduce(0) { $1.kind == .expense ? $0 + $1.amount : $0 }
            let received = list.reduce(0) { $1.kind == .income ? $0 + $1.amount : $0 }
            let total = spent > 0 ? spent : received > 0 ? received : list.reduce(0) { $0 + $1.amount }
            let of = spent > 0 ? flow.expense : received > 0 ? flow.income : 0
            let percent = of > 0 ? Int((Double(total) * 100 / Double(of)).rounded()) : nil
            switch grouping {
            case .category:
                let c = first.category
                let name = c?.name ?? (CashFlow.counts(first.kind) ? String(localized: "Uncategorized", table: "Transactions") : first.kind.title)
                return Group(id: id, name: name, icon: c?.icon ?? first.kind.symbol, color: c?.color ?? .brandDeep,
                             total: total, percent: percent, txns: list)
            case .jar:
                let j = first.jar ?? first.toJar
                return Group(id: id, name: j?.name ?? String(localized: "No jar", table: "Transactions"), icon: j?.icon ?? "tray",
                             color: j?.color ?? Color.inkSecondary, total: total, percent: percent, txns: list)
            }
        }
        .sorted { ($0.percent != nil ? 1 : 0, $0.total) > ($1.percent != nil ? 1 : 0, $1.total) }
    }

    /// One expected bill, salary or other recurring item on a future date.
    struct Upcoming: Identifiable {
        let bill: Recurring
        let date: Date
        var id: String { "\(bill.persistentModelID.hashValue)-\(date.timeIntervalSince1970)" }
    }

    /// Every due date of the recurring items from now until `months` months ahead, soonest first. Unpaid overdue
    /// bills are included; a salary already received this cycle starts at its next payday.
    @MainActor static func upcoming(_ recurrings: [Recurring], txns: [Txn], months: Int, now: Date = .now,
                                    calendar: Calendar = .current) -> [Upcoming] {
        let end = calendar.date(byAdding: .month, value: months, to: calendar.startOfDay(for: now))!
        var out: [Upcoming] = []
        for r in recurrings {
            var due = r.isIncome && BudgetActions.isReceived(r, txns: txns, calendar: calendar)
                ? BudgetActions.nextDue(after: r.nextDue, r.frequency, day: r.dueDay, calendar: calendar) : r.nextDue
            var count = 0 // ponytail: 400 dates per item covers a daily one over 12 months
            while due < end, count < 400 {
                out.append(Upcoming(bill: r, date: due))
                due = BudgetActions.nextDue(after: due, r.frequency, day: r.dueDay, calendar: calendar)
                count += 1
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}

extension TxKind {
    /// Row icon when a txn has no category; transfers get the two-way arrow (not counted as income or spending).
    var symbol: String {
        switch self {
        case .expense: "cart.fill"
        case .income: "arrow.down.circle.fill"
        case .transfer, .jarTransfer: "arrow.left.arrow.right"
        case .lend: "arrow.up.forward.circle.fill"
        case .borrow: "arrow.down.backward.circle.fill"
        case .repay: "arrow.uturn.backward.circle.fill"
        }
    }
}
