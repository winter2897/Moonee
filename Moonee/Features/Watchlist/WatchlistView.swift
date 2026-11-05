import Charts
import SwiftData
import SwiftUI

/// Watchlist tab, MVP (spec §5, ROADMAP): net worth, its composition and manually priced assets.
/// No live prices, watchlist feed or price alerts: those need a data source (version 2).
struct WatchlistView: View {
    @Environment(\.modelContext) private var context
    @Query private var txns: [Txn]
    @Query private var wallets: [Wallet]
    @Query(sort: \Asset.updatedAt, order: .reverse) private var assets: [Asset]
    @Query(sort: \NetWorthSnapshot.month) private var snapshots: [NetWorthSnapshot]
    @State private var editing: Asset?
    @State private var adding = false
    @State private var updating = false

    private let currency = Money.defaultCurrency

    var body: some View {
        let counted = Asset.counted(assets, currency: currency)
        let breakdown = Ledger(txns: txns, wallets: wallets, jars: []).breakdown(assets: counted)
        // ponytail: months without a snapshot replay the transactions at today's asset values (same as Overview).
        // O(months × txns) per render; cache per month if the ledger gets big.
        let assetTotal = counted.map(\.value).reduce(0, +)
        let points = NetWorthHistory.points(snapshots.filter { $0.currencyCode == currency }.map { ($0.month, $0.total) },
                                            current: breakdown.total, since: txns.map(\.date).min()) { end in
            Ledger(txns: txns.filter { $0.date < end }, wallets: wallets, jars: []).netWorth(assets: assetTotal)
        }
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    MooneeHeader(Text("Assets · Investing · Watch", tableName: "Watchlist")) {
                        Button { adding = true } label: { HeaderCircle("plus") }
                            .accessibilityLabel(Text("Add asset", tableName: "Watchlist"))
                    }
                    MooneeHero(mood: .happy, compact: true)
                    NetWorthCard(total: breakdown.total, currency: currency, points: points, change: NetWorthHistory.change(points))
                    if breakdown.gross > 0 || breakdown.debts > 0 {
                        CompositionCard(breakdown: breakdown, currency: currency)
                    }
                    AssetsCard(assets: assets, currency: currency, onAdd: { adding = true }, onEdit: { editing = $0 })
                    if !assets.isEmpty {
                        Button { updating = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "square.3.layers.3d").font(.title3).foregroundStyle(Color.brandPrimary)
                                Text("Update assets", tableName: "Watchlist").font(.chip)
                            }
                            .frame(maxWidth: .infinity)
                            .card(padding: 14)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(MooneeBackground())
            .foregroundStyle(Color.ink)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $adding) { AssetForm(asset: nil) }
            .sheet(item: $editing) { AssetForm(asset: $0) }
            .sheet(isPresented: $updating) { UpdatePricesSheet(assets: assets) }
            .task(id: breakdown.total) { NetWorthSnapshot.record(breakdown.total, currency: currency, in: context) }
        }
    }
}

// MARK: - Net worth

