import Foundation
import SwiftData
import SwiftUI

/// Every number on the Overview dashboard for one period (week / month / year) vs the one before (spec §2).
/// Pure over the fetched models, computed once per render; money math stays in `Ledger`.
struct DashboardStats {
    struct JarRow: Identifiable {
        let jar: Jar
        let month: Ledger<PersistentIdentifier>.JarMonth
        var id: PersistentIdentifier { jar.persistentModelID }
    }

    /// Cumulative spending at the end of bucket `index` (day of the week/month, month of the year).
    /// `current` is nil after today, so the line stops where the period is now.
    struct CumulativePoint: Identifiable {
        let index: Int
        let current: Int?
        let previous: Int?
        var id: Int { index }
    }

    struct CategorySlice: Identifiable {
        /// Category key/name, or "other".
        let id: String
        let name: String
        let icon: String
        let color: Color
        let amount: Int
    }

    let period: Period
    let interval: DateInterval
    let previousInterval: DateInterval
    let income: Int
    let expense: Int
    let previousIncome: Int
    let previousExpense: Int
    var net: Int { income - expense }
    var previousNet: Int { previousIncome - previousExpense }
    /// Σ wallet balances now (credit cards count negative).
    let walletTotal: Int
    let netWorth: Int
    let cumulative: [CumulativePoint]
    /// Top 5 expense categories in the period, then "Other".
    let categories: [CategorySlice]
    /// Jar envelopes for the current month (jars are monthly whatever the period).
    let jars: [JarRow]

    init(txns: [Txn], wallets: [Wallet], jars: [Jar], assets: [Asset], period: Period, now: Date = .now, calendar: Calendar = .current) {
        self.period = period
        interval = calendar.dateInterval(of: period.component, for: now)!
        previousInterval = calendar.dateInterval(of: period.component, for: interval.start.addingTimeInterval(-1))!

        func total(_ kind: TxKind, in i: DateInterval) -> Int {
            txns.reduce(0) { $1.kind == kind && i.start <= $1.date && $1.date < i.end ? $0 + $1.amount : $0 }
        }
        income = total(.income, in: interval)
        expense = total(.expense, in: interval)
        previousIncome = total(.income, in: previousInterval)
        previousExpense = total(.expense, in: previousInterval)

        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        walletTotal = wallets.reduce(0) { $0 + ledger.walletBalance($1.persistentModelID) }
        netWorth = ledger.netWorth(assets: assets.reduce(0) { $0 + $1.value })
        let month = calendar.dateInterval(of: .month, for: now)!
        self.jars = jars.sorted { $0.order < $1.order }.map { JarRow(jar: $0, month: ledger.jarMonth($0.persistentModelID, in: month)) }

        // Cumulative spending per bucket: days for week/month, months for a year.
        let unit: Calendar.Component = period == .year ? .month : .day
        func buckets(_ i: DateInterval) -> [Int] {
            let count = calendar.dateComponents([unit], from: i.start, to: i.end).value(for: unit) ?? 0
            var sums = Array(repeating: 0, count: count)
            for t in txns where t.kind == .expense && i.start <= t.date && t.date < i.end {
                let b = calendar.dateComponents([unit], from: i.start, to: t.date).value(for: unit) ?? 0
                if sums.indices.contains(b) { sums[b] += t.amount }
            }
            var running = 0
            return sums.map { running += $0; return running }
        }
        let current = buckets(interval), previous = buckets(previousInterval)
        let nowBucket = calendar.dateComponents([unit], from: interval.start, to: now).value(for: unit) ?? 0
        cumulative = (0..<max(current.count, previous.count)).map { i in
            CumulativePoint(index: i + 1, current: i < current.count && i <= nowBucket ? current[i] : nil,
                            previous: i < previous.count ? previous[i] : nil)
        }

        let span = interval // a local: closures can't capture self before init ends
        let byCategory = Dictionary(grouping: txns.filter { $0.kind == .expense && span.start <= $0.date && $0.date < span.end }, by: \.category)
            .map { (category: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.amount > $1.amount }
        let top = byCategory.filter { $0.category != nil }.prefix(5)
        let rest = byCategory.reduce(0) { $0 + $1.amount } - top.reduce(0) { $0 + $1.amount }
        var slices = top.compactMap { c in
            c.category.map { CategorySlice(id: $0.key ?? $0.name, name: $0.name, icon: $0.icon, color: $0.color, amount: c.amount) }
        }
        if rest > 0 { slices.append(CategorySlice(id: "other", name: String(localized: "Other", table: "Overview"), icon: "ellipsis", color: .gray, amount: rest)) }
        categories = slices
    }

    /// Percent change, nil when there is nothing to compare with.
    static func change(_ value: Int, from old: Int) -> Int? {
        old != 0 ? Int((Double(value - old) * 100 / Double(abs(old))).rounded()) : nil
    }

    /// Unpaid bills due within `days` days (overdue ones included), soonest first.
    static func billsDue(_ bills: [Recurring], within days: Int = 7, now: Date = .now, calendar: Calendar = .current) -> [Recurring] {
        let end = calendar.date(byAdding: .day, value: days + 1, to: calendar.startOfDay(for: now))!
        return bills.filter { $0.nextDue < end && !$0.isIncome }.sorted { $0.nextDue < $1.nextDue }
    }
}

/// The one-sentence Moonee note on the Overview (spec §2), rule-based from the numbers and gated by the reminder level (§3.4).
struct MooneeNote: Equatable {
    enum Level: String { case low, medium, high }

