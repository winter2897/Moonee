import SwiftData
import SwiftUI

/// Edit or delete one transaction: the one editor for the chat card and the ledger. The kind stays fixed.
/// Saving goes through `TxnEdit.apply`: an expense's new category re-pins its jar and teaches Moonee (merchant rule),
/// an income's new amount rescales its stored jar splits (same proportions, history otherwise untouched).
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
    /// A transfer must land in another wallet, or the money goes nowhere.
    private var canSave: Bool { amount > 0 && (txn.kind != .transfer || (toWallet != nil && toWallet != wallet)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent { Text(txn.kind.title) } label: { Text("Type", tableName: "Transactions") }
                    LabeledContent {
                        TextField(value: $amount, format: .number) { Text(verbatim: "0") }
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    } label: { Text("Amount (\(txn.currencyCode))", tableName: "Transactions") }
                    DatePicker(selection: $date) { Text("Date", tableName: "Transactions") }
                    TextField(text: $note) { Text("Note", tableName: "Transactions") }
                }
                Section {
                    if hasCategory {
                        Picker(selection: $category) {
                            Text("None", tableName: "Transactions").tag(Category?.none)
                            ForEach(categories.filter { $0.kind == txn.kind }) { Label($0.name, systemImage: $0.icon).tag(Optional($0)) }
                        } label: { Text("Category", tableName: "Transactions") }
                    }
                    if txn.kind == .expense {
                        LabeledContent { Text((category == txn.category ? txn.jar : category?.jar)?.name ?? "—") } label: {
                            Text("Jar", tableName: "Transactions")
                        }
                    }
                    if txn.kind != .jarTransfer {
                        Picker(selection: $wallet) {
                            Text("None", tableName: "Transactions").tag(Wallet?.none)
                            ForEach(wallets) { Text($0.name).tag(Optional($0)) }
                        } label: { txn.kind == .transfer ? Text("From wallet", tableName: "Transactions") : Text("Wallet", tableName: "Transactions") }
                    }
                    if txn.kind == .transfer {
                        Picker(selection: $toWallet) {
                            Text("None", tableName: "Transactions").tag(Wallet?.none)
                            ForEach(wallets) { Text($0.name).tag(Optional($0)) }
                        } label: { Text("To wallet", tableName: "Transactions") }
                    }
                } footer: {
                    if hasCategory { Text("Moonee remembers your category for next time.", tableName: "Transactions") }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete transaction", tableName: "Transactions") }
                }
            }
            .navigationTitle(String(localized: "Edit transaction", table: "Transactions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("Cancel", tableName: "Transactions") } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Text("Save", tableName: "Transactions") }.disabled(!canSave)
                }
            }
            .confirmationDialog(Text("Delete this transaction?", tableName: "Transactions"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(role: .destructive) {
                    context.delete(txn) // IncomeSplits cascade (Txn.splits deleteRule)
                    try? context.save()
                    dismiss()
                } label: { Text("Delete", tableName: "Transactions") }
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
        TxnEdit.apply(to: txn, amount: Money(major: amount, txn.currencyCode).minor, date: date, note: note,
                      category: category, wallet: wallet, toWallet: toWallet, in: context)
        try? context.save()
        dismiss()
    }
}

/// The writes behind `TxnEditForm`, kept apart so they are testable.
@MainActor enum TxnEdit {
    static func apply(to txn: Txn, amount: Int, date: Date, note: String, category: Category?, wallet: Wallet?, toWallet: Wallet?,
                      in context: ModelContext) {
        if txn.kind == .income, amount != txn.amount {
            let splits = txn.splits ?? []
            for (s, share) in zip(splits, rescaleSplits(splits.map(\.amount), to: amount)) { s.amount = share }
        }
        txn.amount = amount
        txn.date = date
        txn.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if txn.kind == .expense || txn.kind == .income { setCategory(category, of: txn, in: context) } // after the note: the rule learns it
        if txn.kind != .jarTransfer { txn.wallet = wallet }
        if txn.kind == .transfer { txn.toWallet = toWallet }
    }

    /// A category correction: re-pin this expense's jar and remember note → category for the next parse (spec §3.2).
    // ponytail: the pattern is the whole note ("highlands"); a note with extra words only matches itself.
    static func setCategory(_ category: Category?, of txn: Txn, in context: ModelContext) {
        guard txn.category != category else { return }
        txn.category = category
        if txn.kind == .expense { txn.jar = category?.jar }
        let pattern = txn.note.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let category, !pattern.isEmpty else { return }
        let rules = (try? context.fetch(FetchDescriptor<MerchantRule>(predicate: #Predicate { $0.pattern == pattern }))) ?? []
        if let rule = rules.first {
            rule.category = category
            rule.updatedAt = .now
        } else {
            context.insert(MerchantRule(pattern: pattern, category: category))
        }
    }
}
