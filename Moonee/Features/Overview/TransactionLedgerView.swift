import SwiftData
import SwiftUI

/// The transaction ledger (spec §2): search, filter by wallet / jar / category / date, edit, delete, grouped by day.
struct TransactionLedgerView: View {
    @Query(sort: \Txn.date, order: .reverse) private var txns: [Txn]
    @Environment(\.modelContext) private var context
    @State private var filter = TxnFilter()
    @State private var showFilters = false
    @State private var editing: Txn?

    var body: some View {
        let shown = txns.filter { filter.matches($0) }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        List {
            ForEach(days, id: \.key) { day, items in
                Section {
                    ForEach(items) { t in
                        Button { editing = t } label: { TxnRow(txn: t) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { delete(t) } label: {
                                    Label { Text("Delete", tableName: "Overview") } icon: { Image(systemName: "trash") }
                                }
                            }
                    }
                } header: {
                    Text(dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkSecondary).textCase(nil)
                }
                .listRowBackground(Color.surface.opacity(0.85))
            }
        }
        .scrollContentBackground(.hidden)
        .background(MooneeBackground())
        .overlay {
            if txns.isEmpty {
                EmptyState(mood: .sleepy, title: String(localized: "No transactions yet", table: "Overview"),
                           message: String(localized: "Tap + and tell Moonee “lunch 45k” to log your first one.", table: "Overview"))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: filter.text)
            }
        }
        .navigationTitle(String(localized: "Transactions", table: "Overview"))
        .searchable(text: $filter.text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search notes, categories, wallets", tableName: "Overview"))
        .toolbar {
            Button { showFilters = true } label: {
                Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel(Text("Filters", tableName: "Overview"))
        }
        .sheet(isPresented: $showFilters) { LedgerFilterSheet(filter: $filter).presentationDetents([.medium, .large]) }
        .sheet(item: $editing) { TxnEditForm(txn: $0) }
    }

    private func dayTitle(_ day: Date) -> String {
        Calendar.current.isDateInToday(day) ? String(localized: "Today", table: "Overview")
            : Calendar.current.isDateInYesterday(day) ? String(localized: "Yesterday", table: "Overview")
            : day.formatted(.dateTime.weekday(.wide).day().month().year())
    }

    private func delete(_ t: Txn) {
        context.delete(t) // IncomeSplits cascade (Txn.splits deleteRule)
        try? context.save()
    }
}

private struct LedgerFilterSheet: View {
    @Binding var filter: TxnFilter
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query(sort: \Category.order) private var categories: [Category]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker(selection: $filter.wallet) {
                    Text("All", tableName: "Overview").tag(Wallet?.none)
                    ForEach(wallets) { Text($0.name).tag(Optional($0)) }
                } label: { Text("Wallet", tableName: "Overview") }
                Picker(selection: $filter.jar) {
                    Text("All", tableName: "Overview").tag(Jar?.none)
                    ForEach(jars) { Text($0.name).tag(Optional($0)) }
                } label: { Text("Jar", tableName: "Overview") }
                Picker(selection: $filter.category) {
                    Text("All", tableName: "Overview").tag(Category?.none)
                    ForEach(categories) { Label($0.name, systemImage: $0.icon).tag(Optional($0)) }
                } label: { Text("Category", tableName: "Overview") }
                Section {
                    Toggle(isOn: Binding(get: { filter.from != nil }, set: {
                        filter.from = $0 ? Calendar.current.dateInterval(of: .month, for: .now)?.start : nil
                        filter.to = $0 ? .now : nil
                    })) { Text("Date range", tableName: "Overview") }
                    if let from = filter.from, let to = filter.to {
                        DatePicker(selection: Binding(get: { from }, set: { filter.from = $0 }), in: ...to, displayedComponents: .date) {
                            Text("From", tableName: "Overview")
                        }
                        DatePicker(selection: Binding(get: { to }, set: { filter.to = $0 }), in: from..., displayedComponents: .date) {
                            Text("To", tableName: "Overview")
                        }
                    }
                }
                if filter.isActive {
                    Button(role: .destructive) {
                        filter = TxnFilter(text: filter.text)
                    } label: { Text("Clear filters", tableName: "Overview") }
                }
            }
            .navigationTitle(String(localized: "Filters", table: "Overview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", tableName: "Overview") }
                }
            }
        }
    }
}

