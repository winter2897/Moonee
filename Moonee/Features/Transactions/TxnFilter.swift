import Foundation

/// Ledger search + filters (spec §2: by wallet / jar / category / date).
struct TxnFilter {
    /// Date presets for the toolbar menu (a menu can't hold date pickers).
    enum Range: String, CaseIterable, Identifiable {
        case all, thisWeek, thisMonth, lastMonth, thisYear
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All time", table: "Transactions")
            case .thisWeek: String(localized: "This week", table: "Transactions")
            case .thisMonth: String(localized: "This month", table: "Transactions")
            case .lastMonth: String(localized: "Last month", table: "Transactions")
            case .thisYear: String(localized: "This year", table: "Transactions")
            }
        }

        func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
            switch self {
            case .all: nil
            case .thisWeek: calendar.dateInterval(of: .weekOfYear, for: now)
            case .thisMonth: calendar.dateInterval(of: .month, for: now)
            case .lastMonth: calendar.date(byAdding: .month, value: -1, to: now).flatMap { calendar.dateInterval(of: .month, for: $0) }
            case .thisYear: calendar.dateInterval(of: .year, for: now)
            }
        }
    }

    var text = ""
    var wallet: Wallet?
    var jar: Jar?
    var category: Category?
    var range = Range.all

    var isActive: Bool { wallet != nil || jar != nil || category != nil || range != .all }

    func matches(_ t: Txn, now: Date = .now, calendar: Calendar = .current) -> Bool {
        if let wallet, t.wallet != wallet, t.toWallet != wallet { return false }
        if let jar, t.jar != jar, t.toJar != jar, !(t.splits ?? []).contains(where: { $0.jar == jar }) { return false }
        if let category, t.category != category { return false }
        if let i = range.interval(now: now, calendar: calendar), !(i.start <= t.date && t.date < i.end) { return false }
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
