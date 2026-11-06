import SwiftData
import SwiftUI

/// Wallets as a standalone screen (Account → Wallets).
struct WalletsView: View {
    @State private var sheet: BudgetSheet?

    var body: some View {
        List { WalletsSection(sheet: $sheet) }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MooneeBackground())
            .navigationTitle(loc("Wallets"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc("Add wallet"), systemImage: "plus") { sheet = .wallet(nil) }
                }
            }
            .sheet(item: $sheet) { $0.view }
    }
}

/// Wallets section of the Budget list (spec §4.2): total, each wallet, credit cards with debt, limit and due day.
struct WalletsSection: View {
    @Binding var sheet: BudgetSheet?
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query private var txns: [Txn]

    var body: some View {
        let ledger = Ledger(txns: txns, wallets: wallets, jars: [])
        let balance = { (w: Wallet) in ledger.walletBalance(w.persistentModelID) }
        let debt = wallets.filter { $0.type == .credit }.reduce(0) { $0 + max(-balance($1), 0) }
        Section {
            if wallets.isEmpty {
                ContentUnavailableView {
                    Label(loc("No wallets yet"), systemImage: "wallet.bifold")
                } description: {
                    Text(loc("Add cash, a bank account, an e-wallet or a credit card."))
                } actions: {
                    Button(loc("Add wallet")) { sheet = .wallet(nil) }
                }
            } else {
                // ponytail: sums every wallet as the default currency; convert when multi-currency wallets ship
                LabeledContent(loc("Total in wallets")) {
                    AmountText(wallets.reduce(0) { $0 + balance($1) }, currency: Money.defaultCurrency).foregroundStyle(Color.ink)
                }
                if debt > 0 {
                    LabeledContent(loc("Card debt")) { AmountText(debt, currency: Money.defaultCurrency).foregroundStyle(Color.danger) }
                }
            }
            ForEach(wallets) { w in
                Button { sheet = .wallet(w) } label: {
                    if w.type == .credit { CreditCardRow(card: w, balance: balance(w)) } else { WalletRow(wallet: w, balance: balance(w)) }
                }
                .swipeActions(edge: .leading) {
                    if w.type == .credit, balance(w) < 0 {
                        Button(loc("Pay card"), systemImage: "creditcard") { sheet = .payCard(w, debt: -balance(w)) }.tint(Color.brandPrimary)
                    }
                }
                .contextMenu {
                    if w.type == .credit, balance(w) < 0 {
                        Button(loc("Pay card"), systemImage: "creditcard") { sheet = .payCard(w, debt: -balance(w)) }
                    }
                    Button(loc("Edit"), systemImage: "pencil") { sheet = .wallet(w) }
                }
            }
        } header: {
            Text(loc("Wallets"))
        }
    }
}

private struct WalletRow: View {
    let wallet: Wallet
    let balance: Int

    var body: some View {
        BudgetRow(title: wallet.name, symbol: wallet.type.symbol, tint: wallet.type.color) {
            Text(wallet.type.title).foregroundStyle(Color.inkSecondary)
        } value: {
            AmountText(balance, currency: wallet.currencyCode).foregroundStyle(balance < 0 ? Color.danger : Color.ink)
        }
    }
}

/// A card's balance goes negative as you swipe: the row shows that debt, the next due date and the limit used.
private struct CreditCardRow: View {
    let card: Wallet
    let balance: Int

