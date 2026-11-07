import SwiftData
import SwiftUI

/// "Spending calendar": one month as a grid, each day in a deeper green the more was spent (GitHub-contribution style).
/// Chevrons or a horizontal swipe change month; tapping a day opens its transactions. Numbers come from `SpendingCalendar`.
struct SpendingCalendarCard: View {
    let txns: [Txn]
    @State private var offset = 0 // months back from this one
    @State private var selected: SelectedDay?
    @State private var lastMove = 0 // slide direction of the month change
    @Environment(\.balanceHidden) private var hidden
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        let anchor = cal.date(byAdding: .month, value: offset, to: .now)!
        let data = SpendingCalendar(txns: txns, month: anchor, calendar: cal)
        // txns are sorted newest first: the last one is the oldest, the calendar stops at its month.
        let canGoBack = txns.last.map { $0.date < data.month.start } ?? false
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: Text("Spending calendar", tableName: "Overview"), symbol: "calendar", tint: .brandDeep) {
                HStack(spacing: 4) {
                    chevron("chevron.left", label: Text("Previous month", tableName: "Overview"), enabled: canGoBack) { move(-1) }
                    chevron("chevron.right", label: Text("Next month", tableName: "Overview"), enabled: offset < 0) { move(1) }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(data.month.start.formatted(.dateTime.month(.wide).year()).capitalized(with: locale))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                Spacer()
                AmountText(data.total, currency: Money.defaultCurrency).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
            }
            .accessibilityElement(children: .combine)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(Color.inkSecondary).accessibilityHidden(true)
                }
                ForEach(0..<data.leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 34) }
                ForEach(data.days) { cell($0) }
            }
            .id(data.month.start)
            .transition(reduceMotion ? .opacity : .push(from: lastMove > 0 ? .trailing : .leading))
            .contentShape(.rect)
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { g in
                guard abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
                if g.translation.width < 0, offset < 0 { move(1) } else if g.translation.width > 0, canGoBack { move(-1) }
            })
            legend
        }
        .clipped()
        .card()
        .sheet(item: $selected) { DaySpendingSheet(day: $0.date) }
        #if DEBUG
        // Screenshots: `-calendarBack 1` shows last month, `-calendarDay 5` opens day 5 of the shown month.
        .onAppear {
            let d = UserDefaults.standard
            offset = -d.integer(forKey: "calendarBack")
            let day = d.integer(forKey: "calendarDay")
            if day > 0, let start = cal.date(byAdding: .month, value: offset, to: .now).flatMap({ cal.dateInterval(of: .month, for: $0)?.start }) {
                selected = SelectedDay(date: cal.date(byAdding: .day, value: day - 1, to: start)!)
            }
        }
        #endif
    }

    private func move(_ step: Int) {
        lastMove = step
        if reduceMotion { offset += step } else { withAnimation(.smooth) { offset += step } }
    }

    private func cell(_ day: SpendingCalendar.Day) -> some View {
        let future = day.date > .now
        let today = cal.isDateInToday(day.date)
        return Button { selected = SelectedDay(date: day.date) } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.fill(day.level).opacity(future ? 0.4 : 1))
                .frame(height: 34)
                .overlay {
                    Text(day.date.formatted(.dateTime.day()))
                        .font(.caption2.weight(today ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(future ? Color.inkSecondary.opacity(0.5) : day.level >= 3 ? .white : Color.ink)
                }
                .overlay {
                    if today { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.ink, lineWidth: 2) }
                }
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(Text(verbatim: "\(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(spoken(day.total))"))
        .accessibilityAddTraits(today ? .isSelected : [])
    }

    private func spoken(_ total: Int) -> String {
        if total == 0 { return String(localized: "No spending", table: "Overview") }
        return hidden ? String(localized: "Balance hidden", table: "Components") : AmountFormat.spoken(total, Money.defaultCurrency, locale: locale)
    }

    private func chevron(_ symbol: String, label: Text, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.footnote.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(Color.brandMint, in: .circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.brandDeep : Color.inkSecondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Less", tableName: "Overview")
            ForEach(0..<5) { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.fill($0)).frame(width: 12, height: 12) }
            Text("More", tableName: "Overview")
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

private struct SelectedDay: Identifiable {
    let date: Date
    var id: Date { date }
}

/// One day: what was spent, every transaction (tap → `TxnEditForm`), and a txn's stored attachment (receipt photo) if it has one.
private struct DaySpendingSheet: View {
    let day: Date
    @Query private var txns: [Txn]
    @State private var editing: Txn?
    @Environment(\.dismiss) private var dismiss

    init(day: Date) {
        self.day = day
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        _txns = Query(filter: #Predicate<Txn> { $0.date >= start && $0.date < end }, sort: \.date)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        AmountText(SpendingCalendar.spent(txns), currency: Money.defaultCurrency)
                            .font(.title3.bold()).foregroundStyle(Color.ink)
                    } label: { Text("Spent", tableName: "Overview") }
                }
                Section {
                    ForEach(txns) { t in
                        Button { editing = t } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                TxnRow(txn: t)
                                if let data = t.attachment, let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 72, height: 96)
                                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.track))
                                        .padding(.leading, 44)
                                        .accessibilityLabel(Text("Receipt", tableName: "Overview"))
                                }
                            }
                        }
                        .tint(.primary)
                    }
                } footer: {
                    if txns.isEmpty { Text("No transactions on this day.", tableName: "Overview") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MooneeBackground())
            .navigationTitle(TxnRow.dayTitle(day, withYear: true))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text("Done", tableName: "Overview") } }
            }
            .sheet(item: $editing) { TxnEditForm(txn: $0) }
        }
        .presentationDetents([.medium, .large])
    }
}
