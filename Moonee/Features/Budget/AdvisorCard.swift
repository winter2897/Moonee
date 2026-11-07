import SwiftData
import SwiftUI

/// "Moonee suggests" at the top of Budget (spec §4.6): the one most urgent advice with Agree / Edit / Skip,
/// or what Automatic just did with Undo.
struct AdvisorSection: View {
    @Binding var sheet: BudgetSheet?
    @Environment(\.modelContext) private var context
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query private var txns: [Txn]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Recurring.nextDue) private var recurrings: [Recurring]
    @AppStorage(Prefs.advisorVersion) private var version = 0
    @AppStorage(Prefs.advisorLevel) private var level = AdvisorLevel.suggest.rawValue

    var body: some View {
        let _ = version // re-read AdvisorMemory when it changes
        let facts = BudgetFacts(txns: txns, wallets: wallets, jars: jars, recurrings: recurrings,
                                level: AdvisorLevel(rawValue: level) ?? .suggest)
        if let record = AdvisorMemory.autoRecords.last(where: { $0.date > .now.addingTimeInterval(-3 * 86_400) }) {
            Section { autoCard(record) } header: { Text(loc("Moonee")) }
        } else if let a = AdvisorMemory.pick(facts.advice) {
            Section { card(a) } header: { Text(a.kind.isWarning ? loc("Moonee") : loc("Moonee suggests")) }
        }
    }

    private func card(_ a: BudgetAdvisor.Advice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MooneeNoteCard(mood: a.kind.isWarning ? .worried : .thinking, text: a.text, title: a.title)
            if let why = a.why, !why.isEmpty {
                Label { Text(why) } icon: { Image(systemName: "lightbulb.fill").foregroundStyle(Color.mooneeYellow) }
                    .font(.footnote).foregroundStyle(Color.inkSecondary)
            }
            HStack(spacing: 8) {
                actions(a)
                Spacer(minLength: 0)
                if a.kind == .unallocated, a.amount > 0 { // waits, never mutes the kind
                    Button(loc("Later")) { withAnimation { AdvisorMemory.handle(a) } }.buttonStyle(.borderless).foregroundStyle(Color.inkSecondary)
                } else if a.kind != .pace, a.kind != .monthEnd {
                    Button(loc("Skip")) { withAnimation { AdvisorMemory.dismiss(a) } }.buttonStyle(.borderless).foregroundStyle(Color.inkSecondary)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func actions(_ a: BudgetAdvisor.Advice) -> some View {
        switch a.kind {
        case .payday:
            if let r = recurring(a.ref) {
                if r.isEstimate {
                    primary(loc("Enter amount")) { sheet = .payBill(r) }
                } else {
                    primary(loc("Record & split")) { apply(a) }
                    secondary(loc("Edit")) { sheet = .payBill(r) }
                }
            }
        case .noMoney:
            if let w = wallets.first(where: { $0.inBudget && $0.type == .bank }) ?? wallets.first(where: { $0.inBudget && $0.type != .credit }) {
                primary(loc("Update balance")) { sheet = .wallet(w) }
            }
            if let r = recurring(a.ref) {
                secondary(loc("Record salary early")) {
                    if r.isEstimate { sheet = .payBill(r) } else { done(a) { BudgetActions.receive(r, in: context) } }
                }
            }
        case .negativeJar:
            if let m = a.moves.first {
                primary(loc("Move")) { apply(a) }
                secondary(loc("Edit")) { sheet = .transfer(JarTransferDraft(from: jar(m.from), to: jar(m.to), amount: m.amount)) }
            }
        case .cardDue:
            if let card = wallets.first(where: { $0.ref == a.ref }) { primary(loc("Pay in full")) { sheet = .payCard(card, debt: a.amount) } }
        case .unallocated:
            // New money waiting (spec §4.1, Suggest): the same choices as the chat card. "Later" is the Skip button.
            primary(a.amount > 0 ? loc("Split as suggested") : loc("Move")) { apply(a) }
            if a.amount > 0 {
                secondary(loc("By %")) { done(a) { BudgetActions.splitUnallocated(a.amount, jars: jars, in: context) } }
                Menu {
                    ForEach(jars) { j in Button(j.name) { done(a) { BudgetActions.allocate([j: a.amount], note: loc("Split into jars"), in: context) } } }
                } label: { Image(systemName: "ellipsis").accessibilityLabel(loc("All into one jar")) }
                .buttonStyle(.bordered)
            }
        case .billDue:
            if let bill = recurring(a.ref) {
                primary(loc("Mark paid")) { if bill.isEstimate { sheet = .payBill(bill) } else { done(a) { BudgetActions.markPaid(bill, jars: jars, in: context) } } }
            }
        case .pace:
            primary(loc("Got it")) { withAnimation { AdvisorMemory.handle(a) } }
        case .monthEnd:
            primary(String(localized: "Move to \(jars.first { $0.key == "jar.savings" }?.name ?? "")", table: "Budget")) { apply(a) }
            secondary(loc("Keep it")) { withAnimation { AdvisorMemory.handle(a) } }
        case .rebalance:
            primary(loc("Apply")) { apply(a) }
        }
    }

    private func autoCard(_ record: AdvisorMemory.AutoRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MooneeNoteCard(mood: .happy, text: record.text, title: record.title)
            HStack(spacing: 8) {
                secondary(loc("Undo")) { withAnimation { Autopilot.undo(record, in: context) } }
                if record.kind == BudgetAdvisor.Kind.payday.rawValue, let r = recurrings.first(where: \.isIncome) {
                    secondary(loc("Edit amount")) {
                        Autopilot.undo(record, in: context)
                        sheet = .payBill(r)
                    }
                }
                Spacer(minLength: 0)
                primary(loc("OK")) { withAnimation { Autopilot.acknowledge(record) } }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderedProminent).tint(Color.brandPrimary)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).tint(Color.brandDeep)
    }

    private func apply(_ a: BudgetAdvisor.Advice) { done(a) { BudgetActions.apply(a, in: context) } }

    private func done(_ a: BudgetAdvisor.Advice, _ write: () -> Any?) {
        withAnimation {
            _ = write()
            AdvisorMemory.handle(a)
        }
    }

    private func recurring(_ ref: String?) -> Recurring? { recurrings.first { $0.ref == ref } }
    private func jar(_ id: String?) -> Jar? { id.flatMap { id in jars.first { $0.parserKey == id } } }
}

/// Account / Budget ⋯ → "Moonee's help": Automatic, Suggest or Do it myself, and forgetting what was skipped.
struct AdvisorSettingsView: View {
    @AppStorage(Prefs.advisorLevel) private var level = AdvisorLevel.suggest.rawValue
    @AppStorage(Prefs.advisorVersion) private var version = 0

    var body: some View {
        let _ = version
        Form {
            Section {
                Picker(loc("Moonee's help"), selection: $level) {
                    ForEach(AdvisorLevel.allCases) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.title)
                            Text(l.summary).font(.footnote).foregroundStyle(Color.inkSecondary)
                        }
                        .tag(l.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(loc("Moonee does the math in the app and explains it. Moonee is not a licensed investment adviser."))
            }
            Section {
                Button(loc("Show skipped suggestions again")) { AdvisorMemory.resetLearning() }
                    .disabled(AdvisorMemory.muted.isEmpty)
            } footer: {
                Text(loc("Skip the same kind of suggestion twice and Moonee stops showing it."))
            }
        }
        .navigationTitle(loc("Moonee's help"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Buy an asset, put money into a savings / investment account, or bring it back (spec §4.2 rule A.5).
/// Money out of the budget comes out of a jar; money back lands in Unallocated.
struct SetAsideSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case buy, deposit, sell, withdraw
        var id: String { rawValue }
        var title: String {
            switch self {
            case .buy: loc("Buy an asset")
            case .deposit: loc("Deposit into savings")
            case .sell: loc("Sell an asset")
            case .withdraw: loc("Withdraw from savings")
            }
        }
        var outOfBudget: Bool { self == .buy || self == .deposit }
    }

    @State var mode: Mode
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Jar.order) private var jars: [Jar]
    @Query(sort: \Wallet.order) private var wallets: [Wallet]
    @Query(sort: \Asset.updatedAt, order: .reverse) private var assets: [Asset]
    @Query private var txns: [Txn]
    @Query private var recurrings: [Recurring]
    @State private var amount = 0
    @State private var wallet: Wallet?
    @State private var jar: Jar?
    @State private var asset: Asset?
    @State private var account: Wallet?
    @State private var newName = ""
    @State private var kind = AssetKind.gold
    @State private var quantity: Double?

    private var budgetWallets: [Wallet] { wallets.filter { $0.inBudget && $0.type != .credit } }
    private var accounts: [Wallet] { wallets.filter { !$0.inBudget } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(loc("What"), selection: $mode) { ForEach(Mode.allCases) { Text($0.title).tag($0) } }
                }
                Section { target }
                Section {
                    AmountField(title: loc("Amount"), minor: $amount)
                    Picker(mode.outOfBudget ? loc("Pay from") : loc("Into"), selection: $wallet) {
                        Text(loc("Choose")).tag(nil as Wallet?)
                        ForEach(budgetWallets) { Text($0.name).tag($0 as Wallet?) }
                    }
                    if mode.outOfBudget {
                        Picker(loc("Out of jar"), selection: $jar) {
                            Text(loc("Choose")).tag(nil as Jar?)
                            ForEach(jars) { Text($0.name).tag($0 as Jar?) }
                        }
                    }
                } footer: {
                    footer
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(loc("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(loc("Save"), action: save).disabled(!valid) }
            }
            .onAppear(perform: defaults)
            .onChange(of: mode) { defaults() }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var target: some View {
        switch mode {
        case .buy, .sell:
            Picker(loc("Asset"), selection: $asset) {
                if mode == .buy { Text(loc("New asset")).tag(nil as Asset?) }
                ForEach(assets.filter { mode == .buy || $0.quantity > 0 }) { Text($0.symbol).tag($0 as Asset?) }
            }
            if mode == .buy, asset == nil {
                TextField(loc("Name, e.g. SJC gold, FPT, BTC"), text: $newName)
                Picker(loc("Type"), selection: $kind) { ForEach(AssetKind.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            LabeledContent(loc("Quantity")) {
                TextField(String(0), value: $quantity, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
        case .deposit, .withdraw:
            Picker(loc("Account"), selection: $account) {
                if mode == .deposit { Text(loc("New savings account")).tag(nil as Wallet?) }
                ForEach(accounts) { Text($0.name).tag($0 as Wallet?) }
            }
            if mode == .deposit, account == nil { TextField(loc("Account name"), text: $newName) }
        }
    }

    @ViewBuilder private var footer: some View {
        if mode.outOfBudget {
            let advisor = BudgetFacts(txns: txns, wallets: wallets, jars: jars, recurrings: recurrings).advisor
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("It comes out of the jar you pick, so your jars still match your wallets."))
                if let note = advisor.emergencyNote(spending: amount, from: jar?.parserKey) { Text(note).foregroundStyle(Color.danger) }
                if mode == .buy {
                    Text(loc("Rules of thumb: emergency fund first, invest only money you won't need for 3–5 years, spread it out, never borrow to invest. Moonee is not a licensed investment adviser."))
                }
            }
        } else {
            Text(loc("The money lands in Unallocated: split it once on the Budget tab."))
        }
    }

    private var valid: Bool {
        guard amount > 0, wallet != nil else { return false }
        switch mode {
        case .buy: return jar != nil && (asset != nil || !newName.trimmingCharacters(in: .whitespaces).isEmpty)
        case .deposit: return jar != nil && (account != nil || !newName.trimmingCharacters(in: .whitespaces).isEmpty)
        case .sell: return asset != nil
        case .withdraw: return account != nil
        }
    }

    private func defaults() {
        wallet = wallet ?? budgetWallets.first { $0.type == .bank } ?? budgetWallets.first
        jar = jars.first { $0.key == (mode == .buy ? "jar.investing" : "jar.savings") } ?? jar
        if mode == .sell, asset?.quantity ?? 0 <= 0 { asset = assets.first { $0.quantity > 0 } }
        if mode == .withdraw, account == nil { account = accounts.first }
    }

    private func save() {
        guard let wallet else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .buy:
            guard let jar else { return }
            let a = asset ?? Asset(symbol: name, kind: kind, quantity: 0, unitPrice: 0)
            if asset == nil { context.insert(a) }
            BudgetActions.setAside(amount, from: wallet, jar: jar, asset: a, quantity: quantity ?? 0, in: context)
        case .deposit:
            guard let jar else { return }
            let target = account ?? Wallet(name: name, type: .savings, order: wallets.count)
            if account == nil { context.insert(target) }
            BudgetActions.setAside(amount, from: wallet, jar: jar, into: target, in: context)
        case .sell:
            guard let asset else { return }
            BudgetActions.bringBack(amount, into: wallet, asset: asset, quantity: quantity ?? asset.quantity, in: context)
            if wallet.inBudget { BudgetActions.receive(amount, in: context) } // money in: the one rule (spec §4.1)
        case .withdraw:
            BudgetActions.bringBack(amount, into: wallet, from: account, in: context)
            if wallet.inBudget, account?.inBudget != true { BudgetActions.receive(amount, in: context) }
        }
        dismiss()
    }
}
