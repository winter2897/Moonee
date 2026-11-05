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

    private let currency = Money.defaultCurrency

    var body: some View {
        let breakdown = Ledger(txns: txns, wallets: wallets, jars: []).breakdown(assets: Asset.counted(assets, currency: currency))
        let points = NetWorthHistory.points(snapshots.filter { $0.currencyCode == currency }.map { ($0.month, $0.total) },
                                            current: breakdown.total)
        NavigationStack {
            VStack(spacing: 14) {
                NetWorthCard(total: breakdown.total, currency: currency, points: points, change: NetWorthHistory.change(points))
                if breakdown.gross > 0 || breakdown.debts > 0 {
                    CompositionCard(breakdown: breakdown, currency: currency)
                }
                AssetsCard(assets: assets, currency: currency, onAdd: { adding = true }, onEdit: { editing = $0 })
            }
            .foregroundStyle(Color.ink)
            .mooneeScreen(String(localized: "Watchlist", table: "Watchlist"))
            .toolbar {
                Button(String(localized: "Add asset", table: "Watchlist"), systemImage: "plus") { adding = true }
            }
            .sheet(isPresented: $adding) { AssetForm(asset: nil) }
            .sheet(item: $editing) { AssetForm(asset: $0) }
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
            Text("Net worth", tableName: "Watchlist").font(.headline)
            AmountText(total, currency: currency)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(total < 0 ? Color.danger : Color.ink)
            if let change {
                let up = change.amount >= 0
                HStack(spacing: 4) {
                    Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.caption2)
                    if let p = change.percent {
                        Text(p.formatted(.percent.precision(.fractionLength(0...1)).sign(strategy: .always())))
                    }
                    AmountText(change.amount, currency: currency, plus: true)
                    Text("vs last month", tableName: "Watchlist").foregroundStyle(Color.inkSecondary)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(up ? Color.income : Color.danger)
            } else {
                Text("Wallets + assets + money lent − card debt − money borrowed", tableName: "Watchlist")
                    .font(.footnote).foregroundStyle(Color.inkSecondary)
            }
            if points.count > 1 {
                // Fit the line to its range (the area would otherwise pull the axis down to 0 and flatten it).
                let totals = points.map(\.total)
                let (lo, hi) = (totals.min()!, totals.max()!)
                let base = lo - max((hi - lo) / 5, 1)
                Chart(points) { p in
                    AreaMark(x: .value("Month", p.month, unit: .month), yStart: .value("Base", base), yEnd: .value("Net worth", p.total))
                        .foregroundStyle(LinearGradient(colors: [.brandPrimary.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Month", p.month, unit: .month), y: .value("Net worth", p.total))
                        .foregroundStyle(Color.brandPrimary)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .chartXScale(range: .plotDimension(padding: 24)) // room for the edge labels
                .chartYAxis(.hidden)
                .chartYScale(domain: base...max(hi, base + 1))
                .frame(height: 90)
                .padding(.top, 8)
                .accessibilityLabel(Text("Net worth by month", tableName: "Watchlist"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
            Text("Composition", tableName: "Watchlist").font(.headline)
            HStack(spacing: 16) {
                DonutChart(slices: rows.map { .init(label: $0.label, value: Double(abs($0.value)), color: $0.color) }) {
                    AmountText(breakdown.total, currency: currency, short: true).font(.headline)
                }
                .frame(width: 120)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(row.color).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.label).font(.subheadline)
                                HStack(spacing: 6) {
                                    AmountText(row.value, currency: currency)
                                    if breakdown.gross > 0 {
                                        Text((Double(row.value) / Double(breakdown.gross)).formatted(.percent.precision(.fractionLength(0...1))))
                                            .foregroundStyle(Color.inkSecondary)
                                    }
                                }
                                .font(.footnote.weight(.semibold))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
                Text("Your assets", tableName: "Watchlist").font(.headline)
                Spacer()
                if !assets.isEmpty {
                    Button(String(localized: "Add asset", table: "Watchlist"), systemImage: "plus.circle.fill", action: onAdd)
                        .labelStyle(.iconOnly).font(.title2).foregroundStyle(Color.brandPrimary)
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
                Text(asset.symbol).font(.body.weight(.semibold))
                HStack(spacing: 4) {
                    Text(asset.quantity.formatted())
                    Text(verbatim: "×")
                    AmountText(asset.unitPrice, currency: asset.currencyCode)
                }
                .font(.caption).foregroundStyle(Color.inkSecondary)
                Group {
                    if counted {
                        Text("Price updated \(asset.updatedAt.formatted(.relative(presentation: .numeric)))", tableName: "Watchlist")
                    } else {
                        Text("Not in net worth: priced in \(asset.currencyCode)", tableName: "Watchlist")
                    }
                }
                .font(.caption2).foregroundStyle(counted ? Color.inkSecondary : Color.warningText)
            }
            Spacer(minLength: 8)
            AmountText(asset.value, currency: asset.currencyCode).font(.body.weight(.semibold))
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
