import SwiftData
import SwiftUI

/// The transaction ledger (spec §2): search and a filter menu, then a List / Calendar switch (remembered).
/// List: sections by day. Calendar: a month heatmap (`SpendingHeatmap`, chevrons or swipe for other months), then the
/// month's days, or one day's spend and transactions when a day is tapped (tap it again or "Whole month" to go back).
/// Tap a row (or swipe → Edit) to edit it in `TxnEditForm`; swipe → Delete removes it with its splits.
struct TransactionLedgerView: View {
    enum Mode: String, CaseIterable { case list, calendar }

    @Query(sort: \Txn.date, order: .reverse) private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query(sort: \Category.order) private var categories: [Category]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @AppStorage("ledger.mode") private var mode = Mode.list
    @State private var filter = TxnFilter()
    @State private var editing: Txn?
    /// Calendar mode: any date in the shown month, and the tapped day (nil = whole month).
    @State private var month: Date
    @State private var day: Date?
    @State private var slide = 0 // direction of the last month change
    private let openIn: Mode?
    private let cal = Calendar.current

    /// `mode` opens in that mode (and remembers it); `day` opens Calendar on that day.
    init(mode: Mode? = nil, day: Date? = nil) {
        openIn = day == nil ? mode : .calendar
        var month = day ?? .now
        #if DEBUG
        // Screenshots: `-ledgerBack 1` opens Calendar on last month.
        let back = UserDefaults.standard.integer(forKey: "ledgerBack")
        if day == nil, back > 0 { month = Calendar.current.date(byAdding: .month, value: -back, to: .now)! }
        #endif
        _month = State(initialValue: month)
        _day = State(initialValue: day)
    }

