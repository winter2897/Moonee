import SwiftData
import SwiftUI

/// The transaction ledger (spec §2). Opens on this month: ‹ › or a swipe on the header steps the period, the title
/// menu picks Week / Month / Year / All time / a custom range. Under it a totals card (money in · out · net from
/// `CashFlow`, the same numbers as Overview and the report; a wallet's opening → closing balance when filtered to one).
/// Views: by day (each day with its spending, then "Coming up" bills and salary as faded rows), by category, by jar,
/// and Calendar (a month heatmap, `SpendingHeatmap`; tap a day to see it). Search + filters (wallet, jar, category,
/// type, amount) show as removable chips. Tap a row (or swipe → Edit) to edit it in `TxnEditForm`; swipe → Delete
/// removes it with its splits. Tap a coming-up row to edit the bill in `RecurringForm`.
struct TransactionLedgerView: View {
    enum Mode: String, CaseIterable { case list, category, jar, calendar }

    @Query(sort: \Txn.date, order: .reverse) private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query(sort: \Category.order) private var categories: [Category]
    @Query(sort: \Recurring.nextDue) private var recurrings: [Recurring]
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("ledger.mode") private var mode = Mode.list
    @AppStorage("ledger.upcomingMonths") private var upcomingMonths = 1
    @State private var filter = TxnFilter()
    @State private var editing: Txn?
    @State private var editingBill: Recurring?
    @State private var period: TxnPeriod
    /// Calendar mode: the tapped day (nil = whole month).
    @State private var day: Date?
    @State private var slide = 0 // direction of the last period change
    @State private var pickingRange = false
    @State private var pickingAmount = false
    private let openIn: Mode?
    private let cal = Calendar.current

    /// `mode` opens in that mode (and remembers it); `day` opens Calendar on that day; `period` (else this month),
    /// `kind` and `category` start the ledger there (Overview cards drill in this way).
    init(mode: Mode? = nil, day: Date? = nil, period: TxnPeriod? = nil, kind: TxnFilter.Kind? = nil, category: Category? = nil) {
        openIn = day == nil ? mode : .calendar
        var month = day ?? .now
        #if DEBUG
        // Screenshots: `-ledgerBack 1` opens on last month.
        let back = UserDefaults.standard.integer(forKey: "ledgerBack")
        if day == nil, period == nil, back > 0 { month = Calendar.current.date(byAdding: .month, value: -back, to: .now)! }
        #endif
        _period = State(initialValue: period ?? .current(.month, now: month))
        _day = State(initialValue: day)
        _filter = State(initialValue: TxnFilter(category: category, kind: kind))
    }

    var body: some View {
        let shown = txns.filter { period.contains($0.date) && filter.matches($0) }
        List {
            if !chips.isEmpty { chipsRow }
            Section {
                Picker(selection: $mode) {
                    Text("Days", tableName: "Transactions").tag(Mode.list)
                    Text("Categories", tableName: "Transactions").tag(Mode.category)
                    Text("Jars", tableName: "Transactions").tag(Mode.jar)
                    Text("Calendar", tableName: "Transactions").tag(Mode.calendar)
                } label: { Text("View", tableName: "Transactions") }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                VStack(spacing: 14) {
                    periodHeader
                    totalsCard(shown)
                }
                .padding(.vertical, 6)
                .contentShape(.rect)
                .simultaneousGesture(swipe)
            }
            switch mode {
            case .calendar: calendar(shown)
            case .list:
                upcomingSection
                daySections(shown)
            case .category: groupSections(TxnPeriod.groups(shown, by: .category))
            case .jar: groupSections(TxnPeriod.groups(shown, by: .jar))
            }
            if shown.isEmpty, mode != .calendar, !txns.isEmpty { emptyFooter }
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
            }
        }
        .navigationTitle(String(localized: "Transactions", table: "Transactions"))
        .searchable(text: $filter.text, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Search notes, categories, wallets", tableName: "Transactions"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { filterMenu } }
        .sheet(item: $editing) { TxnEditForm(txn: $0) }
        .sheet(item: $editingBill) { RecurringForm(bill: $0) }
        .sheet(isPresented: $pickingRange) { RangeSheet(period: period) { set($0) } }
        .sheet(isPresented: $pickingAmount) { AmountRangeSheet(filter: $filter) }
        .onAppear { if let openIn { mode = openIn } }
        .onChange(of: mode, initial: true) { _, m in
            // The heatmap is a month: other periods show in the list views.
            if m == .calendar, period.unit != .month { period = .current(.month, now: period.interval?.start ?? .now) }
        }
    }

