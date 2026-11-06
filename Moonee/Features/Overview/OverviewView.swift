import Charts
import SwiftData
import SwiftUI

/// Overview tab (spec §2): a native, grouped dashboard for the chosen period (week / month / year).
/// Balance and in/out vs the previous period, cumulative spending line, spending by category, jars this month,
/// bills due in 7 days, the 5 latest transactions → the ledger. Charts show details on touch.
struct OverviewView: View {
    @Query(sort: \Txn.date, order: .reverse) private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var assets: [Asset]
    @Query(sort: \Recurring.nextDue) private var bills: [Recurring]
    @AppStorage(Prefs.reminderLevel) private var level = MooneeNote.Level.medium.rawValue
    @Environment(\.balanceHidden) private var hidden
    @Environment(\.modelContext) private var context
    @State private var period = Period.month
    @State private var selectedIndex: Int?
    @State private var selectedAmount: Int?
    @State private var editing: Txn?

    private var currency: String { Money.defaultCurrency }

    var body: some View {
        NavigationStack {
            Group {
                if txns.isEmpty {
                    ContentUnavailableView {
                        Label { Text("No transactions yet", tableName: "Overview") } icon: { Image(systemName: "moon.zzz") }
                    } description: {
                        Text("Tap + and tell Moonee “lunch 45k” to log your first one.", tableName: "Overview")
                    }
                } else {
                    dashboard
                }
            }
            .scrollContentBackground(.hidden)
            .background(MooneeBackground())
            .navigationTitle(String(localized: "Overview", table: "Overview"))
            .sheet(item: $editing) { TxnEditForm(txn: $0) }
        }
        #if DEBUG
        .task {
            SampleData.insertIfRequested(context)
            // Screenshots: `-overviewSelect 5` shows the chart callout for day 5.
            if UserDefaults.standard.integer(forKey: "overviewSelect") > 0 { selectedIndex = UserDefaults.standard.integer(forKey: "overviewSelect") }
        }
        #endif
    }

