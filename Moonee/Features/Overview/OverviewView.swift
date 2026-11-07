import Charts
import SwiftData
import SwiftUI

/// Overview tab (spec §2): a dashboard of cards for the chosen period (week / month / year).
/// Moonee's note, balance with income and savings vs the previous period, spending per day with last period's average,
/// the monthly report card, top categories, a ring per jar, bills due in 7 days, the 5 latest transactions → the ledger.
/// Cards rise in one after another, numbers roll, charts grow and show details on touch (see `Dashboard.swift`).
/// Every card opens its detail on the same period: ledger screens and Wallets push here, Budget / Assets switch tab via `AppRoute`.
struct OverviewView: View {
    @Query(sort: \Txn.date, order: .reverse) private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var assets: [Asset]
    @Query(sort: \Recurring.nextDue) private var bills: [Recurring]
    @AppStorage(Prefs.reminderLevel) private var level = MooneeNote.Level.medium.rawValue
    @AppStorage(Prefs.profileName) private var name = ""
    @AppStorage(Prefs.profileAvatar) private var avatar = ""
    @Environment(\.modelContext) private var context
    @State private var period = Period.month
    @State private var editing: Txn?
    @State private var ledger: LedgerRoute?

    private var currency: String { Money.defaultCurrency }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in ScrollView {
                if txns.isEmpty {
                    EmptyState(mood: .sleepy, title: String(localized: "No transactions yet", table: "Overview"),
                               message: String(localized: "Tap + and tell Moonee “lunch 45k” to log your first one.", table: "Overview"))
                        .card()
                        .padding(.horizontal, 16)
                        .padding(.top, 40)
                        .reveal()
                } else {
                    dashboard.padding(.horizontal, 16).padding(.bottom, 24)
                }
            }
            #if DEBUG
            // Screenshots: `-overviewLedger YES` scrolls to the transactions card, `-overviewLedgerDay 6` opens the ledger on day 6 (0: whole month).
            .task {
                let d = UserDefaults.standard
                guard d.bool(forKey: "overviewLedger") else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo("ledger", anchor: .top)
                guard d.object(forKey: "overviewLedgerDay") != nil, let start = Calendar.current.dateInterval(of: .month, for: .now)?.start else { return }
                let day = d.integer(forKey: "overviewLedgerDay") // 0 = the whole month
                ledger = LedgerRoute(mode: .calendar, day: day > 0 ? Calendar.current.date(byAdding: .day, value: day - 1, to: start) : nil)
            }
            #endif
            }
            .background(MooneeBackground())
            .navigationTitle(String(localized: "Overview", table: "Overview"))
            // The dashboard draws its own header (date, greeting, avatar); pushed screens keep the bar.
            .toolbarVisibility(txns.isEmpty ? .automatic : .hidden, for: .navigationBar)
            .sheet(item: $editing) { TxnEditForm(txn: $0) }
            .navigationDestination(item: $ledger) {
                TransactionLedgerView(mode: $0.mode, day: $0.day, period: $0.period, kind: $0.kind, category: $0.category)
            }
            .navigationDestination(for: BudgetRoute.self) { $0.view } // a jar ring → that jar's detail
        }
        #if DEBUG
        .task { SampleData.insertIfRequested(context) }
        #endif
    }

    private var dashboard: some View {
        let s = DashboardStats(txns: txns, wallets: wallets, jars: jars, assets: assets, period: period)
        let due = DashboardStats.billsDue(bills)
        let advice = AdvisorMemory.pick(BudgetFacts(txns: txns, wallets: wallets, jars: jars, recurrings: bills).advice)
        let note = MooneeNote.make(level: MooneeNote.Level(rawValue: level) ?? .medium, advice: advice,
                                   jars: s.jars.map { .init(name: $0.jar.name, balance: $0.month.balance, progress: $0.month.progress) },
                                   bills: due.map { ($0.name, $0.nextDue) },
                                   spentToday: txns.reduce(0) { $1.isSpending && Calendar.current.isDateInToday($1.date) ? $0 + $1.amount : $0 })
        return VStack(spacing: 14) {
            OverviewHeader(name: name, avatar: avatar)
            CapsuleSwitcher(options: Period.allCases.map { ($0, $0.title) }, selection: $period)
                .accessibilityLabel(Text("Period", tableName: "Overview"))
                .padding(.bottom, 2)
            // Every card opens its detail (spec §3): ledger screens push here, Budget and Assets switch tabs.
            Button { AppRoute.shared.tab = .budget } label: {
                HStack(spacing: 8) {
                    MooneeNoteCard(mood: note.mood, text: note.text, animated: true)
                    CardChevron()
                }
                .card(padding: 12)
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            .reveal(0)
            BalanceCard(stats: s, currency: currency, periodNote: comparedWith) { ledger = $0 }.reveal(1)
            SpendingCard(stats: s, currency: currency) { ledger = $0 }.reveal(2)
            ReportCard(txns: txns).reveal(3)
            if !s.categories.isEmpty { CategoriesCard(categories: s.categories, period: s.ledgerPeriod, currency: currency) { ledger = $0 }.reveal(4) }
            if !s.jars.isEmpty { JarRingsCard(rows: s.jars, currency: currency).reveal(5) }
            if !due.isEmpty {
                Button { AppRoute.shared.tab = .budget } label: { BillsCard(bills: due) }
                    .buttonStyle(PressScaleStyle(scale: 0.98))
                    .reveal(6)
            }
            recentCard.id("ledger").reveal(7)
        }
        .animation(.smooth, value: period)
    }

    private var comparedWith: String {
        switch period {
        case .week: String(localized: "Changes compared with last week.", table: "Overview")
        case .month: String(localized: "Changes compared with last month.", table: "Overview")
        case .year: String(localized: "Changes compared with last year.", table: "Overview")
        }
    }

    // MARK: - Transactions

    /// The ledger's front door: this month's spending heatmap and total (tap → ledger in Calendar mode, a day → that day),
    /// the 5 latest transactions (tap → edit), then "All transactions".
    private var recentCard: some View {
        let month = SpendingCalendar(txns: txns, month: .now)
        return VStack(alignment: .leading, spacing: 8) {
            Button { ledger = LedgerRoute(mode: .calendar) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: Text("Transactions", tableName: "Transactions"), symbol: "calendar", tint: .brandDeep) { CardChevron() }
                    HStack(alignment: .firstTextBaseline) {
                        Text("Spent this month", tableName: "Overview").font(.subheadline).foregroundStyle(Color.inkSecondary)
                        Spacer()
                        AmountText(month.total, currency: currency).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
            SpendingHeatmap(calendar: month, compact: true) { ledger = LedgerRoute(mode: .calendar, day: $0) }
            Divider().padding(.vertical, 6)
            Text("Recent transactions", tableName: "Overview").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(txns.prefix(5)) { t in
                Button { editing = t } label: { TxnRow(txn: t, showDay: true).contentShape(.rect) }
                    .buttonStyle(.plain)
                if t != txns.prefix(5).last { Divider().padding(.leading, 46) }
            }
            NavigationLink { TransactionLedgerView() } label: {
                HStack {
                    Text("All transactions", tableName: "Overview")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.rowTitle)
                .foregroundStyle(Color.brandDeep)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .card()
    }
}

/// Opens the ledger from a card: a view, a period (else this month), a calendar day, a type or category filter.
private struct LedgerRoute: Hashable {
    var mode: TransactionLedgerView.Mode? = .list
    var period: TxnPeriod?
    var day: Date?
    var kind: TxnFilter.Kind?
    var category: Category?
}

/// The Overview period (week / month / year) as the ledger's period.
private extension DashboardStats {
    var ledgerPeriod: TxnPeriod {
        TxnPeriod(unit: period == .week ? .week : period == .month ? .month : .year, interval: interval)
    }
}

/// The "opens more" mark on a tappable card.
private struct CardChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.brandDeep).accessibilityHidden(true)
    }
}