    // MARK: - Period

    private var canGoBack: Bool {
        guard let start = period.interval?.start else { return false }
        return txns.last.map { $0.date < start } ?? false // newest first: the last one is the oldest
    }

    private var canGoForward: Bool { period.interval.map { $0.end <= .now } ?? false }

    private var periodHeader: some View {
        HStack {
            chevron("chevron.left", label: Text("Previous period", tableName: "Transactions"), enabled: canGoBack) { move(-1) }
            Spacer()
            Menu {
                ForEach(TxnPeriod.Unit.allCases) { unit in
                    Button {
                        if unit == .custom { pickingRange = true; return }
                        let anchor = period.contains(.now) ? Date.now : period.interval?.start ?? .now
                        set(.current(unit, now: anchor))
                    } label: {
                        if unit == period.unit { Label(unit.title, systemImage: "checkmark") } else { Text(unit.title) }
                    }
                }
                if !period.contains(.now) {
                    Divider()
                    Button { set(.current(period.unit == .custom ? .month : period.unit)) } label: {
                        Label { Text("Back to today", tableName: "Transactions") } icon: { Image(systemName: "arrow.uturn.backward") }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(period.title).font(.headline).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                }
            }
            .accessibilityHint(Text("Choose week, month, year or a date range", tableName: "Transactions"))
            Spacer()
            chevron("chevron.right", label: Text("Next period", tableName: "Transactions"), enabled: canGoForward) { move(1) }
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { g in
            guard abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
            if g.translation.width < 0, canGoForward { move(1) } else if g.translation.width > 0, canGoBack { move(-1) }
        }
    }

    private func move(_ step: Int) {
        slide = step
        animate { period = period.moved(step); day = nil }
    }

    private func set(_ p: TxnPeriod) {
        if mode == .calendar, p.unit != .month { mode = .list }
        animate { period = p; day = nil }
    }

    private func animate(_ change: () -> Void) {
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

    // MARK: - Totals

    /// Money in · out · net of what is shown, or the filtered wallet's opening → closing balance.
    @ViewBuilder private func totalsCard(_ shown: [Txn]) -> some View {
        let currency = Money.defaultCurrency
        if let w = filter.wallet {
            let span = period.walletSpan(w, txns: txns, wallets: wallets, jars: jars)
            HStack(alignment: .firstTextBaseline) {
                stat(Text("Opening balance", tableName: "Transactions"), AmountText(span.opening, currency: w.currencyCode), alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(Color.inkSecondary)
                stat(Text("Closing balance", tableName: "Transactions"), AmountText(span.closing, currency: w.currencyCode), alignment: .trailing)
            }
            HStack {
                Text("Change", tableName: "Transactions")
                Spacer()
                AmountText(span.change, currency: w.currencyCode, plus: true).foregroundStyle(span.change >= 0 ? Color.income : Color.ink)
            }
            .font(.footnote).foregroundStyle(Color.inkSecondary)
        } else {
            let flow = CashFlow(shown)
            HStack(alignment: .firstTextBaseline) {
                stat(Text("Money in", tableName: "Transactions"), AmountText(flow.income, currency: currency, plus: true), color: .income, alignment: .leading)
                stat(Text("Money out", tableName: "Transactions"), AmountText(-flow.expense, currency: currency), alignment: .center)
                stat(Text("Net", tableName: "Transactions"), AmountText(flow.net, currency: currency, plus: true), alignment: .trailing)
            }
            Text("Wallet transfers, jar transfers and loans aren't counted as income or spending.", tableName: "Transactions")
                .font(.caption).foregroundStyle(Color.inkSecondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ title: Text, _ amount: AmountText, color: Color = .ink, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            title.font(.caption).foregroundStyle(Color.inkSecondary)
            amount.font(.headline).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Calendar

    /// The heatmap follows the search and filters, so "Food" shows where the food money went.
    @ViewBuilder private func calendar(_ shown: [Txn]) -> some View {
        let data = SpendingCalendar(txns: shown, month: period.interval?.start ?? .now, calendar: cal)
        Section {
            SpendingHeatmap(calendar: data, selected: day) { tapped in
                day = day.map { cal.isDate($0, inSameDayAs: tapped) } == true ? nil : tapped
            }
            .id(data.month.start)
            .transition(reduceMotion ? .opacity : .push(from: slide > 0 ? .trailing : .leading))
            .contentShape(.rect)
            .simultaneousGesture(swipe)
            .padding(.vertical, 6)
            .clipped()
        }
        if let day {
            let items = shown.filter { cal.isDate($0.date, inSameDayAs: day) }
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
        } else if shown.isEmpty {
            Section {} footer: { Text("No transactions in this month.", tableName: "Transactions") }
        } else {
            daySections(shown)
        }
    }

    // MARK: - Sections

    @ViewBuilder private func daySections(_ items: [Txn]) -> some View {
        let days = Dictionary(grouping: items) { cal.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        ForEach(days, id: \.key) { day, items in
            Section {
                rows(items)
            } header: {
                HStack {
                    Text(TxnRow.dayTitle(day, withYear: true))
                    Spacer()
                    let spent = SpendingCalendar.spent(items)
                    if spent > 0 { AmountText(-spent, currency: Money.defaultCurrency).textCase(nil) }
                }
            }
        }
    }

    private func groupSections(_ groups: [TxnPeriod.Group]) -> some View {
        ForEach(groups) { g in
            Section {
                rows(g.txns)
            } header: {
                HStack(spacing: 8) {
                    IconBadge(symbol: g.icon, color: g.color, size: 22)
                    Text(g.name).lineLimit(1)
                    Spacer()
                    if let p = g.percent { Text(verbatim: "\(p)%").foregroundStyle(Color.inkSecondary) }
                    AmountText(g.total, currency: Money.defaultCurrency).foregroundStyle(Color.ink)
                }
                .textCase(nil)
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    /// Bills, salary and other recurring items due in the next 1 / 3 / 12 months, while the period includes today
    /// and no filter is on (they don't follow the filters, so "Food" would still list the rent).
    @ViewBuilder private var upcomingSection: some View {
        if period.contains(.now), !recurrings.isEmpty, !filter.isActive {
            let items = TxnPeriod.upcoming(recurrings, txns: txns, months: upcomingMonths)
            Section {
                ForEach(items) { u in
                    Button { editingBill = u.bill } label: { UpcomingRow(item: u) }.tint(.primary)
                }
            } header: {
                HStack {
                    Text("Coming up", tableName: "Transactions")
                    Spacer()
                    Picker(selection: $upcomingMonths) {
                        ForEach([1, 3, 12], id: \.self) { n in Text("Next \(n) months", tableName: "Transactions").tag(n) }
                    } label: { Text("Coming up", tableName: "Transactions") }
                        .pickerStyle(.menu)
                        .font(.footnote)
                        .textCase(nil)
                }
            } footer: {
                if items.isEmpty { Text("Nothing due in this time.", tableName: "Transactions") }
            }
        }
    }

    private var emptyFooter: some View {
        Section {} footer: {
            VStack(alignment: .leading, spacing: 8) {
                if !filter.text.isEmpty || filter.isActive {
                    Text("No matching transactions", tableName: "Transactions")
                    if filter.isActive {
                        Button { filter = TxnFilter(text: filter.text) } label: { Text("Clear filters", tableName: "Transactions") }
                    }
                } else {
                    Text("No transactions in this period.", tableName: "Transactions")
                }
            }
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

    // MARK: - Filters

    /// Active filters as removable chips, under the search field.
    private var chips: [(id: String, label: String, clear: () -> Void)] {
        let money = { (v: Int) in AmountFormat.string(v, Money.defaultCurrency) }
        var out: [(id: String, label: String, clear: () -> Void)] = []
        if let w = filter.wallet { out.append(("wallet", w.name, { filter.wallet = nil })) }
        if let j = filter.jar { out.append(("jar", j.name, { filter.jar = nil })) }
        if let c = filter.category { out.append(("category", c.name, { filter.category = nil })) }
        if let k = filter.kind { out.append(("kind", k.title, { filter.kind = nil })) }
        let lo = filter.minAmount, hi = filter.maxAmount
        if lo > 0 || hi > 0 {
            let label = lo > 0 && hi > 0 ? "\(money(lo)) – \(money(hi))" : lo > 0 ? "≥ \(money(lo))" : "≤ \(money(hi))"
            out.append(("amount", label, { filter.minAmount = 0; filter.maxAmount = 0 }))
        }
        return out
    }

    private var chipsRow: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.id) { chip in
                        Button(action: chip.clear) {
                            HStack(spacing: 4) {
                                Text(chip.label).lineLimit(1)
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.brandMint, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brandDeep)
                        .accessibilityLabel(Text("Remove filter \(chip.label)", tableName: "Transactions"))
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(selection: $filter.kind) {
                Text("All types", tableName: "Transactions").tag(TxnFilter.Kind?.none)
                ForEach(TxnFilter.Kind.allCases) { Text($0.title).tag(Optional($0)) }
            } label: { Label { Text("Type", tableName: "Transactions") } icon: { Image(systemName: "arrow.up.arrow.down") } }
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
            Button { pickingAmount = true } label: {
                Label { Text("Amount range…", tableName: "Transactions") } icon: { Image(systemName: "number") }
            }
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

/// A coming-up bill or salary: faded, signed like a txn would be.
private struct UpcomingRow: View {
    let item: TxnPeriod.Upcoming

    var body: some View {
        let r = item.bill
        HStack(spacing: 12) {
            IconBadge(symbol: r.category?.icon ?? (r.isIncome ? "arrow.down.circle.fill" : "calendar"),
                      color: r.category?.color ?? .brandDeep, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.body).lineLimit(1)
                Text(TxnRow.dayTitle(item.date, withYear: true)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            AmountText(r.isIncome ? r.amount : -r.amount, currency: r.currencyCode, plus: r.isIncome)
                .font(.body.weight(.semibold))
                .foregroundStyle(r.isIncome ? Color.income : Color.primary)
        }
        .opacity(0.55)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Upcoming", tableName: "Transactions"))
    }
}

/// Custom period: two days, inclusive.
private struct RangeSheet: View {
    let onDone: (TxnPeriod) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var from: Date
    @State private var to: Date

    init(period: TxnPeriod, onDone: @escaping (TxnPeriod) -> Void) {
        self.onDone = onDone
        let i = period.interval ?? Calendar.current.dateInterval(of: .month, for: .now)!
        _from = State(initialValue: i.start)
        _to = State(initialValue: i.end.addingTimeInterval(-1))
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(selection: $from, displayedComponents: .date) { Text("From", tableName: "Transactions") }
                DatePicker(selection: $to, in: from..., displayedComponents: .date) { Text("To", tableName: "Transactions") }
            }
            .navigationTitle(String(localized: "Custom range", table: "Transactions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { onDone(.custom(from: from, to: to)); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Amount range filter; empty = no bound.
private struct AmountRangeSheet: View {
    @Binding var filter: TxnFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                AmountField(title: String(localized: "At least", table: "Transactions"), minor: $filter.minAmount)
                AmountField(title: String(localized: "At most", table: "Transactions"), minor: $filter.maxAmount)
            }
            .navigationTitle(String(localized: "Amount range", table: "Transactions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(role: .confirm) { dismiss() } }
            }
        }
        .presentationDetents([.medium])
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
                if txn.kind == .transfer || txn.kind == .jarTransfer || txn.excludedFromReport {
                    HStack(spacing: 4) {
                        Image(systemName: txn.excludedFromReport ? "eye.slash" : "arrow.left.arrow.right")
                        Text("Not counted in income & spending", tableName: "Transactions")
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
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
        // A transfer's kind shows in its icon and "not counted" line, so its subtitle is just from → to.
        let isMove = txn.kind == .transfer || txn.kind == .jarTransfer
        let parts: [String?] = showDay ? [TxnRow.dayTitle(txn.date), place] : [isMove && !place.isEmpty ? nil : txn.category?.name ?? txn.kind.title, place]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
