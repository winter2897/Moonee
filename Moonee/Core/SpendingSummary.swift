import SwiftData
import SwiftUI

enum Period: CaseIterable {
    case week, month, year

    var title: String {
        switch self {
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .year: String(localized: "Year")
        }
    }

    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

/// Expense totals for one period vs the previous one. Pure, so it is unit-tested.
struct SpendingSummary {
    struct Row: Identifiable {
        let category: Category?
        let total: Int
        var id: PersistentIdentifier? { category?.persistentModelID }
    }

    let interval: DateInterval
    let total: Int
    let previousTotal: Int
    let rows: [Row]

    /// Percent change vs previous period, nil when there is nothing to compare.
    var change: Int? { previousTotal > 0 ? (total - previousTotal) * 100 / previousTotal : nil }

    init(txns: [Txn], period: Period, anchor: Date, calendar: Calendar = .current) {
        interval = calendar.dateInterval(of: period.component, for: anchor)!
        let previous = calendar.dateInterval(of: period.component, for: interval.start.addingTimeInterval(-1))!

        func expenses(in i: DateInterval) -> [Txn] {
            txns.filter { $0.isSpending && $0.date >= i.start && $0.date < i.end }
        }
        let current = expenses(in: interval)
        total = current.reduce(0) { $0 + $1.amount }
        previousTotal = expenses(in: previous).reduce(0) { $0 + $1.amount }
        rows = Dictionary(grouping: current, by: \.category)
            .map { Row(category: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }
}

