import Foundation

/// One month of the jar rule: each jar's budget is the month's income × its share. Pure, so it is unit-tested.
struct JarBudget {
    struct Row: Identifiable {
        let jar: Jar
        let budget: Int
        let spent: Int
        var id: ObjectIdentifier { ObjectIdentifier(jar) }
        var left: Int { budget - spent }
        var isOver: Bool { spent > budget }
        /// 0...1 for the progress bar; full when spending with no budget.
        var progress: Double { budget > 0 ? min(Double(spent) / Double(budget), 1) : (spent > 0 ? 1 : 0) }
    }

    let interval: DateInterval
    let income: Int
    let spent: Int
    /// Expenses whose category is missing or not mapped to a jar.
    let unassigned: Int
    let percentTotal: Int
    let rows: [Row]

    var monthTitle: String {
        let cal = Calendar.current
        return "Tháng \(cal.component(.month, from: interval.start)), \(String(cal.component(.year, from: interval.start)))"
    }

    init(txns: [Txn], jars: [Jar], anchor: Date, calendar: Calendar = .current) {
        let interval = calendar.dateInterval(of: .month, for: anchor)!
        let month = txns.filter { $0.date >= interval.start && $0.date < interval.end }
        let expenses = month.filter { $0.kind == .expense }
        let income = month.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
        let sorted = jars.sorted { $0.order < $1.order }
        // Old data may not sum to 100: split income by each jar's share of the total so budgets still add up to income.
        let total = sorted.reduce(0) { $0 + max($1.percent, 0) }

        self.interval = interval
        self.income = income
        percentTotal = total
        spent = expenses.reduce(0) { $0 + $1.amount }
        unassigned = expenses.filter { $0.category?.jar == nil }.reduce(0) { $0 + $1.amount }
        rows = sorted.map { jar in
            Row(jar: jar,
                budget: total > 0 ? income * max(jar.percent, 0) / total : 0,
                spent: expenses.filter { $0.category?.jar === jar }.reduce(0) { $0 + $1.amount })
        }
    }
}
