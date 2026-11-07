import SwiftData
import SwiftUI

/// Edit or delete one transaction: the one editor for the chat card and the ledger. The kind stays fixed.
/// Saving goes through `TxnEdit.apply`: an expense's new category re-pins its jar and teaches Moonee (merchant rule),
/// an income's new amount rescales its stored jar splits (same proportions, history otherwise untouched), and an income's
/// "Split into jars" section sets what each jar gets (what no jar gets waits in Unallocated, spec §4.1).
struct TxnEditForm: View {
    let txn: Txn
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Category.order) private var categories: [Category]
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Decimal = 0
    @State private var date = Date.now
    @State private var note = ""
    @State private var category: Category?
    @State private var wallet: Wallet?
    @State private var toWallet: Wallet?
    @State private var confirmDelete = false
    /// income: major units per jar; `splitEdited` once the user touched it (else a new amount rescales the old split).
    @State private var split: [PersistentIdentifier: Decimal] = [:]
    @State private var splitEdited = false
    /// "Don't count in reports" (P1-2).
    @State private var excluded = false

    private var hasCategory: Bool { txn.kind == .expense || txn.kind == .income }
    /// A transfer must land in another wallet, or the money goes nowhere.
    private var canSave: Bool {
        amount > 0 && (txn.kind != .transfer || (toWallet != nil && toWallet != wallet)) && (!splitEdited || unallocated >= 0)
    }
    private var amountMinor: Int { Money(major: amount, txn.currencyCode).minor }
    private var splitMinor: [Jar: Int] {
        Dictionary(jars.compactMap { j in split[j.persistentModelID].map { (j, Money(major: $0, txn.currencyCode).minor) } }, uniquingKeysWith: +)
    }
    /// What no jar gets: it waits in Unallocated.
    private var unallocated: Int { amountMinor - splitMinor.values.reduce(0, +) }

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
                            // Every spend belongs to a jar through its category (P0-2): an expense can't drop it.
                            if txn.kind != .expense || txn.category == nil { Text("None", tableName: "Transactions").tag(Category?.none) }
                            ForEach(categories.filter { $0.kind == txn.kind || $0 == txn.category }) { Label($0.name, systemImage: $0.icon).tag(Optional($0)) }
                        } label: { Text("Category", tableName: "Transactions") }
                    }
                    if txn.kind == .expense && !excluded {
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
                if txn.kind == .income && !excluded { splitSection }
                if hasCategory {
                    Section {
                        Toggle(isOn: $excluded) { Text("Don't count in reports", tableName: "Transactions") }
                    } header: {
                        Text("Advanced", tableName: "Transactions")
                    } footer: {
                        Text("It still changes the wallet's balance, but never counts in income, spending, jars or reports. For money someone pays you back.", tableName: "Transactions")
                    }
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
                excluded = txn.excludedFromReport
                for s in txn.splits ?? [] {
                    if let j = s.jar { split[j.persistentModelID, default: 0] += Money(s.amount, txn.currencyCode).major }
                }
            }
        }
    }

    private var splitSection: some View {
        Section {
            ForEach(jars) { j in
                LabeledContent {
                    TextField(value: Binding(get: { split[j.persistentModelID] ?? 0 },
                                             set: { split[j.persistentModelID] = $0; splitEdited = true }), format: .number) { Text(verbatim: "0") }
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                } label: { Label { Text(j.name) } icon: { Image(systemName: j.icon).foregroundStyle(j.color) } }
            }
            LabeledContent {
                Text(Money(unallocated, txn.currencyCode).formatted()).foregroundStyle(unallocated < 0 ? Color.expense : Color.inkSecondary)
            } label: { Text("Unallocated", tableName: "Transactions") }
            Button { fill(Ledger<Jar>.split(amountMinor, by: jars.map { ($0, $0.percent) })) } label: { Text("By percent", tableName: "Transactions") }
            Button { fill([:]) } label: { Text("Leave it all in Unallocated", tableName: "Transactions") }
        } header: {
            Text("Split into jars", tableName: "Transactions")
        } footer: {
            unallocated < 0 ? Text("The jars get more than this income.", tableName: "Transactions")
                            : Text("What no jar gets waits in Unallocated.", tableName: "Transactions")
        }
    }

    private func fill(_ shares: [Jar: Int]) {
        split = Dictionary(shares.map { ($0.key.persistentModelID, Money($0.value, txn.currencyCode).major) }, uniquingKeysWith: +)
        splitEdited = true
    }

    private func save() {
        TxnEdit.apply(to: txn, amount: amountMinor, date: date, note: note, category: category, wallet: wallet, toWallet: toWallet,
                      splits: txn.kind == .income && splitEdited && !excluded ? splitMinor : nil,
                      excluded: hasCategory ? excluded : nil, in: context)
        try? context.save()
        dismiss()
    }
}

/// The writes behind `TxnEditForm`, kept apart so they are testable.
@MainActor enum TxnEdit {
    /// `splits`: an income's new split per jar (what no jar gets waits in Unallocated); nil keeps it, rescaled to a new amount.
    /// `excluded`: "Don't count in reports" (nil keeps it). An excluded expense has no jar; counted again, it goes back to its
    /// category's jar. An excluded income keeps its split on record, but `Ledger` ignores it while excluded.
    static func apply(to txn: Txn, amount: Int, date: Date, note: String, category: Category?, wallet: Wallet?, toWallet: Wallet?,
                      splits newSplits: [Jar: Int]? = nil, excluded: Bool? = nil, in context: ModelContext) {
        if txn.kind == .income, let newSplits {
            (txn.splits ?? []).forEach(context.delete)
            txn.splits = []
            for (jar, share) in newSplits where share > 0 {
                let s = IncomeSplit(amount: share, jar: jar)
                context.insert(s)
                s.txn = txn
            }
        } else if txn.kind == .income, amount != txn.amount {
            let splits = txn.splits ?? []
            for (s, share) in zip(splits, rescaleSplits(splits.map(\.amount), to: amount)) { s.amount = share }
        }
        txn.amount = amount
        txn.date = date
        txn.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if txn.kind == .expense || txn.kind == .income { setCategory(category, of: txn, in: context) } // after the note: the rule learns it
        if txn.kind != .jarTransfer { txn.wallet = wallet }
        if txn.kind == .transfer { txn.toWallet = toWallet }
        if let excluded, txn.kind == .expense || txn.kind == .income {
            if !excluded, txn.excludedFromReport, txn.kind == .expense { txn.jar = txn.category?.jar }
            txn.excludedFromReport = excluded
        }
        if txn.excludedFromReport, txn.kind == .expense { txn.jar = nil } // never in a jar (P1-2)
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
