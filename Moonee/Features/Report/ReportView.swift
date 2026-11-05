import Charts
import SwiftData
import SwiftUI

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Report") }

/// Monthly report (spec §3.5): spending by jar and by category vs the month before, top expenses, the 6-month trend,
/// jar carry-over and a short Moonee comment (close-management skill; rule-based without a model). Push it, or use `ReportSheet`.
struct ReportView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Txn.date) private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    /// Any day of the month to show; nil = last month if it has data, else this month.
    @State private var anchor: Date?
    @State private var aiComment: (month: Date, text: String)?

    init(month: Date? = nil) { _anchor = State(initialValue: month) }

    private var currency: String { Money.defaultCurrency }

    var body: some View {
        let month = anchor ?? Self.defaultMonth(txns)
        let report = MonthReport(txns: txns, wallets: wallets, jars: jars, month: month)
        ScrollView {
            VStack(spacing: 14) {
                monthSwitcher(report.month)
                if report.isEmpty {
                    EmptyState(mood: .sleepy, title: L("No data for this month"), message: report.ruleComment(currency: currency))
                        .card()
                } else {
                    summary(report)
                    commentCard(report)
                    byJar(report)
                    byCategory(report)
                    trend(report)
                    top(report)
                    carryOver(report)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(MooneeBackground())
        .foregroundStyle(Color.ink)
        .navigationTitle(Text("Monthly report", tableName: "Report"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: report.month.start) { await askMoonee(report) }
    }

    /// Last month when it has anything, else this month (a brand-new user).
    static func defaultMonth(_ txns: [Txn], now: Date = .now, calendar: Calendar = .current) -> Date {
        let last = calendar.dateInterval(of: .month, for: calendar.date(byAdding: .month, value: -1, to: now)!)!
        return txns.contains { $0.date >= last.start && $0.date < last.end } ? last.start : now
    }

    /// "Tháng 10 năm 2026" / "October 2026": ICU gives vi months in lower case.
    static func monthTitle(_ d: Date, year: Bool = true) -> String {
        let s = year ? d.formatted(.dateTime.month(.wide).year()) : d.formatted(.dateTime.month(.wide))
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // MARK: - Sections

    private func monthSwitcher(_ m: DateInterval) -> some View {
        let cal = Calendar.current
        let isCurrent = m.contains(.now)
        return HStack {
            Button { anchor = cal.date(byAdding: .month, value: -1, to: m.start) } label: { HeaderCircle("chevron.left") }
                .accessibilityLabel(Text("Previous month", tableName: "Report"))
            Spacer()
            Text(Self.monthTitle(m.start)).font(.sectionTitle)
            Spacer()
            Button { anchor = cal.date(byAdding: .month, value: 1, to: m.start) } label: { HeaderCircle("chevron.right") }
                .accessibilityLabel(Text("Next month", tableName: "Report"))
                .disabled(isCurrent).opacity(isCurrent ? 0.35 : 1)
        }
        .padding(.top, 4)
    }

    private func summary(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spent", tableName: "Report").font(.caption).foregroundStyle(Color.inkSecondary)
                AmountText(r.spent, currency: currency).heroAmountFont()
                if let c = r.change {
                    // Arrow + sign: colour is never the only cue (spec F).
                    HStack(spacing: 3) {
                        Image(systemName: c > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").imageScale(.small)
                        Text(verbatim: "\(c > 0 ? "+" : "")\(c)%").fontWeight(.semibold).monospacedDigit()
                        Text("vs the month before", tableName: "Report").foregroundStyle(Color.inkSecondary)
                    }
                    .font(.caption)
                    .foregroundStyle(c > 0 ? Color.warningText : Color.brandDeep)
                }
            }
            Divider()
            HStack(alignment: .top) {
                figure(Text("Income", tableName: "Report"), r.income, plus: true)
                Spacer()
                figure(Text("Saved", tableName: "Report"), r.saved, plus: true)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Savings rate", tableName: "Report").font(.caption).foregroundStyle(Color.inkSecondary)
                    Text(verbatim: r.savingsRate.map { "\($0)%" } ?? "–").font(.rowTitle).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func figure(_ title: Text, _ value: Int, plus: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption).foregroundStyle(Color.inkSecondary)
            AmountText(value, currency: currency, plus: plus && value > 0).font(.rowTitle)
                .foregroundStyle(value < 0 ? Color.danger : Color.ink)
        }
    }

    private func commentCard(_ r: MonthReport) -> some View {
        let text = aiComment.flatMap { $0.month == r.month.start ? $0.text : nil } ?? r.ruleComment(currency: currency)
        return HStack(alignment: .top, spacing: 10) {
            MooneeAvatar(size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Moonee's take", tableName: "Report").font(.rowTitle)
                Text(LocalizedStringKey(text)).font(.bodyText).foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ title: Text, symbol: String) -> some View {
        HStack(spacing: 8) {
            IconBadge(symbol: symbol, color: .brandDeep, size: 30)
            title.font(.sectionTitle)
            Spacer()
        }
    }

    private func byJar(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(Text("Spending by jar", tableName: "Report"), symbol: "chart.pie.fill")
            HStack(alignment: .center, spacing: 16) {
                DonutChart(slices: r.byJar.map { .init(label: $0.name, value: Double($0.total), color: $0.color) }) {
                    AmountText(r.spent, currency: currency, short: true).font(.rowTitle) // chart centre: short (spec §B)
                }
                .frame(width: 130)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(r.byJar) { s in
                        HStack(spacing: 6) {
                            Circle().fill(s.color).frame(width: 9, height: 9)
                            Text(s.name).font(.secondaryText).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Text(verbatim: r.spent > 0 ? "\(Int((Double(s.total) * 100 / Double(r.spent)).rounded()))%" : "").font(.caption).foregroundStyle(Color.inkSecondary).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .card()
    }

    private func byCategory(_ r: MonthReport) -> some View {
        let rows = Array(r.byCategory.prefix(6))
        // The two series are named by month ("October" / "September").
        let this = Self.monthTitle(r.month.start, year: false)
        let before = Self.monthTitle(Calendar.current.date(byAdding: .month, value: -1, to: r.month.start)!, year: false)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle(Text("By category", tableName: "Report"), symbol: "square.grid.2x2.fill")
            Chart {
                ForEach(rows) { s in
                    BarMark(x: .value("amount", s.total), y: .value("category", s.name))
                        .foregroundStyle(by: .value("month", this))
                        .position(by: .value("month", this))
                    BarMark(x: .value("amount", s.previous), y: .value("category", s.name))
                        .foregroundStyle(by: .value("month", before))
                        .position(by: .value("month", before))
                }
            }
            .chartForegroundStyleScale([this: Color.brandPrimary, before: Color.brandPrimary.opacity(0.3)])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let n = v.as(Int.self) { Text(AmountFormat.string(n, currency, short: true)) } }
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: CGFloat(rows.count) * 44 + 40)
            ForEach(rows) { s in
                HStack(spacing: 8) {
                    Image(systemName: s.icon).foregroundStyle(s.color).frame(width: 20)
                    Text(s.name).font(.secondaryText)
                    Spacer()
                    AmountText(s.total, currency: currency).font(.secondaryText.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    private func trend(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(Text("Spending trend", tableName: "Report"), symbol: "chart.bar.fill")
            Chart(r.trend) { t in
                BarMark(x: .value("month", t.month, unit: .month), y: .value("spent", t.spent))
                    .foregroundStyle(t.month == r.month.start ? AnyShapeStyle(LinearGradient.brand) : AnyShapeStyle(Color.brandPrimary.opacity(0.3)))
                    .cornerRadius(6)
                    .accessibilityLabel(t.month.formatted(.dateTime.month(.wide)))
                    .accessibilityValue(AmountFormat.spoken(t.spent, currency))
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true) } }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let n = v.as(Int.self) { Text(AmountFormat.string(n, currency, short: true)) } }
                }
            }
            .frame(height: 150)
        }
        .card()
    }

    private func top(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(Text("Top expenses", tableName: "Report"), symbol: "flame.fill").padding(.bottom, 4)
            ForEach(r.top) { t in
                TxnRow(txn: t, showDay: true)
                if t != r.top.last { Divider().padding(.leading, 46) }
            }
        }
        .card()
    }

    private func carryOver(_ r: MonthReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(Text("Carried over to next month", tableName: "Report"), symbol: "arrow.uturn.forward")
            ForEach(r.jars) { row in
                HStack(spacing: 10) {
                    IconBadge(symbol: row.jar.icon, color: row.jar.color, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.jar.name).font(.rowTitle).lineLimit(1)
                        HStack(spacing: 3) {
                            Text("Spent", tableName: "Report")
                            AmountText(row.month.spent, currency: currency)
                        }
                        .font(.caption).foregroundStyle(Color.inkSecondary)
                    }
                    Spacer(minLength: 4)
                    AmountText(row.month.balance, currency: currency).font(.rowTitle)
                        .foregroundStyle(row.month.balance < 0 ? Color.danger : Color.ink)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    // MARK: - Moonee

    /// Asks the close-management skill (this or last month only: its tool knows those two). The model only explains
    /// the numbers the tool computed (spec §9.3); with no model or a failure the rule comment stays.
    private func askMoonee(_ r: MonthReport) async {
        guard !r.isEmpty else { return }
        let cal = Calendar.current
        let lastMonth = cal.dateInterval(of: .month, for: cal.date(byAdding: .month, value: -1, to: .now)!)!
        let ask: String
        if r.month.contains(.now) { ask = L("Wrap up this month for me in two or three sentences.") }
        else if r.month.start == lastMonth.start { ask = L("Wrap up last month for me in two or three sentences.") }
        else { return }
        let router = LLMSettings.router()
        guard !router.candidates(for: Skill.closeManagement.job).isEmpty else { return }
        let assistant = Assistant(router: router, tools: MooneeTools(ledger: StoreLedger(context)))
        if case .answer(let text, _) = await assistant.answer(ask, skill: .closeManagement, context: ParserContext(context)) {
            aiComment = (r.month.start, text)
        }
    }
}

/// The report in its own navigation stack with a Done button, for sheets (chat's "See monthly report").
struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReportView().toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", tableName: "Report") }
                }
            }
        }
    }
}

/// Overview card (spec §2 "end-of-period report card"): shown when last month has data, opens its report.
struct ReportCard: View {
    let txns: [Txn]

    var body: some View {
        let cal = Calendar.current
        let last = cal.dateInterval(of: .month, for: cal.date(byAdding: .month, value: -1, to: .now)!)!
        if txns.contains(where: { $0.date >= last.start && $0.date < last.end }) {
            NavigationLink { ReportView(month: last.start) } label: {
                HStack(spacing: 10) {
                    IconBadge(symbol: "chart.pie.fill", color: .brandDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your \(last.start.formatted(.dateTime.month(.wide))) report is ready", tableName: "Report").font(.rowTitle)
                        Text("Spending by jar, top expenses and Moonee's take", tableName: "Report")
                            .font(.secondaryText).foregroundStyle(Color.inkSecondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 14)
            }
            .buttonStyle(.plain)
        }
    }
}
