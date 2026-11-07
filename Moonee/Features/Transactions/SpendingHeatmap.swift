import SwiftUI

/// One month of `SpendingCalendar` as a grid (GitHub-contribution style): the more spent, the deeper the green.
/// Full size in the ledger's Calendar mode (day numbers, legend), `compact` on the Overview card.
struct SpendingHeatmap: View {
    let calendar: SpendingCalendar
    var selected: Date?
    var compact = false
    let onTap: (Date) -> Void
    @Environment(\.balanceHidden) private var hidden
    @Environment(\.locale) private var locale

    private let cal = Calendar.current
    private var height: CGFloat { compact ? 20 : 34 }
    private var spacing: CGFloat { compact ? 4 : 6 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 7), spacing: spacing) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(Color.inkSecondary).accessibilityHidden(true)
                }
                ForEach(0..<calendar.leadingBlanks, id: \.self) { _ in Color.clear.frame(height: height) }
                ForEach(calendar.days) { cell($0) }
            }
            if !compact { legend }
        }
    }

    private func cell(_ day: SpendingCalendar.Day) -> some View {
        let future = day.date > .now
        let today = cal.isDateInToday(day.date)
        let isSelected = selected.map { cal.isDate($0, inSameDayAs: day.date) } ?? false
        let shape = RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous)
        return Button { onTap(day.date) } label: {
            shape.fill(Self.fill(day.level).opacity(future ? 0.4 : 1))
                .frame(height: height)
                .overlay {
                    if !compact {
                        Text(day.date.formatted(.dateTime.day()))
                            .font(.caption2.weight(today || isSelected ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(future ? Color.inkSecondary.opacity(0.5) : day.level >= 3 ? .white : Color.ink)
                    }
                }
                .overlay {
                    if isSelected { shape.strokeBorder(Color.brandYellow, lineWidth: 3) }
                    else if today { shape.strokeBorder(Color.ink, lineWidth: compact ? 1.5 : 2) }
                }
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(Text(verbatim: "\(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(spoken(day.total))"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func spoken(_ total: Int) -> String {
        if total == 0 { return String(localized: "No spending", table: "Transactions") }
        return hidden ? String(localized: "Balance hidden", table: "Components") : AmountFormat.spoken(total, Money.defaultCurrency, locale: locale)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less", tableName: "Transactions")
            ForEach(0..<5) { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.fill($0)).frame(width: 12, height: 12) }
            Text("More", tableName: "Transactions")
        }
        .font(.caption2)
        .foregroundStyle(Color.inkSecondary)
        .accessibilityHidden(true)
    }

    /// Weekday initials starting on the locale's first weekday.
    private var weekdaySymbols: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    /// Neutral for nothing spent, then the brand greens light → deep.
    static func fill(_ level: Int) -> Color {
        switch level {
        case 0: Color.track.opacity(0.7)
        case 1: Color.brandPrimaryLight.opacity(0.35)
        case 2: Color.brandPrimaryLight
        case 3: Color.brandPrimary
        default: Color.brandDeep
        }
    }
}