    struct JarState {
        let name: String
        let balance: Int
        let progress: Double
    }

    let text: String
    /// SF Symbol for the note row.
    let symbol: String

    /// Most urgent first: negative jar, over-budget jar, bill due (all levels) → jar ≥ 80% (medium+) → evening nudge (high).
    static func make(level: Level, jars: [JarState], bills: [(name: String, due: Date)], spentToday: Int,
                     now: Date = .now, calendar: Calendar = .current) -> MooneeNote {
        if let j = jars.first(where: { $0.balance < 0 }) {
            return .init(text: String(localized: "\(j.name) is in the red. Move some money in from another jar?", table: "Overview"), symbol: "exclamationmark.triangle.fill")
        }
        if let j = jars.filter({ $0.progress > 1 }).max(by: { $0.progress < $1.progress }) {
            return .init(text: String(localized: "\(j.name) is over this month's budget. Let's slow down a little.", table: "Overview"), symbol: "exclamationmark.triangle.fill")
        }
        if let b = bills.first {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: b.due)).day ?? 0
            let text = days < 0 ? String(localized: "\(b.name) is overdue. Pay it soon to avoid fees.", table: "Overview")
                : days == 0 ? String(localized: "\(b.name) is due today.", table: "Overview")
                : days == 1 ? String(localized: "\(b.name) is due tomorrow.", table: "Overview")
                : String(localized: "\(b.name) is due in \(days) days.", table: "Overview")
            return .init(text: text, symbol: days <= 0 ? "exclamationmark.triangle.fill" : "bell.fill")
        }
        if level != .low, let j = jars.filter({ $0.progress >= 0.8 }).max(by: { $0.progress < $1.progress }) {
            let percent = Int((j.progress * 100).rounded())
            return .init(text: String(localized: "\(j.name) has used \(percent)% of this month. Go easy for now!", table: "Overview"), symbol: "gauge.with.dots.needle.67percent")
        }
        if level == .high, spentToday == 0, calendar.component(.hour, from: now) >= 18 {
            return .init(text: String(localized: "Nothing logged today yet. Tell me what you spent?", table: "Overview"), symbol: "moon.zzz.fill")
        }
        return .init(text: String(localized: "Your jars are on track this month. Nice work!", table: "Overview"), symbol: "sparkles")
    }
}
