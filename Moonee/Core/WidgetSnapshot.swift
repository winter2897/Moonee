import Foundation

/// What the widgets show (spec §8). The app computes every number with `BudgetFacts` and writes this file into the
/// App Group (`WidgetSync`); the widget extension only reads it, so it never opens the SwiftData store.
/// Compiled into the app and the widget extension.
struct WidgetSnapshot: Codable, Equatable {
    static let appGroup = "group.com.haiquan.moonee"
    static let deepLink = URL(string: "moonee://chat")!

    struct Jar: Codable, Equatable {
        var name: String
        var colorHex: Int
        /// The jar card's month: budget = start + added, spent, balance now.
        var budget, spent, balance: Int
        var progress: Double { budget > 0 ? min(Double(spent) / Double(budget), 1) : (spent > 0 ? 1 : 0) }
    }

    /// When the app computed it. Today's spend and the month belong to this date.
    var date: Date
    var currency: String
    /// "Hide balances" is on: every amount shows `AmountFormat.mask`.
    var hidden: Bool
    var spentToday: Int
    /// Every jar, in the user's order.
    var jars: [Jar]

    /// Same sums as `BudgetFacts.budget/spent/left`.
    var budget: Int { jars.reduce(0) { $0 + $1.budget } }
    var spent: Int { jars.reduce(0) { $0 + $1.spent } }
    var left: Int { budget - spent }
    /// Spent / budget for the lock-screen gauge, 0…1.
    var progress: Double { budget > 0 ? min(Double(spent) / Double(budget), 1) : (spent > 0 ? 1 : 0) }
    /// The 3 jars that spent most this month (ties keep the user's order).
    var topJars: [Jar] {
        Array(jars.enumerated().sorted { ($0.element.spent, $1.offset) > ($1.element.spent, $0.offset) }.prefix(3).map(\.element))
    }

    /// The snapshot as it reads at `now`, without the app: a later day has spent nothing today yet; a later month
    /// starts every jar from its balance (carry-over) with nothing spent. Income that arrives later shows once the app runs.
    func at(_ now: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        var s = self
        guard now > date else { return s }
        if !calendar.isDate(now, inSameDayAs: date) { s.spentToday = 0 }
        if !calendar.isDate(now, equalTo: date, toGranularity: .month) {
            s.jars = jars.map { Jar(name: $0.name, colorHex: $0.colorHex, budget: $0.balance, spent: 0, balance: $0.balance) }
        }
        return s
    }

    // MARK: - File in the App Group

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "widget.json")
    }

    static func load(from url: URL? = url) -> WidgetSnapshot? {
        url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
    }
}