    var body: some View {
        let shown = txns.filter { filter.matches($0) }
        List {
            Section {
                Picker(selection: $mode) {
                    Text("List", tableName: "Transactions").tag(Mode.list)
                    Text("Calendar", tableName: "Transactions").tag(Mode.calendar)
                } label: { Text("View", tableName: "Transactions") }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if mode == .calendar { calendar(shown) } else { daySections(shown) }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .overlay {
            if txns.isEmpty {
                ContentUnavailableView {
                    Label { Text("No transactions yet", tableName: "Transactions") } icon: { Image(systemName: "tray") }
                } description: {
                    Text("Tap + and tell Moonee “lunch 45k” to log your first one.", tableName: "Transactions")
                }
            } else if shown.isEmpty, mode == .list {
                if filter.text.isEmpty {
                    ContentUnavailableView {
                        Label { Text("No matching transactions", tableName: "Transactions") } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    } actions: {
                        Button { filter = TxnFilter() } label: { Text("Clear filters", tableName: "Transactions") }
                    }
                } else {
                    ContentUnavailableView.search(text: filter.text)
                }
            }
        }
        .navigationTitle(String(localized: "Transactions", table: "Transactions"))
        .searchable(text: $filter.text, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Search notes, categories, wallets", tableName: "Transactions"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { filterMenu } }
        .sheet(item: $editing) { TxnEditForm(txn: $0) }
        .onAppear { if let openIn { mode = openIn } }
    }

    // MARK: - Calendar

    /// The heatmap follows the search and filters, so "Food" shows where the food money went.
    @ViewBuilder private func calendar(_ shown: [Txn]) -> some View {
        let data = SpendingCalendar(txns: shown, month: month, calendar: cal)
        let inMonth = shown.filter { data.month.start <= $0.date && $0.date < data.month.end }
        // txns are newest first: the last one is the oldest, the calendar stops at its month.
        let canGoBack = txns.last.map { $0.date < data.month.start } ?? false
        let canGoForward = data.month.end <= .now
        Section {
            VStack(spacing: 12) {
                HStack {
                    chevron("chevron.left", label: Text("Previous month", tableName: "Transactions"), enabled: canGoBack) { move(-1) }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(data.month.start.formatted(.dateTime.month(.wide).year()).capitalized(with: locale))
                            .font(.headline).foregroundStyle(Color.ink)
                        AmountText(data.total, currency: Money.defaultCurrency).font(.subheadline).foregroundStyle(Color.inkSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    chevron("chevron.right", label: Text("Next month", tableName: "Transactions"), enabled: canGoForward) { move(1) }
                }
                SpendingHeatmap(calendar: data, selected: day) { tapped in
                    day = day.map { cal.isDate($0, inSameDayAs: tapped) } == true ? nil : tapped
                }
                .id(data.month.start)
                .transition(reduceMotion ? .opacity : .push(from: slide > 0 ? .trailing : .leading))
                .contentShape(.rect)
                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { g in
                    guard abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
                    if g.translation.width < 0, canGoForward { move(1) } else if g.translation.width > 0, canGoBack { move(-1) }
                })
            }
            .padding(.vertical, 6)
            .clipped()
        }
        if let day {
            let items = inMonth.filter { cal.isDate($0.date, inSameDayAs: day) }
            Section {
                LabeledContent {
                    AmountText(SpendingCalendar.spent(items), currency: Money.defaultCurrency).font(.headline).foregroundStyle(Color.ink)
                } label: { Text("Spent", tableName: "Transactions") }
                rows(items)
            } header: {
                HStack {
                    Text(TxnRow.dayTitle(day, withYear: true))
                    Spacer()
                    Button { self.day = nil } label: { Text("Whole month", tableName: "Transactions") }
                        .font(.footnote.weight(.semibold)).textCase(nil)
                }
            } footer: {
                if items.isEmpty { Text("No transactions on this day.", tableName: "Transactions") }
            }
        } else if inMonth.isEmpty {
            Section {} footer: { Text("No transactions in this month.", tableName: "Transactions") }
        } else {
            daySections(inMonth)
        }
    }

    private func move(_ step: Int) {
        slide = step
        let change = {
            month = cal.date(byAdding: .month, value: step, to: month)!
            day = nil
        }
        if reduceMotion { change() } else { withAnimation(.smooth) { change() } }
    }

    private func chevron(_ symbol: String, label: Text, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.footnote.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Color.brandMint, in: .circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.brandDeep : Color.inkSecondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Rows

    @ViewBuilder private func daySections(_ items: [Txn]) -> some View {
        let days = Dictionary(grouping: items) { cal.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        ForEach(days, id: \.key) { day, items in
            Section(TxnRow.dayTitle(day, withYear: true)) { rows(items) }
        }
    }

    /// One row per txn, with its stored attachment (receipt photo) as a thumbnail when it has one.
    private func rows(_ items: [Txn]) -> some View {
        ForEach(items) { t in
            Button { editing = t } label: {
                VStack(alignment: .leading, spacing: 8) {
                    TxnRow(txn: t)
                    if let data = t.attachment, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 72, height: 96)
                            .clipShape(.rect(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.track))
                            .padding(.leading, 44)
                            .accessibilityLabel(Text("Receipt", tableName: "Transactions"))
                    }
                }
            }
            .tint(.primary)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { delete(t) } label: {
                    Label { Text("Delete", tableName: "Transactions") } icon: { Image(systemName: "trash") }
                }
                Button { editing = t } label: {
                    Label { Text("Edit", tableName: "Transactions") } icon: { Image(systemName: "pencil") }
                }
                .tint(.brandDeep)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(selection: $filter.range) {
                ForEach(TxnFilter.Range.allCases) { Text($0.title).tag($0) }
            } label: { Label { Text("Date", tableName: "Transactions") } icon: { Image(systemName: "calendar") } }
                .pickerStyle(.menu)
            Picker(selection: $filter.wallet) {
                Text("All wallets", tableName: "Transactions").tag(Wallet?.none)
                ForEach(wallets) { Label($0.name, systemImage: $0.type.symbol).tag(Optional($0)) }
            } label: { Label { Text("Wallet", tableName: "Transactions") } icon: { Image(systemName: "wallet.bifold") } }
                .pickerStyle(.menu)
            Picker(selection: $filter.jar) {
                Text("All jars", tableName: "Transactions").tag(Jar?.none)
                ForEach(jars) { Label($0.name, systemImage: $0.icon).tag(Optional($0)) }
            } label: { Label { Text("Jar", tableName: "Transactions") } icon: { Image(systemName: "square.stack.3d.up") } }
                .pickerStyle(.menu)
            Picker(selection: $filter.category) {
                Text("All categories", tableName: "Transactions").tag(Category?.none)
                ForEach(categories) { Label($0.name, systemImage: $0.icon).tag(Optional($0)) }
            } label: { Label { Text("Category", tableName: "Transactions") } icon: { Image(systemName: "tag") } }
                .pickerStyle(.menu)
            if filter.isActive {
                Divider()
                Button(role: .destructive) { filter = TxnFilter(text: filter.text) } label: {
                    Label { Text("Clear filters", tableName: "Transactions") } icon: { Image(systemName: "xmark.circle") }
                }
            }
        } label: {
            Label {
                Text("Filters", tableName: "Transactions")
            } icon: {
                Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
    }

    private func delete(_ t: Txn) {
        context.delete(t) // IncomeSplits cascade (Txn.splits deleteRule)
        try? context.save()
    }
}

/// One transaction row: category icon, title, a secondary line, signed amount.
struct TxnRow: View {
    let txn: Txn
    /// The ledger is grouped by day, so it shows the category; elsewhere the row shows the day.
    var showDay = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: txn.category?.icon ?? txn.kind.symbol, color: txn.category?.color ?? .brandDeep, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(txn.title).font(.body).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            let flow = txn.flow
            AmountText(flow == 0 ? txn.amount : flow, currency: txn.currencyCode, plus: flow != 0)
                .font(.body.weight(.semibold))
                .foregroundStyle(flow > 0 ? Color.income : Color.primary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    static func dayTitle(_ day: Date, withYear: Bool = false) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return String(localized: "Today", table: "Transactions") }
        if cal.isDateInYesterday(day) { return String(localized: "Yesterday", table: "Transactions") }
        let sameYear = cal.isDate(day, equalTo: .now, toGranularity: .year)
        return withYear ? day.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.weekday(.wide).day().month(.wide).year())
            : day.formatted(.dateTime.day().month())
    }

    private var subtitle: String {
        let from = txn.kind == .jarTransfer ? txn.jar?.name : txn.wallet?.name
        let to = txn.kind == .jarTransfer ? txn.toJar?.name : txn.toWallet?.name
        let place = [from, to].compactMap { $0 }.joined(separator: " → ")
        let parts = showDay ? [TxnRow.dayTitle(txn.date), place] : [txn.category?.name ?? txn.kind.title, place]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private extension Txn {
    /// Note, else category, else kind ("Transfer").
    var title: String { !note.isEmpty ? note : category?.name ?? kind.title }

    /// What it did to my money: out < 0, in > 0, a move between my own wallets/jars = 0.
    var flow: Int {
        switch kind {
        case .expense, .lend: -amount
        case .income, .borrow: amount
        case .repay: debt?.direction == .lent ? amount : -amount
        case .transfer, .jarTransfer: 0
        }
    }
}

private extension TxKind {
    var symbol: String {
        switch self {
        case .expense: "cart.fill"
        case .income: "arrow.down.circle.fill"
        case .transfer: "arrow.left.arrow.right"
        case .jarTransfer: "arrow.triangle.swap"
        case .lend: "arrow.up.forward.circle.fill"
        case .borrow: "arrow.down.backward.circle.fill"
        case .repay: "arrow.uturn.backward.circle.fill"
        }
    }
}
