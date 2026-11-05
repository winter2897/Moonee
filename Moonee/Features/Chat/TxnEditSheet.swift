import SwiftData
import SwiftUI

/// Edits one saved transaction from its chat card. A category change teaches Moonee (spec §3.2).
struct TxnEditSheet: View {
    @Bindable var txn: Txn
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.order) private var categories: [Category]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @State private var major: Decimal = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Note", table: "Chat"), text: $txn.note)
                    LabeledContent {
                        TextField(value: $major, format: .number) { Text("Amount", tableName: "Chat") }
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    } label: {
                        Text("Amount (\(txn.currencyCode))", tableName: "Chat")
                    }
                    DatePicker(selection: $txn.date, displayedComponents: .date) { Text("Date", tableName: "Chat") }
                }
                if txn.kind == .expense || txn.kind == .income {
                    Section {
                        Picker(selection: category) {
                            Text("None", tableName: "Chat").tag(Category?.none)
                            ForEach(categories.filter { $0.kind == txn.kind }) { c in
                                Label(c.name, systemImage: c.icon).tag(Optional(c))
                            }
                        } label: { Text("Category", tableName: "Chat") }
                        if txn.kind == .expense {
                            LabeledContent { Text(txn.jar?.name ?? "—") } label: { Text("Jar", tableName: "Chat") }
                        }
                    } footer: {
                        Text("Moonee remembers your category for next time.", tableName: "Chat")
                    }
                }
                Section {
                    Picker(selection: $txn.wallet) {
                        ForEach(wallets) { w in Label(w.name, systemImage: w.type.symbol).tag(Optional(w)) }
                    } label: { Text("Wallet", tableName: "Chat") }
                }
            }
            .navigationTitle(Text("Edit transaction", tableName: "Chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Text("Done", tableName: "Chat") }
                }
            }
        }
        .onAppear { major = txn.money.major }
    }

    private var category: Binding<Category?> {
        Binding(get: { txn.category }, set: { ChatBook.setCategory($0, of: txn, in: context) })
    }

    private func save() {
        let minor = Money(major: major, txn.currencyCode).minor
        if minor > 0, minor != txn.amount {
            txn.amount = minor
            ChatBook.resplit(txn, in: context)
        }
        try? context.save()
        dismiss()
    }
}
