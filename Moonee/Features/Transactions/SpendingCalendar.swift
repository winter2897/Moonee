import Foundation

/// The spending calendar (ledger Calendar mode, Overview card) (GitHub-contribution style): one month's expense total per day and a 0–4 heat level.
/// Pure over the fetched txns, so it is unit-tested; `SpendingHeatmap` only renders it.
struct SpendingCalendar {
    struct Day: Identifiable {
        let date: Date
        let total: Int
        /// 0 = nothing spent, 1–4 = lightest → darkest green.
        let level: Int
        var id: Date { date }
    }

    let month: DateInterval
    /// Every day of the month, in order.
    let days: [Day]
    /// Empty cells before day 1, so weeks start on `calendar.firstWeekday` (Monday in Vietnam).
    let leadingBlanks: Int
    var total: Int { days.reduce(0) { $0 + $1.total } }

    init(txns: [Txn], month anchor: Date, calendar: Calendar = .current) {
        month = calendar.dateInterval(of: .month, for: anchor)!
        let totals = Self.dailyTotals(txns, in: month, calendar: calendar)
        let levels = Self.levels(Array(totals.values))
        var days: [Day] = []
        var d = month.start
        while d < month.end {
            let total = totals[d] ?? 0
            days.append(Day(date: d, total: total, level: levels[total] ?? 0))
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        self.days = days
        leadingBlanks = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
    }

    /// Expenses only, keyed by start of day.
    static func dailyTotals(_ txns: [Txn], in interval: DateInterval, calendar: Calendar = .current) -> [Date: Int] {
        txns.reduce(into: [:]) { totals, t in
            guard t.isSpending, interval.start <= t.date, t.date < interval.end else { return }
            totals[calendar.startOfDay(for: t.date), default: 0] += t.amount
        }
    }

    /// Spent on one day's txns (the day sheet's header).
    static func spent(_ txns: [Txn]) -> Int { txns.reduce(0) { $1.isSpending ? $0 + $1.amount : $0 } }

    /// Heat level per daily total: 0 for nothing, else 1–4 by rank among the month's distinct totals (quantiles),
    /// so one huge day doesn't wash out the rest. The smallest is 1, the largest 4.
    static func levels(_ totals: [Int]) -> [Int: Int] {
        let distinct = Set(totals.filter { $0 > 0 }).sorted()
        var levels = [0: 0]
        for (i, v) in distinct.enumerated() {
            levels[v] = distinct.count == 1 ? 4 : 1 + i * 3 / (distinct.count - 1)
        }
        return levels
    }
}
