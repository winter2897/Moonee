import Foundation
import SwiftData

/// The stored books as plain values for the AI tools (`LedgerReading`) and any screen that wants them.
/// A snapshot taken on the main actor: build a fresh one per question.
// ponytail: reads every txn of the currency; fetch by date range once ledgers get big.
struct StoreLedger: LedgerReading {
    let currency: String
    let jarList: [LedgerJar]
    let txns: [LedgerTxn]
    let budgetFacts: BudgetFacts

    @MainActor init(_ context: ModelContext, currency: String = Money.defaultCurrency, now: Date = .now, calendar: Calendar = .current) {
        let txns = (try? context.fetch(FetchDescriptor<Txn>())) ?? []
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let wallets = (try? context.fetch(FetchDescriptor<Wallet>())) ?? []
        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        budgetFacts = BudgetFacts(txns: txns, wallets: wallets, jars: jars,
                                  recurrings: (try? context.fetch(FetchDescriptor<Recurring>())) ?? [], now: now, calendar: calendar)
        self.currency = currency
        jarList = jars.map { LedgerJar(key: $0.parserKey, name: $0.name, percent: $0.percent, balance: ledger.jarBalance($0.persistentModelID)) }
        self.txns = txns.filter { $0.currencyCode == currency }.map { t in
            LedgerTxn(date: t.date, amount: t.amount, kind: EntryKind(rawValue: t.kindRaw) ?? .expense,
                      categoryKey: t.category?.parserKey, categoryName: t.category?.name,
                      jarKey: t.jar?.parserKey, toJarKey: t.toJar?.parserKey,
                      splits: Dictionary((t.splits ?? []).compactMap { s in s.jar.map { ($0.parserKey, s.amount) } }, uniquingKeysWith: +),
                      note: t.note, person: t.debt?.person)
        }
    }

    func jars() async throws -> [LedgerJar] { jarList }
    func budget() async throws -> BudgetFacts? { budgetFacts }
    func transactions(in i: DateInterval) async throws -> [LedgerTxn] { txns.filter { $0.date >= i.start && $0.date < i.end } }
}

/// The Budget tab's numbers for one month, all from `Ledger`. The Budget tab shows them and the assistant's
/// `monthBudget` tool reads the very same struct, so "how much can I still spend?" matches the screen (spec §9.3).
struct BudgetFacts: Sendable, Equatable {
    struct JarLine: Sendable, Equatable {
        var key: String
        var name: String
        var percent: Int
        /// Carried over from before the month, added during it (income splits, moves), spent, balance at the end.
        var start, added, spent, balance: Int
        var budget: Int { start + added }
    }

    struct Due: Sendable, Equatable {
        var name: String
        var amount: Int
        var date: Date
        var isEstimate = false
    }

    var month: DateInterval
    var jars: [JarLine]
    /// Wallet money no jar holds yet (now, whatever the month). Positive = to split.
    var unallocated: Int
    /// Income received in the month (the Overview's month income is the same number).
    var income: Int
    /// Salaries and other income recurrings not received yet, next payday first.
    var expectedIncome: [Due]
    /// Unpaid bills due before the month ends, overdue ones included.
    var bills: [Due]

    /// "Total budget": what the jars have for the month (start of month + added).
    var budget: Int { jars.reduce(0) { $0 + $1.budget } }
    var spent: Int { jars.reduce(0) { $0 + $1.spent } }
    /// "Left" = budget − spent.
    var left: Int { budget - spent }
    var billsTotal: Int { bills.reduce(0) { $0 + $1.amount } }

    @MainActor init(txns: [Txn], wallets: [Wallet], jars: [Jar], recurrings: [Recurring], month: DateInterval? = nil,
                    now: Date = .now, calendar: Calendar = .current) {
        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        let month = month ?? calendar.dateInterval(of: .month, for: now)!
        self.month = month
        self.jars = jars.sorted { $0.order < $1.order }.map { j in
            let m = ledger.jarMonth(j.persistentModelID, in: month)
            return JarLine(key: j.parserKey, name: j.name, percent: j.percent, start: m.start, added: m.added, spent: m.spent, balance: m.endBalance)
        }
        unallocated = ledger.unallocated
        income = ledger.income(in: month)
        expectedIncome = recurrings.filter(\.isIncome).map { r in
            let received = BudgetActions.isReceived(r, txns: txns, calendar: calendar)
            let date = received ? BudgetActions.nextDue(after: r.nextDue, r.frequency, day: r.dueDay, calendar: calendar) : r.nextDue
            return Due(name: r.name, amount: r.amount, date: date, isEstimate: r.isEstimate)
        }.sorted { $0.date < $1.date }
        bills = recurrings.filter { !$0.isIncome && $0.nextDue < month.end }.sorted { $0.nextDue < $1.nextDue }
            .map { Due(name: $0.name, amount: $0.amount, date: $0.nextDue, isEstimate: $0.isEstimate) }
    }
}

extension ParserContext {
    /// What the parser should know from the store: wallets, jar and category names, learned merchant rules.
    @MainActor init(_ context: ModelContext, now: Date = .now) {
        self.init()
        currency = Money.defaultCurrency
        self.now = now
        wallets = ((try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))) ?? []).map(\.name)
        let byName = { (pairs: [(String, String)]) in Dictionary(pairs, uniquingKeysWith: { a, _ in a }) }
        jars = byName(((try? context.fetch(FetchDescriptor<Jar>())) ?? []).map { ($0.name, $0.parserKey) })
        categories = byName(((try? context.fetch(FetchDescriptor<Category>())) ?? []).map { ($0.name, $0.parserKey) })
        merchantRules = byName(((try? context.fetch(FetchDescriptor<MerchantRule>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? [])
            .compactMap { r in r.category.map { (r.pattern, $0.parserKey) } })
    }
}

// The parser and tools speak keys; user-made jars/categories have none, so they get one from their name.
// ponytail: renaming a custom category orphans its merchant-rule key text; use a stored UUID if renames matter.
extension Category {
    var parserKey: String { key ?? "category.custom.\(customName ?? "")" }
}

extension Jar {
    var parserKey: String { key ?? "jar.custom.\(customName ?? "")" }
}
