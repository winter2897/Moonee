import Foundation
import SwiftData

/// What net worth is made of, by type: the donut's slices and the screen's sections. `total` equals `Ledger.netWorth(assets:)`.
struct NetWorthParts: Equatable {
    /// Wallets with money in them.
    var cash = 0
    /// Manual assets by type, in the ledger's currency.
    var assets: [AssetKind: Int] = [:]
    /// Money people still owe you.
    var lent = 0
    /// Credit cards (and overdrawn wallets) in debt, as a positive number.
    var cardDebt = 0
    /// Money you still owe people, as a positive number.
    var borrowed = 0

    /// What you own before debts. The donut's percentages are shares of this.
    var owned: Int { cash + assets.values.reduce(0, +) + lent }
    var debts: Int { cardDebt + borrowed }
    var total: Int { owned - debts }
}

extension Ledger {
    /// `assets`: values already in the ledger's currency (see `Asset.counted`).
    func parts(assets: [(kind: AssetKind, value: Int)]) -> NetWorthParts {
        var p = NetWorthParts()
        for balance in walletBalances.values {
            if balance >= 0 { p.cash += balance } else { p.cardDebt -= balance }
        }
        for (debt, remaining) in debtRemaining {
            if debtDirections[debt] == .borrowed { p.borrowed += remaining } else { p.lent += remaining }
        }
        for a in assets { p.assets[a.kind, default: 0] += a.value }
        return p
    }
}

extension Asset {
    /// Assets priced in another currency stay out of net worth until FX rates exist (no fake conversions).
    // ponytail: same-currency only; convert when an FX source ships (version 2, with live prices).
    static func counted(_ assets: [Asset], currency: String = Money.defaultCurrency) -> [(kind: AssetKind, value: Int)] {
        assets.filter { $0.currencyCode == currency }.map { ($0.kind, $0.value) }
    }
}

// MARK: - History

/// Net worth as last seen in a month, one per month and currency. Past months can't be recomputed exactly from
/// transactions because asset prices have no history, so the app records the current month whenever it shows it.
/// Months before the first snapshot fall back to a transaction estimate (see `NetWorthHistory.points`).
@Model final class NetWorthSnapshot {
    /// Start of the month.
    var month: Date = Date.distantPast
    var total: Int = 0
    var currencyCode: String = Money.defaultCurrency
    var updatedAt: Date = Date.now

    init(month: Date, total: Int, currencyCode: String) {
        self.month = month
        self.total = total
        self.currencyCode = currencyCode
    }

    /// Writes this month's net worth (insert or update). Also merges duplicates that iCloud sync may create.
    @MainActor static func record(_ total: Int, currency: String = Money.defaultCurrency, now: Date = .now,
                                  calendar: Calendar = .current, in context: ModelContext) {
        let month = calendar.dateInterval(of: .month, for: now)!
        let (start, end) = (month.start, month.end)
        let found = (try? context.fetch(FetchDescriptor<NetWorthSnapshot>(
            predicate: #Predicate { $0.month >= start && $0.month < end && $0.currencyCode == currency }))) ?? []
        found.dropFirst().forEach(context.delete)
        if let s = found.first {
            guard s.total != total else { return }
            s.total = total
            s.updatedAt = now
        } else {
            context.insert(NetWorthSnapshot(month: start, total: total, currencyCode: currency))
        }
    }
}

enum NetWorthHistory {
    struct Point: Equatable, Identifiable {
        var month: Date
        var total: Int
        var id: Date { month }
    }

    /// The chart: the last `months` months, then this month at the live total. A past month uses its snapshot,
    /// or without one `estimate(end of month)` (the ledger replayed to that day + today's asset values).
    /// It starts one month before the first data (`since` = first transaction, or the first snapshot): that month is
    /// the "before Moonee" baseline, so even a brand-new user has two points and sees the trend.
    static func points(_ snapshots: [(month: Date, total: Int)], current: Int, since: Date?, estimate: (Date) -> Int,
                       now: Date = .now, months: Int = 6, calendar: Calendar = .current) -> [Point] {
        let start = { (d: Date) in calendar.dateInterval(of: .month, for: d)!.start }
        let thisMonth = start(now)
        let stored = Dictionary(snapshots.map { (start($0.month), $0.total) }, uniquingKeysWith: { a, _ in a })
        let firstData = ([since].compactMap { $0 } + stored.keys).min().map(start) ?? thisMonth
        let first = calendar.date(byAdding: .month, value: -1, to: firstData)!
        let past = (1..<max(months, 1)).reversed().compactMap { back -> Point? in
            let m = calendar.date(byAdding: .month, value: -back, to: thisMonth)!
            guard m >= first else { return nil }
            return Point(month: m, total: stored[m] ?? estimate(calendar.date(byAdding: .month, value: 1, to: m)!))
        }
        return past + [Point(month: thisMonth, total: current)]
    }

    /// Change vs the previous month: the last point minus the one before it. nil with a single point.
    static func change(_ points: [Point]) -> (amount: Int, percent: Double?)? {
        guard points.count > 1, let last = points.last else { return nil }
        let first = points[points.count - 2]
        let amount = last.total - first.total
        return (amount, first.total == 0 ? nil : Double(amount) / Double(abs(first.total)))
    }

    /// The point a chart selection falls on: the month the touch is in (points are month starts, sorted),
    /// clamped to the first point before the chart starts.
    static func nearest(_ points: [Point], to date: Date) -> Point? {
        points.last { $0.month <= date } ?? points.first
    }
}