/// Dashboard header: today's date in brand green, a greeting by time of day with the profile name, the avatar.
private struct OverviewHeader: View {
    let name: String
    let avatar: String

    var body: some View {
        let date = Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(date.prefix(1).uppercased() + date.dropFirst())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.brandDeep)
                Text(greeting)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            ProfileAvatarImage(avatar: avatar, size: 48)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .shadow(color: Color.brandDeep.opacity(0.18), radius: 8, y: 3)
        }
        .padding(.top, 8)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch (hour, trimmed.isEmpty) {
        case (5..<12, true): return String(localized: "Good morning!", table: "Overview")
        case (5..<12, false): return String(localized: "Good morning, \(trimmed)", table: "Overview")
        case (12..<18, true): return String(localized: "Good afternoon!", table: "Overview")
        case (12..<18, false): return String(localized: "Good afternoon, \(trimmed)", table: "Overview")
        case (_, true): return String(localized: "Good evening!", table: "Overview")
        case (_, false): return String(localized: "Good evening, \(trimmed)", table: "Overview")
        }
    }
}

extension MooneeNote {
    /// Moonee's face for the note: worried for warnings, thinking for a bill coming up, sleepy for the evening nudge.
    var mood: MooneeMood {
        switch symbol {
        case "sparkles": .happy
        case "moon.zzz.fill": .sleepy
        case "bell.fill", "lightbulb.fill": .thinking
        default: .worried
        }
    }
}