private struct NetWorthCard: View {
    let total: Int
    let currency: String
    let points: [NetWorthHistory.Point]
    let change: (amount: Int, percent: Double?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Net worth", tableName: "Watchlist").font(.sectionTitle)
                    AmountText(total, currency: currency)
                        .heroAmountFont()
                        .foregroundStyle(total < 0 ? Color.danger : Color.ink)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if points.count > 1 { Sparkline(points: points).frame(width: 110, height: 56) }
            }
            if let change {
                let up = change.amount >= 0
                HStack(spacing: 4) {
                    Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.caption2)
                    if let p = change.percent {
                        Text(p.formatted(.percent.precision(.fractionLength(0...1)).sign(strategy: .always())))
                    }
                    HStack(spacing: 0) {
                        Text(verbatim: "(")
                        AmountText(change.amount, currency: currency, plus: true)
                        Text(verbatim: ")")
                    }
                    Text("vs last month", tableName: "Watchlist").fontWeight(.regular).foregroundStyle(Color.inkSecondary)
                }
                .font(.secondaryText.weight(.semibold))
                .foregroundStyle(up ? Color.income : Color.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Mockup sparkline: no axes, area fitted to the line's range, a dot on the latest month.
private struct Sparkline: View {
    let points: [NetWorthHistory.Point]

    var body: some View {
        let totals = points.map(\.total)
        let (lo, hi) = (totals.min()!, totals.max()!)
        let base = lo - max((hi - lo) / 5, 1) // keeps the area from pulling the axis down to 0
        Chart(points) { p in
            AreaMark(x: .value("Month", p.month, unit: .month), yStart: .value("Base", base), yEnd: .value("Net worth", p.total))
                .foregroundStyle(LinearGradient(colors: [.brandPrimary.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Month", p.month, unit: .month), y: .value("Net worth", p.total))
                .foregroundStyle(Color.brandPrimary)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            if p == points.last {
                PointMark(x: .value("Month", p.month, unit: .month), y: .value("Net worth", p.total))
                    .foregroundStyle(Color.brandPrimary).symbolSize(30)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: base...max(hi, base + 1))
        .accessibilityLabel(Text("Net worth by month", tableName: "Watchlist"))
    }
}

// MARK: - Composition

private struct CompositionCard: View {
    let breakdown: NetWorthBreakdown
    let currency: String

    private var rows: [(label: String, value: Int, color: Color)] {
        [
            (String(localized: "Cash & equivalents", table: "Watchlist"), breakdown.cash, Color.brandPrimary),
            (String(localized: "Investments", table: "Watchlist"), breakdown.investments, Color.brandYellow),
            (String(localized: "Other assets", table: "Watchlist"), breakdown.other, JarPalette.color(3)),
            (String(localized: "Debts (−)", table: "Watchlist"), -breakdown.debts, JarPalette.color(2)),
        ].filter { $0.1 != 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Composition", tableName: "Watchlist").font(.sectionTitle)
            HStack(spacing: 12) {
                DonutChart(slices: rows.map { .init(label: $0.label, value: Double(abs($0.value)), color: $0.color) }) {
                    DonutCenter(minor: breakdown.total, currency: currency)
                }
                .frame(width: 96)
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 8) {
                    ForEach(rows, id: \.label) { row in
                        if row.label != rows.first?.label { Divider() }
                        GridRow {
                            Circle().fill(row.color).frame(width: 8, height: 8)
                            Text(row.label).lineLimit(1).minimumScaleFactor(0.7)
                            AmountText(row.value, currency: currency).fixedSize().gridColumnAlignment(.trailing)
                            Text(breakdown.gross > 0 ? (Double(row.value) / Double(breakdown.gross)).formatted(.percent.precision(.fractionLength(0...1))) : "")
                                .monospacedDigit().foregroundStyle(Color.inkSecondary).fixedSize().gridColumnAlignment(.trailing)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// "245,6" over "million ₫", as in the mockup.
private struct DonutCenter: View {
    let minor: Int
    let currency: String
    @Environment(\.balanceHidden) private var hidden
    @Environment(\.locale) private var locale

    var body: some View {
        let major = NSDecimalNumber(decimal: AmountFormat.major(minor, currency)).doubleValue
        let symbol = { let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = currency; f.locale = locale; return f.currencySymbol ?? currency }()
        let (value, unit): (Double, String) = switch abs(major) {
        case 1e9...: (major / 1e9, String(localized: "billion \(symbol)", table: "Watchlist"))
        case 1e6...: (major / 1e6, String(localized: "million \(symbol)", table: "Watchlist"))
        case 1e3...: (major / 1e3, String(localized: "thousand \(symbol)", table: "Watchlist"))
        default: (major, symbol)
        }
        VStack(spacing: 0) {
            Text(hidden ? AmountFormat.mask : value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)))
                .font(.subheadline.weight(.bold)).monospacedDigit()
            if !hidden { Text(unit).font(.caption2) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement()
        .accessibilityLabel(hidden ? String(localized: "Balance hidden", table: "Components") : AmountFormat.spoken(minor, currency, locale: locale))
    }
}

// MARK: - Assets

private struct AssetsCard: View {
    let assets: [Asset]
    let currency: String
    let onAdd: () -> Void
    let onEdit: (Asset) -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your assets", tableName: "Watchlist").font(.sectionTitle)
                Spacer()
                if !assets.isEmpty {
                    Button(String(localized: "Add asset", table: "Watchlist"), systemImage: "plus.circle.fill", action: onAdd)
                        .labelStyle(.iconOnly).font(.title3).foregroundStyle(Color.brandPrimary)
                }
            }
            if assets.isEmpty {
                EmptyState(mood: .sleepy,
                           title: String(localized: "No assets yet", table: "Watchlist"),
                           message: String(localized: "Add gold, stocks, crypto or foreign currency with the price you know. Moonee adds them to your net worth.", table: "Watchlist")) {
                    Button(String(localized: "Add asset", table: "Watchlist"), action: onAdd)
                        .buttonStyle(MooneeButtonStyle()).padding(.top, 8)
                }
            } else {
                ForEach(assets) { a in
                    Button { onEdit(a) } label: { AssetRow(asset: a, counted: a.currencyCode == currency) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(String(localized: "Delete", table: "Watchlist"), systemImage: "trash", role: .destructive) { context.delete(a) }
                        }
                    if a != assets.last { Divider().padding(.leading, 50) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct AssetRow: View {
    let asset: Asset
    /// false = priced in another currency, left out of net worth.
    let counted: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: asset.kind.symbol, color: asset.kind.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.symbol).font(.rowTitle)
                HStack(spacing: 4) {
                    Text(asset.quantity.formatted())
                    Text(verbatim: "×")
                    AmountText(asset.unitPrice, currency: asset.currencyCode)
                }
                .font(.secondaryText).foregroundStyle(Color.inkSecondary)
                Group {
                    if counted {
                        Text("Price updated \(asset.updatedAt.formatted(.relative(presentation: .numeric)))", tableName: "Watchlist")
                    } else {
                        Text("Not in net worth: priced in \(asset.currencyCode)", tableName: "Watchlist")
                    }
                }
                .font(.caption).foregroundStyle(counted ? Color.inkSecondary : Color.warningText)
            }
            Spacer(minLength: 8)
            AmountText(asset.value, currency: asset.currencyCode).font(.rowTitle)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }
}

extension AssetKind {
    var title: String {
        switch self {
        case .gold: String(localized: "Gold", table: "Watchlist")
        case .silver: String(localized: "Silver", table: "Watchlist")
        case .stock: String(localized: "Stock", table: "Watchlist")
        case .fx: String(localized: "Foreign currency", table: "Watchlist")
        case .crypto: String(localized: "Crypto", table: "Watchlist")
        case .other: String(localized: "Other", table: "Watchlist")
        }
    }

    var symbol: String {
        switch self {
        case .gold, .silver: "square.stack.3d.up.fill"
        case .stock: "chart.line.uptrend.xyaxis"
        case .fx: "dollarsign.arrow.circlepath"
        case .crypto: "bitcoinsign.circle.fill"
        case .other: "shippingbox.fill"
        }
    }

    var color: Color {
        switch self {
        case .gold: JarPalette.color(0)
        case .silver: JarPalette.color(10)
        case .stock: JarPalette.color(1)
        case .fx: .brandDeep
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
    @State private var name = ""
    @State private var kind = AssetKind.gold
    @State private var quantity: Double?
    @State private var price: Decimal?
    @State private var currency = Money.defaultCurrency
    @State private var updated = Date.now
    @State private var confirmDelete = false

    private var unitPrice: Int { Money(major: price ?? 0, currency).minor }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (quantity ?? -1) >= 0 && (price ?? -1) >= 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Type", table: "Watchlist"), selection: $kind) {
                        ForEach(AssetKind.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    TextField(String(localized: "Name, e.g. SJC gold, FPT, USD, BTC", table: "Watchlist"), text: $name)
                }
                Section {
                    TextField(String(localized: "Quantity", table: "Watchlist"), value: $quantity, format: .number)
                        .keyboardType(.decimalPad)
                    TextField(String(localized: "Price per unit", table: "Watchlist"), value: $price, format: .number)
                        .keyboardType(.decimalPad)
                        .onChange(of: price) { old, _ in if old != nil { updated = .now } } // a new price is today's price
                    Picker(String(localized: "Currency", table: "Watchlist"), selection: $currency) {
                        ForEach(currencies, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    DatePicker(String(localized: "Price updated", table: "Watchlist"), selection: $updated, in: ...Date.now, displayedComponents: .date)
                } footer: {
                    Text("Moonee has no live prices yet: type the price you know, e.g. 2 taels of gold at today's price per tael.", tableName: "Watchlist")
                }
                Section {
                    LabeledContent(String(localized: "Value", table: "Watchlist")) {
                        AmountText(Int(((quantity ?? 0) * Double(unitPrice)).rounded()), currency: currency).font(.headline)
                    }
                }
                if let asset {
                    Section {
                        Button(String(localized: "Delete asset", table: "Watchlist"), role: .destructive) { confirmDelete = true }
                            .confirmationDialog(String(localized: "Delete \(asset.symbol)?", table: "Watchlist"),
                                                isPresented: $confirmDelete, titleVisibility: .visible) {
                                Button(String(localized: "Delete", table: "Watchlist"), role: .destructive) {
                                    context.delete(asset)
                                    dismiss()
                                }
                            }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MooneeBackground())
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
        guard let a = asset else { return }
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

// MARK: - Update prices

/// "Update assets" tile: one price field per asset. Only changed prices get today's date.
private struct UpdatePricesSheet: View {
    let assets: [Asset]
    @Environment(\.dismiss) private var dismiss
    @State private var prices: [PersistentIdentifier: Decimal] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(assets) { a in
                        LabeledContent {
                            TextField(String(localized: "Price per unit", table: "Watchlist"), value: Binding(
                                get: { prices[a.persistentModelID] }, set: { prices[a.persistentModelID] = $0 }), format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.symbol).font(.subheadline.weight(.semibold))
                                Text(verbatim: "\(a.currencyCode) · \(a.updatedAt.formatted(.relative(presentation: .numeric)))")
                                    .font(.caption).foregroundStyle(Color.inkSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Type today's price for each asset. Only changed prices get today's date.", tableName: "Watchlist")
                }
            }
            .scrollContentBackground(.hidden)
            .background(MooneeBackground())
            .navigationTitle(String(localized: "Update assets", table: "Watchlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", table: "Watchlist"), role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Save", table: "Watchlist"), action: save) }
            }
            .onAppear {
                prices = Dictionary(assets.map { ($0.persistentModelID, Money($0.unitPrice, $0.currencyCode).major) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    private func save() {
        for a in assets {
            guard let p = prices[a.persistentModelID], p >= 0 else { continue }
            let minor = Money(major: p, a.currencyCode).minor
            if minor != a.unitPrice {
                a.unitPrice = minor
                a.updatedAt = .now
            }
        }
        dismiss()
    }
}
