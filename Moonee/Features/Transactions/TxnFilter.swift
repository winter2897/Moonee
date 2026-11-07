import Foundation

/// Ledger search + filters (spec §2: by wallet / jar / category / type / amount). The period lives in `LedgerPeriod`.
struct TxnFilter {
    /// The type filter: money out, money in, moves between my own wallets / jars, the debt book.
    enum Kind: String, CaseIterable, Identifiable {
        case expense, income, transfer, debt
        var id: String { rawValue }

        var title: String {
            switch self {
            case .expense: String(localized: "Spending", table: "Transactions")
            case .income: String(localized: "Income", table: "Transactions")
            case .transfer: String(localized: "Transfers", table: "Transactions")
            case .debt: String(localized: "Loans & debts", table: "Transactions")
            }
        }

        func matches(_ k: TxKind) -> Bool {
            switch self {
            case .expense: k == .expense
            case .income: k == .income
            case .transfer: k == .transfer || k == .jarTransfer
            case .debt: k == .lend || k == .borrow || k == .repay
            }
        }
    }

    var text = ""
    var wallet: Wallet?
    var jar: Jar?
    var category: Category?
    var kind: Kind?
    /// Amount range in minor units; 0 = no bound.
    var minAmount = 0
    var maxAmount = 0

    var isActive: Bool { wallet != nil || jar != nil || category != nil || kind != nil || minAmount > 0 || maxAmount > 0 }

    func matches(_ t: Txn) -> Bool {
        if let wallet, t.wallet != wallet, t.toWallet != wallet { return false }
        if let jar, t.jar != jar, t.toJar != jar, !(t.splits ?? []).contains(where: { $0.jar == jar }) { return false }
        if let category, t.category != category { return false }
        if let kind, !kind.matches(t.kind) { return false }
        if minAmount > 0, t.amount < minAmount { return false }
        if maxAmount > 0, t.amount > maxAmount { return false }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [t.note, t.category?.name, t.wallet?.name, t.toWallet?.name, t.debt?.person, t.rawInput]
            .contains { $0?.localizedStandardContains(q) == true }
    }
}

/// Keeps an edited income's jar shares in the same proportions: floors each, remainder to the largest, sum = `total`.
func rescaleSplits(_ amounts: [Int], to total: Int) -> [Int] {
    let old = amounts.reduce(0, +)
    guard old > 0, let biggest = amounts.indices.max(by: { amounts[$0] < amounts[$1] }) else { return amounts }
    var out = amounts.map { $0 * total / old }
    out[biggest] += total - out.reduce(0, +)
    return out
}
