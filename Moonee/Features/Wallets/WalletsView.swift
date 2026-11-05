import SwiftData
import SwiftUI

/// Wallets as a standalone screen (Account → Wallets).
struct WalletsView: View {
    var body: some View {
        WalletsSection().mooneeScreen(loc("Wallets"))
    }
}

/// Wallets segment of the Budget tab (spec §4.2): where the money is. Credit cards show debt, limit and days.
struct WalletsSection: View {
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query private var txns: [Txn]
    @State private var editing: Wallet?
    @State private var adding = false
    @State private var paying: Wallet?

    var body: some View {
        let ledger = Ledger(txns: txns, wallets: wallets, jars: [])
        let balance = { (w: Wallet) in ledger.walletBalance(w.persistentModelID) }
        let cards = wallets.filter { $0.type == .credit }
        let others = wallets.filter { $0.type != .credit }
        VStack(spacing: 12) {
            // ponytail: sums every wallet as the default currency; convert when multi-currency wallets ship
            VStack(alignment: .leading, spacing: 8) {
                Text(loc("Total in wallets")).font(.rowTitle)
                AmountText(wallets.reduce(0) { $0 + balance($1) }, currency: Money.defaultCurrency)
                    .heroAmountFont()
                let debt = cards.reduce(0) { $0 + max(-balance($1), 0) }
                if debt > 0 {
                    HStack(spacing: 4) {
                        Text(loc("Card debt")).foregroundStyle(Color.inkSecondary)
                        AmountText(debt, currency: Money.defaultCurrency).fontWeight(.semibold)
                    }
                    .font(.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 18)

            BudgetSectionHeader(title: String(localized: "Wallets (\(others.count))", table: "Budget")) {
                Button(loc("Add"), systemImage: "plus") { adding = true }.fontWeight(.semibold)
            }
            if wallets.isEmpty {
                EmptyState(title: loc("No wallets yet"), message: loc("Add cash, a bank account, an e-wallet or a credit card."))
            }
            VStack(spacing: 8) {
                ForEach(others) { w in
                    Button { editing = w } label: { WalletRow(wallet: w, balance: balance(w)) }.buttonStyle(.plain)
                }
            }
            if !cards.isEmpty {
                BudgetSectionHeader(title: loc("Credit cards")) { EmptyView() }
                ForEach(cards) { c in
                    CreditCardRow(card: c, balance: balance(c), onEdit: { editing = c }, onPay: { paying = c })
                }
            }
        }
        .sheet(isPresented: $adding) { WalletForm(wallet: nil, nextOrder: wallets.count) }
        .sheet(item: $editing) { WalletForm(wallet: $0, nextOrder: wallets.count) }
        .sheet(item: $paying) { PayCardSheet(card: $0, debt: max(-balance($0), 0)) }
    }
}

private struct WalletRow: View {
    let wallet: Wallet
    let balance: Int

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: wallet.type.symbol, color: wallet.type.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name).font(.rowTitle)
                Text(wallet.type.title).font(.secondaryText).foregroundStyle(Color.inkSecondary)
            }
            Spacer()
            AmountText(balance, currency: wallet.currencyCode)
                .font(.rowTitle)
                .foregroundStyle(balance < 0 ? Color.danger : Color.ink)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkSecondary)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(Color.surface.opacity(0.85), in: .rect(cornerRadius: 20))
        .contentShape(.rect)
    }
}

/// Card debt (a card's balance goes negative as you swipe), limit used, statement/due days and "Pay card".
private struct CreditCardRow: View {
    let card: Wallet
    let balance: Int
    let onEdit: () -> Void
    let onPay: () -> Void

    var body: some View {
        let debt = max(-balance, 0)
        let limit = card.creditLimit ?? 0
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    IconBadge(symbol: card.type.symbol, color: card.type.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.name).font(.rowTitle)
                        Text(loc("Current debt")).font(.secondaryText).foregroundStyle(Color.inkSecondary)
                    }
                    Spacer()
                    AmountText(debt, currency: card.currencyCode).font(.rowTitle)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if limit > 0 {
                let level = BudgetLevel(progress: Double(debt) / Double(limit))
                MooneeProgressBar(progress: Double(debt) / Double(limit), tint: level.fill)
                HStack(spacing: 4) {
                    Text(loc("Available")).foregroundStyle(Color.inkSecondary)
                    AmountText(limit - debt, currency: card.currencyCode).fontWeight(.semibold)
                    Spacer()
                    Text(loc("Limit")).foregroundStyle(Color.inkSecondary)
                    AmountText(limit, currency: card.currencyCode, short: true)
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                if let day = card.statementDay { dayChip("doc.text", String(localized: "Statement: day \(day)", table: "Budget")) }
                if let day = card.dueDay {
                    dayChip("calendar.badge.exclamationmark",
                            String(localized: "Due \(BudgetActions.nextDate(day: day).formatted(.dateTime.day().month()))", table: "Budget"))
                }
                Spacer(minLength: 4)
                if debt > 0 {
                    Button(loc("Pay card"), action: onPay)
                        .buttonStyle(OutlinePillStyle(filled: true))
                }
            }
        }
        .padding(14)
        .background(Color.surface.opacity(0.85), in: .rect(cornerRadius: 20))
    }

    private func dayChip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.brandMintSoft, in: .capsule)
    }
}

/// Paying a card = a transfer from another wallet into the card (spec §4.2), never a second expense.
private struct PayCardSheet: View {
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

private struct WalletForm: View {
    let wallet: Wallet?
    let nextOrder: Int
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: WalletType = .cash
    @State private var initial = 0
    @State private var limit = 0
    @State private var statementDay: Int?
    @State private var dueDay: Int?
    @State private var confirmDelete = false

    init(wallet: Wallet?, nextOrder: Int) {
        self.wallet = wallet
        self.nextOrder = nextOrder
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
                    Button(loc("Delete wallet"), role: .destructive) { confirmDelete = true }
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
        let w = wallet ?? Wallet(name: name, type: type, order: nextOrder)
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