// MARK: - Balance

/// Total balance → Wallets, Net worth → the Assets tab, Income → this period's income, Saved → this period's totals.
private struct BalanceCard: View {
    let stats: DashboardStats
    let currency: String
    let periodNote: String
    let open: (LedgerRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                NavigationLink { WalletsView() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Total balance", tableName: "Overview").font(.subheadline).foregroundStyle(Color.inkSecondary)
                            Spacer()
                            CardChevron()
                        }
                        RollingAmount(stats.walletTotal, currency: currency).font(.heroAmount).foregroundStyle(Color.ink)
                    }
                    .contentShape(.rect)
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(PressScaleStyle(scale: 0.98))
                Button { AppRoute.shared.tab = .watchlist } label: {
                    HStack(spacing: 4) {
                        Text("Net worth", tableName: "Overview")
                        RollingAmount(stats.netWorth, currency: currency).fontWeight(.semibold)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).accessibilityHidden(true)
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.inkSecondary)
                    .frame(minHeight: 28)
                    .contentShape(.rect)
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(PressScaleStyle(scale: 0.98))
            }
            AdaptiveStack(spacing: 10) {
                Button { open(LedgerRoute(period: stats.ledgerPeriod, kind: .income)) } label: {
                    tile(Text("Income", tableName: "Overview"), symbol: "arrow.down.left", tint: .income,
                         value: stats.income, change: DashboardStats.change(stats.income, from: stats.previousIncome))
                }
                Button { open(LedgerRoute(period: stats.ledgerPeriod)) } label: {
                    tile(Text("Saved", tableName: "Overview"), symbol: "leaf.fill", tint: JarPalette.color(1),
                         value: stats.net, change: DashboardStats.change(stats.net, from: stats.previousNet), signed: true)
                }
            }
            .buttonStyle(PressScaleStyle(scale: 0.97))
            .fixedSize(horizontal: false, vertical: true)
            Text(periodNote).font(.caption).foregroundStyle(Color.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func tile(_ title: Text, symbol: String, tint: Color, value: Int, change: Int?, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
                    .frame(width: 22, height: 22).background(tint.opacity(0.14), in: .circle)
                title.font(.footnote.weight(.medium)).foregroundStyle(Color.inkSecondary)
                Spacer(minLength: 0)
                CardChevron()
            }
            RollingAmount(value, currency: currency, plus: signed).font(.cardAmount)
                .foregroundStyle(value < 0 ? Color.danger : Color.ink)
            if let change { ChangeBadge(percent: change, upIsGood: true) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.brandMint.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
        .contentShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Spending per day

/// Mebius "ghost bars": past buckets in grey, the selected one (else today) in the brand gradient,
/// a dashed line at last period's average, a callout comparing the same day of both periods.
/// The header opens this period's spending in the ledger; a tap on a bar opens that day (week / month) or month (year).
/// Touch-and-drag still inspects the bars.
private struct SpendingCard: View {
    let stats: DashboardStats
    let currency: String
    let open: (LedgerRoute) -> Void
    @State private var selectedIndex: Int?
    @State private var plot = CGRect.zero
    @State private var grow = 0.0
    @Environment(\.balanceHidden) private var hidden

    private var period: Period { stats.period }
    // Plain Strings: chart value labels stay out of the String Catalog.
    private let axisX = "Day", axisY = "Spent"

    var body: some View {
        let points = stats.perBucket
        let today = points.last { $0.current != nil }?.index
        let highlight = selectedIndex ?? today
        let selected = selectedIndex.flatMap { i in points.first { $0.index == i } }
        // Every day/month gets a faint full-height slot (Mebius ghost ticks), so a young month still reads as a month.
        let top = Double(max(points.compactMap(\.current).max() ?? 0, stats.previousAverage, 1)) * 1.08
        VStack(alignment: .leading, spacing: 12) {
            Button { open(LedgerRoute(period: stats.ledgerPeriod, kind: .expense)) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: Text("Spending", tableName: "Overview"), symbol: "chart.bar.fill", tint: .brandPrimary) { CardChevron() }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(periodName(previous: false)).font(.subheadline).foregroundStyle(Color.inkSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            RollingAmount(stats.expense, currency: currency).font(.heroAmount).foregroundStyle(Color.ink)
                            if let c = DashboardStats.change(stats.expense, from: stats.previousExpense) { ChangeBadge(percent: c) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            Chart {
                ForEach(points) { p in
                    BarMark(x: .value(axisX, p.index), yStart: .value(axisY, 0), yEnd: .value(axisY, top), width: .fixed(barWidth))
                        .cornerRadius(period == .month ? 3 : 7)
                        .foregroundStyle(Color.track.opacity(0.45))
                        .accessibilityHidden(true)
                }
                ForEach(points) { p in
                    if let v = p.current {
                        BarMark(x: .value(axisX, p.index), y: .value(axisY, Double(v) * grow), width: .fixed(barWidth))
                            .cornerRadius(period == .month ? 3 : 7)
                            .foregroundStyle(p.index == highlight ? AnyShapeStyle(LinearGradient.brand) : AnyShapeStyle(Color.ghostBar))
                            .accessibilityLabel(bucketLabel(p.index, long: true))
                            .accessibilityValue(AmountFormat.spoken(v, currency))
                    }
                }
                if stats.previousAverage > 0 {
                    RuleMark(y: .value(axisY, Double(stats.previousAverage) * grow))
                        .foregroundStyle(Color.inkSecondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            ChartPill(text: averageLabel)
                        }
                        .accessibilityLabel(averageLabel)
                }
                if let selected {
                    RuleMark(x: .value(axisX, selected.index))
                        .foregroundStyle(Color.brandPrimary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            ChartCallout(title: bucketLabel(selected.index, long: true),
                                         rows: [.init(color: .brandPrimary, amount: selected.current ?? 0),
                                                .init(color: .ghostBar, amount: selected.previous ?? 0)],
                                         currency: currency)
                        }
                }
            }
            .chartXSelection(value: $selectedIndex)
            .chartOverlay { proxy in
                // Only measures the plot area: a view here that takes touches would block the chart's drag-to-inspect.
                GeometryReader { geo in
                    let frame = proxy.plotFrame.map { geo[$0] } ?? .zero
                    Color.clear.allowsHitTesting(false).onChange(of: frame, initial: true) { plot = $1 }
                }
            }
            // A tap on a bar opens it; a drag fails the tap and keeps inspecting.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                guard plot.width > 0 else { return }
                let slots = Double(max(points.count, 2)) // matches chartXScale: 0.5 … slots + 0.5
                let i = Int((0.5 + (tap.location.x - plot.minX) / plot.width * slots).rounded())
                if points.contains(where: { $0.index == i && $0.current != nil }) { openBucket(i) }
            })
            .sensoryFeedback(.selection, trigger: selectedIndex)
            .chartXScale(domain: 0.5...(Double(max(points.count, 2)) + 0.5))
            .chartYScale(domain: 0...top)
            .chartXAxis {
                AxisMarks(values: xTicks) { v in
                    AxisValueLabel { if let i = v.as(Int.self) { Text(bucketLabel(i, long: false)) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel { if let a = v.as(Double.self) { Text(hidden ? "" : AmountFormat.string(Int(a), currency, short: true)) } }
                }
            }
            .frame(height: 190)
            .growIn($grow)
            .onChange(of: period) { selectedIndex = nil }
            #if DEBUG
            // Screenshots: `-overviewSelect 3` shows the callout for day 3.
            .onAppear { if UserDefaults.standard.integer(forKey: "overviewSelect") > 0 { selectedIndex = UserDefaults.standard.integer(forKey: "overviewSelect") } }
            #endif
            HStack(spacing: 14) {
                legend(Text(periodName(previous: false)), LinearGradient.brand)
                legend(Text(periodName(previous: true)), Color.ghostBar)
            }
            .font(.caption)
            .foregroundStyle(Color.inkSecondary)
        }
        .card()
    }

    /// A day of the week / month → that day in the ledger's calendar; a month of the year → that month's calendar.
    private func openBucket(_ i: Int) {
        let cal = Calendar.current
        if period == .year {
            let month = cal.date(byAdding: .month, value: i - 1, to: stats.interval.start)!
            open(LedgerRoute(mode: .calendar, period: .current(.month, now: month), kind: .expense))
        } else {
            open(LedgerRoute(mode: .calendar, day: cal.date(byAdding: .day, value: i - 1, to: stats.interval.start)!, kind: .expense))
        }
    }

    /// Mebius bars are slim capsules: about 60% of a day's / month's slot on an iPhone-wide card.
    private var barWidth: CGFloat {
        switch period {
        case .week: 22
        case .month: 6
        case .year: 13
        }
    }

    private var averageLabel: String {
        let amount = hidden ? AmountFormat.mask : AmountFormat.string(stats.previousAverage, currency, short: true)
        return String(localized: "Avg \(periodName(previous: true).lowercased()): \(amount)", table: "Overview")
    }

    private func legend(_ title: Text, _ style: some ShapeStyle) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(style).frame(width: 14, height: 6)
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

    /// Every weekday, every week's first day, every other month.
    private var xTicks: [Int] {
        switch period {
        case .week: Array(1...7)
        case .month: [1, 8, 15, 22, 29]
        case .year: Array(stride(from: 1, through: 12, by: 2))
        }
    }

    /// X labels: weekday for a week, day number for a month, month for a year.
    private func bucketLabel(_ i: Int, long: Bool) -> String {
        let cal = Calendar.current
        let start = stats.interval.start
        switch period {
        case .week:
            return cal.date(byAdding: .day, value: i - 1, to: start)!.formatted(.dateTime.weekday(long ? .wide : .abbreviated))
        case .month:
            return long ? cal.date(byAdding: .day, value: i - 1, to: start)!.formatted(.dateTime.day().month()) : "\(i)"
        case .year:
            return cal.date(byAdding: .month, value: i - 1, to: start)!.formatted(.dateTime.month(long ? .wide : .abbreviated))
        }
    }
}

extension Color {
    /// Mebius "ghost" bar: the not-highlighted bars and last period's series.
    static let ghostBar = Color(hex: 0xD5DDDA)
}

// MARK: - Categories

/// Top categories: one stacked capsule of shares, then a bar per category in its own colour.
/// The header opens the period's ledger by category; a category row opens its transactions.
private struct CategoriesCard: View {
    let categories: [DashboardStats.CategorySlice]
    let period: TxnPeriod
    let currency: String
    let open: (LedgerRoute) -> Void
    @State private var grow = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One category's share of the bar (2 pt gaps between segments). A function so the type checker stays fast on CI.
    private func segmentWidth(_ amount: Int, of total: Int, in width: CGFloat) -> CGFloat {
        let usable: CGFloat = width - CGFloat(categories.count - 1) * 2
        let share: CGFloat = CGFloat(amount) / CGFloat(total)
        return max(0, usable * share * grow)
    }

    var body: some View {
        let total = max(categories.reduce(0) { $0 + $1.amount }, 1)
        let top = max(categories.map(\.amount).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 14) {
            Button { open(LedgerRoute(mode: .category, period: period)) } label: {
                CardHeader(title: Text("Spending by category", tableName: "Overview"), symbol: "square.grid.2x2.fill", tint: JarPalette.color(3)) { CardChevron() }
                    .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(categories) { c in
                        Rectangle().fill(c.color.gradient)
                            .frame(width: segmentWidth(c.amount, of: total, in: geo.size.width))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(.capsule)
                .background(Color.track, in: .capsule)
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            ForEach(Array(categories.enumerated()), id: \.element.id) { i, c in
                Button {
                    // "Other" has no one category: the by-category view shows them all.
                    open(c.category.map { LedgerRoute(period: period, category: $0) } ?? LedgerRoute(mode: .category, period: period))
                } label: { row(i, c, total: total, top: top) }
                .buttonStyle(PressScaleStyle(scale: 0.98))
            }
        }
        .card()
        .growIn($grow)
    }

    private func row(_ i: Int, _ c: DashboardStats.CategorySlice, total: Int, top: Int) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: c.icon, color: c.color, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c.name).font(.rowTitle).foregroundStyle(Color.ink).lineLimit(1)
                    Text((Double(c.amount) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).foregroundStyle(Color.inkSecondary).monospacedDigit()
                    Spacer(minLength: 4)
                    AmountText(c.amount, currency: currency).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                }
                GeometryReader { geo in
                    Capsule().fill(c.color.gradient)
                        .frame(width: max(6, geo.size.width * CGFloat(c.amount) / CGFloat(top) * grow))
                        .animation(reduceMotion ? nil : .chartGrow.delay(0.15 + Double(i) * 0.06), value: grow)
                }
                .frame(height: 6)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Jars

/// One ring per jar: spent this month out of what the jar had, in the jar's colour (orange ≥ 80%, red when over).
private struct JarRingsCard: View {
    let rows: [DashboardStats.JarRow]
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { AppRoute.shared.tab = .budget } label: {
                CardHeader(title: Text("Jars this month", tableName: "Overview"), symbol: "square.stack.3d.up.fill", tint: JarPalette.color(0)) { CardChevron() }
                    .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 16) {
                ForEach(rows) { row in
                    // Pushed here (Overview's stack), so Back returns to Overview.
                    NavigationLink(value: BudgetRoute.jar(row.jar.persistentModelID, month: monthStart)) { cell(row) }
                        .buttonStyle(PressScaleStyle())
                }
            }
            Text("Ring: spent this month out of what the jar had. Amount: what is left.", tableName: "Overview")
                .font(.caption).foregroundStyle(Color.inkSecondary)
        }
        .card()
    }

    private var monthStart: Date { Calendar.current.dateInterval(of: .month, for: .now)!.start }

    private func cell(_ row: DashboardStats.JarRow) -> some View {
        let m = row.month
        let level = BudgetLevel(balance: m.balance, spent: m.spent, budget: m.budget)
        let progress = BudgetLevel.progress(spent: m.spent, budget: m.budget)
        return VStack(spacing: 6) {
            SweepRing(progress: progress, color: level == .normal ? row.jar.color : level.fill, lineWidth: 8) {
                Image(systemName: level.symbol ?? row.jar.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(level == .normal ? row.jar.color : level.text)
            }
            .frame(width: 64, height: 64)
            Text(row.jar.name).font(.caption.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.8)
            AmountText(m.balance, currency: currency, short: true).font(.footnote.weight(.semibold))
                .foregroundStyle(m.balance < 0 ? Color.danger : Color.ink)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(progress.formatted(.percent.precision(.fractionLength(0)))))
    }
}

// MARK: - Bills

private struct BillsCard: View {
    let bills: [Recurring]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: Text("Bills due in 7 days", tableName: "Overview"), symbol: "calendar", tint: .warning) { CardChevron() }
            ForEach(bills) { b in
                let status = BillStatus(due: b.nextDue, paid: false)
                HStack(spacing: 12) {
                    VStack(spacing: 0) {
                        Text(b.nextDue.formatted(.dateTime.day())).font(.headline).monospacedDigit()
                        Text(b.nextDue.formatted(.dateTime.weekday(.abbreviated))).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(status.color)
                    .frame(width: 44, height: 44)
                    .background(status.color.opacity(0.12), in: .rect(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name).font(.rowTitle).foregroundStyle(Color.ink).lineLimit(1)
                        HStack(spacing: 4) {
                            if let symbol = status.symbol { Image(systemName: symbol) }
                            status.label
                        }
                        .font(.caption)
                        .foregroundStyle(status.color)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        if b.isEstimate { Text(verbatim: "≈") }
                        AmountText(b.amount, currency: b.currencyCode)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(.rect)
    }
}
