import SwiftData
import SwiftUI

enum Period: CaseIterable {
    case week, month, year

    var title: String {
        switch self {
        case .week: "Tuần"
        case .month: "Tháng"
        case .year: "Năm"
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
            txns.filter { $0.kind == .expense && $0.date >= i.start && $0.date < i.end }
        }
        let current = expenses(in: interval)
        total = current.reduce(0) { $0 + $1.amount }
        previousTotal = expenses(in: previous).reduce(0) { $0 + $1.amount }
        rows = Dictionary(grouping: current, by: \.category)
            .map { Row(category: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
    }
}

struct SpendingView: View {
    @Query private var txns: [Txn]
    @State private var period: Period = .month
    @State private var anchor = Date()

    private var summary: SpendingSummary { SpendingSummary(txns: txns, period: period, anchor: anchor) }

    var body: some View {
        let s = summary
        NavigationStack {
            VStack(spacing: 14) {
                PillPicker(options: Period.allCases.map { ($0, $0.title) }, selection: $period)

                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(title(for: s.interval)).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
                .foregroundStyle(Color.mooneeInk)
                .padding(.horizontal, 12)

                totalCard(s)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Chi tiêu theo danh mục").font(.headline)
                    if s.rows.isEmpty {
                        Text("Chưa có chi tiêu trong kỳ này").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    }
                    ForEach(s.rows) { row in
                        CategoryRow(row: row, share: s.total > 0 ? Double(row.total) / Double(s.total) : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .foregroundStyle(Color.mooneeInk)
            .mooneeScreen("Chi tiêu")
        }
    }

    private func totalCard(_ s: SpendingSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tổng chi").font(.subheadline)
            Text(s.total.vnd).font(.system(size: 34, weight: .bold, design: .rounded))
            if let change = s.change {
                Label("\(change > 0 ? "+" : "")\(change)% so với \(period.title.lowercased()) trước",
                      systemImage: change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(change > 0 ? .red : .mooneeDark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(alignment: .bottomTrailing) { Hills().frame(width: 180, height: 90) }
        .background(LinearGradient(colors: [.white.opacity(0.9), Color(hex: 0xDCFCE7)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(.rect(cornerRadius: 22))
        .shadow(color: .mooneeDark.opacity(0.1), radius: 14, y: 6)
    }

    private func shift(_ step: Int) {
        anchor = Calendar.current.date(byAdding: period.component, value: step, to: anchor) ?? anchor
    }

    private func title(for i: DateInterval) -> String {
        let cal = Calendar.current
        switch period {
        case .week:
            let end = i.end.addingTimeInterval(-1)
            return "\(i.start.formatted(.dateTime.day().month(.twoDigits))) – \(end.formatted(.dateTime.day().month(.twoDigits)))"
        case .month: return "Tháng \(cal.component(.month, from: i.start)), \(String(cal.component(.year, from: i.start)))"
        case .year: return "Năm \(String(cal.component(.year, from: i.start)))"
        }
    }
}

private struct CategoryRow: View {
    let row: SpendingSummary.Row
    let share: Double

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: row.category?.icon ?? "questionmark", color: row.category?.color ?? .gray, size: 42)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.category?.name ?? "Chưa phân loại").font(.subheadline.weight(.medium))
                    Spacer()
                    Text(row.total.vnd).font(.subheadline.weight(.semibold))
                }
                HStack {
                    ProgressView(value: share).tint(.mooneeGreen)
                    Text("\(Int((share * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}
