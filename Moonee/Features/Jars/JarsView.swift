import SwiftData
import SwiftUI

/// Monthly jar dashboard: budget = month's income × jar percent, minus what its categories spent.
struct JarsView: View {
    @Query private var txns: [Txn]
    @Query private var jars: [Jar]
    @State private var anchor = Date()

    var body: some View {
        let b = JarBudget(txns: txns, jars: jars, anchor: anchor)
        VStack(spacing: 14) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(b.monthTitle).font(.subheadline.weight(.semibold))
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal, 12)

            incomeCard(b)

            if b.income == 0 {
                notice("Chưa có thu nhập tháng này. Thêm thu nhập để chia tiền vào các lọ.", symbol: "info.circle.fill", color: .mooneeDark)
            }
            if !b.rows.isEmpty && b.percentTotal != 100 {
                notice("Tổng tỉ lệ các lọ đang là \(b.percentTotal)%. Ngân sách được chia theo tỉ lệ tương ứng — hãy chỉnh lại cho đủ 100%.",
                       symbol: "exclamationmark.triangle.fill", color: .orange)
            }

            VStack(spacing: 16) {
                if b.rows.isEmpty {
                    Text("Chưa có lọ nào").foregroundStyle(.secondary).padding()
                }
                ForEach(b.rows) { JarRow(row: $0) }
                if b.unassigned > 0 {
                    Divider()
                    NavigationLink { JarMappingView() } label: {
                        HStack(spacing: 12) {
                            IconBadge(symbol: "questionmark", color: .orange, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Chưa thuộc lọ nào").font(.subheadline.weight(.medium))
                                Text("Gán danh mục để tính vào lọ").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(b.unassigned.vnd).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()

            VStack(spacing: 0) {
                link("slider.horizontal.3", "Tuỳ chỉnh lọ & tỉ lệ") { JarSettingsView() }
                Divider().padding(.leading, 44)
                link("tag", "Gán danh mục vào lọ") { JarMappingView() }
            }
            .card(padding: 12)
        }
        .foregroundStyle(Color.mooneeInk)
        .mooneeScreen("6 chiếc lọ")
    }

    private func incomeCard(_ b: JarBudget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Thu nhập tháng").font(.subheadline)
            Text(b.income.vnd).font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Đã chi \(b.spent.vnd) · Còn \((b.income - b.spent).vnd)")
                .font(.caption.weight(.medium))
                .foregroundStyle(b.spent > b.income ? .red : .mooneeDark)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(alignment: .bottomTrailing) { Hills().frame(width: 180, height: 90) }
        .background(LinearGradient(colors: [.white.opacity(0.9), Color(hex: 0xDCFCE7)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(.rect(cornerRadius: 22))
        .shadow(color: .mooneeDark.opacity(0.1), radius: 14, y: 6)
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(color)
            .card(padding: 12)
    }

    private func link<D: View>(_ symbol: String, _ title: String, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Color.mooneeGreen).frame(width: 30)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func shift(_ step: Int) {
        anchor = Calendar.current.date(byAdding: .month, value: step, to: anchor) ?? anchor
    }
}

private struct JarRow: View {
    let row: JarBudget.Row

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: row.jar.icon, color: row.jar.color, size: 42)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.jar.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(row.jar.percent)%").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.budget.vnd).font(.subheadline.weight(.semibold))
                }
                ProgressView(value: row.progress).tint(row.isOver ? .red : row.jar.color)
                HStack {
                    Text("Đã chi \(row.spent.vnd)")
                    Spacer()
                    if row.isOver {
                        Label("Vượt \((-row.left).vnd)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text("Còn \(row.left.vnd)").foregroundStyle(Color.mooneeDark)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Compact jar overview for the Spending tab; taps through to the dashboard.
struct JarSummaryCard: View {
    let anchor: Date
    @Query private var txns: [Txn]
    @Query private var jars: [Jar]

    var body: some View {
        let b = JarBudget(txns: txns, jars: jars, anchor: anchor)
        NavigationLink { JarsView() } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("6 chiếc lọ · \(b.monthTitle)").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                    ForEach(b.rows) { row in
                        VStack(spacing: 6) {
                            IconBadge(symbol: row.jar.icon, color: row.jar.color, size: 32)
                            Text(row.jar.name).font(.caption2.weight(.medium)).lineLimit(1)
                            ProgressView(value: row.progress).tint(row.isOver ? .red : row.jar.color)
                            Text(row.isOver ? "Vượt \((-row.left).vnd)" : "Còn \(row.left.vnd)")
                                .font(.caption2)
                                .foregroundStyle(row.isOver ? .red : .secondary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
    }
}