    var body: some View {
        let debt = max(-balance, 0)
        let limit = card.creditLimit ?? 0
        VStack(alignment: .leading, spacing: 8) {
            BudgetRow(title: card.name, symbol: card.type.symbol, tint: card.type.color) {
                if let day = card.dueDay {
                    Text(String(localized: "Due \(BudgetActions.nextDate(day: day).formatted(.dateTime.day().month()))", table: "Budget"))
                        .foregroundStyle(Color.inkSecondary)
                } else {
                    Text(loc("Current debt")).foregroundStyle(Color.inkSecondary)
                }
            } value: {
                AmountText(debt, currency: card.currencyCode)
            }
            if limit > 0 {
                ProgressView(value: min(Double(debt) / Double(limit), 1)) {
                    EmptyView()
                } currentValueLabel: {
                    HStack(spacing: 4) {
                        Text(loc("Available"))
                        AmountText(limit - debt, currency: card.currencyCode)
                    }
                }
                .tint(BudgetLevel(progress: Double(debt) / Double(limit)).fill)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Paying a card = a transfer from another wallet into the card (spec §4.2), never a second expense.
struct PayCardSheet: View {
    let card: Wallet
    let debt: Int
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query private var jars: [Jar]
    @State private var from: Wallet?
    @State private var amount: Int
    @State private var date = Date.now

    init(card: Wallet, debt: Int) {
        self.card = card
        self.debt = debt
        _amount = State(initialValue: debt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(loc("Current debt")) { AmountText(debt, currency: card.currencyCode) }
                    Picker(loc("Pay from"), selection: $from) {
                        Text(loc("Choose")).tag(nil as Wallet?)
                        ForEach(wallets.filter { $0.type != .credit }) { Text($0.name).tag($0 as Wallet?) }
                    }
                    AmountField(title: loc("Amount"), minor: $amount, currency: card.currencyCode)
                    DatePicker(loc("Date"), selection: $date, displayedComponents: .date)
                } footer: {
                    Text(loc("Recorded as a transfer: your jars were already charged when you swiped."))
                }
            }
            .navigationTitle(String(localized: "Pay \(card.name)", table: "Budget"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("Pay")) {
                        guard let from else { return }
                        BudgetActions.payCard(card, amount: amount, from: from, date: date, jars: jars, in: context)
                        dismiss()
                    }
                    .disabled(from == nil || amount <= 0)
                }
            }
            .onAppear {
                from = from ?? wallets.first { $0.type == .bank } ?? wallets.first { $0.type != .credit }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct WalletForm: View {
    let wallet: Wallet?
    @Query private var wallets: [Wallet]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: WalletType = .cash
    @State private var initial = 0
    @State private var limit = 0
    @State private var statementDay: Int?
    @State private var dueDay: Int?
    @State private var confirmDelete = false

    init(wallet: Wallet?) {
        self.wallet = wallet
        guard let wallet else { return }
        _name = State(initialValue: wallet.name)
        _type = State(initialValue: wallet.type)
        // A card's opening debt is stored as a negative balance; the form asks for the debt.
        _initial = State(initialValue: wallet.type == .credit ? -wallet.initialBalance : wallet.initialBalance)
        _limit = State(initialValue: wallet.creditLimit ?? 0)
        _statementDay = State(initialValue: wallet.statementDay)
        _dueDay = State(initialValue: wallet.dueDay)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(loc("Wallet name"), text: $name)
                    Picker(loc("Type"), selection: $type) {
                        ForEach(WalletType.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    AmountField(title: type == .credit ? loc("Debt when added") : loc("Opening balance"), minor: $initial)
                }
                if type == .credit {
                    Section {
                        AmountField(title: loc("Credit limit"), minor: $limit)
                        dayPicker(loc("Statement day"), $statementDay)
                        dayPicker(loc("Due day"), $dueDay)
                    } footer: {
                        Text(loc("Swiping the card is spending (it comes out of a jar); paying the card is a transfer."))
                    }
                }
                if wallet != nil {
                    Section { Button(loc("Delete wallet"), role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(wallet == nil ? loc("Add wallet") : loc("Edit wallet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("Save"), action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog(loc("Deleting a wallet also deletes its transactions."), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(loc("Delete wallet"), role: .destructive) {
                    if let wallet { context.delete(wallet) }
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func dayPicker(_ title: String, _ day: Binding<Int?>) -> some View {
        Picker(title, selection: day) {
            Text(loc("Not set")).tag(nil as Int?)
            ForEach(1...31, id: \.self) { Text(verbatim: "\($0)").tag($0 as Int?) }
        }
    }

    private func save() {
        let w = wallet ?? Wallet(name: name, type: type, order: wallets.count)
        if wallet == nil { context.insert(w) }
        w.name = name.trimmingCharacters(in: .whitespaces)
        w.type = type
        w.initialBalance = type == .credit ? -initial : initial
        w.creditLimit = type == .credit && limit > 0 ? limit : nil
        w.statementDay = type == .credit ? statementDay : nil
        w.dueDay = type == .credit ? dueDay : nil
        dismiss()
    }
}
