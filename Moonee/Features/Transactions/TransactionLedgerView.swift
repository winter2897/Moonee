import SwiftData
import SwiftUI

/// The transaction ledger (spec §2): one list, sections by day, search, a filter menu in the toolbar.
/// Tap a row (or swipe → Edit) to edit it in `TxnEditForm`; swipe → Delete removes it with its splits.
struct TransactionLedgerView: View {
    @Query(sort: \Txn.date, order: .reverse) private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query(sort: \Category.order) private var categories: [Category]
    @Environment(\.modelContext) private var context
    @State private var filter = TxnFilter()
    @State private var editing: Txn?

    var body: some View {
        let shown = txns.filter { filter.matches($0) }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        List {
            ForEach(days, id: \.key) { day, items in
                Section(TxnRow.dayTitle(day, withYear: true)) {
                    ForEach(items) { t in
                        Button { editing = t } label: { TxnRow(txn: t) }
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
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .overlay {
            if txns.isEmpty {
                ContentUnavailableView {
                    Label { Text("No transactions yet", tableName: "Transactions") } icon: { Image(systemName: "tray") }
                } description: {
                    Text("Tap + and tell Moonee “lunch 45k” to log your first one.", tableName: "Transactions")
                }
            } else if shown.isEmpty {
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
