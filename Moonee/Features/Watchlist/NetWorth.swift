import Foundation
import SwiftData

/// Net worth split into the four slices of the Watchlist donut. `total` equals `Ledger.netWorth(assets:)`.
struct NetWorthBreakdown: Equatable {
    /// Wallets with money in them + foreign currency held.
    var cash = 0
    /// Gold, silver, stocks, crypto.
    var investments = 0
    /// Other assets + money lent out.
    var other = 0
    /// Card debt + money borrowed, as a positive number.
    var debts = 0

    var total: Int { cash + investments + other - debts }
    /// What is owned, before debts. The donut's percentages are shares of this.
    var gross: Int { cash + investments + other }
}

extension AssetKind {
    var slice: WritableKeyPath<NetWorthBreakdown, Int> {
        switch self {
        case .fx: \.cash
        case .gold, .silver, .stock, .crypto: \.investments
        case .other: \.other
        }
    }
}

extension Ledger {
    /// `assets`: values already in the ledger's currency (see `Asset.counted`).
    func breakdown(assets: [(kind: AssetKind, value: Int)]) -> NetWorthBreakdown {
        var b = NetWorthBreakdown()
        for balance in walletBalances.values {
            if balance >= 0 { b.cash += balance } else { b.debts -= balance } // a card in debt
        }
        for (debt, remaining) in debtRemaining {
            if debtDirections[debt] == .borrowed { b.debts += remaining } else { b.other += remaining }
        }
        for a in assets { b[keyPath: a.kind.slice] += a.value }
        return b
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

/// Net worth as last seen in a month, one per month and currency. Past months can't be recomputed from
/// transactions because asset prices have no history, so the app records the current month whenever it shows it.
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

    /// The chart: past months (up to `months` back) that have a snapshot, then this month at the live total.
    static func points(_ snapshots: [(month: Date, total: Int)], current: Int, now: Date = .now,
                       months: Int = 12, calendar: Calendar = .current) -> [Point] {
        let thisMonth = calendar.dateInterval(of: .month, for: now)!.start
        let from = calendar.date(byAdding: .month, value: -(months - 1), to: thisMonth)!
        let past = Dictionary(snapshots.filter { $0.month >= from && $0.month < thisMonth }
                                .map { (calendar.dateInterval(of: .month, for: $0.month)!.start, $0.total) },
                              uniquingKeysWith: { a, _ in a })
        return past.map { Point(month: $0.key, total: $0.value) }.sorted { $0.month < $1.month }
            + [Point(month: thisMonth, total: current)]
    }

    /// Change against last month's snapshot. nil when last month has none (an older one would not be "vs last month").
    static func change(_ points: [Point], now: Date = .now, calendar: Calendar = .current) -> (amount: Int, percent: Double?)? {
        let thisMonth = calendar.dateInterval(of: .month, for: now)!.start
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)!
        guard let previous = points.first(where: { $0.month == lastMonth }),
              let current = points.first(where: { $0.month == thisMonth }) else { return nil }
        let amount = current.total - previous.total
        return (amount, previous.total == 0 ? nil : Double(amount) / Double(abs(previous.total)))
    }
}
