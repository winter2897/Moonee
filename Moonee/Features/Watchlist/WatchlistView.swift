import Charts
import SwiftData
import SwiftUI

/// Watchlist tab, MVP (spec §5, ROADMAP): net worth over time, what it is made of, and manually priced assets.
/// Standard list layout (feedback 3): large title, inset-grouped sections, sheet form, swipe to delete.
/// No live prices, watchlist feed or price alerts: those need a data source (version 2).
struct WatchlistView: View {
    @Environment(\.modelContext) private var context
    @Query private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Debt.createdAt) private var debts: [Debt]
    @Query(sort: \Asset.updatedAt, order: .reverse) private var assets: [Asset]
    @Query(sort: \NetWorthSnapshot.month) private var snapshots: [NetWorthSnapshot]
    @State private var period = ChartPeriod.sixMonths
    @State private var editing: Asset?
    @State private var adding = false
    @State private var setAside: SetAsideSheet.Mode?

    private let currency = Money.defaultCurrency

    var body: some View {
        let ledger = Ledger(txns: txns, wallets: wallets, jars: [])
        let counted = Asset.counted(assets, currency: currency)
        let parts = ledger.parts(assets: counted)
        let assetTotal = counted.map(\.value).reduce(0, +)
        // ponytail: months without a snapshot replay the transactions at today's asset values (same as Overview).
        // O(months × txns) per render; cache per month if the books get big.
        let points = NetWorthHistory.points(snapshots.filter { $0.currencyCode == currency }.map { ($0.month, $0.total) },
                                            current: parts.total, since: txns.map(\.date).min(), estimate: { end in
            Ledger(txns: txns.filter { $0.date < end }, wallets: wallets, jars: []).netWorth(assets: assetTotal)
        }, months: period.months)
        NavigationStack {
            Group {
                if assets.isEmpty && parts.owned == 0 && parts.debts == 0 {
                    ScrollView {
                        EmptyState(mood: .sleepy, title: String(localized: "No assets yet", table: "Watchlist"),
                                   message: String(localized: "Add gold, stocks, crypto or foreign currency with the price you know. Moonee adds them to your net worth.", table: "Watchlist")) {
                            Button(String(localized: "Add asset", table: "Watchlist")) { adding = true }
                                .buttonStyle(MooneeButtonStyle())
                        }
                        .card()
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .reveal()
                    }
                } else {
                    list(ledger: ledger, parts: parts, points: points)
                }
            }
            .background(MooneeBackground())
            .navigationTitle(String(localized: "Assets", table: "Watchlist"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(String(localized: "Add asset", table: "Watchlist"), systemImage: "plus") { adding = true }
                        // Spec §4.2 rule A.5: bought with budget money, it comes out of a jar; sold, it lands in Unallocated.
                        Button(loc("Buy an asset"), systemImage: "cart") { setAside = .buy }
                        Button(loc("Sell an asset"), systemImage: "arrow.uturn.backward") { setAside = .sell }
                        Button(loc("Deposit into savings"), systemImage: "lock") { setAside = .deposit }
                        Button(loc("Withdraw from savings"), systemImage: "lock.open") { setAside = .withdraw }
                    } label: {
                        Label(String(localized: "Add asset", table: "Watchlist"), systemImage: "plus")
                    }
                }
            }
            .sheet(item: $setAside) { SetAsideSheet(mode: $0) }
            .sheet(isPresented: $adding) { AssetForm(asset: nil) }
            .sheet(item: $editing) { AssetForm(asset: $0) }
            .task(id: parts.total) { NetWorthSnapshot.record(parts.total, currency: currency, in: context) }
        }
    }

    private func list(ledger: Ledger<PersistentIdentifier>, parts: NetWorthParts, points: [NetWorthHistory.Point]) -> some View {
        let balances = wallets.map { ($0, ledger.walletBalance($0.persistentModelID)) }
        let remaining = debts.map { ($0, ledger.debtRemaining[$0.persistentModelID] ?? 0) }
        let lent = remaining.filter { $0.0.direction == .lent && $0.1 > 0 }
        let borrowed = remaining.filter { $0.0.direction == .borrowed && $0.1 > 0 }
        let inDebt = balances.filter { $0.1 < 0 }
        return List {
            Section {
                NetWorthHeader(total: parts.total, currency: currency, points: points, period: $period)
            }
            if parts.owned > 0 {
                Section(String(localized: "Composition", table: "Watchlist")) {
                    CompositionRow(parts: parts, currency: currency)
                }
            }

            if assets.isEmpty {
                Section {
                    Button { adding = true } label: {
                        Label(String(localized: "Add your first asset", table: "Watchlist"), systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Gold, stocks, crypto or foreign currency, at the price you know.", tableName: "Watchlist")
                }
            }
            ForEach(AssetKind.allCases, id: \.self) { kind in
                let group = assets.filter { $0.kind == kind }.sorted { $0.value > $1.value }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { a in
                            Button { editing = a } label: { AssetRow(asset: a, counted: a.currencyCode == currency) }
                                .swipeActions {
                                    Button(String(localized: "Delete", table: "Watchlist"), systemImage: "trash", role: .destructive) {
                                        context.delete(a)
                                    }
                                }
                        }
                    } header: {
                        SectionTotal(title: kind.title, symbol: kind.symbol, amount: parts.assets[kind] ?? 0, currency: currency)
                    }
                }
            }

            if parts.cash > 0 {
                Section {
                    ForEach(balances.filter { $0.1 > 0 }, id: \.0.id) { w, balance in
                        ReadOnlyRow(title: w.name, symbol: w.type.symbol, amount: balance, currency: currency)
                    }
                } header: {
                    SectionTotal(title: String(localized: "Cash", table: "Watchlist"), symbol: "banknote", amount: parts.cash, currency: currency)
                } footer: {
                    Text("Wallets are managed in Budget.", tableName: "Watchlist")
                }
            }
            if !lent.isEmpty {
                Section {
                    ForEach(lent, id: \.0.id) { d, amount in
                        ReadOnlyRow(title: d.person, symbol: "person", amount: amount, currency: currency)
                    }
                } header: {
                    SectionTotal(title: String(localized: "Money lent", table: "Watchlist"), symbol: "arrow.up.forward.circle", amount: parts.lent, currency: currency)
                }
            }
            if parts.debts > 0 {
                Section {
                    ForEach(inDebt, id: \.0.id) { w, balance in
                        ReadOnlyRow(title: w.name, symbol: w.type.symbol, amount: balance, currency: currency)
                    }
                    ForEach(borrowed, id: \.0.id) { d, amount in
                        ReadOnlyRow(title: d.person, symbol: "person", amount: -amount, currency: currency)
                    }
                } header: {
                    SectionTotal(title: String(localized: "Debts", table: "Watchlist"), symbol: "creditcard", amount: -parts.debts, currency: currency)
                } footer: {
                    Text("Card debt and loans come from your wallets and the debt book.", tableName: "Watchlist")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Net worth and chart

enum ChartPeriod: CaseIterable, Hashable {
    case sixMonths, year, all

    var months: Int {
        switch self {
        case .sixMonths: 6
        case .year: 12
        case .all: 120 // ponytail: 10 years back is "all" until someone has more history than that
        }
    }

    var title: String {
        switch self {
        case .sixMonths: String(localized: "6M", table: "Watchlist")
        case .year: String(localized: "1Y", table: "Watchlist")
        case .all: String(localized: "All", table: "Watchlist")
        }
    }
}

private struct NetWorthHeader: View {
    let total: Int
    let currency: String
    let points: [NetWorthHistory.Point]
    @Binding var period: ChartPeriod
    @State private var selectedDate: Date?
    @State private var grow = 0.0
    @Environment(\.balanceHidden) private var hidden
    @Environment(\.locale) private var locale

    var body: some View {
        let selected = selectedDate.flatMap { NetWorthHistory.nearest(points, to: $0) }
        let shown = selected?.total ?? total
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let selected {
                    Text(selected.month.formatted(.dateTime.month(.wide).year()))
                } else {
                    Text("Net worth", tableName: "Watchlist")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Group {
                if selected == nil { RollingAmount(total, currency: currency) }
                else { AmountText(shown, currency: currency).contentTransition(.numericText(value: Double(shown))) }
            }
                .font(.largeTitle.bold())
                .fontDesign(.rounded)
                .animation(.smooth, value: shown)
                .foregroundStyle(shown < 0 ? Color.danger : Color.ink)
            if selected == nil, let change = NetWorthHistory.change(points), let first = points.first {
                ChangeLine(amount: change.amount, percent: change.percent, since: first.month, currency: currency)
            }
            if points.count > 1 {
                CapsuleSwitcher(options: ChartPeriod.allCases.map { ($0, $0.title) }, selection: $period)
                    .accessibilityLabel(Text("Period", tableName: "Watchlist"))
                    .padding(.top, 8)
                chart(selected: selected)
            }
        }
        .padding(.vertical, 6)
    }

    private func chart(selected: NetWorthHistory.Point?) -> some View {
        let totals = points.map(\.total)
        let (lo, hi) = (totals.min()!, totals.max()!)
        let base = Double(lo - max((hi - lo) / 5, 1)) // fit the area to the line instead of pulling the axis down to 0
        return Chart {
            ForEach(points) { p in line(p, base: base) }
            if let last = points.last, selected == nil {
                PointMark(x: .value("Month", last.month, unit: .month), y: .value("Net worth", risen(last.total, base)))
                    .foregroundStyle(Color.brandAction)
                    .symbolSize(70)
            }
            if let selected { selection(selected) }
        }
        .chartXSelection(value: $selectedDate)
        .sensoryFeedback(.selection, trigger: selected?.month)
        .growIn($grow)
        .chartYScale(domain: base...max(Double(hi), base + 1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    // The axis would give the amounts away when balances are hidden.
                    if !hidden, let v = value.as(Double.self) { Text(AmountFormat.string(Int(v), currency, short: true, locale: locale)) }
                }
            }
        }
        .frame(height: 180)
        .accessibilityLabel(Text("Net worth by month", tableName: "Watchlist"))
    }

    /// The line rises from the floor on appear (grow 0 → 1).
    private func risen(_ total: Int, _ base: Double) -> Double { base + (Double(total) - base) * grow }

    @ChartContentBuilder
    private func line(_ p: NetWorthHistory.Point, base: Double) -> some ChartContent {
        let fill = LinearGradient(colors: [.brandPrimary.opacity(0.32), .brandPrimary.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        let stroke = LinearGradient(colors: [.brandPrimaryLight, .brandAction], startPoint: .leading, endPoint: .trailing)
        AreaMark(x: .value("Month", p.month, unit: .month), yStart: .value("Base", base), yEnd: .value("Net worth", risen(p.total, base)))
            .foregroundStyle(fill)
            .interpolationMethod(.monotone)
        LineMark(x: .value("Month", p.month, unit: .month), y: .value("Net worth", risen(p.total, base)))
            .foregroundStyle(stroke)
            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            .interpolationMethod(.monotone)
    }

    @ChartContentBuilder
    private func selection(_ p: NetWorthHistory.Point) -> some ChartContent {
        RuleMark(x: .value("Month", p.month, unit: .month))
            .foregroundStyle(Color.brandPrimary.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        PointMark(x: .value("Month", p.month, unit: .month), y: .value("Net worth", Double(p.total)))
            .foregroundStyle(Color.brandAction)
            .symbolSize(90)
            .annotation(position: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                ChartCallout(title: p.month.formatted(.dateTime.month(.wide).year()),
                             rows: [.init(color: .brandPrimary, amount: p.total)], currency: currency)
            }
    }
}

private struct ChangeLine: View {
    let amount: Int
    let percent: Double?
    let since: Date
    let currency: String

    var body: some View {
        let up = amount >= 0
        HStack(spacing: 4) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
            if let percent {
                Text(percent.formatted(.percent.precision(.fractionLength(0...1)).sign(strategy: .always())))
            }
            HStack(spacing: 0) {
                Text(verbatim: "(")
                AmountText(amount, currency: currency, plus: true)
                Text(verbatim: ")")
            }
            Text("since \(since.formatted(.dateTime.month(.abbreviated).year()))", tableName: "Watchlist")
                .foregroundStyle(Color.inkSecondary)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(up ? Color.income : Color.danger)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - Composition

private struct CompositionRow: View {
    let parts: NetWorthParts
    let currency: String

    private var slices: [(label: String, value: Double, color: Color)] {
        ([(String(localized: "Cash", table: "Watchlist"), parts.cash, Color.brandPrimary)]
         + AssetKind.allCases.map { ($0.title, parts.assets[$0] ?? 0, $0.color) }
         + [(String(localized: "Money lent", table: "Watchlist"), parts.lent, JarPalette.color(7))])
            .filter { $0.1 > 0 }
            .map { ($0.0, Double($0.1), $0.2) }
    }

    var body: some View {
        let total = slices.map(\.value).reduce(0, +)
        AdaptiveStack(spacing: 16) {
            DonutChart(slices: slices.map { .init(label: $0.label, value: $0.value, color: $0.color) }) {
                VStack(spacing: 0) {
                    Text("Owned", tableName: "Watchlist").font(.caption2).foregroundStyle(.secondary)
                    AmountText(parts.owned, currency: currency, short: true).font(.subheadline.bold())
                }
            }
            .frame(width: 120)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(slices, id: \.label) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(s.color.gradient).frame(width: 10, height: 10)
                            Text(s.label).lineLimit(1)
                            Spacer(minLength: 4)
                            Text((s.value / total).formatted(.percent.precision(.fractionLength(0...1))))
                                .monospacedDigit().fontWeight(.semibold).foregroundStyle(Color.ink)
                        }
                        .font(.subheadline)
                        AmountText(Int(s.value), currency: currency, short: true)
                            .font(.caption).foregroundStyle(Color.inkSecondary).padding(.leading, 18)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Rows

private struct SectionTotal: View {
    let title: String
    let symbol: String
    let amount: Int
    let currency: String

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            AmountText(amount, currency: currency)
        }
    }
}

/// Wallets and debts: shown for the full picture, edited where they live (Budget, chat).
private struct ReadOnlyRow: View {
    let title: String
    let symbol: String
    let amount: Int
    let currency: String

    var body: some View {
        HStack {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
            Spacer()
            AmountText(amount, currency: currency).foregroundStyle(amount < 0 ? Color.danger : Color.ink)
        }
    }
}

private struct AssetRow: View {
    let asset: Asset
    /// false = priced in another currency, left out of net worth.
    let counted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(asset.symbol)
                Spacer()
                AmountText(asset.value, currency: asset.currencyCode)
            }
            .foregroundStyle(Color.ink)
            HStack(spacing: 4) {
                Text(asset.quantity.formatted())
                Text(verbatim: "×")
                AmountText(asset.unitPrice, currency: asset.currencyCode)
                Text(verbatim: "·")
                Text("updated \(asset.updatedAt.formatted(.relative(presentation: .numeric)))", tableName: "Watchlist")
            }
            .font(.subheadline)
            .foregroundStyle(Color.inkSecondary) // explicit: inside a Button `.secondary` picks up the green tint
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if !counted {
                Label(String(localized: "Not in net worth: priced in \(asset.currencyCode)", table: "Watchlist"),
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
        }
        .contentShape(.rect)
    }
}

extension AssetKind {
    var title: String {
        switch self {
        case .gold: String(localized: "Gold", table: "Watchlist")
        case .silver: String(localized: "Silver", table: "Watchlist")
        case .stock: String(localized: "Stocks", table: "Watchlist")
        case .fx: String(localized: "Foreign currency", table: "Watchlist")
        case .crypto: String(localized: "Crypto", table: "Watchlist")
        case .other: String(localized: "Other", table: "Watchlist")
        }
    }

    var symbol: String {
        switch self {
        case .gold, .silver: "square.stack.3d.up"
        case .stock: "chart.line.uptrend.xyaxis"
        case .fx: "dollarsign.arrow.circlepath"
        case .crypto: "bitcoinsign.circle"
        case .other: "shippingbox"
        }
    }

    var color: Color {
        switch self {
        case .gold: JarPalette.color(0)
        case .silver: JarPalette.color(10)
        case .stock: JarPalette.color(1)
        case .fx: JarPalette.color(2)
        case .crypto: JarPalette.color(6)
        case .other: JarPalette.color(3)
        }
    }
}

// MARK: - Add / edit

private struct AssetForm: View {
    let asset: Asset?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var kind = AssetKind.gold
    @State private var quantity: Double?
    @State private var price: Decimal?
    @State private var currency = Money.defaultCurrency
    @State private var updated = Date.now

    private var unitPrice: Int { Money(major: price ?? 0, currency).minor }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (quantity ?? -1) >= 0 && (price ?? -1) >= 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name, e.g. SJC gold, FPT, USD, BTC", table: "Watchlist"), text: $name)
                        .focused($nameFocused)
                    Picker(String(localized: "Type", table: "Watchlist"), selection: $kind) {
                        ForEach(AssetKind.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                }
                Section {
                    LabeledContent(String(localized: "Quantity", table: "Watchlist")) {
                        TextField(String(0), value: $quantity, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent(String(localized: "Price per unit", table: "Watchlist")) {
                        TextField(String(0), value: $price, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .onChange(of: price) { old, _ in if old != nil { updated = .now } } // a new price is today's price
                    }
                    Picker(String(localized: "Currency", table: "Watchlist"), selection: $currency) {
                        ForEach(currencies, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    DatePicker(String(localized: "Price date", table: "Watchlist"), selection: $updated, in: ...Date.now, displayedComponents: .date)
                    LabeledContent(String(localized: "Value", table: "Watchlist")) {
                        AmountText(Int(((quantity ?? 0) * Double(unitPrice)).rounded()), currency: currency).bold()
                    }
                } footer: {
                    Text("No live prices yet: type the price you know, e.g. 2 taels of gold at today's price per tael.", tableName: "Watchlist")
                }
            }
            .navigationTitle(asset == nil ? String(localized: "Add asset", table: "Watchlist") : String(localized: "Edit asset", table: "Watchlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", table: "Watchlist"), role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Save", table: "Watchlist"), action: save).disabled(!valid) }
            }
            .onAppear(perform: load)
        }
    }

    private var currencies: [String] {
        let rest = Locale.commonISOCurrencyCodes.filter { $0 != Money.defaultCurrency && $0 != currency }
        return Array(Set([Money.defaultCurrency, currency])).sorted() + rest
    }

    private func load() {
        guard let a = asset else { nameFocused = true; return }
        name = a.symbol
        kind = a.kind
        quantity = a.quantity
        currency = a.currencyCode
        price = Money(a.unitPrice, a.currencyCode).major
        updated = a.updatedAt
    }

    private func save() {
        let a = asset ?? Asset(symbol: "", kind: kind, quantity: 0, unitPrice: 0, currencyCode: currency)
        if asset == nil { context.insert(a) }
        a.symbol = name.trimmingCharacters(in: .whitespaces)
        a.kind = kind
        a.quantity = quantity ?? 0
        a.currencyCode = currency
        a.unitPrice = unitPrice
        a.updatedAt = updated
        dismiss()
    }
}