/// Edit or delete one transaction. The kind stays fixed; changing an expense's category re-pins its jar,
/// changing an income's amount rescales its stored jar splits (same proportions, history otherwise untouched).
struct TxnEditForm: View {
    let txn: Txn
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Category.order) private var categories: [Category]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Decimal = 0
    @State private var date = Date.now
    @State private var note = ""
    @State private var category: Category?
    @State private var wallet: Wallet?
    @State private var toWallet: Wallet?
    @State private var confirmDelete = false

    private var hasCategory: Bool { txn.kind == .expense || txn.kind == .income }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent { Text(txn.kind.title) } label: { Text("Type", tableName: "Overview") }
                    LabeledContent {
                        TextField(value: $amount, format: .number) { Text(verbatim: "0") }
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    } label: { Text("Amount (\(txn.currencyCode))", tableName: "Overview") }
                    DatePicker(selection: $date) { Text("Date", tableName: "Overview") }
                    TextField(text: $note) { Text("Note", tableName: "Overview") }
                }
                Section {
                    if hasCategory {
                        Picker(selection: $category) {
                            Text("None", tableName: "Overview").tag(Category?.none)
                            ForEach(categories.filter { $0.kind == txn.kind }) { Label($0.name, systemImage: $0.icon).tag(Optional($0)) }
                        } label: { Text("Category", tableName: "Overview") }
                    }
                    if txn.kind != .jarTransfer {
                        Picker(selection: $wallet) {
                            Text("None", tableName: "Overview").tag(Wallet?.none)
                            ForEach(wallets) { Text($0.name).tag(Optional($0)) }
                        } label: { txn.kind == .transfer ? Text("From wallet", tableName: "Overview") : Text("Wallet", tableName: "Overview") }
                    }
                    if txn.kind == .transfer {
                        Picker(selection: $toWallet) {
                            Text("None", tableName: "Overview").tag(Wallet?.none)
                            ForEach(wallets) { Text($0.name).tag(Optional($0)) }
                        } label: { Text("To wallet", tableName: "Overview") }
                    }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete transaction", tableName: "Overview") }
                }
            }
            .navigationTitle(String(localized: "Edit transaction", table: "Overview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("Cancel", tableName: "Overview") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Text("Save", tableName: "Overview") }.disabled(amount <= 0)
                }
            }
            .confirmationDialog(Text("Delete this transaction?", tableName: "Overview"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(role: .destructive) {
                    context.delete(txn)
                    try? context.save()
                    dismiss()
                } label: { Text("Delete", tableName: "Overview") }
            }
            .onAppear {
                amount = txn.money.major
                date = txn.date
                note = txn.note
                category = txn.category
                wallet = txn.wallet
                toWallet = txn.toWallet
            }
        }
    }

    private func save() {
        let minor = Money(major: amount, txn.currencyCode).minor
        if txn.kind == .income, minor != txn.amount {
            let splits = txn.splits ?? []
            for (s, share) in zip(splits, rescaleSplits(splits.map(\.amount), to: minor)) { s.amount = share }
        }
        if txn.kind == .expense, category != txn.category { txn.jar = category?.jar }
        txn.amount = minor
        txn.date = date
        txn.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasCategory { txn.category = category }
        if txn.kind != .jarTransfer { txn.wallet = wallet }
        if txn.kind == .transfer { txn.toWallet = toWallet }
        try? context.save()
        dismiss()
    }
}
