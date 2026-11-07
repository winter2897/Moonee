import SwiftData
import SwiftUI

extension Seed {
    /// The fixed "Balance adjustment" category (P1-2). Kind .transfer so no picker or jar mapping lists it; never in a jar.
    static let adjustmentKey = "category.adjustment"

    /// Found, or made the first time a balance is adjusted (existing installs have no seed for it).
    @MainActor static func adjustmentCategory(in context: ModelContext) -> Category {
        let key = adjustmentKey
        if let c = try? context.fetch(FetchDescriptor<Category>(predicate: #Predicate { $0.key == key })).first { return c }
        let c = Category(key: key, icon: "slider.horizontal.3", colorHex: 0x64748B, kind: .transfer, order: 999)
        context.insert(c)
        return c
    }
}

extension BudgetActions {
    /// "Update balance" (P1-2, spec §4.1): the wallet really holds `balance`. Records ONE txn for the difference
    /// (income if more, expense if less) in "Balance adjustment", not counted in reports and in no jar. A shortfall comes
    /// out of Unallocated; extra money in a budget wallet is new money, so it follows the one rule for inflows (`receive`).
    @discardableResult
    static func adjustBalance(_ wallet: Wallet, to balance: Int, date: Date = .now, level: AdvisorLevel = .current,
                              in context: ModelContext) -> Txn? {
        let txns = (try? context.fetch(FetchDescriptor<Txn>())) ?? []
        let wallets = (try? context.fetch(FetchDescriptor<Wallet>())) ?? []
        let diff = balance - Ledger(txns: txns, wallets: wallets, jars: []).walletBalance(wallet.persistentModelID)
        guard diff != 0 else { return nil }
        let t = Txn(amount: abs(diff), kind: diff > 0 ? .income : .expense, currencyCode: wallet.currencyCode, date: date,
                    category: Seed.adjustmentCategory(in: context), wallet: wallet)
        t.excludedFromReport = true
        context.insert(t)
        if diff > 0, wallet.inBudget { receive(diff, level: level, date: date, in: context) }
        try? context.save()
        return t
    }
}

/// "Update balance": type what the wallet really holds; Moonee records the difference (`BudgetActions.adjustBalance`).
/// Pushed from `WalletForm`, or a sheet from the wallet row's swipe / menu (`showsCancel`).
struct AdjustBalanceView: View {
    let wallet: Wallet
    /// Moonee's balance now (a card: negative = debt).
    let balance: Int
    var showsCancel = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// A card asks for its debt (positive), every other wallet for its balance.
    @State private var real: Int

    init(wallet: Wallet, balance: Int, showsCancel: Bool = false) {
        self.wallet = wallet
        self.balance = balance
        self.showsCancel = showsCancel
        _real = State(initialValue: wallet.type == .credit ? -balance : balance)
    }

    private var isCard: Bool { wallet.type == .credit }
    // ponytail: AmountField takes positive amounts only; an overdrawn (negative) non-card wallet can't be typed in.
    private var diff: Int { (isCard ? -real : real) - balance }

    var body: some View {
        Form {
            Section {
                LabeledContent(isCard ? loc("Moonee's debt") : loc("Moonee's balance")) {
                    AmountText(isCard ? -balance : balance, currency: wallet.currencyCode)
                }
                AmountField(title: isCard ? loc("Real debt now") : loc("Real balance now"), minor: $real, currency: wallet.currencyCode)
                if diff != 0 {
                    LabeledContent(loc("Difference")) {
                        AmountText(diff, currency: wallet.currencyCode, plus: true).foregroundStyle(diff > 0 ? Color.income : Color.ink)
                    }
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle(loc("Update balance"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancel { ToolbarItem(placement: .cancellationAction) { Button(loc("Cancel")) { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button(loc("Save")) {
                    BudgetActions.adjustBalance(wallet, to: isCard ? -real : real, in: context)
                    dismiss()
                }
                .disabled(diff == 0)
            }
        }
    }

    private var footer: String {
        let what = loc("Moonee records the difference as one “Balance adjustment”: it changes this wallet only and isn't counted as income or spending.")
        guard wallet.inBudget, diff != 0 else { return what }
        return what + " " + (diff > 0 ? loc("The extra money goes to Unallocated, like any money coming in.")
                                      : loc("The missing money comes out of Unallocated."))
    }
}
