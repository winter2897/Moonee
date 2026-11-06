import Foundation

/// All money math, pure Swift (no SwiftData) so it is unit-tested. Spec §4, §5, §9.3: the app computes every number.
/// `ID` is whatever identifies wallets/jars/debts: `PersistentIdentifier` in the app (see `Ledger(txns:…)`), strings in tests.
///
/// Rules:
/// - expense: wallet −, jar − (a credit-card swipe is an expense on the card wallet: its balance goes negative = card debt).
/// - income: wallet +, jars + by its stored splits only (no splits = unallocated). Splits and the expense jar are
///   fixed when the txn is saved (`Txn.allocate`), so editing percents or remapping a category never rewrites history.
/// - transfer: wallet → toWallet (paying a card is a transfer into it, not a second expense).
/// - jarTransfer: jar → toJar, no wallet moves. With splits and no source jar it is a split of unallocated money
///   (wallet money no jar holds yet, `unallocated`) into the jars.
/// - lend/borrow/repay: wallet and debt book only, never jars.
// ponytail: one currency per ledger; amounts in other currencies are summed as-is. Add FX when multi-currency wallets ship.
struct Ledger<ID: Hashable> {
    struct Entry {
        var kind: TxKind
        var amount: Int
        var date: Date
        var wallet: ID?
        var toWallet: ID?
        var jar: ID?
        var toJar: ID?
        var debt: ID?
        /// income: its split into jars (empty = unallocated). jarTransfer: extra jar inflows (splitting unallocated money).
        var splits: [ID: Int] = [:]
    }

    /// One jar's numbers for a month (the jar card).
    struct JarMonth: Equatable {
        /// Carried over from before the month.
        var start: Int
        /// Income splits + net jar transfers during the month.
        var added: Int
        var spent: Int
        /// Big number on the card: balance now (end of the entries given).
        var balance: Int
        /// What the month had to spend.
        var budget: Int { start + added }
        /// The card's bar: spent / budget. > 1 = over; nothing to spend but spending = .infinity.
        var progress: Double {
            budget > 0 ? Double(spent) / Double(budget) : (spent > 0 ? .infinity : 0)
        }
    }

    let entries: [Entry]
    private(set) var walletBalances: [ID: Int]
    private(set) var jarBalances: [ID: Int]
    /// What is still owed on each debt (positive), by its direction.
    private(set) var debtRemaining: [ID: Int] = [:]
    let debtDirections: [ID: DebtDirection]
    private let jarOpening: [ID: Int]

    init(entries: [Entry], walletOpening: [ID: Int] = [:], jarOpening: [ID: Int] = [:], debtDirections: [ID: DebtDirection] = [:]) {
        self.entries = entries
        self.debtDirections = debtDirections
        self.jarOpening = jarOpening
        walletBalances = walletOpening
        jarBalances = jarOpening
        for e in entries {
            for (id, d) in walletDeltas(e) { walletBalances[id, default: 0] += d }
            for (id, d) in jarDeltas(e) { jarBalances[id, default: 0] += d }
            if let debt = e.debt {
                switch e.kind {
                case .lend, .borrow: debtRemaining[debt, default: 0] += e.amount
                case .repay: debtRemaining[debt, default: 0] -= e.amount
                default: break
                }
            }
        }
    }

    func walletBalance(_ id: ID) -> Int { walletBalances[id] ?? 0 }
    func jarBalance(_ id: ID) -> Int { jarBalances[id] ?? 0 }

    func jarMonth(_ jar: ID, in month: DateInterval) -> JarMonth {
        var m = JarMonth(start: jarOpening[jar] ?? 0, added: 0, spent: 0, balance: jarBalance(jar))
        for e in entries {
            for (id, d) in jarDeltas(e) where id == jar {
                if e.date < month.start { m.start += d }
                else if e.date < month.end { if e.kind == .expense { m.spent -= d } else { m.added += d } }
            }
        }
        return m
    }

    /// Wallets (credit cards count negative) + assets + money lent out − money borrowed. Spec §5.
    func netWorth(assets: Int = 0) -> Int {
        let debts = debtRemaining.reduce(0) { sum, d in
            sum + (debtDirections[d.key] == .borrowed ? -d.value : d.value)
        }
        return walletBalances.values.reduce(0, +) + assets + debts
    }

    /// Money in wallets (plus lent out, minus borrowed) that no jar holds yet: "Unallocated" on the Budget tab.
    /// Positive = to split into jars; negative = the jars promise more than there is. Spec §4.1, decision 06/11.
    var unallocated: Int { netWorth() - jarBalances.values.reduce(0, +) }

    /// What the given jars hold for the month: Σ start + added, Σ spent. "Total budget" / "Spent" / "Left" on the Budget tab.
    func monthTotals(_ jars: [ID], in month: DateInterval) -> JarMonth {
        jars.map { jarMonth($0, in: month) }.reduce(JarMonth(start: 0, added: 0, spent: 0, balance: 0)) {
            JarMonth(start: $0.start + $1.start, added: $0.added + $1.added, spent: $0.spent + $1.spent, balance: $0.balance + $1.balance)
        }
    }

    /// Income received in `interval` (Overview and Budget show the same number).
    func income(in interval: DateInterval) -> Int {
        entries.reduce(0) { $1.kind == .income && interval.start <= $1.date && $1.date < interval.end ? $0 + $1.amount : $0 }
    }

    /// Splits an income by percents. Floors each share; the rounding remainder goes to the largest jar, so shares sum to `amount`.
    static func split(_ amount: Int, by percents: [(ID, Int)]) -> [ID: Int] {
        guard let biggest = percents.max(by: { $0.1 < $1.1 }), percents.contains(where: { $0.1 > 0 }) else { return [:] }
        var out: [ID: Int] = [:]
        for (id, p) in percents where p > 0 { out[id, default: 0] += amount * p / 100 }
        out[biggest.0, default: 0] += amount - out.values.reduce(0, +)
        return out
    }

    // MARK: - Per-entry effects

    private func walletDeltas(_ e: Entry) -> [(ID, Int)] {
        let a = e.amount
        let deltas: [(ID?, Int)] = switch e.kind {
        case .expense, .lend: [(e.wallet, -a)]
        case .income, .borrow: [(e.wallet, a)]
        case .transfer: [(e.wallet, -a), (e.toWallet, a)]
        case .jarTransfer: []
        // Repaying a debt I owe pays out; being repaid for money I lent pays in. No debt: assume I pay.
        case .repay: [(e.wallet, e.debt.flatMap { debtDirections[$0] } == .lent ? a : -a)]
        }
        return deltas.compactMap { id, d in id.map { ($0, d) } }
    }

    private func jarDeltas(_ e: Entry) -> [(ID, Int)] {
        switch e.kind {
        case .expense: e.jar.map { [($0, -e.amount)] } ?? []
        case .income: e.splits.map { ($0.key, $0.value) }
        case .jarTransfer: [(e.jar, -e.amount), (e.toJar, e.amount)].compactMap { id, d in id.map { ($0, d) } }
            + e.splits.map { ($0.key, $0.value) }
        case .transfer, .lend, .borrow, .repay: []
        }
    }
}
