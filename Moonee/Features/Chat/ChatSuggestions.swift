import Foundation

/// The three question tiles under Moonee's last message, picked from the user's books (pure, so it is unit-tested).
/// Order: what needs doing now (at most two), then today's allowance, then a question to understand the month.
/// Every question is answered offline: it routes to a skill whose tools compute the numbers (`ChatSuggestionTests`).
struct ChatSuggestion: Equatable, Identifiable {
    enum Kind: String, Equatable {
        // Action now, only when true.
        case split, dueSoon, lowJar, owedToMe, categoryLimit
        // Daily.
        case today
        // Understanding.
        case topThisWeek, lastMonthReport, compareMonths
    }

    /// What tapping it does: send the question to Moonee, open the Budget tab's split, or open last month's report.
    enum Action: Equatable { case ask, openSplit, openReport }

    var kind: Kind
    /// The question as the user would type it; `.ask` sends exactly this.
    var title: String
    var symbol: String
    var action: Action = .ask
    var id: Kind { kind }

    static func pick(facts: BudgetFacts, debts: [LedgerDebt], currency: String, now: Date = .now, calendar: Calendar = .current) -> [ChatSuggestion] {
        let today = calendar.startOfDay(for: now)
        var actions: [ChatSuggestion] = []
        if facts.unallocated > 0 {
            let amount = AmountFormat.string(facts.unallocated, currency, short: true)
            actions.append(.init(kind: .split, title: String(localized: "Split \(amount) into jars", table: "Chat"),
                                 symbol: "square.stack.3d.up.fill", action: .openSplit))
        }
        if !MooneeTools.dueSoon(bills: facts.bills, debts: debts, now: now, calendar: calendar).isEmpty {
            actions.append(.init(kind: .dueSoon, title: String(localized: "What do I have to pay soon?", table: "Chat"), symbol: "calendar.badge.clock"))
        }
        // Below zero first, then the most used; Savings/Investing hold money for later and never "run low".
        let low = facts.jars.filter { j in
            j.balance < 0 || (!BudgetAdvisor.Role(key: j.key).isReserve && j.budget > 0 && j.spent * 5 >= j.budget * 4)
        }
        if let j = low.min(by: { a, b in (a.balance < 0 ? 0 : 1, -ratio(a)) < (b.balance < 0 ? 0 : 1, -ratio(b)) }) {
            actions.append(.init(kind: .lowJar, title: String(localized: "My \(j.name) jar is running low, what should I do?", table: "Chat"),
                                 symbol: "exclamationmark.triangle.fill"))
        }
        if debts.contains(where: { $0.theyOweMe && ($0.dueDate.map { $0 < today } ?? false) }) {
            actions.append(.init(kind: .owedToMe, title: String(localized: "Who owes me money?", table: "Chat"), symbol: "person.2.fill"))
        }
        if let c = facts.limited.filter({ $0.level != .normal }).max(by: { Double($0.spent) / Double($0.limit!) < Double($1.spent) / Double($1.limit!) }) {
            actions.append(.init(kind: .categoryLimit, title: String(localized: "How much is left for \(c.name)?", table: "Chat"), symbol: "gauge.with.needle.fill"))
        }

        let daily = ChatSuggestion(kind: .today, title: String(localized: "How much can I spend today?", table: "Chat"), symbol: "sun.max.fill")
        // The first 5 days of a month look back at the last one; otherwise (the last 5 days above all) compare with it.
        // ponytail: mid-month the comparison is the third tile too; give it its own question if the owner wants one.
        let month = calendar.component(.day, from: now) <= 5
            ? ChatSuggestion(kind: .lastMonthReport, title: String(localized: "See last month's report", table: "Chat"), symbol: "chart.bar.fill", action: .openReport)
            : ChatSuggestion(kind: .compareMonths, title: String(localized: "How does this month compare with last month?", table: "Chat"), symbol: "arrow.left.arrow.right")
        let week = ChatSuggestion(kind: .topThisWeek, title: String(localized: "Where did I spend the most this week?", table: "Chat"), symbol: "chart.pie.fill")
        return Array((actions.prefix(2) + [daily, week, month]).prefix(3))
    }

    private static func ratio(_ j: BudgetFacts.JarLine) -> Double { j.budget > 0 ? Double(j.spent) / Double(j.budget) : 0 }
}