    private var dashboard: some View {
        let s = DashboardStats(txns: txns, wallets: wallets, jars: jars, assets: assets, period: period)
        let due = DashboardStats.billsDue(bills)
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)!.start
        let note = MooneeNote.make(level: MooneeNote.Level(rawValue: level) ?? .medium,
                                   jars: s.jars.map { .init(name: $0.jar.name, balance: $0.month.balance, progress: $0.month.progress) },
                                   bills: due.map { ($0.name, $0.nextDue) },
                                   spentToday: txns.reduce(0) { $1.kind == .expense && Calendar.current.isDateInToday($1.date) ? $0 + $1.amount : $0 })
        return List {
            Section {
                Picker(selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Text("Period", tableName: "Overview") }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Label { Text(note.text) } icon: { Image(systemName: note.symbol).foregroundStyle(Color.brandDeep) }
            }
            summary(s)
            if let last = Calendar.current.date(byAdding: .month, value: -1, to: monthStart),
               txns.contains(where: { $0.date >= last && $0.date < monthStart }) {
                Section {
                    NavigationLink { ReportView(month: last) } label: {
                        Label { Text("\(last.formatted(.dateTime.month(.wide))) report", tableName: "Overview") } icon: { Image(systemName: "doc.text.magnifyingglass") }
                    }
                }
            }
            spendingChart(s)
            categoryChart(s)
            jarsSection(s)
            if !due.isEmpty { billsSection(due) }
            recentSection
        }
        .listStyle(.insetGrouped)
        .onChange(of: period) { selectedIndex = nil; selectedAmount = nil }
    }

    // MARK: - Summary

    private func summary(_ s: DashboardStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total balance", tableName: "Overview").font(.subheadline).foregroundStyle(.secondary)
                AmountText(s.walletTotal, currency: currency).font(.largeTitle.weight(.bold))
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            LabeledContent { AmountText(s.netWorth, currency: currency) } label: { Text("Net worth", tableName: "Overview") }
            changeRow(Text("Income", tableName: "Overview"), value: s.income, previous: s.previousIncome, upIsGood: true)
            changeRow(Text("Expenses", tableName: "Overview"), value: s.expense, previous: s.previousExpense, upIsGood: false)
            changeRow(Text("Difference", tableName: "Overview"), value: s.net, previous: s.previousNet, upIsGood: true, signed: true)
        } footer: {
            Text(comparedWith)
        }
    }

    private var comparedWith: String {
        switch period {
        case .week: String(localized: "Income and expenses this week, compared with last week.", table: "Overview")
        case .month: String(localized: "Income and expenses this month, compared with last month.", table: "Overview")
        case .year: String(localized: "Income and expenses this year, compared with last year.", table: "Overview")
        }
    }

    /// "Income   12.000.000 ₫ / ↑ 8%": arrow + sign, so colour is never the only cue.
    private func changeRow(_ title: Text, value: Int, previous: Int, upIsGood: Bool, signed: Bool = false) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                AmountText(value, currency: currency, plus: signed).foregroundStyle(.primary)
                if let c = DashboardStats.change(value, from: previous), c != 0 {
                    HStack(spacing: 2) {
                        Image(systemName: c > 0 ? "arrow.up" : "arrow.down")
                        Text(verbatim: "\(c > 0 ? "+" : "")\(c)%").monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                        .foregroundStyle((c > 0) == upIsGood ? Color.brandDeep : Color.warningText)
                }
            }
        } label: { title }
    }

    // MARK: - Cumulative spending

    private func spendingChart(_ s: DashboardStats) -> some View {
        let selected = selectedIndex.flatMap { i in s.cumulative.first { $0.index == i } }
        return Section {
            Chart {
                ForEach(s.cumulative) { p in
                    if let v = p.previous {
                        LineMark(x: .value(axisX, p.index), y: .value(axisY, v), series: .value(seriesKey, "previous"))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                            .interpolationMethod(.monotone)
                    }
                    if let v = p.current {
                        LineMark(x: .value(axisX, p.index), y: .value(axisY, v), series: .value(seriesKey, "current"))
                            .foregroundStyle(Color.brandPrimary)
                            .lineStyle(StrokeStyle(lineWidth: 3))
                            .interpolationMethod(.monotone)
                    }
                }
                if let selected {
                    RuleMark(x: .value(axisX, selected.index))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            callout(selected)
                        }
                }
            }
            .chartXSelection(value: $selectedIndex)
            .chartXScale(domain: 1...max(s.cumulative.count, 2))
            .chartXAxis {
                AxisMarks(values: xTicks) { v in
                    AxisGridLine()
                    AxisValueLabel { if let i = v.as(Int.self) { Text(bucketLabel(i, long: false)) } }
                }
            }
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { if let a = v.as(Int.self) { Text(hidden ? "" : AmountFormat.string(a, currency, short: true)) } }
                }
            }
            .frame(height: 200)
            .padding(.top, 8)
            HStack(spacing: 16) {
                legend(current: true, Text(periodName(previous: false)))
                legend(current: false, Text(periodName(previous: true)))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Spending over time", tableName: "Overview")
        } footer: {
            Text("Touch and hold the chart to see each day.", tableName: "Overview")
        }
    }

    private func callout(_ p: DashboardStats.CumulativePoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bucketLabel(p.index, long: true)).font(.caption.weight(.semibold))
            if let c = p.current { HStack(spacing: 4) { Circle().fill(Color.brandPrimary).frame(width: 6, height: 6); AmountText(c, currency: currency) } }
            if let v = p.previous { HStack(spacing: 4) { Circle().fill(Color.secondary).frame(width: 6, height: 6); AmountText(v, currency: currency) } }
        }
        .font(.caption)
        .padding(8)
        .background(Color(.systemBackground), in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func legend(current: Bool, _ title: Text) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(current ? Color.brandPrimary : Color.secondary.opacity(0.6)).frame(width: 16, height: 3)
            title
        }
        .accessibilityElement(children: .combine)
    }

    private func periodName(previous: Bool) -> String {
        switch (period, previous) {
        case (.week, false): String(localized: "This week", table: "Overview")
        case (.week, true): String(localized: "Last week", table: "Overview")
        case (.month, false): String(localized: "This month", table: "Overview")
        case (.month, true): String(localized: "Last month", table: "Overview")
        case (.year, false): String(localized: "This year", table: "Overview")
        case (.year, true): String(localized: "Last year", table: "Overview")
        }
    }

    /// Every weekday, every week's first day, every month: clear of the plot's edges.
    private var xTicks: [Int] {
        switch period {
        case .week: Array(1...7)
        case .month: [1, 8, 15, 22, 29]
        case .year: Array(1...12)
        }
    }

    /// X labels: weekday for a week, day number for a month, month for a year.
    private func bucketLabel(_ i: Int, long: Bool) -> String {
        let cal = Calendar.current
        let start = cal.dateInterval(of: period.component, for: .now)!.start
        switch period {
        case .week:
            return cal.date(byAdding: .day, value: i - 1, to: start)!.formatted(.dateTime.weekday(long ? .wide : .abbreviated))
        case .month:
            return long ? cal.date(byAdding: .day, value: i - 1, to: start)!.formatted(.dateTime.day().month()) : "\(i)"
        case .year:
            return cal.date(byAdding: .month, value: i - 1, to: start)!.formatted(.dateTime.month(long ? .wide : .narrow))
        }
    }

    // Plain Strings: chart value labels stay out of the String Catalog.
    private let axisX = "Day", axisY = "Spent", seriesKey = "Period"

    // MARK: - By category

    private func categoryChart(_ s: DashboardStats) -> some View {
        let total = s.categories.reduce(0) { $0 + $1.amount }
        let selected = selectedAmount.flatMap { pick in
            var running = 0
            return s.categories.first { running += $0.amount; return pick <= running }
        }
        return Section {
            if s.categories.isEmpty {
                Text("No spending in this period.", tableName: "Overview").foregroundStyle(.secondary)
            } else {
                Chart(s.categories) { c in
                    SectorMark(angle: .value(axisY, c.amount), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(c.color)
                        .opacity(selected == nil || selected?.id == c.id ? 1 : 0.35)
                        .accessibilityLabel(c.name)
                }
                .chartAngleSelection(value: $selectedAmount)
                .chartLegend(.hidden)
                .chartBackground { proxy in
                    GeometryReader { geo in
                        if let plot = proxy.plotFrame {
                            let f = geo[plot]
                            VStack(spacing: 2) {
                                Text(selected?.name ?? String(localized: "Spent", table: "Overview"))
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                AmountText(selected?.amount ?? total, currency: currency).font(.title3.weight(.bold))
                            }
                            .frame(width: f.width * 0.55)
                            .position(x: f.midX, y: f.midY)
                        }
                    }
                }
                .frame(height: 220)
                .padding(.vertical, 8)
                ForEach(s.categories) { c in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(total > 0 ? (Double(c.amount) / Double(total)).formatted(.percent.precision(.fractionLength(0))) : "")
                                .foregroundStyle(.secondary).monospacedDigit()
                            AmountText(c.amount, currency: currency).foregroundStyle(.primary)
                        }
                    } label: {
                        Label { Text(c.name) } icon: { Image(systemName: c.icon).foregroundStyle(c.color) }
                    }
                }
            }
        } header: {
            Text("Spending by category", tableName: "Overview")
        }
    }

    // MARK: - Jars

    private func jarsSection(_ s: DashboardStats) -> some View {
        Section {
            ForEach(s.jars) { row in
                let m = row.month
                let level = BudgetLevel(balance: m.balance, spent: m.spent, budget: m.budget)
                let progress = BudgetLevel.progress(spent: m.spent, budget: m.budget)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label { Text(row.jar.name) } icon: { Image(systemName: row.jar.icon).foregroundStyle(row.jar.color) }
                        Spacer()
                        AmountText(m.balance, currency: currency).font(.body.weight(.semibold)).fixedSize()
                            .foregroundStyle(m.balance < 0 ? Color.danger : .primary)
                    }
                    ProgressView(value: min(max(progress, 0), 1)).tint(level.fill)
                    HStack(spacing: 4) {
                        AmountText(m.spent, currency: currency)
                        Text(verbatim: "/")
                        AmountText(m.budget, currency: currency)
                        Spacer()
                        if let symbol = level.symbol { Image(systemName: symbol).foregroundStyle(level.text) }
                        Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                            .foregroundStyle(level == .normal ? Color.secondary : level.text)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Jars this month", tableName: "Overview")
        } footer: {
            Text("Big number: what is left in the jar. Bar: spent this month out of what the jar had for the month.", tableName: "Overview")
        }
    }

    // MARK: - Bills

    private func billsSection(_ due: [Recurring]) -> some View {
        Section {
            ForEach(due) { b in
                let status = BillStatus(due: b.nextDue, paid: false)
                LabeledContent {
                    HStack(spacing: 2) {
                        if b.isEstimate { Text(verbatim: "≈") }
                        AmountText(b.amount, currency: b.currencyCode)
                    }
                    .foregroundStyle(.primary)
                } label: {
                    Label {
                        Text(b.name)
                        HStack(spacing: 4) {
                            if let symbol = status.symbol { Image(systemName: symbol) }
                            status.label
                        }
                        .foregroundStyle(status.color)
                    } icon: { Image(systemName: b.category?.icon ?? "doc.text").foregroundStyle(Color.brandDeep) }
                }
            }
        } header: {
            Text("Bills due in 7 days", tableName: "Overview")
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        Section {
            ForEach(txns.prefix(5)) { t in
                Button { editing = t } label: { TxnRow(txn: t, showDay: true) }
                    .tint(.primary)
            }
            NavigationLink { TransactionLedgerView() } label: {
                Text("All transactions", tableName: "Overview").foregroundStyle(Color.brandDeep)
            }
        } header: {
            Text("Recent transactions", tableName: "Overview")
        }
    }
}
