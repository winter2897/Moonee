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
                    Text(dayTitle(day)).font(.secondaryText.weight(.semibold)).foregroundStyle(Color.inkSecondary).textCase(nil)
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
