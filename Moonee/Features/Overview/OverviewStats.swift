import Foundation
import SwiftData

/// Every number on the Overview card stack, computed once per render from the stored data (spec §2).
struct OverviewStats {
    struct JarRow: Identifiable {
        let jar: Jar
        let month: Ledger<PersistentIdentifier>.JarMonth
        var id: PersistentIdentifier { jar.persistentModelID }
    }

    let spentToday: Int
    let spentYesterday: Int
    let spentMonth: Int
    /// Σ (start + added this month) of the jars spending comes out of (jars with a category mapped).
    let monthBudget: Int
    let jars: [JarRow]
    let netWorth: Int
    /// Net worth at the end of each of the last 5 months, then now (oldest first).
    let netWorthTrend: [Int]

    /// Percent change of today vs yesterday; nil when yesterday had nothing.
    var todayChange: Int? { OverviewStats.change(spentToday, from: spentYesterday) }
    var budgetProgress: Double? { monthBudget > 0 ? Double(spentMonth) / Double(monthBudget) : nil }
    var netWorthChange: Int? { netWorthTrend.count > 1 ? OverviewStats.change(netWorth, from: netWorthTrend[netWorthTrend.count - 2]) : nil }

    init(txns: [Txn], wallets: [Wallet], jars: [Jar], assets: [Asset], now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.dateInterval(of: .day, for: now)!
        let yesterday = calendar.dateInterval(of: .day, for: today.start.addingTimeInterval(-1))!
        let month = calendar.dateInterval(of: .month, for: now)!
        func spent(_ i: DateInterval) -> Int {
            txns.reduce(0) { $1.kind == .expense && $1.date >= i.start && $1.date < i.end ? $0 + $1.amount : $0 }
        }
        spentToday = spent(today)
        spentYesterday = spent(yesterday)
        spentMonth = spent(month)

        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        self.jars = jars.sorted { $0.order < $1.order }.map { JarRow(jar: $0, month: ledger.jarMonth($0.persistentModelID, in: month)) }
        monthBudget = self.jars.filter { !($0.jar.categories ?? []).isEmpty }.reduce(0) { $0 + max($1.month.budget, 0) }

        // ponytail: assets have no price history, so past points use today's asset value; one Ledger per point is
        // O(6·n) — keep a monthly snapshot when histories get long.
        let assetValue = assets.reduce(0) { $0 + $1.value }
        netWorth = ledger.netWorth(assets: assetValue)
        netWorthTrend = (1...5).reversed().map { back in
            let end = calendar.date(byAdding: .month, value: -(back - 1), to: month.start)!
            return Ledger(txns: txns.filter { $0.date < end }, wallets: wallets, jars: jars).netWorth(assets: assetValue)
        } + [netWorth]
    }

    static func change(_ value: Int, from old: Int) -> Int? {
        old != 0 ? Int((Double(value - old) * 100 / Double(abs(old))).rounded()) : nil
    }

    /// Unpaid bills due within `days` days (overdue ones included), soonest first.
    static func billsDue(_ bills: [Recurring], within days: Int = 7, now: Date = .now, calendar: Calendar = .current) -> [Recurring] {
        let end = calendar.date(byAdding: .day, value: days + 1, to: calendar.startOfDay(for: now))!
        return bills.filter { $0.nextDue < end }.sorted { $0.nextDue < $1.nextDue }
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
    let mood: MooneeMood

    /// Most urgent first: negative jar, over-budget jar, bill due (all levels) → jar ≥ 80% (medium+) → evening nudge (high).
    static func make(level: Level, jars: [JarState], bills: [(name: String, due: Date)], spentToday: Int,
                     now: Date = .now, calendar: Calendar = .current) -> MooneeNote {
        if let j = jars.first(where: { $0.balance < 0 }) {
            return .init(text: String(localized: "\(j.name) is in the red. Move some money in from another jar?", table: "Overview"), mood: .worried)
        }
        if let j = jars.filter({ $0.progress > 1 }).max(by: { $0.progress < $1.progress }) {
            return .init(text: String(localized: "\(j.name) is over this month's budget. Let's slow down a little.", table: "Overview"), mood: .worried)
        }
        if let b = bills.first {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: b.due)).day ?? 0
            let text = days < 0 ? String(localized: "\(b.name) is overdue. Pay it soon to avoid fees.", table: "Overview")
                : days == 0 ? String(localized: "\(b.name) is due today.", table: "Overview")
                : days == 1 ? String(localized: "\(b.name) is due tomorrow.", table: "Overview")
                : String(localized: "\(b.name) is due in \(days) days.", table: "Overview")
            return .init(text: text, mood: days <= 0 ? .worried : .thinking)
        }
        if level != .low, let j = jars.filter({ $0.progress >= 0.8 }).max(by: { $0.progress < $1.progress }) {
            let percent = Int((j.progress * 100).rounded())
            return .init(text: String(localized: "\(j.name) has used \(percent)% of this month. Go easy for now!", table: "Overview"), mood: .worried)
        }
        if level == .high, spentToday == 0, calendar.component(.hour, from: now) >= 18 {
            return .init(text: String(localized: "Nothing logged today yet. Tell me what you spent?", table: "Overview"), mood: .sleepy)
        }
        return .init(text: String(localized: "Your jars are on track this month. Nice work!", table: "Overview"), mood: .happy)
    }
}

/// Ledger search + filters (spec §2: by wallet / jar / category / date).
struct TxnFilter {
    var text = ""
    var wallet: Wallet?
    var jar: Jar?
    var category: Category?
    /// Whole days, inclusive.
    var from: Date?
    var to: Date?

    var isActive: Bool { wallet != nil || jar != nil || category != nil || from != nil || to != nil }

    func matches(_ t: Txn, calendar: Calendar = .current) -> Bool {
        if let wallet, t.wallet != wallet, t.toWallet != wallet { return false }
        if let jar, t.jar != jar, t.toJar != jar, !(t.splits ?? []).contains(where: { $0.jar == jar }) { return false }
        if let category, t.category != category { return false }
        if let from, t.date < calendar.startOfDay(for: from) { return false }
        if let to, t.date >= calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))! { return false }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [t.note, t.category?.name, t.wallet?.name, t.toWallet?.name, t.debt?.person, t.rawInput]
            .contains { $0?.localizedStandardContains(q) == true }
    }
}

/// Keeps an edited income's jar shares in the same proportions: floors each, remainder to the largest, sum = `total`.
func rescaleSplits(_ amounts: [Int], to total: Int) -> [Int] {
    let old = amounts.reduce(0, +)
    guard old > 0, let biggest = amounts.indices.max(by: { amounts[$0] < amounts[$1] }) else { return amounts }
    var out = amounts.map { $0 * total / old }
    out[biggest] += total - out.reduce(0, +)
    return out
}
